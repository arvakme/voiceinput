import AVFoundation
import Foundation

/// Captures microphone audio, converts to 16 kHz mono PCM s16le, and provides
/// ~100 ms chunks for ASR backends. Also computes normalized RMS levels for
/// the waveform display and assembles a running WAV file for the HTTP backend.
///
/// macOS has no AVAudioSession — tap AVAudioEngine.inputNode directly.
final class AudioCapture {
    struct Diagnostics {
        var inputFormat = "Not started"
        var hardwareFrames = 0
        var pcmFrames = 0
        var peak: Int = 0
        var conversionErrors = 0
        var lastError: String?

        var summary: String {
            let result: String
            if hardwareFrames == 0 { result = "No microphone samples received." }
            else if pcmFrames == 0 { result = "Microphone samples received, but PCM conversion produced no audio." }
            else if peak == 0 { result = "Audio received, but all converted samples are zero (silent)." }
            else { result = "Nonzero microphone audio captured." }
            return "\(result) Input: \(inputFormat). Input frames: \(hardwareFrames); PCM frames: \(pcmFrames); peak: \(peak)/32768; conversion errors: \(conversionErrors)." + (lastError.map { " \($0)" } ?? "")
        }
    }

    var diagnostics: Diagnostics {
        wavLock.lock(); defer { wavLock.unlock() }
        return captureDiagnostics
    }

    // MARK: - Public callbacks

    /// Called on a background thread with ~100 ms of 16 kHz mono PCM s16le audio.
    var onChunk: ((Data) -> Void)?

    /// Called on the MAIN thread with a normalized RMS level in [0, 1].
    /// Formula: `(20*log10(max(rms, 1e-6)) + 50) / 40` clamped to [0, 1].
    var onLevel: ((Float) -> Void)?

    // MARK: - Public state

    /// Running WAV file (16 kHz mono pcm_s16le with RIFF header). Thread-safe read.
    ///
    /// The RIFF header is assembled lazily on read from the accumulated raw
    /// samples, so the hot capture path never rebuilds the whole file per chunk.
    var sessionWAV: Data {
        wavLock.lock(); defer { wavLock.unlock() }
        return AudioCapture.buildWAV(samples: wavSamples)
    }

    /// The captured session audio as a complete WAV, or `nil` when no samples
    /// were captured. Same bytes as `sessionWAV`, but `nil`-typed so callers
    /// (e.g. history) can pass it straight through and only materialise the copy
    /// when they actually need it. Reading this builds the WAV; only call it
    /// once, at session end, when the audio is actually wanted.
    var capturedAudioWAV: Data? {
        wavLock.lock(); defer { wavLock.unlock() }
        guard !wavSamples.isEmpty else { return nil }
        return AudioCapture.buildWAV(samples: wavSamples)
    }

    // MARK: - Private constants

    /// Target output sample rate for ASR.
    private static let targetSampleRate: Double = 16_000

    /// Chunk size in output samples (~100 ms at 16 kHz = 1600 samples).
    private static let chunkSamples: Int = 1_600

    /// Hard cap on accumulated WAV sample bytes: ~10 minutes of 16 kHz mono
    /// Int16 audio (16000 samples/s × 2 bytes × 600 s ≈ 19.2 MB). Audio beyond
    /// this point is dropped (with a one-time log) to bound memory.
    private static let maxWAVSampleBytes: Int = 16_000 * 2 * 600

    // MARK: - Private state

    private var audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isTapInstalled = false
    private let processingLock = NSLock()
    private var captureDiagnostics = Diagnostics()

    /// Accumulation buffer for 16 kHz s16le samples before emitting a chunk.
    private var sampleAccumulator = Data()

    /// Lock protecting sessionWAV from concurrent reads/writes.
    private let wavLock = NSLock()

    /// Internal WAV sample buffer (at 16 kHz Int16) before finalizing the header.
    private var wavSamples = Data()

    /// True once the WAV accumulation cap has been hit and a drop was logged,
    /// so the overflow warning fires exactly once per session.
    private var wavCapReached = false

    // MARK: - Lifecycle

    /// Start audio capture.
    /// - Throws: Any error thrown by `AVAudioEngine.start()`.
    func start() throws {
        stop()
        // Re-read the current default input on every recording, rather than
        // retaining an engine whose hardware configuration may have changed.
        audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard Self.isValidInputFormat(inputFormat), Self.isValidInputFormat(hwFormat) else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter = conv

        // Reset running state.
        sampleAccumulator = Data()
        wavLock.lock()
        wavSamples = Data()
        wavCapReached = false
        captureDiagnostics = Diagnostics(inputFormat: hwFormat.description)
        wavLock.unlock()
        Log.audio.info("AudioCapture input=\(inputFormat.description, privacy: .public) tap=\(hwFormat.description, privacy: .public)")

        // Buffer size: ~100 ms worth of hardware-rate samples.
        let bufferSize = AVAudioFrameCount(max(512, hwFormat.sampleRate / 10))

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            self?.handleHardwareBuffer(buffer)
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            throw error
        }
    }

    /// Stop audio capture and tear down the engine.
    func stop() {
        let hadTap = isTapInstalled
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        processingLock.lock(); defer { processingLock.unlock() }
        converter = nil

        // Flush the <100 ms remainder that never reached a full chunk boundary —
        // otherwise the tail of speech right before stop is silently dropped.
        if !sampleAccumulator.isEmpty {
            onChunk?(sampleAccumulator)
            sampleAccumulator = Data()
        }
        if hadTap {
            Log.audio.info("AudioCapture stopped: \(self.diagnostics.summary, privacy: .public)")
        }
    }

    // MARK: - Audio processing

    private func handleHardwareBuffer(_ buffer: AVAudioPCMBuffer) {
        processingLock.lock(); defer { processingLock.unlock() }
        guard let conv = converter else { return }
        wavLock.lock()
        captureDiagnostics.hardwareFrames += Int(buffer.frameLength)
        wavLock.unlock()

        let outBuf: AVAudioPCMBuffer
        do {
            guard let converted = try Self.convert(buffer, using: conv) else { return }
            outBuf = converted
        } catch {
            let nsError = error as NSError
            let message = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
            wavLock.lock()
            captureDiagnostics.conversionErrors += 1
            captureDiagnostics.lastError = message
            let shouldLog = captureDiagnostics.conversionErrors == 1
            wavLock.unlock()
            if shouldLog { Log.audio.error("AudioCapture conversion failed: \(message, privacy: .public)") }
            return
        }

        let frameLen = Int(outBuf.frameLength)
        guard let int16Data = outBuf.int16ChannelData?[0] else { return }
        var sum: Double = 0
        var peak = 0
        for i in 0..<frameLen {
            let sample = Int(int16Data[i])
            peak = max(peak, abs(sample))
            let scaled = Double(sample) / 32768
            sum += scaled * scaled
        }
        let rms = sqrt(sum / Double(frameLen))
        let normalized = Float(max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 40)))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(normalized) }
        let rawBytes = Data(bytes: int16Data, count: frameLen * MemoryLayout<Int16>.size)

        wavLock.lock()
        captureDiagnostics.pcmFrames += frameLen
        captureDiagnostics.peak = max(captureDiagnostics.peak, peak)
        let remaining = max(0, AudioCapture.maxWAVSampleBytes - wavSamples.count)
        wavSamples.append(rawBytes.prefix(remaining))
        if rawBytes.count > remaining, !wavCapReached {
            wavCapReached = true
            Log.audio.warning("AudioCapture: WAV accumulation hit 10-minute cap; further audio dropped from history")
        }
        wavLock.unlock()

        sampleAccumulator.append(rawBytes)
        let chunkBytes = AudioCapture.chunkSamples * MemoryLayout<Int16>.size
        while sampleAccumulator.count >= chunkBytes {
            let chunk = sampleAccumulator.prefix(chunkBytes)
            sampleAccumulator.removeFirst(chunkBytes)
            onChunk?(chunk)
        }
    }

    static func isValidInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
    }

    /// The production conversion path is independently testable without opening a microphone.
    static func convert(_ buffer: AVAudioPCMBuffer, using conv: AVAudioConverter) throws -> AVAudioPCMBuffer? {
        guard isValidInputFormat(buffer.format), buffer.format == conv.inputFormat else {
            throw AudioCaptureError.invalidInputFormat
        }
        guard buffer.frameLength > 0 else { return nil }
        let hwSampleRate = buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * AudioCapture.targetSampleRate / hwSampleRate) + 16
        )
        guard outputFrameCapacity > 0,
              let outBuf = AVAudioPCMBuffer(
                pcmFormat: conv.outputFormat,
                frameCapacity: outputFrameCapacity
              ) else { throw AudioCaptureError.formatCreationFailed }

        var consumedAll = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumedAll {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedAll = true
            outStatus.pointee = .haveData
            return buffer
        }

        var convError: NSError?
        let status = conv.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
        if let convError { throw convError }
        guard status != .error else { throw AudioCaptureError.conversionFailed }
        return outBuf.frameLength > 0 ? outBuf : nil
    }

    // MARK: - WAV helpers

    /// Returns a minimal valid empty WAV (44-byte header, 0 data bytes).
    static func emptyWAV() -> Data {
        return buildWAV(samples: Data())
    }

    /// Build a complete 16 kHz mono 16-bit PCM WAV from raw Int16 sample bytes.
    static func buildWAV(samples: Data) -> Data {
        let sampleRate: UInt32 = UInt32(targetSampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign: UInt16 = channels * bytesPerSample
        let dataSize = UInt32(samples.count)
        let chunkSize = UInt32(36) + dataSize

        var wav = Data(capacity: 44 + samples.count)
        wav.appendASCII("RIFF")
        wav.appendLE32(chunkSize)
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLE32(16)       // PCM subchunk size
        wav.appendLE16(1)        // PCM format
        wav.appendLE16(channels)
        wav.appendLE32(sampleRate)
        wav.appendLE32(byteRate)
        wav.appendLE16(blockAlign)
        wav.appendLE16(bitsPerSample)
        wav.appendASCII("data")
        wav.appendLE32(dataSize)
        wav.append(samples)
        return wav
    }
}

// MARK: - Error types

enum AudioCaptureError: Error, LocalizedError {
    case invalidInputFormat
    case conversionFailed
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat: return "Microphone format is unavailable or changed. Check the macOS sound input and start recording again."
        case .conversionFailed: return "Microphone audio could not be converted to 16 kHz PCM."
        case .formatCreationFailed:   return "AudioCapture: failed to create 16 kHz mono Int16 format"
        case .converterCreationFailed: return "AudioCapture: failed to create AVAudioConverter"
        }
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
