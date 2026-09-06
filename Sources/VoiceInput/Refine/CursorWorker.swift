import Foundation
import Combine
import Darwin

/// Cancellation belongs to one request, not to the shared Cursor process.
protocol PolishCancellable: AnyObject {
    func cancel()
}

extension AccountCommandTask: PolishCancellable {}

final class CursorRequestTask: PolishCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        action()
    }
}

/// One private Node worker per app. All transport state lives on `queue`;
/// published UI state and client completions are always delivered on main.
final class CursorWorker: ObservableObject, @unchecked Sendable {
    static let shared = CursorWorker()
    @Published private(set) var status = "Cursor is not running."
    @Published private(set) var lastTimingSummary = ""

    struct Configuration: Equatable {
        let executable: URL
        let helper: URL
        let sdkDirectory: URL
    }

    private struct Pending {
        let operation: String
        let startedAt: Date
        let completion: (Result<String, Error>) -> Void
    }

    private let queue = DispatchQueue(label: "VoiceInput.CursorWorker", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "VoiceInput.CursorWorker.Input", qos: .userInitiated)
    private let timeout: TimeInterval
    private let cancellationGrace: TimeInterval
    private let temporaryRoot: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var directory: URL?
    private var configuration: Configuration?
    private var generation = UUID()
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var awaitingCancellation = Set<String>()
    private var warmFingerprint: Int?

    init(timeout: TimeInterval = 60, cancellationGrace: TimeInterval = 2,
         temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.timeout = timeout
        self.cancellationGrace = cancellationGrace
        self.temporaryRoot = temporaryRoot
    }

    @discardableResult
    func request(configuration: Configuration, payload: Data, operation: String = "polish",
                 completion: @escaping (Result<String, Error>) -> Void) -> CursorRequestTask {
        let id = UUID().uuidString
        let task = CursorRequestTask { [weak self] in
            self?.queue.async { self?.cancelRequest(id) }
        }
        queue.async { [self] in
            do {
                guard payload.count <= 1_048_576,
                      let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw AccountCommandError.message("Cursor request exceeded the size limit or was invalid.")
                }
                try self.ensureProcess(configuration)
                self.pending[id] = Pending(operation: operation, startedAt: Date(), completion: completion)
                let generation = self.generation
                try self.send(["id": id, "op": operation, "request": object])
                self.publishStatus(operation == "warmup" ? "Preparing Cursor…" : "Cursor is polishing…")
                self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                    guard let self, self.generation == generation, self.pending[id] != nil else { return }
                    // A stalled shared worker must not trap every later dictation.
                    self.stopWorker(error: .timeout)
                }
            } catch {
                if let request = self.pending.removeValue(forKey: id) {
                    self.complete(request, .failure(error))
                } else {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
        return task
    }

    func prewarm(configuration: Configuration, payload: Data) {
        queue.async { [self] in
            var hasher = Hasher()
            hasher.combine(configuration.executable.path)
            hasher.combine(configuration.sdkDirectory.path)
            hasher.combine(payload)
            let fingerprint = hasher.finalize()
            guard self.warmFingerprint != fingerprint || self.process?.isRunning != true else { return }
            self.warmFingerprint = fingerprint
            self.request(configuration: configuration, payload: payload, operation: "warmup") { [weak self] result in
                switch result {
                case .success:
                    self?.queue.async {
                        guard let self, self.configuration == configuration, self.process?.isRunning == true else { return }
                        self.warmFingerprint = fingerprint
                    }
                case .failure(let error):
                    self?.queue.async { self?.warmFingerprint = nil }
                    self?.publishStatus(error.localizedDescription)
                }
            }
        }
    }

    func shutdown() {
        queue.async { self.stopWorker(error: .cancelled, status: "Cursor is not running.") }
    }

    /// App termination cannot leave the child behind with credentials in RAM.
    /// This bounded join is only used by applicationWillTerminate and tests.
    func shutdownAndWait(timeout: TimeInterval = 2) {
        let child: Process? = queue.sync {
            let child = self.process
            self.stopWorker(error: .cancelled, status: "Cursor is not running.")
            return child
        }
        guard let child else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning && Date() < deadline { usleep(10_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    private func ensureProcess(_ next: Configuration) throws {
        if configuration == next, process?.isRunning == true { return }
        stopWorker(error: .message("Cursor runtime changed. Retry polish."))
        let cwd = temporaryRoot.appendingPathComponent("voiceinput-cursor-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = next.executable
        child.arguments = [next.helper.path, "--worker"]
        child.currentDirectoryURL = cwd
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment.merge(CursorPolishClient.workerEnvironment(directory: cwd)) { _, new in new }
        child.environment = environment
        let current = UUID()
        generation = current
        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.receive(data, generation: current) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // SDK diagnostics can contain keys, prompts, or account details.
            // Drain without exposing or retaining them.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] _ in
            // Each process owns its temporary directory, even if it was retired
            // and replaced before its termination callback arrived.
            try? FileManager.default.removeItem(at: cwd)
            self?.queue.async {
                guard let self, self.generation == current else { return }
                self.stopWorker(error: .message("Cursor stopped unexpectedly. The next request will restart it."))
            }
        }
        do { try child.run() }
        catch {
            stdoutHandle.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: cwd)
            throw AccountCommandError.message("Could not start Node. Check the Cursor runtime path in Providers.")
        }
        // Never block the transport queue behind a large write or a stalled JS loop.
        let fd = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        process = child
        input = stdin
        output = stdout
        errorOutput = stderr
        directory = cwd
        configuration = next
        buffer.removeAll(keepingCapacity: true)
    }

    private func send(_ object: [String: Any]) throws {
        guard let process, process.isRunning, let handle = input?.fileHandleForWriting else {
            throw AccountCommandError.message("Cursor is not running. Retry polish.")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 1_052_672 else {
            throw AccountCommandError.message("Cursor request exceeded the size limit.")
        }
        data.append(10)
        let current = generation
        writerQueue.async { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            let fd = handle.fileDescriptor
            let written = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count && process.isRunning && Date() < deadline {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(8192, bytes.count - offset))
                    if count > 0 { offset += count }
                    else if errno == EAGAIN || errno == EINTR { usleep(5_000) }
                    else { return false }
                }
                return offset == bytes.count
            }
            if !written {
                self?.queue.async {
                    guard let self, self.generation == current else { return }
                    self.stopWorker(error: .message("Cursor stopped accepting requests. Retry polish."))
                }
            }
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        guard !data.isEmpty else { return } // terminationHandler owns EOF failure.
        buffer.append(data)
        guard buffer.count <= 1_052_672 else {
            stopWorker(error: .message("Cursor output exceeded the size limit."))
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = reply["id"] as? String, let ok = reply["ok"] as? Bool else {
                stopWorker(error: .message("Cursor returned an invalid worker response."))
                return
            }
            let cancelled = awaitingCancellation.remove(id) != nil
            guard let request = pending.removeValue(forKey: id) else {
                if cancelled && pending.isEmpty { publishStatus("Cursor is ready · runtime stays warm.") }
                continue
            }
            if ok {
                if request.operation == "warmup" {
                    complete(request, .success(""))
                } else if let text = reply["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    publishTimings(reply["timings"] as? [String: Any], elapsed: Date().timeIntervalSince(request.startedAt))
                    complete(request, .success(text))
                } else {
                    complete(request, .failure(AccountCommandError.message("Cursor returned no complete polish text.")))
                }
            } else {
                complete(request, .failure(Self.error(for: reply["error"] as? String)))
            }
            if reply["retire"] as? Bool == true {
                stopWorker(error: .message("Cursor runtime is restarting. Retry polish."),
                           status: "Cursor connection will restart for the next request.")
                return
            }
            publishStatus(pending.values.contains { $0.operation == "polish" } ? "Cursor is polishing…" : "Cursor is ready · runtime stays warm.")
        }
    }

    private func cancelRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        complete(request, .failure(AccountCommandError.cancelled))
        awaitingCancellation.insert(id)
        do { try send(["id": id, "op": "cancel"]) }
        catch { stopWorker(error: .message("Cursor did not accept cancellation. Retry polish.")); return }
        let current = generation
        queue.asyncAfter(deadline: .now() + cancellationGrace) {
            guard self.generation == current, self.awaitingCancellation.contains(id) else { return }
            self.stopWorker(error: .message("Cursor did not stop the cancelled request. Its runtime will restart."))
        }
    }

    private func stopWorker(error: AccountCommandError, status: String? = nil) {
        let child = process
        let stdin = input
        generation = UUID()
        process = nil
        configuration = nil
        warmFingerprint = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        input = nil
        output = nil
        errorOutput = nil
        directory = nil
        buffer.removeAll(keepingCapacity: false)
        awaitingCancellation.removeAll()
        let abandoned = Array(pending.values)
        pending.removeAll()
        for request in abandoned { complete(request, .failure(error)) }
        // EOF triggers the worker's normal disposal. SIGTERM and a bounded kill
        // also cover a worker whose event loop is stuck. No Login Item/daemon.
        writerQueue.async { try? stdin?.fileHandleForWriting.close() }
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        publishStatus(status ?? error.localizedDescription)
    }

    private func complete(_ request: Pending, _ result: Result<String, Error>) {
        DispatchQueue.main.async { request.completion(result) }
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    private func publishTimings(_ timings: [String: Any]?, elapsed: TimeInterval) {
        let preparation = ["sdkLoadMs", "prewarmMs", "agentCreateMs"].reduce(0.0) { sum, key in
            sum + ((timings?[key] as? NSNumber)?.doubleValue ?? 0)
        }
        var summary = String(format: "Last polish: %.2f s total · %.2f s preparation", elapsed, preparation / 1000)
        if let first = (timings?["firstTokenMs"] as? NSNumber)?.doubleValue {
            summary += String(format: " · %.2f s to first text", first / 1000)
        }
        DispatchQueue.main.async { [weak self] in self?.lastTimingSummary = summary }
    }

    private static func error(for code: String?) -> AccountCommandError {
        switch code {
        case "cancelled": return .cancelled
        case "timeout": return .timeout
        case "node_version": return .message("Cursor requires Node.js 22.13 or newer.")
        case "sdk_missing", "sdk_version": return .message("Install Cursor SDK 1.0.31 in Providers.")
        case "incomplete": return .message("Cursor did not finish its polish response. Your original text is preserved.")
        case "authentication": return .message("Cursor rejected authentication (401). Check whether the User API key has expired or been revoked.")
        case "permission": return .message("Cursor denied access (403). Check this account's model or team permissions.")
        case "rate_limit": return .message("Cursor reported a request or usage limit. Try again later or check usage in Cursor Dashboard.")
        case "model_configuration": return .message("Cursor rejected the model or its parameters. Refresh the model list and select it again.")
        case "network", "temporary": return .message("Cursor had a temporary connection or service failure. Your original text is preserved.")
        case "busy": return .message("Cursor's request queue is full. Try again after the current request finishes.")
        case "worker_unhealthy": return .message("Cursor's local runtime needs to restart. Retry polish; your original text is preserved.")
        default: return .message("Cursor failed without a classified cause (request_failed). Your original text is preserved; this does not establish an API key problem.")
        }
    }
}
