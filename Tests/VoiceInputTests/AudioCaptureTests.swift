import AVFoundation
import Testing
@testable import VoiceInput

struct AudioCaptureTests {
    @Test(arguments: [44100.0, 48000.0])
    func realConverterPreservesSignalAndDuration(rate: Double) throws {
        for kind in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            for channels: AVAudioChannelCount in [1, 2] {
                for interleaved in [false, true] {
                    let input = try #require(AVAudioFormat(commonFormat: kind, sampleRate: rate, channels: channels, interleaved: interleaved))
                    let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
                    let converter = try #require(AVAudioConverter(from: input, to: output))
                    let count = Int(rate / 10)
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count)))
                    buffer.frameLength = AVAudioFrameCount(count)
                    for ch in 0..<Int(channels) {
                        for i in 0..<count {
                            let signal = sin(Double(i) * 2 * .pi * 440 / rate) * 0.25
                            let index = interleaved ? i * Int(channels) + ch : i
                            let plane = interleaved ? 0 : ch
                            if kind == .pcmFormatFloat32 { buffer.floatChannelData![plane][index] = Float(signal) }
                            else { buffer.int16ChannelData![plane][index] = Int16(signal * 32767) }
                        }
                    }
                    var frames = 0
                    var peak = 0
                    for _ in 0..<10 {
                        let converted = try #require(try AudioCapture.convert(buffer, using: converter))
                        frames += Int(converted.frameLength)
                        let samples = try #require(converted.int16ChannelData?[0])
                        for i in 0..<Int(converted.frameLength) { peak = max(peak, abs(Int(samples[i]))) }
                    }
                    #expect(frames > 15500 && frames <= 16000)
                    #expect(peak > 7000 && peak < 9500)
                }
            }
        }
    }

    @Test func changedFormatFailsInsteadOfFeedingStaleConverter() throws {
        let original = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: original, to: target))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 100))
        buffer.frameLength = 100
        #expect(throws: AudioCaptureError.self) { try AudioCapture.convert(buffer, using: converter) }
    }

    @Test func emptyBuffersDoNotCreateAudio() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: input, to: target))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 100))
        #expect(try AudioCapture.convert(buffer, using: converter) == nil)
    }

    @Test func connectionTimeoutCannotSucceedBeforeConfigSend() {
        let progress = ASRConnectionTester.Progress()
        if case .success = progress.timeoutResult() { Issue.record("Pending connection falsely succeeded") }
        progress.didSendConfig()
        if case .failure = progress.timeoutResult() { Issue.record("Completed config send was not recorded") }
    }
}
