import MeetingCore
import SwiftUI

/// The complete collection backing the dashboard count, including meeting context.
struct OpenCommitmentsView: View {
    let model: DashboardModel
    let onSetCompleted: (AnalysisItem, Bool) async throws -> Void
    let onOpenMeeting: (AnalysisItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving: Set<String> = []
    @State private var lastCompleted: AnalysisItem?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Compromisos abiertos").font(DS.Font.title)
                    Text("\(model.openItems.count) pendientes en tus reuniones")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                Button("Cerrar lista") { dismiss() }
                    .buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
            }
            if let item = lastCompleted {
                HStack(spacing: DS.Space.s) {
                    Label("Compromiso completado", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.success)
                    Spacer()
                    Button("Deshacer") { setCompleted(item, completed: false) }
                        .buttonStyle(.ds(.ghost, size: .small)).disabled(saving.contains(item.id))
                        .help("Volver a marcar como pendiente: \(item.text)")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(DS.Font.callout).foregroundStyle(DS.Color.danger)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                    if model.openItems.isEmpty {
                        EmptyStateView(systemImage: "checklist", title: "Sin compromisos abiertos",
                                       message: "Los compromisos pendientes aparecerán aquí al analizar tus reuniones.")
                    }
                    ForEach(model.openItems) { item in
                        SurfaceCard(padding: DS.Space.l) {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Text(item.text).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Text(natureLabel(item.nature))
                                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                                let metadata = [item.ownerName, item.dueText].compactMap { $0 }.joined(separator: " · ")
                                if !metadata.isEmpty {
                                    Text(metadata).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                                }
                                if item.evidenceStatus == .verified, let quote = item.evidenceQuote {
                                    Text("“\(quote)”").font(DS.Font.callout).italic()
                                        .foregroundStyle(DS.Color.textSecondary).textSelection(.enabled)
                                } else if item.evidenceStatus != .verified {
                                    Label("Información no confirmada", systemImage: "exclamationmark.triangle")
                                        .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                                }
                                Button { onOpenMeeting(item) } label: {
                                    Label(model.meetingTitles[item.meetingId] ?? "Abrir reunión",
                                          systemImage: "arrow.up.forward.square")
                                }
                                .buttonStyle(.ds(.ghost, size: .small))
                                .help("Abrir los compromisos de esta reunión")
                                Button { setCompleted(item, completed: true) } label: {
                                    Label("Completar", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(.ds(.secondary, size: .small))
                                .disabled(saving.contains(item.id))
                                .accessibilityLabel("Completar compromiso: \(item.text)")
                                .help("Marcar este compromiso como completado")
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Layout.Sheet.l, height: DS.Layout.Sheet.reviewHeight)
        .background(DS.Color.background)
    }

    private func setCompleted(_ item: AnalysisItem, completed: Bool) {
        guard saving.insert(item.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { saving.remove(item.id) }
            do {
                try await onSetCompleted(item, completed)
                lastCompleted = completed ? item : nil
            } catch {
                errorMessage = "No se pudo \(completed ? "completar" : "reabrir") el compromiso: \(error.localizedDescription)"
            }
        }
    }

    private func natureLabel(_ nature: StatementNature) -> String {
        switch nature {
        case .fact: "Dicho en la reunión"
        case .interpretation: "Interpretación de la IA"
        case .recommendation: "Recomendación de la IA"
        }
    }
}
