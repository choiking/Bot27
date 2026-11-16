import SwiftUI

/// Every selectable row comes from the provider catalog, including any default
/// alias the provider itself returns. Empty/stale selections are labels, not rows.
struct CatalogModelPicker: View {
    let provider: AppConfig.Provider
    @Binding var selection: String
    @ObservedObject private var catalog = ModelCatalog.shared

    private var models: [(id: String, name: String)] { catalog.models(for: provider) }
    private var selectedID: String { AppConfig.resolvedModel(selection, for: provider) }

    var body: some View {
        LabeledContent("Default model") {
            Menu {
                ForEach(models, id: \.id) { model in
                    Button { selection = model.id } label: {
                        if model.id == selectedID { Label(model.name, systemImage: "checkmark") }
                        else { Text(model.name) }
                    }
                }
            } label: {
                Text(models.first { $0.id == selectedID }?.name
                     ?? (models.isEmpty ? "Models unavailable" : "Choose a model"))
            }
            .disabled(models.isEmpty)
        }
    }
}

/// Passive status: both catalogs update automatically; there is no refresh button.
struct ModelCatalogStatus: View {
    @ObservedObject private var catalog = ModelCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !catalog.refreshing.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Updating model lists…")
                }
            }
            ForEach(AppConfig.Provider.allCases, id: \.self) { provider in
                if let error = catalog.errors[provider] {
                    Text(error + (catalog.models(for: provider).isEmpty ? "" : " Using the saved model list."))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task { catalog.refreshIfNeeded() }
    }
}

struct GPTReasoningPicker: View {
    let title: String
    let model: String
    @Binding var selection: String
    @ObservedObject private var catalog = ModelCatalog.shared

    private var metadata: CodexModel? { CodexModels.selected(model, in: catalog.gptModels) }
    private var effectiveSelection: Binding<String> {
        Binding(get: {
            guard let metadata, !metadata.supportedReasoningEfforts.contains(where: { $0.id == selection }) else {
                return selection
            }
            return ""
        }, set: { selection = $0 })
    }

    var body: some View {
        Picker(title, selection: effectiveSelection) {
            Text(metadata.map { "Default (\($0.defaultReasoningEffort.capitalized))" } ?? "Model default").tag("")
            ForEach(metadata?.supportedReasoningEfforts ?? []) { effort in
                Text(effort.label).tag(effort.id).help(effort.description)
            }
            if metadata == nil && !selection.isEmpty {
                Text("Saved: \(selection.capitalized)").tag(selection)
            }
        }
    }
}
