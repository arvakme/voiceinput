import SwiftUI

/// Mutable rolling history for the waveform.
///
/// A reference type so the `Canvas` draw closure can advance it in place
/// without round-tripping through SwiftUI `@State` writes on every frame.
/// `TimelineView(.animation)` already re-evaluates the body each frame, so the
/// `Canvas` reads the freshest ring on its own clock — no `@Published` needed.
@MainActor
private final class WaveformHistory {
    private(set) var samples: [CGFloat]
    var smoothedLevel: CGFloat = 0
    var lastAdvance: TimeInterval = 0

    init(count: Int) {
        samples = Array(repeating: 0, count: count)
    }

    func advance(appending value: CGFloat) {
        samples.removeFirst()
        samples.append(value)
    }

    /// Adapts the ring to a new bar count when the box is resized: trims the
    /// oldest samples or pads the past with silence, preserving the recent tail.
    func resize(to count: Int) {
        guard count != samples.count, count > 0 else { return }
        if count < samples.count {
            samples.removeFirst(samples.count - count)
        } else {
            samples.insert(contentsOf: Array(repeating: 0, count: count - samples.count), at: 0)
        }
    }
}

/// A dense, rolling real-time waveform rendered with `Canvas` + `TimelineView`.
///
/// Newest sample on the right, oldest on the left. Bars are symmetric about the
/// vertical centerline, drawn with rounded caps in an accent gradient. When the
/// incoming level sits near zero the view "breathes": a slow, gentle sinusoidal
/// ripple so the box never looks frozen between words.
struct WaveformView: View {
    @ObservedObject var state: AppState

    /// Bar geometry. The bar count adapts to the width the layout offers, so
    /// the waveform densifies as the user resizes the box or capsule.
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 2.5
    private let height: CGFloat?

    @State private var history = WaveformHistory(count: 72)

    /// Pass `height: nil` to fill whatever vertical space the parent offers
    /// (used by the compact capsule).
    init(state: AppState, height: CGFloat? = 34) {
        self.state = state
        self.height = height
    }

    /// Only the audio-active phases drive the per-frame render clock. When the
    /// box is idle/dismissed (or merely refining/injecting, where no audio
    /// flows), `TimelineView(.animation)` is torn down so the `Canvas` stops
    /// repainting at the display refresh rate — otherwise the always-mounted
    /// box would burn CPU forever behind a hidden panel.
    private var isLive: Bool {
        switch state.phase {
        case .connecting, .listening, .finalizing: return true
        case .idle, .refining, .injecting, .reviewing, .error: return false
        }
    }

    var body: some View {
        Group {
            if isLive {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(in: &context,
                             size: size,
                             now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                // A single static frame of the current ring — no clock, no churn.
                Canvas { context, size in
                    draw(in: &context, size: size, now: 0)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Advances the rolling window and paints the bars.
    @MainActor
    private func draw(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        // Fit as many bars as the current width allows (resize-adaptive).
        let barCount = max(12, Int((size.width + barGap) / (barWidth + barGap)))
        history.resize(to: barCount)
        // --- Update the rolling history on the render clock ---
        let live = CGFloat(max(0, min(1, state.audioLevel)))
        // Ease the live level toward its target. Faster attack than release.
        let alpha: CGFloat = live > history.smoothedLevel ? 0.45 : 0.18
        history.smoothedLevel += (live - history.smoothedLevel) * alpha

        // Advance the ring at a fixed cadence so scroll speed is machine-stable.
        let advanceInterval: TimeInterval = 1.0 / 55.0
        if now - history.lastAdvance >= advanceInterval {
            history.lastAdvance = now
            history.advance(appending: history.smoothedLevel)
        }

        let samples = history.samples
        let smoothed = history.smoothedLevel

        let centerY = size.height / 2
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (size.width - totalWidth) / 2
        let maxHeight = size.height * 0.92
        let minHeight: CGFloat = 2.5

        // Idle breathing: a slow travelling sine so a silent box still feels
        // alive. Only meaningfully contributes when the live signal is quiet.
        let breathPhase = now * 1.6
        let idleness = max(0, 1 - smoothed * 6) // 1 when silent, →0 with speech

        let accent = Theme.accent

        // A true left→right Theme.accent gradient (per SPEC) at 0.9 peak opacity.
        // The recency brightness — older history dimmer at the leading edge, the
        // freshest "now" bars at full strength on the right — is encoded in the
        // gradient endpoints rather than per-bar opacity math.
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [accent.opacity(0.9 * 0.55), accent.opacity(0.9)]),
            startPoint: CGPoint(x: startX, y: centerY),
            endPoint: CGPoint(x: startX + totalWidth, y: centerY)
        )

        for i in 0..<barCount {
            let s = samples.indices.contains(i) ? samples[i] : 0

            let positional = Double(i) / Double(barCount - 1)

            // Per-bar idle ripple: phase offset along the row so it travels.
            let breathe = sin(breathPhase - positional * 5.0) * 0.5 + 0.5
            let idleContribution = idleness * breathe * 0.12

            // A subtle envelope so the very ends of the row taper.
            let edge = edgeEnvelope(positional)

            let level = min(1, max(0, s + CGFloat(idleContribution))) * edge
            let h = minHeight + (maxHeight - minHeight) * level

            let x = startX + CGFloat(i) * (barWidth + barGap)
            let rect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)

            context.fill(path, with: shading)
        }
    }

    /// Smooth taper at the row's extremes, full strength in the middle.
    private func edgeEnvelope(_ t: Double) -> CGFloat {
        let edge = 0.06 // fraction of the row to taper on each side
        if t < edge {
            return CGFloat(0.35 + 0.65 * (t / edge))
        } else if t > 1 - edge {
            return CGFloat(0.35 + 0.65 * ((1 - t) / edge))
        }
        return 1
    }
}
