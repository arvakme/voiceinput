import SwiftUI

/// Vocabulary editor: a table of canonical terms and their common mishearings,
/// inline-editable, with ChatWise +/- controls at the bottom-left. Terms feed
/// Soniox recognition biasing and the polish prompt's correction list.
struct VocabularyTab: View {
    @EnvironmentObject private var vocabulary: VocabularyStore
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedID: VocabularyEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 18) {
                CardHeading(
                    title: "Custom vocabulary",
                    subtitle: "Terms sent to Soniox for recognition biasing and used by polish to fix mishearings — e.g. ‘cloud code’ → ‘Claude Code’."
                )

                table

                ListControlBar(
                    canRemove: selectedID != nil,
                    onAdd: addEntry,
                    onRemove: removeSelected
                )
            }

            learningCard

            rimeImportCard
        }
    }

    private var learningCard: some View {
        Card(padding: 18) {
            CardHeading(
                title: "Automatic term learning",
                subtitle: "Your spelling corrections teach full English names and identifiers automatically. AI polish suggestions and Chinese phrases need confirmation before they influence recognition."
            )
            InlineRow(title: "Learn from accepted dictation", help: "Works after you insert or apply a review. Turn off to stop collecting new terms and suggestions.") {
                BlueToggle(isOn: $vocabulary.learningEnabled)
            }
            Text("\(vocabulary.entries.filter { $0.autoLearned }.count) learned terms · \(vocabulary.pendingCandidates.count) awaiting confirmation")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            if vocabulary.pendingCandidates.isEmpty {
                Text("Correct a name in the review box, or accept a polished transcript. Term suggestions will appear here; ordinary sentence rewrites are ignored.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(vocabulary.pendingCandidates) { suggestion in
                    Hairline()
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(suggestion.oldTerm) → \(suggestion.newTerm)")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            Text("\(suggestion.source == .polish ? "AI polish" : "Your correction") · seen \(suggestion.observations) time(s)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Ignore") { vocabulary.dismissSuggestion(suggestion.id) }
                            .buttonStyle(.bordered)
                        Button("Learn") { vocabulary.acceptSuggestion(suggestion.id) }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                }
            }
            Text("Learned terms stay editable in the table. Deleted or ignored terms will not be suggested again; add one manually to allow learning it again.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Rime import

    private var rimeImportCard: some View {
        Card(padding: 18) {
            CardHeading(
                title: "Rime Import",
                subtitle: "Folds terms learned by the 鼠须管 (Rime) input method — custom phrases and frequently-typed words — into the vocabulary above for recognition biasing only."
            )

            InlineRow(
                title: "Import from Rime",
                help: "Refreshes automatically shortly after VoiceInput launches."
            ) {
                BlueToggle(isOn: $settings.rimeImportEnabled)
            }

            Hairline()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rimeStatusText
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    vocabulary.refreshFromRime()
                } label: {
                    HStack(spacing: 5) {
                        if vocabulary.isRefreshingImportedTerms {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Theme.accent)
                .disabled(vocabulary.isRefreshingImportedTerms)
            }
        }
    }

    private var rimeStatusText: some View {
        Text(rimeStatusMessage)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .truncationMode(.tail)
    }

    private var rimeStatusMessage: String {
        if let error = vocabulary.importedRefreshError {
            return error
        } else if let date = vocabulary.importedRefreshDate {
            return "\(vocabulary.importedTermCount) terms · refreshed \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
        } else {
            return "Not yet refreshed."
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            Hairline()
            if vocabulary.entries.isEmpty {
                emptyState
            } else {
                ForEach(Array(vocabulary.entries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(index: index, entry: entry)
                    if index < vocabulary.entries.count - 1 {
                        Hairline()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Term")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Common mishearings")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("No terms yet. Click + to add a term the recognizer should learn.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
    }

    private func entryRow(index: Int, entry: VocabularyEntry) -> some View {
        let isSelected = selectedID == entry.id
        return HStack(spacing: 12) {
            if entry.autoLearned {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .help("Learned from your correction or an explicitly approved suggestion")
            }
            cellField(
                placeholder: "Claude Code",
                value: Binding(
                    get: { entry.term },
                    set: { newValue in setField(index: index) { $0.term = newValue } }
                )
            )
            cellField(
                placeholder: "cloud code, clot code",
                value: Binding(
                    get: { entry.hints },
                    set: { newValue in setField(index: index) { $0.hints = newValue } }
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = entry.id }
    }

    private func cellField(placeholder: String, value: Binding<String>) -> some View {
        TextField(placeholder, text: value)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Mutations

    /// Mutate a copy of the entry at `index` and push it back through
    /// `VocabularyStore.update`, which persists to settings.
    private func setField(index: Int, _ assign: (inout VocabularyEntry) -> Void) {
        guard vocabulary.entries.indices.contains(index) else { return }
        var entry = vocabulary.entries[index]
        assign(&entry)
        vocabulary.update(entry)
    }

    private func addEntry() {
        let entry = VocabularyEntry(term: "", hints: "")
        vocabulary.add(entry)
        selectedID = entry.id
    }

    private func removeSelected() {
        guard let selectedID,
              let index = vocabulary.entries.firstIndex(where: { $0.id == selectedID })
        else { return }
        vocabulary.remove(at: IndexSet(integer: index))
        self.selectedID = nil
    }
}
