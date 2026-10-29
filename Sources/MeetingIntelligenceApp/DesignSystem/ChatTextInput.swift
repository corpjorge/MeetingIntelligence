import AppKit
import SwiftUI

/// Native editing enables spelling, contextual suggestions, and automatic
/// correction using the user's macOS language settings in both chat screens.
struct ChatTextInput: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Self.makeEditor()
        editor.delegate = context.coordinator
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    static func makeEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.minSize = NSSize(width: DS.Space.none, height: DS.Layout.editorMinHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame.size.height = DS.Layout.editorMinHeight
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: DS.Space.none, height: DS.Space.xs)
        editor.setAccessibilityLabel("Pregunta sobre tus reuniones")
        return editor
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text, !editor.hasMarkedText() else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextInput
        init(_ parent: ChatTextInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}
