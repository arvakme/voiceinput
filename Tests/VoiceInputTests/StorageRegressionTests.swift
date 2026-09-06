import Foundation
import Testing
@testable import VoiceInput

@MainActor
struct StorageRegressionTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceinput-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func record(audioFilename: String?) -> HistoryRecord {
        HistoryRecord(id: UUID(), date: Date(), durationSeconds: 1,
                      backend: "test", rawTranscript: "original", refinedTranscript: nil,
                      injected: false, audioFilename: audioFilename, correctedTranscript: nil)
    }

    private func write(_ records: [HistoryRecord], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: directory.appendingPathComponent("history.json"))
    }

    @Test
    func testCorruptHistoryPreservesAudioAndOriginalFileAcrossMutations() throws {
        try withDirectory { directory in
            let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let audio = audioDirectory.appendingPathComponent("recoverable.wav")
            try Data([1, 2, 3]).write(to: audio)
            let history = directory.appendingPathComponent("history.json")
            let damaged = Data("{truncated history".utf8)
            try damaged.write(to: history)
            let store = HistoryStore(baseDirectory: directory, observesSettings: false)
            store.waitForPendingWrites(timeout: 5)
            #expect(FileManager.default.fileExists(atPath: audio.path))
            store.updateCorrection(id: UUID(), corrected: "must not replace damaged data")
            store.delete([UUID()])
            store.clearAll()
            store.waitForPendingWrites(timeout: 5)
            #expect(try Data(contentsOf: history) == damaged)
            #expect(try Data(contentsOf: audio) == Data([1, 2, 3]))
        }
    }

    @Test
    func testEmptyHistoryFileDoesNotAuthorizeAudioCleanup() throws {
        try withDirectory { directory in
            let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let audio = audioDirectory.appendingPathComponent("recoverable.wav")
            try Data([1]).write(to: audio)
            try Data().write(to: directory.appendingPathComponent("history.json"))
            let store = HistoryStore(baseDirectory: directory, observesSettings: false)
            store.waitForPendingWrites(timeout: 5)
            #expect(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    @Test
    func testValidHistoryStillCleansOrphans() throws {
        try withDirectory { directory in
            let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let retained = audioDirectory.appendingPathComponent("retained.wav")
            let orphan = audioDirectory.appendingPathComponent("orphan.wav")
            try Data([1]).write(to: retained)
            try Data([2]).write(to: orphan)
            try write([record(audioFilename: "retained.wav")], to: directory)
            let store = HistoryStore(baseDirectory: directory, observesSettings: false)
            store.waitForPendingWrites(timeout: 5)
            #expect(FileManager.default.fileExists(atPath: retained.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test
    func testAudioResolutionRejectsPathsAndPreservesBasenames() throws {
        try withDirectory { directory in
            let store = HistoryStore(baseDirectory: directory, observesSettings: false)
            for filename in ["../outside.wav", "/tmp/outside.wav", "sub/audio.wav", ".", "..", "", "sub\\audio.wav"] {
                #expect(store.audioURL(for: record(audioFilename: filename)) == nil)
            }
            #expect(store.audioURL(for: record(audioFilename: "valid.wav")) ==
                    directory.appendingPathComponent("audio/valid.wav"))
            store.waitForPendingWrites(timeout: 5)
        }
    }

    @Test
    func testClearHistoryCannotDeleteFileOutsideAudioDirectory() throws {
        try withDirectory { directory in
            let outside = directory.appendingPathComponent("outside.wav")
            try Data([4, 5, 6]).write(to: outside)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("audio"),
                                                    withIntermediateDirectories: true)
            try write([record(audioFilename: "../outside.wav")], to: directory)
            let store = HistoryStore(baseDirectory: directory, observesSettings: false)
            store.clearAll()
            store.waitForPendingWrites(timeout: 5)
            #expect(try Data(contentsOf: outside) == Data([4, 5, 6]))
            let remaining = try JSONDecoder().decode([HistoryRecord].self,
                from: Data(contentsOf: directory.appendingPathComponent("history.json")))
            #expect(remaining.isEmpty)
        }
    }

    @Test
    func testCustomOnlyPresetSettingsRestoreDailyBeforeDeletion() throws {
        let suiteName = "voiceinput-preset-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = PolishPreset(name: "Custom", icon: "star", systemPrompt: "Test")
        let encoded = try JSONEncoder().encode([custom])
        defaults.set(String(decoding: encoded, as: UTF8.self), forKey: "polishPresetsJSON")
        defaults.set(custom.id.uuidString, forKey: "selectedPolishPresetID")
        let store = PolishPresetStore(defaults: defaults)
        #expect(store.selected.id == custom.id)
        #expect(store.presets.contains { $0.id == PolishPresetStore.dailyID })
        store.remove(custom.id)
        #expect(store.selected.id == PolishPresetStore.dailyID)
        #expect(store.presets.count == 1)
        // The published array is mutable, so selected must remain safe even
        // when an external binding replaces it with an empty list.
        store.presets = []
        #expect(store.selected.id == PolishPresetStore.dailyID)
    }

}
