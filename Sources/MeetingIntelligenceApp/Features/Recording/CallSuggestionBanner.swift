import MeetingAudio
import SwiftUI

/// "<App> está en una llamada — ¿Grabar?" Only a suggestion: nothing records until the user confirms.
struct CallSuggestionBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let suggestion = env.calls.startSuggestion, !env.recording.isActive {
            InlineBanner(tone: .recording, systemImage: "phone.connection",
                         title: "\(suggestion.app.name) está en una llamada",
                         message: "¿Grabar y transcribir esta conversación? Nada se graba sin tu confirmación.") {
                HStack(spacing: DS.Space.s) {
                    Menu {
                        Button("No sugerir para \(suggestion.app.name)") { env.calls.ignoreApp(suggestion.id) }
                        Button("Descartar") { env.calls.dismissStart() }
                    } label: { Text("Ahora no") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button("Preparar grabación") { env.calls.acceptStart() }.buttonStyle(.ds(.recording, size: .small))
                }
            }
        }
    }
}
