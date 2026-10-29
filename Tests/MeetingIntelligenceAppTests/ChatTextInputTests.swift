import AppKit
import SwiftUI
import Testing
@testable import MeetingIntelligenceApp

@Suite("Chat: edición y ortografía")
struct ChatTextInputTests {
    @Test func nativeEditorEnablesSpellingAndAutomaticCorrection() {
        let editor = ChatTextInput.makeEditor()
        #expect(editor.isContinuousSpellCheckingEnabled)
        #expect(editor.isGrammarCheckingEnabled)
        #expect(editor.isAutomaticSpellingCorrectionEnabled)
        #expect(editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isRichText)
        #expect(!editor.isAutomaticLinkDetectionEnabled)
    }

    @Test func typingBindsDraftAndReturnSubmitsOnce() {
        var draft = ""
        var submissions: [String] = []
        let input = ChatTextInput(text: Binding(get: { draft }, set: { draft = $0 }), onSubmit: {
            submissions.append(draft)
        })
        let coordinator = input.makeCoordinator()
        let editor = ChatTextInput.makeEditor()
        editor.string = "¿Qué validaciones faltan?"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(draft == editor.string)
        #expect(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submissions == [editor.string])
        #expect(!coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }
}
