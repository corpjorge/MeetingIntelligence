import MeetingCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "waveform.circle.fill").font(DS.Font.heroIcon).foregroundStyle(DS.Color.accent)
                VStack(alignment: .leading) {
                    Text("Bienvenido a \(AppIdentity.displayName)").font(DS.Font.title)
                    Text("Graba, transcribe y analiza conversaciones de cualquier app de videollamada. Todo local por defecto.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            if step == 0 {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    feature("lock.shield", "Privado por diseño", "Audio, transcripciones y perfiles de voz se quedan en este Mac.")
                    feature("cpu", "Parakeet Ultra en el Neural Engine", "Transcripción local de alta precisión en español con términos en inglés.")
                    feature("person.2.wave.2", "Quién dijo qué", "Diarización local y reconocimiento de voces solo con consentimiento.")
                    feature("sparkles", "IA opcional", "Claude Code, Codex, Antigravity, GitHub Copilot u Ollama, siempre con tu confirmación.")
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("¿Cómo te llamas?").font(DS.Font.headline)
                    TextField("Tu nombre", text: $name).textFieldStyle(.roundedBorder)
                    Text("Se usa para atribuirte lo que se graba con tu micrófono.").font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("Modelos locales").font(DS.Font.headline)
                    Text("Parakeet Ultra (~630 MB) y los modelos de diarización se descargan una sola vez desde Hugging Face (FluidInference) y se compilan para el Neural Engine.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    ModelSetupBanner()
                    Text("Puedes continuar mientras se descargan.").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            HStack {
                if step == 1 { Button("Atrás") { step = 0 }.buttonStyle(.dsGhost) }
                Spacer()
                if step == 0 {
                    Button("Continuar") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            env.settings.localUserName = trimmed
                            _ = try? env.database.setLocalUserName(trimmed)
                        }
                        step = 1
                    }
                    .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("Empezar") { env.settings.hasCompletedOnboarding = true }
                        .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: DS.Layout.Sheet.xl)
        .onAppear { name = env.settings.localUserName }
        .interactiveDismissDisabled()
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: icon).foregroundStyle(DS.Color.accent).frame(width: DS.Size.featureIcon)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.bodyEmphasis)
                Text(text).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            }
        }
    }
}
