import SwiftUI

// MARK: - Model catalog fetching

/// Fetches available model identifiers from a provider endpoint. Speaks both
/// list dialects: OpenAI-style (`GET {base}/models`, Bearer auth — OpenRouter,
/// Cerebras, Ollama, …) and Anthropic-style (same path, but `x-api-key` +
/// `anthropic-version` headers). Soniox realtime has no public list endpoint,
/// so it ships a curated catalog.
enum ModelCatalog {
    enum Kind {
        case chat            // every model the endpoint lists
        case sonioxRealtime  // curated static list
        case sonioxAsync     // curated static list
    }

    static let sonioxModels = ["stt-rt-v5", "stt-rt-v4", "stt-rt-preview"]
    static let sonioxAsyncModels = ["stt-async-v5", "stt-async-preview", "stt-async-v4"]

    static func fetch(kind: Kind, baseURL: String, apiKey: String) async throws -> [String] {
        switch kind {
        case .sonioxRealtime: return sonioxModels
        case .sonioxAsync:    return sonioxAsyncModels
        case .chat: break
        }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              let url = URL(string: base.hasSuffix("/") ? base + "models" : base + "/models") else {
            throw CatalogError.badURL
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        let isAnthropic = base.lowercased().contains("anthropic")
        if isAnthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }

        // Both dialects return {"data": [{"id": ...}, ...]}.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw CatalogError.badResponse
        }
        var ids = list.compactMap { $0["id"] as? String }
        ids = Array(Set(ids)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return ids
    }

    enum CatalogError: LocalizedError {
        case badURL, badResponse
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL:       return "Invalid base URL"
            case .badResponse:  return "Unexpected response shape"
            case .http(let c):  return "HTTP \(c)"
            }
        }
    }
}

// MARK: - Picker field

/// A model field that stays free-text editable but adds a browse button: it
/// fetches the provider's model list and presents a searchable popover —
/// essential for catalogs like OpenRouter's 400+ models.
struct ModelPickerField: View {
    let placeholder: String
    @Binding var model: String
    let kind: ModelCatalog.Kind
    /// Closures so the fetch always uses the *current* field values.
    var baseURL: () -> String = { "" }
    var apiKey: () -> String = { "" }

    @State private var showBrowser = false

    var body: some View {
        HStack(spacing: 8) {
            FilledTextField(placeholder: placeholder, text: $model, monospaced: true)
            Button {
                showBrowser = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("Browse available models")
            .popover(isPresented: $showBrowser, arrowEdge: .bottom) {
                ModelBrowser(
                    kind: kind,
                    baseURL: baseURL(),
                    apiKey: apiKey(),
                    current: model
                ) { picked in
                    model = picked
                    showBrowser = false
                }
            }
        }
    }
}

/// The searchable popover list.
private struct ModelBrowser: View {
    let kind: ModelCatalog.Kind
    let baseURL: String
    let apiKey: String
    let current: String
    let onPick: (String) -> Void

    @State private var search = ""
    @State private var models: [String] = []
    @State private var error: String?
    @State private var loading = true

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return models }
        // Space-separated terms must all match (e.g. "oss free").
        let terms = query.lowercased().split(separator: " ")
        return models.filter { id in
            let lower = id.lowercased()
            return terms.allSatisfy { lower.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search models…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(filtered.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if let error {
                VStack(spacing: 6) {
                    Text("Couldn't fetch models")
                        .font(.system(size: 12, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Check the base URL / API key, or just type the model name.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else if !loading && filtered.isEmpty {
                Text(models.isEmpty ? "No models returned" : "No match")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered, id: \.self) { id in
                            ModelRow(id: id, isCurrent: id == current) {
                                onPick(id)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 340, height: 320)
        .task {
            do {
                models = try await ModelCatalog.fetch(kind: kind, baseURL: baseURL, apiKey: apiKey)
                loading = false
            } catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}

private struct ModelRow: View {
    let id: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(id)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.pill.opacity(0.7) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
