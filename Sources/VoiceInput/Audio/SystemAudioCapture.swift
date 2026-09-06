import AVFoundation
import ScreenCaptureKit
import os.log

/// Captures the Mac's OWN audio output (calls, videos, any app sound) via
/// ScreenCaptureKit audio-only capture, downmixed and resampled to the same
/// 16 kHz mono s16le chunk format `AudioCapture` produces — so ASR sessions
/// can consume either source interchangeably.
///
/// Requires the Screen & System Audio Recording permission (TCC prompts on
/// first use). Video is configured to the minimum SCK allows and never read.
// @unchecked Sendable: crosses the SCK sample queue, an async start Task and
// the main thread; callbacks are assigned before start() and never mutated
// mid-capture, and stream/pending are only touched from start/stop + the
// sample queue.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 16 kHz mono s16le, ~100 ms per chunk. Delivered on a background queue.
    var onChunk: ((Data) -> Void)?
    /// Normalized RMS 0…1, delivered on the main thread.
    var onLevel: ((Float) -> Void)?
    /// Capture failure (permission denied, no display, stream error). Main thread.
    var onError: ((String) -> Void)?

    // All three are mutated from main (stop/start), the cooperative pool (the
    // start Task), the SCK delegate queue, and the sample queue — so every
    // access goes through `sampleQueue` to avoid a data race.
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "VoiceInput.SystemAudio")
    private var pending = Data()
    /// 100 ms at 16 kHz mono 16-bit.
    private let chunkBytes = 3200
    private var stopped = true
    private var generation: UInt64 = 0

    func start() {
        let gen: UInt64? = sampleQueue.sync {
            guard stopped else { return nil }
            generation &+= 1
            stopped = false
            pending = Data()
            return generation
        }
        guard let gen else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // Triggers the Screen & System Audio Recording TCC prompt.
                let content = try await SCShareableContent.current
                guard self.isCurrent(gen) else { return }
                guard let display = content.displays.first else {
                    throw CaptureError.message("No display available for audio capture")
                }
                let filter = SCContentFilter(display: display,
                                             excludingApplications: [],
                                             exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                // Minimal video plumbing — SCK requires a video config but we
                // never attach a video output.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                // Publish and check cancellation in one critical section.
                // Otherwise stop() can observe nil between the check and
                // assignment and leave an untracked stream recording.
                let accepted = self.sampleQueue.sync {
                    guard !self.stopped, self.generation == gen else { return false }
                    self.stream = stream
                    return true
                }
                guard accepted else {
                    try? await stream.stopCapture()
                    return
                }
                Log.audio.info("SystemAudioCapture started")
            } catch {
                Log.audio.error("SystemAudioCapture start failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.onError?("System audio capture failed: \(error.localizedDescription). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
                }
            }
        }
    }

    func stop() {
        let active: SCStream? = sampleQueue.sync {
            stopped = true
            generation &+= 1
            let s = stream
            stream = nil
            pending = Data()
            return s
        }
        guard let active else { return }
        Task { try? await active.stopCapture() }
        Log.audio.info("SystemAudioCapture stopped")
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let gen: UInt64? = sampleQueue.sync {
            guard !stopped, self.stream === stream else { return nil }
            return generation
        }
        guard let gen else { return }
        Log.audio.error("SystemAudioCapture stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.onError?("System audio stream stopped: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // A retired stream can still enqueue samples while stopCapture awaits.
        // Only the registered stream may feed the current generation.
        guard type == .audio, sampleBuffer.isValid, !stopped,
              self.stream === stream else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        // Collect the buffer as mono float32 (averaging channels if several).
        var mono: [Float] = []
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            let buffers = Array(audioBufferList)
            guard !buffers.isEmpty else { return }
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            guard isFloat else { return }

            if buffers.count == 1, asbd.mChannelsPerFrame <= 1 {
                // Mono, one buffer — the configured fast path.
                if let p = buffers[0].mData {
                    let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                    mono = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: count))
                }
            } else {
                // De-interleaved channels in separate buffers: average them.
                var channels: [[Float]] = []
                for buffer in buffers {
                    guard let p = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    channels.append(Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: count)))
                }
                guard let frameCount = channels.map(\.count).min(), frameCount > 0 else { return }
                mono = (0..<frameCount).map { i in
                    channels.reduce(Float(0)) { $0 + $1[i] } / Float(channels.count)
                }
            }
        }
        guard !mono.isEmpty else { return }

        // Level (same normalization as AudioCapture).
        var sum: Float = 0
        for sample in mono { sum += sample * sample }
        let rms = sqrtf(sum / Float(mono.count))
        let normalized = max(0, min(1, (20 * log10f(max(rms, 1e-6)) + 50) / 40))
        let gen = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.onLevel?(normalized)
        }

        // Decimate to 16 kHz (48 kHz / 3, averaging triples as a cheap low-pass)
        // and quantize to s16le.
        let ratio = max(1, Int((asbd.mSampleRate / 16_000).rounded()))
        var out = Data(capacity: (mono.count / ratio) * 2)
        var index = 0
        while index + ratio <= mono.count {
            var acc: Float = 0
            for offset in 0..<ratio { acc += mono[index + offset] }
            let avg = acc / Float(ratio)
            var sample = Int16(max(-1, min(1, avg)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { out.append(contentsOf: $0) }
            index += ratio
        }

        pending.append(out)
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onChunk?(Data(chunk))
        }
    }

    /// Called from main-thread callbacks, never from sampleQueue itself.
    private func isCurrent(_ gen: UInt64) -> Bool {
        sampleQueue.sync { !stopped && generation == gen }
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }
}
