import AVFoundation
import Foundation

/// Captures microphone audio, converts to 16 kHz mono PCM s16le, and provides
/// ~100 ms chunks for ASR backends. Also computes normalized RMS levels for
/// the waveform display and assembles a running WAV file for the HTTP backend.
///
/// macOS has no AVAudioSession — tap AVAudioEngine.inputNode directly.
final class AudioCapture {
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

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isTapInstalled = false

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

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

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
        wavLock.unlock()

        // Buffer size: ~100 ms worth of hardware-rate samples.
        let bufferSize = AVAudioFrameCount(max(512, hwFormat.sampleRate / 10))

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            self?.handleHardwareBuffer(buffer)
        }
        isTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stop audio capture and tear down the engine.
    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        converter = nil

        // Flush the <100 ms remainder that never reached a full chunk boundary —
        // otherwise the tail of speech right before stop is silently dropped.
        if !sampleAccumulator.isEmpty {
            onChunk?(sampleAccumulator)
            sampleAccumulator = Data()
        }
    }

    // MARK: - Audio processing

    private func handleHardwareBuffer(_ buffer: AVAudioPCMBuffer) {
        // ── Compute RMS level (formula from old-app) ────────────────────────
        // Average power across every available channel so stereo/aggregate inputs
        // don't read ~3 dB low from sampling channel 0 alone.
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if frameCount > 0, channelCount > 0, let channelData = buffer.floatChannelData {
            var sum: Float = 0
            for ch in 0..<channelCount {
                let samples = channelData[ch]
                for i in 0..<frameCount { sum += samples[i] * samples[i] }
            }
            let rms = sqrtf(sum / Float(frameCount * channelCount))
            let dB = 20.0 * log10(max(rms, 1e-6))
            let normalized = max(0.0, min(1.0, (dB + 50.0) / 40.0))
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(normalized)
            }
        }

        // ── Resample to 16 kHz Int16 mono ───────────────────────────────────
        guard let conv = converter else { return }
        let hwSampleRate = buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * AudioCapture.targetSampleRate / hwSampleRate) + 16
        )
        guard outputFrameCapacity > 0,
              let outBuf = AVAudioPCMBuffer(
                pcmFormat: conv.outputFormat,
                frameCapacity: outputFrameCapacity
              ) else { return }

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
        guard status != .error, outBuf.frameLength > 0 else { return }

        // outBuf is Int16 interleaved mono; extract raw bytes.
        let frameLen = Int(outBuf.frameLength)
        guard let int16Data = outBuf.int16ChannelData?[0] else { return }
        let rawBytes = Data(
            bytes: int16Data,
            count: frameLen * MemoryLayout<Int16>.size
        )

        // ── Append to running WAV (bounded at ~10 min) ───────────────────────
        wavLock.lock()
        if wavSamples.count < AudioCapture.maxWAVSampleBytes {
            let remaining = AudioCapture.maxWAVSampleBytes - wavSamples.count
            if rawBytes.count <= remaining {
                wavSamples.append(rawBytes)
            } else {
                wavSamples.append(rawBytes.prefix(remaining))
                if !wavCapReached {
                    wavCapReached = true
                    Log.audio.warning("AudioCapture: WAV accumulation hit 10-minute cap; further audio dropped from history")
                }
            }
        } else if !wavCapReached {
            wavCapReached = true
            Log.audio.warning("AudioCapture: WAV accumulation hit 10-minute cap; further audio dropped from history")
        }
        wavLock.unlock()

        // ── Accumulate → emit ~100 ms chunks ────────────────────────────────
        sampleAccumulator.append(rawBytes)
        let chunkBytes = AudioCapture.chunkSamples * MemoryLayout<Int16>.size
        while sampleAccumulator.count >= chunkBytes {
            let chunk = sampleAccumulator.prefix(chunkBytes)
            sampleAccumulator.removeFirst(chunkBytes)
            onChunk?(chunk)
        }
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
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
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
