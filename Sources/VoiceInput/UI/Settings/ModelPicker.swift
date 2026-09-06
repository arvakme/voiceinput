import SwiftUI

/// Discovery is the primary path. Manual IDs remain an explicit fallback for
/// private/preview deployments whose provider does not publish a catalog.
struct ModelPickerField: View {
    let placeholder: String
    @Binding var model: String
    let kind: ModelCatalog.Kind
    var baseURL: () -> String = { "" }
    var apiKey: () -> String = { "" }
    var executablePath: () -> String = { "" }
    var nodePath: () -> String = { "" }
    var sdkDirectory: () -> String = { "" }
    var selectedParameters: Binding<[CursorModelParameter]>? = nil

    @State private var showBrowser = false
    @State private var manualEntry = false
    @State private var selectedName = ""
    @State private var selectionIdentity = ""

    private var currentIdentity: String {
        CatalogModel(modelID: model, displayName: "", parameters: selectedParameters?.wrappedValue ?? []).id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { showBrowser = true } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text(model.isEmpty ? "Choose a model…" : (selectionIdentity == currentIdentity && !selectedName.isEmpty ? selectedName : model))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Search models by name or ID")
                Button { manualEntry.toggle() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .help("Enter a custom model ID manually")
            }
            if let parameters = selectedParameters?.wrappedValue, !parameters.isEmpty {
                Text(parameters.map { "\($0.id): \($0.value)" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            if manualEntry {
                FilledTextField(placeholder: placeholder, text: Binding(get: { model }, set: {
                    model = $0; selectedName = ""; selectedParameters?.wrappedValue = []
                }), monospaced: true)
            }
        }
        .popover(isPresented: $showBrowser, arrowEdge: .bottom) {
            ModelBrowser(configuration: .init(kind: kind, baseURL: baseURL(), apiKey: apiKey(),
                executablePath: executablePath(), nodePath: nodePath(), sdkDirectory: sdkDirectory()),
                current: model, currentParameters: selectedParameters?.wrappedValue ?? []) { picked in
                    model = picked.modelID
                    selectedParameters?.wrappedValue = picked.parameters
                    selectedName = picked.displayName
                    selectionIdentity = picked.id
                    showBrowser = false
                }
        }
    }
}

private struct ModelBrowser: View {
    let configuration: ModelCatalog.Configuration
    let current: String
    let currentParameters: [CursorModelParameter]
    let onPick: (CatalogModel) -> Void
    @State private var search = ""
    @State private var models: [CatalogModel] = []
    @State private var error: String?
    @State private var loading = true
    @State private var refresh = 0

    private var filtered: [CatalogModel] {
        models.filter { ModelCatalogSearch.matches($0, query: search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Search name, ID or fast…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                if loading { ProgressView().controlSize(.small) }
                else { Text("\(filtered.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(loading).help("Refresh provider model list")
            }
            .padding(12)
            Divider()
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t refresh models").font(.system(size: 12, weight: .semibold))
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    if models.isEmpty {
                        Text("Check the connection above and Refresh. The pencil button supports private model IDs.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Showing the previously loaded list.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(12)
            }
            if !loading && filtered.isEmpty {
                Text(models.isEmpty ? "No models loaded" : "No matching models")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if configuration.kind == .codex || configuration.kind == .grok {
                            ModelRow(model: CatalogModel(modelID: "", displayName: "Account default"),
                                isCurrent: current.isEmpty) { onPick(CatalogModel(modelID: "", displayName: "Account default")) }
                        }
                        ForEach(filtered) { model in
                            ModelRow(model: model, isCurrent: model.modelID == current && Set(model.parameters) == Set(currentParameters)) {
                                onPick(model)
                            }
                        }
                    }.padding(6)
                }
            }
            Divider()
            Text("Provider catalog · cached for 5 minutes · Refresh reloads it")
                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary).padding(9)
        }
        .frame(width: 410, height: 380)
        .task(id: refresh) {
            loading = true; error = nil
            do {
                let fetched = try await ModelCatalog.fetch(configuration: configuration, refresh: refresh > 0)
                try Task.checkCancellation()
                models = fetched
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct ModelRow: View {
    let model: CatalogModel
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    if model.displayName != model.modelID && !model.modelID.isEmpty {
                        Text(model.modelID).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if !model.detail.isEmpty {
                        Text(model.detail).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                    if !model.parameters.isEmpty {
                        Text(model.parameters.map { "\($0.id)=\($0.value)" }.joined(separator: " · "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.pill.opacity(0.7) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}


/// Search by user-facing name and the exact parameter selections. A bare
/// "fast" query means enabled Fast mode; "fast=false" can find Standard.
enum ModelCatalogSearch {
    static func matches(_ model: CatalogModel, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let parameters = model.parameters.map { "\($0.id)=\($0.value)" }.joined(separator: " ")
        let searchable = "\(model.displayName) \(model.modelID) \(model.detail) \(parameters)".lowercased()
        return terms.allSatisfy { term in
            if term == "fast", !terms.contains("false"),
               let fast = model.parameters.first(where: { $0.id.lowercased() == "fast" }) {
                return fast.value.lowercased() == "true"
            }
            return searchable.contains(term)
        }
    }
}
