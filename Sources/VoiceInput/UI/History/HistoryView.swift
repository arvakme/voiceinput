import AppKit
import AVFoundation
import Charts
import SwiftUI

// MARK: - HistoryView

/// ChatWise master-detail history browser. The left column is a searchable list
/// of past dictation sessions; the right pane shows the selected session's
/// transcripts, an audio player (when audio was kept), and a delete control.
struct HistoryView: View {
    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedID: HistoryRecord.ID?
    @State private var searchText: String = ""
    @State private var showClearAllConfirm = false

    // Correction-rate chart data — a plain snapshot pulled from
    // `SessionStatsStore` (not itself observable), refreshed on first
    // appearance and every time the window is brought forward.
    @State private var dailyStats: [(day: Date, injected: Int, corrected: Int)] = []
    @State private var weekStats: (injected: Int, corrected: Int) = (injected: 0, corrected: 0)

    // Shared (not view-owned) so `HistoryWindowController` can stop playback
    // from the window's `willClose` notification — see its comment for why
    // `.onDisappear` below can't be relied on for that.
    @StateObject private var player = AudioPlayer.shared

    private var filteredRecords: [HistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.records }
        return store.records.filter { record in
            record.rawTranscript.lowercased().contains(query)
                || (record.refinedTranscript?.lowercased().contains(query) ?? false)
        }
    }

    private var selectedRecord: HistoryRecord? {
        guard let selectedID else { return nil }
        return store.records.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            SessionStatsHeader(dailyStats: dailyStats, weekStats: weekStats)
            Hairline()
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chrome)
        .onDisappear { player.stop() }
        // Stop playback whenever the selection changes.
        .onChange(of: selectedID) { _, _ in
            player.stop()
        }
        // Keep a valid selection as the list mutates (deletes / filtering).
        .onChange(of: filteredRecords.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = ids.first
            } else if selectedID == nil {
                self.selectedID = ids.first
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = filteredRecords.first?.id
            }
            refreshSessionStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowDidShow)) { _ in
            refreshSessionStats()
        }
    }

    /// Pulls a fresh snapshot from `SessionStatsStore` — called on first
    /// appearance and again on every `.historyWindowDidShow` (window reopen),
    /// since the store itself isn't observable and the hosting view persists
    /// across closes.
    private func refreshSessionStats() {
        dailyStats = SessionStatsStore.shared.dailyStats(days: 14)
        weekStats = SessionStatsStore.shared.weekStats()
    }

    // MARK: In-content header

    private var header: some View {
        ZStack {
            Text("History")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Theme.chrome)
    }

    // MARK: Sidebar (session list)

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Hairline()
            sessionList
            Hairline()
            footerBar
        }
        .frame(width: 240)
        .background(Theme.sidebarBackground)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search transcripts", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(10)
    }

    @ViewBuilder
    private var sessionList: some View {
        if store.records.isEmpty {
            emptyHistoryState
        } else if filteredRecords.isEmpty {
            noMatchState
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredRecords) { record in
                        SessionRow(record: record, isSelected: record.id == selectedID) {
                            selectedID = record.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyHistoryState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(settings.historyEnabled
                 ? "Your dictation sessions will appear here."
                 : "Saving history is turned off.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("No sessions contain “\(searchText)”.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer bar

    private var footerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(audioUsageLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Menu {
                Toggle("Save history", isOn: $settings.historyEnabled)
                Toggle("Keep audio", isOn: $settings.historyKeepAudio)
                    .disabled(!settings.historyEnabled)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("History options")

            Button {
                showClearAllConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(store.records.isEmpty ? Theme.textSecondary.opacity(0.4) : Color.red)
            }
            .buttonStyle(.plain)
            .disabled(store.records.isEmpty)
            .help("Clear all history")
            .confirmationDialog(
                "Delete all dictation history?",
                isPresented: $showClearAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    player.stop()
                    store.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every saved transcript and audio recording.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var countLabel: String {
        let count = store.records.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }

    /// "Audio: 213 MB" — `store.audioDiskUsageBytes` is recomputed by the
    /// store itself on window-open and after a delete, never polled here.
    private var audioUsageLabel: String {
        "Audio: \(HistoryFormat.diskSize(store.audioDiskUsageBytes))"
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detail: some View {
        if let record = selectedRecord {
            HistoryDetailView(record: record, player: player) {
                deleteRecord(record)
            }
            .id(record.id)
        } else {
            noSelectionState
        }
    }

    private var noSelectionState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("Select a session")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Pick a dictation session on the left to see its transcript and audio.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }

    // MARK: Actions

    private func deleteRecord(_ record: HistoryRecord) {
        player.stop()
        // Advance selection to a neighbour before removing.
        if let index = filteredRecords.firstIndex(where: { $0.id == record.id }) {
            let remaining = filteredRecords.filter { $0.id != record.id }
            let nextIndex = min(index, remaining.count - 1)
            selectedID = nextIndex >= 0 ? remaining[nextIndex].id : nil
        }
        store.delete([record.id])
    }
}

// MARK: - SessionStatsHeader

/// A compact 14-day correction-rate chart, spanning the window above the
/// master-detail split: one bar per day for sessions whose text actually
/// reached the target app, with the corrected count overlaid so the bar
/// visibly "hollows out" as ASR quality improves. Headline is the rolling
/// 7-day rate. Purely reactive — the two arrays are pulled snapshots handed
/// down from `HistoryView`, never a live subscription.
private struct SessionStatsHeader: View {
    let dailyStats: [(day: Date, injected: Int, corrected: Int)]
    let weekStats: (injected: Int, corrected: Int)

    private var hasData: Bool {
        dailyStats.contains { $0.injected > 0 || $0.corrected > 0 }
    }

    private var weekHeadline: String {
        guard weekStats.injected > 0 else { return "This week: no dictations" }
        let percent = Int((Double(weekStats.corrected) / Double(weekStats.injected) * 100).rounded())
        return "This week: \(percent)% corrected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Correction rate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(weekHeadline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            if hasData {
                chart.frame(height: 52)
            } else {
                Text("No data yet — corrections you make in the review box will chart here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.chrome)
    }

    /// Two `.unstacked` bar marks per day sharing one x — the lighter
    /// `injected` bar is the full session count for that day, the accent
    /// `corrected` bar draws at the same baseline so it reads as a fill
    /// level inside the bar rather than a second, stacked series.
    private var chart: some View {
        Chart(dailyStats, id: \.day) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Sessions", entry.injected),
                stacking: .unstacked
            )
            .foregroundStyle(Theme.pill)
            .cornerRadius(2)

            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Corrected", entry.corrected),
                stacking: .unstacked
            )
            .foregroundStyle(Theme.accent)
            .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - SessionRow

/// A single source-list row: primary line is the start of the best transcript;
/// the secondary line is a relative date and duration.
private struct SessionRow: View {
    let record: HistoryRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLine)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(secondaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if record.audioFilename != nil {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.pill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var primaryLine: String {
        let text = record.bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "(empty transcript)" }
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 40 { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 40)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var secondaryLine: String {
        "\(HistoryFormat.relativeDate(record.date)) · \(HistoryFormat.duration(record.durationSeconds))"
    }
}

// MARK: - HistoryDetailView

/// The right-hand detail pane for one session.
private struct HistoryDetailView: View {
    let record: HistoryRecord
    @ObservedObject var player: AudioPlayer
    let onDelete: () -> Void

    @EnvironmentObject private var store: HistoryStore

    @State private var rawCopied = false
    @State private var refinedCopied = false

    private var audioURL: URL? { store.audioURL(for: record) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metaHeader

                if let url = audioURL {
                    AudioPlayerRow(player: player, url: url)
                }

                transcriptSection(
                    title: "Raw transcript",
                    text: record.rawTranscript,
                    copied: $rawCopied
                )

                if let refined = record.refinedTranscript,
                   !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcriptSection(
                        title: "Refined",
                        text: refined,
                        copied: $refinedCopied
                    )
                }

                deleteRow
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }

    // MARK: Header

    private var metaHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HistoryFormat.absoluteDate(record.date))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                metaChip(record.backend, system: "cpu")
                metaChip(HistoryFormat.duration(record.durationSeconds), system: "clock")
                metaChip(record.injected ? "Injected" : "Not injected",
                         system: record.injected ? "checkmark.circle" : "xmark.circle")
            }
        }
    }

    private func metaChip(_ text: String, system: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .regular))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(Theme.pill.opacity(0.6))
        )
    }

    // MARK: Transcript sections

    private func transcriptSection(title: String, text: String, copied: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    copyToPasteboard(text)
                    flash(copied)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                        Text(copied.wrappedValue ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }

            let display = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(display.isEmpty ? "(empty)" : display)
                .font(.system(size: 13))
                .foregroundStyle(display.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.fieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
    }

    // MARK: Delete

    private var deleteRow: some View {
        HStack {
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Label("Delete session", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.red)
        }
    }

    // MARK: Helpers

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            flag.wrappedValue = false
        }
    }
}

// MARK: - AudioPlayerRow

/// A compact transport: play/pause, a scrubbable progress bar, and elapsed /
/// total timestamps. Binds to the shared `AudioPlayer` for this view tree.
private struct AudioPlayerRow: View {
    @ObservedObject var player: AudioPlayer
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying(url: url) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            VStack(spacing: 5) {
                ProgressBar(progress: player.isLoaded(url: url) ? player.progress : 0) { fraction in
                    player.seek(to: fraction, url: url)
                }
                .frame(height: 6)

                HStack {
                    Text(HistoryFormat.timecode(player.isLoaded(url: url) ? player.currentTime : 0))
                    Spacer()
                    Text(HistoryFormat.timecode(player.duration(of: url)))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// A simple accent-tinted progress bar that reports a 0…1 tap/drag position.
private struct ProgressBar: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.hairline)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        onSeek(fraction)
                    }
            )
        }
    }
}

// MARK: - AudioPlayer

/// A small `ObservableObject` wrapper around `AVAudioPlayer`. It owns one player
/// at a time, identified by the file URL, and publishes playback progress on a
/// timer so the transport stays in sync. Playback is stopped explicitly when the
/// selection changes or the window closes.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var playing = false

    private var avPlayer: AVAudioPlayer?
    private var loadedURL: URL?
    private var timer: Timer?
    private var durationCache: [URL: TimeInterval] = [:]

    /// 0…1 fraction of the loaded file that has played.
    var progress: Double {
        guard let player = avPlayer, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    func isLoaded(url: URL) -> Bool {
        loadedURL == url && avPlayer != nil
    }

    func isPlaying(url: URL) -> Bool {
        isLoaded(url: url) && playing
    }

    /// Total duration of a file, cached so the UI can show it before playback.
    func duration(of url: URL) -> TimeInterval {
        if let cached = durationCache[url] { return cached }
        if isLoaded(url: url), let player = avPlayer {
            durationCache[url] = player.duration
            return player.duration
        }
        // Probe without disturbing any active player.
        if let probe = try? AVAudioPlayer(contentsOf: url) {
            durationCache[url] = probe.duration
            return probe.duration
        }
        return 0
    }

    /// Toggle play/pause for `url`, loading it if it isn't already loaded.
    func toggle(url: URL) {
        if isLoaded(url: url) {
            if playing { pause() } else { play() }
        } else {
            load(url: url)
            play()
        }
    }

    /// Seek to a 0…1 fraction of `url`, loading it first if needed.
    func seek(to fraction: Double, url: URL) {
        if !isLoaded(url: url) {
            load(url: url)
        }
        guard let player = avPlayer else { return }
        let clamped = max(0, min(1, fraction))
        player.currentTime = clamped * player.duration
        currentTime = player.currentTime
    }

    /// Stop and tear down the active player.
    ///
    /// Also clears `durationCache` so it cannot grow without bound across a long
    /// window session (e.g. deleting and re-creating many records). Durations
    /// are cheap to re-probe from a prepared `AVAudioPlayer` when next needed.
    func stop() {
        timer?.invalidate()
        timer = nil
        avPlayer?.stop()
        avPlayer = nil
        loadedURL = nil
        playing = false
        currentTime = 0
        durationCache.removeAll()
    }

    // MARK: Private

    private func load(url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            avPlayer = player
            loadedURL = url
            durationCache[url] = player.duration
            currentTime = 0
        } catch {
            Log.ui.error("History: failed to load audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func play() {
        guard let player = avPlayer else { return }
        player.play()
        playing = true
        startTimer()
    }

    private func pause() {
        avPlayer?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
        if let player = avPlayer { currentTime = player.currentTime }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.avPlayer else { return }
            self.currentTime = player.currentTime
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.playing = false
            player.currentTime = 0
            self.currentTime = 0
        }
    }
}

// MARK: - Formatting

/// Date / duration formatting shared across the history UI.
private enum HistoryFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// "3 min ago", "yesterday", etc.
    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// "Jun 11, 2026 at 2:14 PM"
    static func absoluteDate(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    /// "213 MB", "1.2 GB", etc.
    static func diskSize(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Duration as "0:12" or "1:05:09".
    static func duration(_ seconds: Double) -> String {
        timecode(seconds)
    }

    /// m:ss (or h:mm:ss) timecode for a non-negative second count.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
