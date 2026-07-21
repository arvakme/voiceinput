import Foundation

// MARK: - CorrectionStore

/// Gold-standard training data captured from the post-dictation review box:
/// every time the user edits the just-injected text, we log
/// {raw ASR output, what got injected, what they corrected it to, backend} as
/// one JSON line. Deliberately separate from `HistoryStore` — this is an
/// ever-growing, append-only corpus meant for future vocabulary/prompt
/// tuning, not a bounded, prunable session log.
///
/// Storage: `~/Library/Application Support/VoiceInput/corrections.jsonl`.
final class CorrectionStore {
    static let shared = CorrectionStore()

    private struct CorrectionRecord: Codable {
        let date: Date
        let raw: String
        let injected: String
        let corrected: String
        let backend: String
    }

    /// Serializes all file I/O — both the append and the weekly-count read —
    /// so a `countThisWeek()` call always sees a consistent file, never a
    /// half-written line from a concurrent `append`.
    private let io = DispatchQueue(label: "com.zhijie.VoiceInput.corrections.io", qos: .utility)
    private let fileManager = FileManager.default

    /// Cached weekly count. Mutated only on `io` (both from `append`'s
    /// invalidation and from `countThisWeek`'s recompute), so it never needs
    /// its own lock. The file stays small (one short line per correction), so
    /// re-parsing it after every append is cheap.
    private var cachedWeeklyCount: Int?

    private init() {}

    // MARK: - Locations

    private var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
    }

    private var fileURL: URL {
        baseDirectory.appendingPathComponent("corrections.jsonl", isDirectory: false)
    }

    // MARK: - Append

    /// Appends one correction as a JSON line. Safe to call from any thread.
    func append(raw: String, injected: String, corrected: String, backend: String) {
        let record = CorrectionRecord(date: Date(), raw: raw, injected: injected, corrected: corrected, backend: backend)
        io.async { [weak self] in
            guard let self else { return }
            self.appendOnQueue(record)
            self.cachedWeeklyCount = nil
        }
    }

    /// `io`-confined: creates the directory/file if needed and atomically
    /// appends one line via `FileHandle.seekToEndOfFile`.
    private func appendOnQueue(_ record: CorrectionRecord) {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            } catch {
                Log.app.error("CorrectionStore: failed to create directory: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else {
            Log.app.error("CorrectionStore: failed to encode correction record")
            return
        }
        var line = data
        line.append(0x0A) // "\n"

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } catch {
            Log.app.error("CorrectionStore: failed to append: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Weekly count

    /// Number of corrections recorded in the last 7 days. Blocks the caller
    /// briefly on `io` (serialized with `append`); cheap since the file is
    /// small. Cached after the first read until the next `append`.
    func countThisWeek() -> Int {
        io.sync {
            if let cachedWeeklyCount { return cachedWeeklyCount }
            let count = readCountThisWeekOnQueue()
            cachedWeeklyCount = count
            return count
        }
    }

    private func readCountThisWeekOnQueue() -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        var count = 0
        for lineData in data.split(separator: 0x0A) where !lineData.isEmpty {
            guard let record = try? decoder.decode(CorrectionRecord.self, from: lineData) else { continue }
            if record.date >= cutoff { count += 1 }
        }
        return count
    }
}
