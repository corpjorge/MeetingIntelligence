import MeetingCore
import SwiftUI

/// Shared selection for analysis and chat; both use the persisted AI configuration.
struct AIProviderControls: View {
    var showsEffort = true
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) { providerPicker; statusPill; modelPicker; if showsEffort { effortPicker } }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.m) { providerPicker; statusPill }
                HStack(spacing: DS.Space.m) { modelPicker; if showsEffort { effortPicker } }
            }
        }
    }

    var providerPicker: some View {
        @Bindable var ai = env.ai
        return Picker("Proveedor", selection: $ai.selectedProvider) {
            ForEach(AIProviderKind.allCases) { kind in
                Text(kind.displayName + (kind.sendsDataToRemoteService ? " · nube" : " · local")).tag(kind)
            }
        }
        .frame(width: DS.Layout.Control.pickerWideWidth)
    }

    @ViewBuilder
    var statusPill: some View {
        if let status = env.ai.statuses[env.ai.selectedProvider] {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ProviderStatusPill(status: status)
                if let login = status.accountLogin {
                    Text(login).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1).help("Cuenta usada por \(status.kind.displayName)")
                }
            }
        }
    }

    var modelPicker: some View {
        HStack(spacing: DS.Space.xs) {
            Picker("Modelo", selection: Binding(
                get: { env.ai.selectedModel(for: env.ai.selectedProvider) },
                set: { env.ai.selectModel($0, for: env.ai.selectedProvider) })) {
                Text(env.ai.selectedProvider == .copilotCLI ? "Automático"
                     : env.ai.selectedProvider == .ollama ? "Seleccionar modelo" : "Predeterminado").tag("")
                ForEach(env.ai.modelChoices(for: env.ai.selectedProvider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: DS.Layout.Control.pickerWidth)
            .help("Modelo usado para las próximas consultas y análisis con el proveedor seleccionado")
            IconButton(systemImage: "arrow.clockwise", help: "Actualizar modelos disponibles") {
                Task { await env.ai.refreshStatuses() }
            }
            .disabled(env.ai.isDetecting)
        }
    }

    @ViewBuilder
    var effortPicker: some View {
        if let status = env.ai.statuses[env.ai.selectedProvider] {
            if !status.effortLevels.isEmpty {
                Picker("Esfuerzo", selection: Binding(
                    get: { env.ai.configuration(for: env.ai.selectedProvider).effort ?? "" },
                    set: { value in
                        var config = env.ai.configuration(for: env.ai.selectedProvider)
                        config.effort = value.isEmpty ? nil : value
                        env.ai.save(config)
                    })) {
                    Text("Esfuerzo predeterminado").tag("")
                    ForEach(status.effortLevels, id: \.self) { Text("Esfuerzo: \(EffortLabel.text($0))").tag($0) }
                }
                .labelsHidden()
                .disabled(!env.ai.configuration(for: env.ai.selectedProvider).supportsEffortSelection)
                .frame(width: DS.Layout.Control.pickerNarrowWidth)
                .help(env.ai.configuration(for: env.ai.selectedProvider).supportsEffortSelection
                      ? "Nivel de razonamiento del modelo. Más esfuerzo = respuesta más profunda, más lenta y con más consumo."
                      : "Copilot en Automático utiliza esfuerzo predeterminado. Elige un modelo concreto para cambiarlo.")
            }
        }
    }

}
