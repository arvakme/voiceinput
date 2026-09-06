import Foundation
import Testing
import Darwin
@testable import VoiceInput

@Suite(.serialized)
@MainActor
struct CursorWorkerTests {
    @Test func reusesOneProcessAndKeepsRequestPayloadsIndependent() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.close() }
        let first = try await fixture.call(text: "第一段 \"API\"\n$(not a command)").get()
        let second = try await fixture.call(text: "独立的第二段").get()
        #expect(first.split(separator: "|", maxSplits: 1).first == second.split(separator: "|", maxSplits: 1).first)
        #expect(first.hasSuffix("第一段 \"API\"\n$(not a command)"))
        #expect(second.hasSuffix("独立的第二段"))
        #expect(!second.contains("第一段"))
        #expect(fixture.worker.lastTimingSummary.contains("total"))
    }

    @Test func cancellingOneRequestDoesNotCancelAnotherOrDeliverTwice() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.close() }
        var cancelled: [Result<String, Error>] = []
        var other: [Result<String, Error>] = []
        let task = fixture.worker.request(configuration: fixture.configuration,
            payload: try fixture.payload("cancel me", behavior: "slow")) { cancelled.append($0) }
        fixture.worker.request(configuration: fixture.configuration,
            payload: try fixture.payload("keep me")) { other.append($0) }
        task.cancel()
        task.cancel()
        try await waitUntil { cancelled.count == 1 && other.count == 1 }
        #expect(try other[0].get().hasSuffix("keep me"))
        if case .failure(let error) = cancelled[0] {
            #expect((error as? AccountCommandError)?.localizedDescription == AccountCommandError.cancelled.localizedDescription)
        } else { Issue.record("Cancellation returned polished text") }
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(cancelled.count == 1)
        #expect(other.count == 1)
        #expect(try await fixture.call(text: "still usable").get().hasSuffix("still usable"))
    }

    @Test func timeoutRestartsWorkerInsteadOfBlockingFutureDictations() async throws {
        let fixture = try WorkerFixture(timeout: 0.5)
        defer { fixture.close() }
        let first = try await fixture.call(text: "initial").get()
        let timedOut = await fixture.call(text: "never delivered", behavior: "hang")
        if case .failure(let error) = timedOut {
            #expect((error as? AccountCommandError)?.localizedDescription == AccountCommandError.timeout.localizedDescription)
        } else { Issue.record("Hung request did not time out") }
        let later = try await fixture.call(text: "recovered").get()
        #expect(first.split(separator: "|").first != later.split(separator: "|").first)
        #expect(later.hasSuffix("recovered"))
    }

    @Test func malformedOrCrashedWorkerFailsWithoutExposingOutputAndRecovers() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.close() }
        for behavior in ["malformed", "crash"] {
            let result = await fixture.call(text: "PRIVATE_FIXTURE_TEXT", behavior: behavior)
            if case .failure(let error) = result {
                #expect(!error.localizedDescription.contains("PRIVATE_FIXTURE_TEXT"))
                #expect(!error.localizedDescription.contains("FAKE_SECRET"))
            } else { Issue.record("Invalid worker produced a successful dictation") }
            #expect(try await fixture.call(text: "recovered").get().hasSuffix("recovered"))
        }
    }

    @Test func retiredWorkerDeliversCompletedTextThenRestartsBeforeNextRequest() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.close() }
        let completed = try await fixture.call(text: "preserved", behavior: "retire").get()
        #expect(completed.hasSuffix("preserved"))
        let next = try await fixture.call(text: "next").get()
        #expect(completed.split(separator: "|").first != next.split(separator: "|").first)
        #expect(next.hasSuffix("next"))
    }

    @Test func warmupUsesNoPolishAndShutdownRemovesChildAndTemporaryFiles() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.close() }
        fixture.worker.prewarm(configuration: fixture.configuration, payload: try fixture.payload("unused"))
        try await waitUntil { fixture.worker.status.contains("ready") }
        let result = try await fixture.call(text: "first", behavior: "count").get()
        let parts = result.split(separator: "|")
        let pid = try #require(Int32(parts[0]))
        #expect(parts.last == "1")
        fixture.worker.shutdownAndWait()
        try await waitUntil {
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
                .filter { $0.hasPrefix("voiceinput-cursor-worker-") }.isEmpty) == true
        }
        #expect(kill(pid, 0) != 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition(), "Worker fixture did not finish within three seconds")
    }
}

@MainActor
private final class WorkerFixture {
    let directory: URL
    let worker: CursorWorker
    let configuration: CursorWorker.Configuration

    init(timeout: TimeInterval = 3) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceinput-worker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-worker.mjs")
        try Self.script.write(to: helper, atomically: true, encoding: .utf8)
        let node = try #require(CursorPolishClient.nodeExecutable(override: ""), "Worker tests require installed Node.js")
        configuration = CursorWorker.Configuration(executable: node, helper: helper, sdkDirectory: directory)
        worker = CursorWorker(timeout: timeout, cancellationGrace: 0.25, temporaryRoot: directory)
    }

    func payload(_ text: String, behavior: String = "normal") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["text": text, "behavior": behavior,
                                                    "apiKey": "FAKE_SECRET", "sdkDirectory": directory.path])
    }

    func call(text: String, behavior: String = "normal") async -> Result<String, Error> {
        do {
            let data = try payload(text, behavior: behavior)
            return await withCheckedContinuation { continuation in
                worker.request(configuration: configuration, payload: data) { result in
                    #expect(Thread.isMainThread)
                    continuation.resume(returning: result)
                }
            }
        } catch { return .failure(error) }
    }

    func close() {
        worker.shutdownAndWait()
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
        import { createInterface } from 'node:readline';
        const timers = new Map();
        let count = 0;
        const write = reply => process.stdout.write(JSON.stringify(reply) + '\n');
        const input = createInterface({ input: process.stdin });
        input.on('line', line => {
          const {id, op, request = {}} = JSON.parse(line);
          if (op === 'warmup') { write({id, ok:true}); return; }
          if (op === 'cancel') {
            clearTimeout(timers.get(id)); timers.delete(id);
            write({id, ok:false, error:'cancelled'}); return;
          }
          if (op === 'shutdown') { write({id, ok:true}); process.exit(0); }
          count++;
          if (request.behavior === 'hang') return;
          if (request.behavior === 'crash') process.exit(9);
          if (request.behavior === 'malformed') {
            process.stdout.write('FAKE_SECRET PRIVATE_FIXTURE_TEXT\n'); return;
          }
          const value = request.behavior === 'count' ? String(count) : request.text;
          const reply = () => {
            timers.delete(id);
            write({id, ok:true, retire:request.behavior === 'retire', text:process.pid + '|' + value,
                   timings:{sdkLoadMs:0,prewarmMs:0,agentCreateMs:1,firstTokenMs:2,totalMs:3}});
          };
          if (request.behavior === 'slow') timers.set(id, setTimeout(reply, 300));
          else reply();
        });
        input.on('close', () => process.exit(0));
        """#
}
