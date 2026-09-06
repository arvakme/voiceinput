import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A local recording test, independent of provider credentials and transcript history.
@MainActor
final class MicrophoneTest: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message = "Record 5 seconds locally, then export a WAV to check what the microphone captured. No audio is sent to a provider."
    @Published private(set) var audio: Data?
    private var capture: AudioCapture?
    private var finishWork: DispatchWorkItem?
    private var generation = 0

    func start() {
        cancel()
        audio = nil
        isRecording = true
        message = "Checking microphone permission…"
        let gen = generation
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.isRecording else { return }
                guard granted else {
                    self.isRecording = false
                    self.message = "Microphone access is denied. Enable VoiceInput in System Settings → Privacy & Security → Microphone."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let capture = AudioCapture()
        self.capture = capture
        do {
            try capture.start()
            message = "Recording for 5 seconds — speak into your microphone."
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            finishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        } catch {
            capture.stop()
            self.capture = nil
            isRecording = false
            message = error.localizedDescription
        }
    }

    private func finish() {
        guard let capture else { return }
        capture.stop()
        audio = capture.capturedAudioWAV
        message = capture.diagnostics.summary
        self.capture = nil
        finishWork = nil
        isRecording = false
    }

    func cancel() {
        generation += 1
        finishWork?.cancel()
        finishWork = nil
        capture?.stop()
        capture = nil
        if isRecording { message = "Microphone test cancelled." }
        isRecording = false
    }

    func export() {
        guard let audio else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoiceInput-microphone-test.wav"
        panel.allowedContentTypes = [.wav]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try audio.write(to: url, options: .atomic) }
            catch { self?.message = "WAV export failed: \(error.localizedDescription)" }
        }
    }
}

struct MicrophoneTestView: View {
    @StateObject private var test = MicrophoneTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(test.isRecording ? "Cancel microphone test" : "Test microphone (5 seconds)") {
                    if test.isRecording { test.cancel() } else { test.start() }
                }
                if test.isRecording { ProgressView().controlSize(.small) }
                Button("Export test WAV…") { test.export() }
                    .disabled(test.audio == nil || test.isRecording)
            }
            Text(test.message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
        .onDisappear { test.cancel() }
    }
}
