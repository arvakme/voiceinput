import Foundation

/// Lightweight connectivity smoke-tests for the two ASR providers: open the
/// real WebSocket, send the real handshake/config frame, and report whether
/// the server accepted it — without touching the microphone or `AudioCapture`.
///
/// Streaming ASR has no request/response round trip the way Polish's
/// chat-completions call does: a healthy session just sits there waiting for
/// audio. Success requires a completed config send (or a valid server response);
/// it never means microphone capture or speech recognition was verified.
enum ASRConnectionTester {
    /// `Result`'s failure type must conform to `Error` — `String` alone
    /// doesn't, so this just wraps one for display. `ExpressibleByStringLiteral`
    /// keeps the `.failure("...")` call sites below terse.
    struct ConnectionError: Error, CustomStringConvertible, ExpressibleByStringLiteral {
        let message: String
        init(_ message: String) { self.message = message }
        init(stringLiteral value: String) { self.message = value }
        var description: String { message }
    }

    private static let window: TimeInterval = 4

    final class Progress {
        private let lock = NSLock()
        private var configSent = false

        func didSendConfig() {
            lock.lock(); defer { lock.unlock() }
            configSent = true
        }

        func timeoutResult() -> Result<String, ConnectionError> {
            lock.lock(); defer { lock.unlock() }
            return configSent
                ? .success("Config sent; no error observed. Microphone and transcription not tested.")
                : .failure("Connection timed out before config could be sent. Check network/proxy access.")
        }
    }

    static func testSoniox(apiKey: String, model: String, completion: @escaping (Result<String, ASRConnectionTester.ConnectionError>) -> Void) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            completion(.failure("API key is empty"))
            return
        }

        let task = URLSession.shared.webSocketTask(with: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        let finish = makeFinisher(task: task, completion: completion)
        let progress = Progress()

        let config: [String: Any] = [
            "api_key": trimmedKey,
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SonioxDefaults.realtimeModel : model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            finish(.failure("Failed to encode config"))
            return
        }

        task.resume()
        task.send(.string(json)) { error in
            if let error { finish(.failure(ConnectionError(error.localizedDescription))) }
            else { progress.didSendConfig() }
        }

        receiveSonioxResponse(task: task, finish: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            finish(progress.timeoutResult())
        }
    }

    private static func receiveSonioxResponse(task: URLSessionWebSocketTask, finish: @escaping (Result<String, ASRConnectionTester.ConnectionError>) -> Void) {
        task.receive { result in
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:    text = ""
                }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    finish(.failure("Invalid server response"))
                    return
                }
                if let errorCode = obj["error_code"] as? Int {
                    let message = obj["error_message"] as? String ?? "error \(errorCode)"
                    finish(.failure(ConnectionError(message)))
                } else {
                    finish(.success("Server responded. Microphone and transcription not tested."))
                }
            case .failure(let error):
                finish(.failure(ConnectionError(error.localizedDescription)))
            }
        }
    }

    static func testDoubao(apiKey: String, resourceId: String, completion: @escaping (Result<String, ASRConnectionTester.ConnectionError>) -> Void) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            completion(.failure("API key is empty"))
            return
        }

        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        let trimmedResourceId = resourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(trimmedKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(trimmedResourceId.isEmpty ? "volc.seedasr.sauc.duration" : trimmedResourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let task = URLSession.shared.webSocketTask(with: request)
        let finish = makeFinisher(task: task, completion: completion)
        let progress = Progress()

        let payload: [String: Any] = [
            "user": ["uid": "voiceinput-macos-test"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel"],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            finish(.failure("Failed to encode config"))
            return
        }

        task.resume()
        let header = DoubaoWireFormat.header(messageType: .fullClientRequest, flags: .none, serialization: .json, compression: .none)
        task.send(.data(DoubaoWireFormat.frame(header: header, payload: json))) { error in
            if let error { finish(.failure(ConnectionError(error.localizedDescription))) }
            else { progress.didSendConfig() }
        }

        receiveDoubaoResponse(task: task, finish: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            finish(progress.timeoutResult())
        }
    }

    private static func receiveDoubaoResponse(task: URLSessionWebSocketTask, finish: @escaping (Result<String, ASRConnectionTester.ConnectionError>) -> Void) {
        task.receive { result in
            switch result {
            case .success(let message):
                guard case .data(let d) = message, let parsed = DoubaoWireFormat.parseServerMessage(d) else {
                    finish(.failure("Invalid server response"))
                    return
                }
                switch parsed {
                case .error(let code, let message): finish(.failure(ConnectionError("\(code): \(message)")))
                case .transcript:                    finish(.success("Server responded. Microphone and transcription not tested."))
                }
            case .failure(let error):
                finish(.failure(ConnectionError(error.localizedDescription)))
            }
        }
    }

    /// A finisher that fires at most once, always tears down the socket, and
    /// always calls back on the main thread — shared by both providers.
    private static func makeFinisher(
        task: URLSessionWebSocketTask,
        completion: @escaping (Result<String, ASRConnectionTester.ConnectionError>) -> Void
    ) -> (Result<String, ASRConnectionTester.ConnectionError>) -> Void {
        var finished = false
        let lock = NSLock()
        return { result in
            lock.lock()
            let shouldRun = !finished
            finished = true
            lock.unlock()
            guard shouldRun else { return }
            task.cancel(with: .normalClosure, reason: nil)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
