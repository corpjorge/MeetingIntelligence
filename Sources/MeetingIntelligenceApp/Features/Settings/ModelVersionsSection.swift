import AppKit
import MeetingCore
import SwiftUI

/// Versions, updates and unused models (Ajustes › Modelos). TD-27.
struct ModelVersionsSection: View {
    @Environment(AppEnvironment.self) private var env

    private var updates: ModelUpdateController { env.modelUpdates }

    var body: some View {
        Section("Versiones y actualizaciones") {
            HStack(spacing: DS.Space.m) {
                Button("Buscar actualizaciones") { Task { await updates.checkForUpdates() } }
                    .disabled(updates.isChecking)
                if updates.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                if let last = updates.lastChecked {
                    Text("Última comprobación: \(last.formatted(date: .omitted, time: .shortened))")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            Text("Solo se consulta huggingface.co al pulsar el botón y no se envía nada de tus reuniones. Una actualización descarga solo los archivos que cambiaron, comprueba su huella, elimina los que ya no existen y conserva la versión anterior hasta verificar que la nueva carga.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            ForEach(updates.rows) { row in rowView(row) }
        }
        .task { updates.refreshInventory() }

        if !updates.unusedFolders.isEmpty {
            Section("Modelos que esta app no usa") {
                Text("Están en la caché compartida de FluidAudio. Otra app basada en FluidAudio podría usarlos; si los necesita, los volverá a descargar.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                ForEach(updates.unusedFolders) { folder in
                    HStack {
                        Text(folder.url.lastPathComponent).font(DS.Font.body)
                        Spacer()
                        Text(size(folder.bytes)).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                        Button("Borrar") {
                            if confirm("¿Borrar \(folder.url.lastPathComponent)?", "Se liberan \(size(folder.bytes)).") {
                                updates.deleteFolder(folder)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ModelUpdateController.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(row.model.displayName).font(DS.Font.bodyEmphasis)
                Text(describe(row.state)).font(DS.Font.caption).foregroundStyle(tone(row.state))
                if let reason = row.model.unusedReason, row.model.isInstalled {
                    Text("Sin uso: \(reason).").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            Spacer()
            if row.bytes > 0 {
                Text(size(row.bytes)).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
            }
            if case .available(let plan) = row.state {
                Button("Actualizar") { Task { await updates.update(row.id) } }
                    .disabled(updates.busyReason != nil)
                    .help(updates.busyReason.map { "No disponible mientras \($0)" } ?? "Descarga \(size(plan.downloadBytes))")
            }
            if row.model.unusedReason != nil, row.model.isInstalled {
                Button("Borrar") {
                    if confirm("¿Borrar \(row.model.displayName)?",
                               "Se liberan \(size(row.bytes)). Si vuelves a activar la función, se descargará de nuevo.") {
                        Task { await updates.deleteUnusedModel(row.id) }
                    }
                }
            }
        }
    }

    private func describe(_ state: ModelUpdateController.State) -> String {
        switch state {
        case .unchecked: "Sin comprobar"
        case .checking: "Comprobando…"
        case .notInstalled: "No descargado"
        case .upToDate(let revision): "Al día · versión \(revision.prefix(7))"
        case .available(let plan):
            "Actualización disponible: \(plan.changed.count) archivo(s), \(size(plan.downloadBytes))"
                + (plan.obsolete.isEmpty ? "" : "; \(plan.obsolete.count) obsoleto(s) se eliminan")
        case .pinned(let revision): "Versión \(revision.prefix(7)) fijada por FluidAudio 0.17.7: cambia al actualizar la biblioteca"
        case .updating(let fraction): "Actualizando…" + (fraction.map { " \(Int($0 * 100)) %" } ?? "")
        case .failed(let message): "Error: \(message)"
        }
    }

    private func tone(_ state: ModelUpdateController.State) -> Color {
        switch state {
        case .available: DS.Color.accent
        case .failed: DS.Color.warning
        case .upToDate: DS.Color.success
        default: DS.Color.textSecondary
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Borrar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
