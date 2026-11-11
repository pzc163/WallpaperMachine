import AppKit
import SwiftUI

/// Native, scrollable plain text input with IME-safe Return handling and a three-to-eight-line height.
struct CreatorPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let focusID: UUID
    let submit: () -> Void
    var pasteImage: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = Editor()
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.font = .systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
        editor.defaultParagraphStyle = paragraph
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("creator-prompt")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        if editor.string != text { editor.string = text }
        editor.isEditable = context.environment.isEnabled
        editor.submit = submit
        editor.pasteImage = pasteImage
        editor.setAccessibilityLabel(L("Describe your wallpaper or the changes you want"))
        if context.coordinator.lastFocus != focusID, let window = editor.window, window.isKeyWindow {
            context.coordinator.lastFocus = focusID
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = max(0, proposal.width ?? 300)
        guard let editor = scroll.documentView as? NSTextView, let container = editor.textContainer,
              let layout = editor.layoutManager else { return CGSize(width: width, height: 76) }
        container.containerSize = CGSize(width: max(1, width - 8), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: min(176, max(76, ceil(layout.usedRect(for: container).height) + 16)))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CreatorPromptEditor
        var lastFocus: UUID?
        init(_ parent: CreatorPromptEditor) { self.parent = parent; lastFocus = parent.focusID }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
    final class Editor: NSTextView {
        var submit: () -> Void = {}
        var pasteImage: (() -> Bool)?
        override func paste(_ sender: Any?) {
            if pasteImage?() == true { return }
            else { super.paste(sender) }
        }
        static func sends(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, marked: Bool) -> Bool {
            [36, 76].contains(keyCode) && modifiers.intersection([.shift, .option, .control, .command]).isEmpty && !marked
        }
        override func keyDown(with event: NSEvent) {
            if Self.sends(keyCode: event.keyCode, modifiers: event.modifierFlags, marked: hasMarkedText()) {
                if isEditable { submit() }
            } else { super.keyDown(with: event) }
        }
    }
}
