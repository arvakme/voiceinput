import SwiftUI

/// Live Captions glass card with two layouts:
/// - **dual**: original speech (left) + translation (right), two columns.
/// - **bar**: a wide YouTube-style caption strip — large translation, small
///   original above — for glanceable real-time translation.
/// Same Liquid Glass language as the voice box: single glass surface +
/// user-opacity scrim, specular rim, drag grabber, edge resize, tail-pinned
/// fading transcript.
struct ListenView: View {
    @ObservedObject var state: ListenState
    @ObservedObject var settings: AppSettings
    let resizeController: ListenResizeController

    var onClose: () -> Void
    var onClear: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isBar: Bool { settings.listenMode == "bar" }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isBar ? 22 : 28, style: .continuous)
    }

    var body: some View {
        Group {
            if isBar { barContent } else { dualContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(glassBackground)
        .overlay(specularRim)
        .clipShape(shape)
        .overlay(listenResizeHandles)
        .overlay(alignment: .top) { ListenDragGrabber().padding(.top, 6) }
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .gesture(WindowDragGesture())
        .padding(40)
        .animation(.spring(duration: 0.3), value: state.errorMessage)
        .animation(.spring(duration: 0.3), value: state.reconnecting)
    }

    // MARK: - Status note (error / quiet reconnecting)

    /// A terminal error is shown in red; an auto-reconnect in progress (network
    /// blip, provider session-length cap) is shown as a quiet, non-alarming
    /// note instead — it isn't something the user needs to act on.
    @ViewBuilder
    private func statusText(fontSize: CGFloat) -> some View {
        if state.reconnecting {
            Text("Reconnecting…")
                .font(.system(size: fontSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .lineLimit(1)
        } else if let error = state.errorMessage {
            Text(error)
                .font(.system(size: fontSize))
                .foregroundStyle(Color.red.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Dual layout

    private var dualContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(compact: false)
            HStack(alignment: .top, spacing: 16) {
                column(
                    titleView: AnyView(columnTitle("Original")),
                    snapshot: state.original,
                    placeholder: state.connecting ? "Connecting…" : "Listening…",
                    id: "original",
                    fontSize: 15
                )
                Rectangle()
                    .fill(Theme.hairline.opacity(0.6))
                    .frame(width: 1)
                    .padding(.vertical, 2)
                column(
                    titleView: AnyView(targetMenu),
                    snapshot: state.translation,
                    placeholder: "Translation appears here…",
                    id: "translation",
                    fontSize: 15
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    // MARK: - Bar layout (caption strip)

    private var barContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Compact floating controls.
            HStack(spacing: 8) {
                ListenPulseDot(active: state.active, connecting: state.connecting)
                targetMenu
                providerMenu
                statusText(fontSize: 10.5)
                Spacer(minLength: 8)
                sourceMenu
                ListenIconButton(systemName: "rectangle.split.2x1", help: "Two-column view (Fn+Shift+Space)") {
                    settings.listenMode = "dual"
                }
                ListenIconButton(systemName: "xmark", help: "Close (Fn+Space)", action: onClose)
            }

            // Small original line.
            if !state.original.isEmpty {
                singleLineTail(state.original)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            // Large translation — the star of the bar.
            if state.translation.isEmpty {
                Text(state.connecting ? "Connecting…" : "Translation appears here…")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                tailPinnedScroll(snapshot: state.translation, id: "bar-translation", fontSize: 25, weight: .semibold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Header (dual)

    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            ListenPulseDot(active: state.active, connecting: state.connecting)
            Text("Live Captions")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))

            providerMenu
            sourceMenu

            statusText(fontSize: 11)

            Spacer(minLength: 12)

            MiniWaveform(audioLevel: state.audioLevel)
                .frame(width: 60, height: 16)

            ListenIconButton(systemName: "rectangle.compress.vertical", help: "Caption bar view (Fn+Shift+Space)") {
                settings.listenMode = "bar"
            }
            ListenIconButton(systemName: "trash", help: "Clear transcripts", action: onClear)
            ListenIconButton(systemName: "xmark", help: "Close (Fn+Space)", action: onClose)
        }
    }

    // MARK: - Menus

    private var providerMenu: some View {
        Menu {
            ForEach(LiveCaptionProvider.allCases, id: \.self) { provider in
                Button {
                    settings.liveCaptionProvider = provider
                } label: {
                    pickLabel(provider.displayName, checked: settings.liveCaptionProvider == provider)
                }
            }
        } label: {
            pill(icon: "cpu", text: settings.liveCaptionProvider.displayName, tint: Theme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Captioning engine")
    }

    private var sourceMenu: some View {
        Menu {
            Button { settings.listenSource = "system" } label: {
                pickLabel("System audio", checked: settings.listenSource == "system")
            }
            Button { settings.listenSource = "mic" } label: {
                pickLabel("Microphone", checked: settings.listenSource == "mic")
            }
        } label: {
            pill(icon: settings.listenSource == "mic" ? "mic" : "speaker.wave.2",
                 text: settings.listenSource == "mic" ? "Microphone" : "System audio",
                 tint: Theme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var targetMenu: some View {
        Menu {
            ForEach(ListenLanguages.all, id: \.code) { language in
                Button { settings.listenTargetLanguage = language.code } label: {
                    pickLabel(language.name, checked: settings.listenTargetLanguage == language.code)
                }
            }
        } label: {
            pill(icon: "globe", text: ListenLanguages.name(for: settings.listenTargetLanguage), tint: Theme.accent)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Translation target — changing restarts the stream, keeping the text so far")
    }

    private func pill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text).font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tint == Theme.accent ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.07)))
    }

    private func pickLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            if checked { Image(systemName: "checkmark") }
            Text(title)
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - Columns / transcript

    private func column(titleView: AnyView, snapshot: TranscriptSnapshot,
                        placeholder: String, id: String, fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titleView
            if snapshot.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                tailPinnedScroll(snapshot: snapshot, id: id, fontSize: fontSize, weight: .medium)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tailPinnedScroll(snapshot: TranscriptSnapshot, id: String,
                                  fontSize: CGFloat, weight: Font.Weight) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                columnText(snapshot, fontSize: fontSize, weight: weight)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 1)
                    .id("tail-\(id)")
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .clipped()
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Color.black
                }
            )
            .onChange(of: snapshot) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("tail-\(id)", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("tail-\(id)", anchor: .bottom) }
        }
    }

    /// Displayed text is capped to a tail window so a hours-long session
    /// doesn't rebuild an ever-growing AttributedString on every token — the
    /// full text still accumulates in the session/controller for carry-over
    /// across restarts, only rendering is windowed.
    private static let displayWindowChars = 5_000

    /// Last `displayWindowChars` characters of `text`, advanced forward to
    /// the next line boundary so the visible window doesn't open mid-line.
    private func windowedTail(_ text: String) -> Substring {
        guard text.count > Self.displayWindowChars else { return text[...] }
        let cut = text.index(text.endIndex, offsetBy: -Self.displayWindowChars)
        if let newline = text[cut...].firstIndex(of: "\n") {
            return text[text.index(after: newline)...]
        }
        return text[cut...]
    }

    private func columnText(_ snapshot: TranscriptSnapshot, fontSize: CGFloat, weight: Font.Weight) -> Text {
        var attributed = AttributedString(String(windowedTail(snapshot.finalText)))
        attributed.foregroundColor = Theme.textPrimary
        var interim = AttributedString(snapshot.interimText)
        interim.foregroundColor = Theme.textSecondary.opacity(0.6)
        attributed.append(interim)
        return Text(attributed).font(.system(size: fontSize, weight: weight))
    }

    /// Last ~80 chars of a transcript, for the bar's small original line —
    /// computed from the tail window (bounded), never the full string.
    private func singleLineTail(_ snapshot: TranscriptSnapshot) -> Text {
        let windowed = String(windowedTail(snapshot.finalText)) + snapshot.interimText
        let trimmed = windowed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.count > 90 ? String(trimmed.suffix(90)) : trimmed
        return Text(tail)
    }

    // MARK: - Resize handles

    private var listenResizeHandles: some View {
        let grip: CGFloat = 8
        let corner: CGFloat = 14
        return Color.clear
            .overlay(alignment: .top) {
                ListenResizeHandle(edges: .top, controller: resizeController)
                    .frame(height: grip).padding(.horizontal, corner)
            }
            .overlay(alignment: .bottom) {
                ListenResizeHandle(edges: .bottom, controller: resizeController)
                    .frame(height: grip).padding(.horizontal, corner)
            }
            .overlay(alignment: .leading) {
                ListenResizeHandle(edges: .left, controller: resizeController)
                    .frame(width: grip).padding(.vertical, corner)
            }
            .overlay(alignment: .trailing) {
                ListenResizeHandle(edges: .right, controller: resizeController)
                    .frame(width: grip).padding(.vertical, corner)
            }
            .overlay(alignment: .topLeading) {
                ListenResizeHandle(edges: [.top, .left], controller: resizeController).frame(width: corner, height: corner)
            }
            .overlay(alignment: .topTrailing) {
                ListenResizeHandle(edges: [.top, .right], controller: resizeController).frame(width: corner, height: corner)
            }
            .overlay(alignment: .bottomLeading) {
                ListenResizeHandle(edges: [.bottom, .left], controller: resizeController).frame(width: corner, height: corner)
            }
            .overlay(alignment: .bottomTrailing) {
                ListenResizeHandle(edges: [.bottom, .right], controller: resizeController).frame(width: corner, height: corner)
            }
    }

    // MARK: - Glass

    @ViewBuilder
    private var glassBackground: some View {
        let opacity = settings.voiceBoxOpacity
        ZStack {
            if !reduceTransparency && opacity < 0.99 {
                Color.clear.glassEffect(.regular, in: shape)
            }
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : opacity))
        }
    }

    private var specularRim: some View {
        ZStack {
            shape.strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.05), location: 0.00),
                        .init(color: .white.opacity(0.50), location: 0.16),
                        .init(color: .white.opacity(0.12), location: 0.34),
                        .init(color: .white.opacity(0.05), location: 0.55),
                        .init(color: .white.opacity(0.22), location: 0.70),
                        .init(color: .white.opacity(0.05), location: 1.00),
                    ]),
                    center: .center, angle: .degrees(-90)
                ),
                lineWidth: 1.5
            )
            shape.inset(by: 1.5).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Resize handle

private struct ListenResizeHandle: View {
    let edges: ResizeEdges
    let controller: ListenResizeController

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                guard !controller.isResizing else { return }
                if inside { cursor.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        if !controller.isResizing { controller.begin() }
                        cursor.set()
                        controller.update(edges: edges)
                    }
                    .onEnded { _ in
                        controller.end()
                        NSCursor.arrow.set()
                    }
            )
    }

    private var cursor: NSCursor {
        NSCursor.frameResize(position: position, directions: .all)
    }
    private var position: NSCursor.FrameResizePosition {
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
        case (true, _, true, _):  return .topLeft
        case (true, _, _, true):  return .topRight
        case (_, true, true, _):  return .bottomLeft
        case (_, true, _, true):  return .bottomRight
        case (true, _, _, _):     return .top
        case (_, true, _, _):     return .bottom
        case (_, _, true, _):     return .left
        default:                  return .right
        }
    }
}

// MARK: - Small components

private struct ListenPulseDot: View {
    let active: Bool
    let connecting: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(connecting ? Theme.accent.opacity(0.6) : (active ? Theme.accent : .secondary))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(Theme.accent, lineWidth: 2)
                    .scaleEffect(pulse ? 2.1 : 1).opacity(pulse ? 0 : 0.6)
            )
            // Only run the forever-repeating pulse while capture is live;
            // otherwise the animation keeps compositing behind a hidden panel.
            .animation(
                (active || connecting)
                    ? .easeOut(duration: 1.1).repeatForever(autoreverses: false)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = (active || connecting) }
            .onChange(of: active) { _, _ in pulse = (active || connecting) }
            .onChange(of: connecting) { _, _ in pulse = (active || connecting) }
    }
}

private struct MiniWaveform: View {
    // Observed here ONLY — level updates arrive up to ~100 Hz and must not
    // bubble up into ListenView's body (see `ListenState.audioLevel`).
    @ObservedObject var audioLevel: ListenAudioLevel
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<9, id: \.self) { index in
                Capsule().fill(Theme.accent.opacity(0.85)).frame(width: 2.5, height: barHeight(index))
            }
        }
        .animation(.easeOut(duration: 0.12), value: audioLevel.level)
        .accessibilityHidden(true)
    }
    private func barHeight(_ index: Int) -> CGFloat {
        let envelope = sin(Double(index + 1) / 10.0 * .pi)
        return 3 + CGFloat(Double(audioLevel.level) * envelope) * 13
    }
}

private struct ListenIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

private struct ListenDragGrabber: View {
    @State private var hovering = false
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(hovering ? 0.32 : 0.15))
            .frame(width: 42, height: 4.5)
            .frame(width: 150, height: 20)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Drag to move")
    }
}
