import Foundation
import Testing
@testable import VoiceInput

struct ExternalStatusTests {
    @Test func exportedStatesContainNoDictationOrErrorDetails() throws {
        let phases: [(DictationPhase, String)] = [(.idle, "idle"), (.connecting, "connecting"),
            (.listening, "recording"), (.finalizing, "processing"), (.refining, "processing"),
            (.injecting, "processing"), (.reviewing, "reviewing"), (.error("PRIVATE_ERROR_TEXT"), "error")]
        for (phase, state) in phases {
            let data = try JSONEncoder().encode(ExternalStatusPublisher.Snapshot(phase: phase, enabled: true, pid: 42))
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(fields.keys) == ["version", "pid", "state"])
            #expect(fields["state"] as? String == state)
            #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_ERROR_TEXT"))
        }
        #expect(ExternalStatusPublisher.Snapshot(phase: .listening, enabled: false).state == "disabled")
    }

    @Test func notificationFollowsAtomicSnapshotAndShutdownCannotBeRevived() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        var observed: [String] = []
        let publisher = ExternalStatusPublisher(url: url) {
            let data = try? Data(contentsOf: url)
            let snapshot = data.flatMap { try? JSONDecoder().decode(ExternalStatusPublisher.Snapshot.self, from: $0) }
            observed.append(snapshot?.state ?? "invalid")
        }
        publisher.publish(phase: .listening, enabled: true)
        publisher.publish(phase: .listening, enabled: true)
        publisher.publish(phase: .refining, enabled: true)
        publisher.finish()
        publisher.publish(phase: .idle, enabled: true)
        publisher.waitForPendingWrites()
        #expect(observed == ["recording", "processing", "offline"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
