import Foundation
import Combine

// MARK: - HistoryRecord

/// One persisted dictation session: its transcripts, timing, backend, whether
/// the text was injected, and the name of an accompanying WAV file (when audio
/// was kept). `audioFilename` is just the basename inside the `audio/` subdir.
struct HistoryRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let backend: String
    let rawTranscript: String
    let refinedTranscript: String?
    let injected: Bool
    let audioFilename: String?
    /// The user's post-dictation review edit, when they corrected the
    /// injected text. Optional so pre-existing `history.json` files (written
    /// before this field existed) still decode.
    let correctedTranscript: String?

    /// The most polished transcript available: refined when present and
    /// non-empty, otherwise the raw transcript.
    var bestTranscript: String {
        if let refined = refinedTranscript,
           !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return refined
        }
        return rawTranscript
    }
}

// MARK: - HistoryStore

/// Owns the dictation history: a list of `HistoryRecord`s plus their WAV files.
///
/// Storage lives under `~/Library/Application Support/VoiceInput/`:
///   - `history.json` — the array of records (atomic writes).
///   - `audio/<uuid>.wav` — one WAV per record that kept audio.
///
/// The `@Published records` array only ever mutates on the main thread; all
/// file I/O happens on a private serial background queue so the UI never blocks.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Newest first. Mutated only on the main thread.
    @Published private(set) var records: [HistoryRecord] = []

    private let io = DispatchQueue(label: "com.zhijie.VoiceInput.history.io", qos: .utility)
    private let fileManager = FileManager.default

    private init() {
        loadInitial()
    }

    // MARK: - Locations

    /// `~/Library/Application Support/VoiceInput/`
    private var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
    }

    /// `…/VoiceInput/audio/`
    private var audioDirectory: URL {
        baseDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    /// `…/VoiceInput/history.json`
    private var historyFileURL: URL {
        baseDirectory.appendingPathComponent("history.json", isDirectory: false)
    }

    /// Ensures the base and audio directories exist. Safe to call repeatedly.
    private func ensureDirectories() {
        for dir in [baseDirectory, audioDirectory] {
            if !fileManager.fileExists(atPath: dir.path) {
                do {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    Log.app.error("History: failed to create directory \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Resolve the on-disk URL for a record's audio, if the record claims to
    /// have one. This trusts `audioFilename` and does NOT touch the filesystem,
    /// so it is safe to call from the main thread during SwiftUI rendering — a
    /// stalled or networked volume can make `fileExists` block and drop frames.
    /// If the file turns out to be missing, `AVAudioPlayer` load fails
    /// gracefully and the transport simply shows a zero-length track.
    func audioURL(for record: HistoryRecord) -> URL? {
        guard let filename = record.audioFilename, !filename.isEmpty else { return nil }
        return audioDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - Loading

    /// Loads `history.json` lazily at init on the background queue, then
    /// publishes the parsed records on the main thread.
    private func loadInitial() {
        io.async { [weak self] in
            guard let self else { return }
            let loaded = self.readRecordsFromDisk()
            DispatchQueue.main.async {
                self.records = loaded
            }
        }
    }

    private func readRecordsFromDisk() -> [HistoryRecord] {
        guard fileManager.fileExists(atPath: historyFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: historyFileURL)
            guard !data.isEmpty else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([HistoryRecord].self, from: data)
            // Newest first regardless of on-disk order.
            return decoded.sorted { $0.date > $1.date }
        } catch {
            Log.app.error("History: failed to read history.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Recording

    /// Append a new session to the history.
    ///
    /// Respects `AppSettings.shared.historyEnabled` (skips entirely when off)
    /// and `historyKeepAudio` (drops the audio when off). After insertion the
    /// list is pruned to `historyMaxSessions`, deleting the audio files of any
    /// records that fall off the end.
    ///
    /// Safe to call from any thread. Returns the new record's id immediately
    /// (even though the write itself completes asynchronously) so callers can
    /// later target it with `updateCorrection(id:corrected:)`.
    @discardableResult
    func record(raw: String,
                refined: String?,
                durationSeconds: Double,
                backend: String,
                injected: Bool,
                audioWAV: Data?) -> UUID {
        let id = UUID()
        let settings = AppSettings.shared
        guard settings.historyEnabled else { return id }

        let keepAudio = settings.historyKeepAudio
        let maxSessions = max(0, settings.historyMaxSessions)

        // A zero cap means "keep nothing": short-circuit before doing any audio
        // write or disk work so we never pay for a pointless write-then-delete.
        guard maxSessions > 0 else { return id }

        let audioData: Data? = (keepAudio && (audioWAV?.isEmpty == false)) ? audioWAV : nil
        let audioFilename: String? = audioData != nil ? "\(id.uuidString).wav" : nil

        let newRecord = HistoryRecord(
            id: id,
            date: Date(),
            durationSeconds: durationSeconds,
            backend: backend,
            rawTranscript: raw,
            refinedTranscript: refined,
            injected: injected,
            audioFilename: audioFilename,
            correctedTranscript: nil
        )

        io.async { [weak self] in
            guard let self else { return }
            self.ensureDirectories()

            // Write audio first; if that fails, fall back to a no-audio record.
            var effectiveRecord = newRecord
            if let audioData, let filename = audioFilename {
                let audioURL = self.audioDirectory.appendingPathComponent(filename, isDirectory: false)
                do {
                    try audioData.write(to: audioURL, options: .atomic)
                } catch {
                    Log.app.error("History: failed to write audio \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    effectiveRecord = HistoryRecord(
                        id: newRecord.id,
                        date: newRecord.date,
                        durationSeconds: newRecord.durationSeconds,
                        backend: newRecord.backend,
                        rawTranscript: newRecord.rawTranscript,
                        refinedTranscript: newRecord.refinedTranscript,
                        injected: newRecord.injected,
                        audioFilename: nil,
                        correctedTranscript: nil
                    )
                }
            }

            // Build the new list (newest first) and prune the overflow.
            var current = self.readRecordsFromDisk()
            current.insert(effectiveRecord, at: 0)
            current.sort { $0.date > $1.date }

            var pruned = current
            if pruned.count > maxSessions {
                let overflow = Array(pruned[maxSessions...])
                pruned = Array(pruned[0..<maxSessions])
                for record in overflow {
                    self.deleteAudioFile(for: record)
                }
            }

            self.writeRecordsToDisk(pruned)

            DispatchQueue.main.async {
                self.records = pruned
            }
        }

        return id
    }

    /// Applies a post-dictation review edit to the record with `id`: mutates
    /// its `correctedTranscript` and persists. Safe to call from any thread.
    /// A no-op (logged) if the record isn't found — e.g. history was disabled
    /// or cleared between recording and the review completing.
    func updateCorrection(id: UUID, corrected: String) {
        io.async { [weak self] in
            guard let self else { return }
            var current = self.readRecordsFromDisk()
            guard let index = current.firstIndex(where: { $0.id == id }) else {
                Log.app.info("History: updateCorrection found no record for id \(id, privacy: .public)")
                return
            }
            let old = current[index]
            current[index] = HistoryRecord(
                id: old.id,
                date: old.date,
                durationSeconds: old.durationSeconds,
                backend: old.backend,
                rawTranscript: old.rawTranscript,
                refinedTranscript: old.refinedTranscript,
                injected: old.injected,
                audioFilename: old.audioFilename,
                correctedTranscript: corrected
            )
            self.writeRecordsToDisk(current)

            DispatchQueue.main.async {
                self.records = current
            }
        }
    }

    // MARK: - Deletion

    /// Delete the records with the given ids, including their audio files.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        io.async { [weak self] in
            guard let self else { return }
            var current = self.readRecordsFromDisk()
            let toDelete = current.filter { ids.contains($0.id) }
            for record in toDelete {
                self.deleteAudioFile(for: record)
            }
            current.removeAll { ids.contains($0.id) }
            self.writeRecordsToDisk(current)

            DispatchQueue.main.async {
                self.records = current
            }
        }
    }

    /// Delete every record and every audio file.
    func clearAll() {
        io.async { [weak self] in
            guard let self else { return }
            let current = self.readRecordsFromDisk()
            for record in current {
                self.deleteAudioFile(for: record)
            }
            self.writeRecordsToDisk([])

            DispatchQueue.main.async {
                self.records = []
            }
        }
    }

    // MARK: - Disk helpers (background queue only)

    private func writeRecordsToDisk(_ records: [HistoryRecord]) {
        ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            Log.app.error("History: failed to write history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteAudioFile(for record: HistoryRecord) {
        guard let filename = record.audioFilename, !filename.isEmpty else { return }
        let url = audioDirectory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Log.app.error("History: failed to delete audio \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
