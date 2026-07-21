import Foundation

// MARK: - SessionStatsStore

/// The correction-rate curve — the user's "graduation metric": the day they
/// stop editing transcripts is the day ASR quality has won. Every resolved
/// dictation session (one hotkey press through to its final outcome — inject,
/// review-apply, or review-abandon) appends exactly one line recording
/// whether the text ultimately landed in the target app and whether the user
/// corrected it first. Deliberately separate from `CorrectionStore` (which
/// keeps the actual before/after text as training data) and from
/// `HistoryStore` (bounded, prunable transcripts) — this is a small, permanent
/// tally meant only for the rate.
///
/// Storage: `~/Library/Application Support/VoiceInput/session-stats.jsonl`.
final class SessionStatsStore {
    static let shared = SessionStatsStore()

    private struct SessionStatRecord: Codable {
        let date: Date
        let injected: Bool
        let corrected: Bool
    }

    /// Serializes all file I/O — the append and every read — so a read always
    /// sees a consistent file, never a half-written line from a concurrent
    /// `append`.
    private let io = DispatchQueue(label: "com.zhijie.VoiceInput.sessionStats.io", qos: .utility)
    private let fileManager = FileManager.default

    /// Cached parse of the whole file. `nil` means "needs a re-read from
    /// disk". Mutated only on `io`, so it never needs its own lock. The file
    /// stays small (one short line per session), so re-parsing it after every
    /// append is cheap.
    private var cachedRecords: [SessionStatRecord]?

    private init() {}

    // MARK: - Locations

    private var baseDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
    }

    private var fileURL: URL {
        baseDirectory.appendingPathComponent("session-stats.jsonl", isDirectory: false)
    }

    // MARK: - Append

    /// Appends one resolved session's outcome as a JSON line. Safe to call
    /// from any thread; call exactly once per resolved session (see
    /// `DictationController`'s review/inject exit paths — cancelled sessions
    /// and empty transcripts never call this at all).
    func append(injected: Bool, corrected: Bool) {
        let record = SessionStatRecord(date: Date(), injected: injected, corrected: corrected)
        io.async { [weak self] in
            guard let self else { return }
            self.appendOnQueue(record)
            self.cachedRecords = nil
        }
    }

    /// `io`-confined: creates the directory/file if needed and atomically
    /// appends one line via `FileHandle.seekToEndOfFile`.
    private func appendOnQueue(_ record: SessionStatRecord) {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            } catch {
                Log.app.error("SessionStatsStore: failed to create directory: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else {
            Log.app.error("SessionStatsStore: failed to encode session stat record")
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
            Log.app.error("SessionStatsStore: failed to append: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reads

    /// `io`-confined: returns the cached parse, re-reading the file first if
    /// the cache was invalidated by an `append`.
    private func loadRecordsOnQueue() -> [SessionStatRecord] {
        if let cachedRecords { return cachedRecords }
        let records = readRecordsFromDiskOnQueue()
        cachedRecords = records
        return records
    }

    private func readRecordsFromDiskOnQueue() -> [SessionStatRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [SessionStatRecord] = []
        records.reserveCapacity(64)
        for lineData in data.split(separator: 0x0A) where !lineData.isEmpty {
            guard let record = try? decoder.decode(SessionStatRecord.self, from: lineData) else { continue }
            records.append(record)
        }
        return records
    }

    /// Per-calendar-day counts for the trailing `days` days (oldest first,
    /// today last) — a fixed-length series suitable for driving a bar chart
    /// even on days with no sessions at all. `injected`/`corrected` mirror the
    /// per-record fields: sessions that were abandoned before ever reaching
    /// the target app (declined "before"-mode review) count toward neither.
    func dailyStats(days: Int) -> [(day: Date, injected: Int, corrected: Int)] {
        io.sync {
            let records = loadRecordsOnQueue()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            var buckets: [Date: (injected: Int, corrected: Int)] = [:]
            for record in records {
                let day = calendar.startOfDay(for: record.date)
                var bucket = buckets[day] ?? (injected: 0, corrected: 0)
                if record.injected { bucket.injected += 1 }
                if record.corrected { bucket.corrected += 1 }
                buckets[day] = bucket
            }

            var series: [(day: Date, injected: Int, corrected: Int)] = []
            series.reserveCapacity(max(0, days))
            for offset in stride(from: days - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let bucket = buckets[day] ?? (injected: 0, corrected: 0)
                series.append((day: day, injected: bucket.injected, corrected: bucket.corrected))
            }
            return series
        }
    }

    /// Rolling 7-day totals (not calendar-week) — `injected` is the
    /// denominator for the correction rate (sessions that actually delivered
    /// text), `corrected` the numerator (how many of those the user edited
    /// before/after delivery).
    func weekStats() -> (injected: Int, corrected: Int) {
        io.sync {
            let records = loadRecordsOnQueue()
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            var injected = 0
            var corrected = 0
            for record in records where record.date >= cutoff {
                if record.injected { injected += 1 }
                if record.corrected { corrected += 1 }
            }
            return (injected: injected, corrected: corrected)
        }
    }
}
