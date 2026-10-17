import MeetingAudio
import SwiftUI

/// "Muted in the call ≠ paused here". Static on purpose: the call app's mute state
/// is not readable (TD-23). The button only pauses; resuming is always explicit.
struct CallMuteReminderBanner: View {
    let appName: String?
    let onPauseMicrophone: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        InlineBanner(tone: .info, systemImage: "mic.badge.xmark",
                     title: CallMuteReminder.title(appName: appName),
                     message: CallMuteReminder.message(appName: appName)) {
            HStack(spacing: DS.Space.s) {
                Button("Pausar mi micrófono", action: onPauseMicrophone)
                    .buttonStyle(.ds(.secondary, size: .small))
                IconButton(systemImage: "xmark", help: "Ocultar este recordatorio en esta grabación", action: onDismiss)
            }
        }
    }
}
