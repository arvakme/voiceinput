import Foundation
import os.log

/// Doubao (Volcengine "豆包语音识别大模型" / Seed-ASR) bidirectional streaming
/// transcription over a WebSocket — the same engine behind 豆包输入法, 抖音
/// language input, and 剪映's auto-subtitles, sold standalone as an API.
///
/// Protocol summary (docs.volcengine.com/docs/6561/1354869):
/// 1. Open `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`
///    (双向流式模式-优化版本: only pushes a new response when the text changes,
///    lowest first/last-word latency of the three streaming modes) with
///    auth headers.
/// 2. Send one binary "full client request" frame — JSON config, no
///    compression (see below).
/// 3. Stream binary "audio only request" frames with raw PCM16 chunks from
///    `AudioCapture.onChunk`.
/// 4. Each "full server response" carries the ENTIRE cumulative transcript
///    in `result.text` (not incremental tokens like Soniox) — replace,
///    don't append.
/// 5. `stop()`: send one last audio-only frame with the "final packet" flag
///    (empty payload is fine), await the response whose flag marks it as
///    final, then tear down. 3s timeout → fall back to the last known text.
/// 6. Compression is deliberately `none`: the wire format lets client and
///    server negotiate gzip, but PCM16 chunks at dictation length are small
///    enough that skipping gzip removes an entire failure surface (needing
///    a system zlib bridge) for no measurable cost.
final class DoubaoRealtimeSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    var isStreaming: Bool { true }

    // MARK: - Private constants

    private static let websocketURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private static let finalizeTimeoutInterval: TimeInterval = 3

    // MARK: - Private state

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let capture = AudioCapture()
    private let wsQueue = DispatchQueue(label: "com.zhijie.VoiceInput.DoubaoWS")

    private var generation: UInt64 = 0
    private let genLock = NSLock()

    // Protected by wsQueue:
    private var wsTask: URLSessionWebSocketTask?
    private var latestText: String = ""
    private var reportedError = false
    private var isFinalized = false
    private var stopCompletion: ((String) -> Void)?

    // MARK: - Init

    init(settings: AppSettings, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    // MARK: - TranscriptionSession

    func start() throws {
        let gen = newGeneration()

        capture.onLevel = audioLevelHandler
        capture.onChunk = { [weak self] data in
            self?.sendAudioChunk(data, isLast: false, gen: gen)
        }

        try capture.start()
        openWebSocket(gen: gen)
        Log.asr.info("DoubaoRealtimeSession started, gen=\(gen)")
    }

    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        Log.asr.info("DoubaoRealtimeSession stop(), gen=\(gen)")

        capture.stop()

        wsQueue.async { [weak self] in
            guard let self, self.isCurrentGen(gen) else {
                DispatchQueue.main.async { completion("") }
                return
            }
            guard self.stopCompletion == nil else {
                Log.asr.debug("DoubaoRealtimeSession: duplicate stop() ignored")
                DispatchQueue.main.async { completion("") }
                return
            }

            self.stopCompletion = completion
            self.isFinalized = true

            // Empty payload, flagged as the last audio packet — tells the
            // server no more audio is coming so it emits a final response.
            self.sendAudioChunk(Data(), isLast: true, gen: gen)

            let deadline = DispatchTime.now() + DoubaoRealtimeSession.finalizeTimeoutInterval
            self.wsQueue.asyncAfter(deadline: deadline) { [weak self] in
                guard let self, self.isCurrentGen(gen), let cb = self.stopCompletion else { return }
                Log.asr.warning("DoubaoRealtimeSession: finalize timeout, delivering last known text")
                self.stopCompletion = nil
                let text = self.latestText
                self.tearDownWebSocketOnQueue()
                DispatchQueue.main.async { cb(text) }
            }
        }
    }

    func cancel() {
        _ = newGeneration()
        capture.stop()
        wsQueue.async { [weak self] in
            self?.tearDownWebSocketOnQueue()
            self?.stopCompletion = nil
        }
        Log.asr.info("DoubaoRealtimeSession cancelled")
    }

    // MARK: - WebSocket setup

    private func openWebSocket(gen: UInt64) {
        wsQueue.async { [weak self] in
            guard let self, self.isCurrentGen(gen) else { return }
            self.tearDownWebSocketOnQueue()

            var request = URLRequest(url: DoubaoRealtimeSession.websocketURL)
            let apiKey = self.settings.doubaoAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let resourceId = self.settings.doubaoResourceId.trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue(resourceId.isEmpty ? "volc.seedasr.sauc.duration" : resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

            let task = URLSession.shared.webSocketTask(with: request)
            self.wsTask = task
            self.latestText = ""
            self.reportedError = false
            self.isFinalized = false

            task.resume()
            self.sendConfigFrameOnQueue()
            self.receiveLoop(task: task, gen: gen)
            Log.asr.debug("DoubaoRealtimeSession WebSocket opened")
        }
    }

    private func sendConfigFrameOnQueue() {
        var requestFields: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
        ]

        let hotwords = vocabulary.doubaoHotwords
        if !hotwords.isEmpty,
           let hotwordsData = try? JSONSerialization.data(withJSONObject: ["hotwords": hotwords.map { ["word": $0] }]),
           let hotwordsJSON = String(data: hotwordsData, encoding: .utf8) {
            // `context` is itself a JSON string nested inside `corpus`, per spec.
            requestFields["corpus"] = ["context": hotwordsJSON]
        }

        let payload: [String: Any] = [
            "user": ["uid": "voiceinput-macos"],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            ],
            "request": requestFields,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.asr.error("DoubaoRealtimeSession: failed to encode config frame")
            return
        }

        let header = DoubaoWireFormat.header(messageType: .fullClientRequest, flags: .none, serialization: .json, compression: .none)
        let frame = DoubaoWireFormat.frame(header: header, payload: json)
        sendDataOnQueue(frame)
        Log.asr.debug("DoubaoRealtimeSession: sent config frame (hotwords=\(hotwords.count))")
    }

    // MARK: - Receive loop

    private func receiveLoop(task: URLSessionWebSocketTask, gen: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.wsQueue.async {
                guard self.isCurrentGen(gen), self.wsTask === task else { return }
                switch result {
                case .success(let message):
                    let shouldContinue = self.handleMessage(message, gen: gen)
                    if shouldContinue {
                        self.receiveLoop(task: task, gen: gen)
                    }
                case .failure(let error):
                    let nsErr = error as NSError
                    if nsErr.code == NSURLErrorCancelled { return }
                    let msg = "WebSocket receive error: \(error.localizedDescription)"
                    Log.asr.error("DoubaoRealtimeSession: \(msg)")

                    if !self.reportedError {
                        self.reportedError = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isCurrentGen(gen) else { return }
                            self.onError?(msg)
                        }
                    }
                    if let cb = self.stopCompletion {
                        self.stopCompletion = nil
                        let text = self.latestText
                        self.tearDownWebSocketOnQueue()
                        DispatchQueue.main.async { cb(text) }
                    }
                }
            }
        }
    }

    // MARK: - Message handling

    /// Returns false when the receive loop should stop (session finished or fatal error).
    private func handleMessage(_ message: URLSessionWebSocketTask.Message, gen: UInt64) -> Bool {
        guard case .data(let data) = message else {
            Log.asr.debug("DoubaoRealtimeSession: ignoring non-binary message")
            return true
        }

        guard let parsed = DoubaoWireFormat.parseServerMessage(data) else {
            Log.asr.debug("DoubaoRealtimeSession: unparseable frame")
            return true
        }

        switch parsed {
        case .error(let code, let message):
            let fullMsg = "Doubao \(code): \(message)"
            Log.asr.error("DoubaoRealtimeSession: \(fullMsg)")
            if !reportedError {
                reportedError = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentGen(gen) else { return }
                    self.onError?(fullMsg)
                }
            }
            return true

        case .transcript(let text, let isFinal):
            if text != latestText {
                latestText = text
                let snapshot = TranscriptSnapshot(finalText: "", interimText: text)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentGen(gen) else { return }
                    self.onTranscript?(snapshot)
                }
            }

            if isFinal {
                Log.asr.info("DoubaoRealtimeSession: server indicated final response")
                if let cb = stopCompletion {
                    stopCompletion = nil
                    let finalText = latestText
                    tearDownWebSocketOnQueue()
                    DispatchQueue.main.async { cb(finalText) }
                } else {
                    tearDownWebSocketOnQueue()
                }
                return false
            }
            return true
        }
    }

    // MARK: - Sending helpers

    private func sendAudioChunk(_ data: Data, isLast: Bool, gen: UInt64) {
        wsQueue.async { [weak self] in
            guard let self, self.isCurrentGen(gen), let task = self.wsTask else { return }
            guard isLast || !self.isFinalized else { return }
            let header = DoubaoWireFormat.header(
                messageType: .audioOnlyRequest,
                flags: isLast ? .lastPacket : .none,
                serialization: .none,
                compression: .none
            )
            let frame = DoubaoWireFormat.frame(header: header, payload: data)
            task.send(.data(frame)) { error in
                if let error {
                    Log.asr.error("DoubaoRealtimeSession: audio send error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendDataOnQueue(_ data: Data) {
        wsTask?.send(.data(data)) { error in
            if let error {
                Log.asr.error("DoubaoRealtimeSession: send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Teardown

    private func tearDownWebSocketOnQueue() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
    }

    // MARK: - Generation counter

    private func newGeneration() -> UInt64 {
        genLock.lock(); defer { genLock.unlock() }
        generation &+= 1
        return generation
    }

    private func currentGeneration() -> UInt64 {
        genLock.lock(); defer { genLock.unlock() }
        return generation
    }

    private func isCurrentGen(_ gen: UInt64) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return gen == generation
    }
}

// MARK: - DoubaoWireFormat

/// The binary framing Volcengine's "大模型流式语音识别" WebSocket API uses
/// instead of plain JSON text frames: a 4-byte header, a big-endian uint32
/// payload size, then the payload. See the type's doc comments on
/// `DoubaoRealtimeSession` for the protocol reference.
///
/// Internal (not `private`) so `ASRConnectionTester` can reuse the same
/// framing for its handshake-only smoke test without duplicating the protocol.
enum DoubaoWireFormat {
    enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnlyRequest  = 0b0010
        case fullServerResponse = 0b1001
        case errorResponse = 0b1111
    }

    /// "Message type specific flags" nibble. `.lastPacket` marks the final
    /// audio-only request (no audio has to follow); the server mirrors this
    /// same bit (or the sequence-number variants) to mark its final response.
    enum Flags: UInt8 {
        case none = 0b0000
        case sequencePresent = 0b0001
        case lastPacket = 0b0010
        case sequencePresentLast = 0b0011
    }

    enum Serialization: UInt8 {
        case none = 0b0000
        case json = 0b0001
    }

    enum Compression: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }

    enum ParsedMessage {
        case transcript(text: String, isFinal: Bool)
        case error(code: UInt32, message: String)
    }

    static func header(messageType: MessageType, flags: Flags, serialization: Serialization, compression: Compression) -> [UInt8] {
        let byte0: UInt8 = (0b0001 << 4) | 0b0001  // protocol v1, header size = 1 * 4 bytes
        let byte1: UInt8 = (messageType.rawValue << 4) | flags.rawValue
        let byte2: UInt8 = (serialization.rawValue << 4) | compression.rawValue
        let byte3: UInt8 = 0x00
        return [byte0, byte1, byte2, byte3]
    }

    static func frame(header: [UInt8], payload: Data) -> Data {
        var data = Data(header)
        data.append(bigEndianUInt32(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    static func parseServerMessage(_ data: Data) -> ParsedMessage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        let messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        var offset = 4

        if messageType == MessageType.errorResponse.rawValue {
            guard let code = readUInt32BE(bytes, at: offset) else { return nil }
            offset += 4
            guard let msgSize = readUInt32BE(bytes, at: offset) else { return nil }
            offset += 4
            guard bytes.count >= offset + Int(msgSize) else { return nil }
            let message = String(decoding: bytes[offset..<(offset + Int(msgSize))], as: UTF8.self)
            return .error(code: code, message: message)
        }

        guard messageType == MessageType.fullServerResponse.rawValue else { return nil }

        var isFinal = flags == Flags.lastPacket.rawValue || flags == Flags.sequencePresentLast.rawValue
        if flags == Flags.sequencePresent.rawValue || flags == Flags.sequencePresentLast.rawValue {
            guard let sequence = readUInt32BE(bytes, at: offset) else { return nil }
            offset += 4
            if Int32(bitPattern: sequence) < 0 { isFinal = true }
        }

        guard let payloadSize = readUInt32BE(bytes, at: offset) else { return nil }
        offset += 4
        guard bytes.count >= offset + Int(payloadSize) else { return nil }
        let payload = Data(bytes[offset..<(offset + Int(payloadSize))])

        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return nil
        }
        let text = result["text"] as? String ?? ""
        return .transcript(text: text, isFinal: isFinal)
    }

    private static func bigEndianUInt32(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard bytes.count >= offset + 4 else { return nil }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
