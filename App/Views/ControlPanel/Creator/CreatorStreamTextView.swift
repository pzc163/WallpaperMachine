import AppKit
import SwiftUI

/// Native bounded text viewport; append-only updates preserve selection and scroll position.
struct CreatorStreamTextView: NSViewRepresentable {
    let text: String
    var monospaced = true
    var onEdit: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CreatorStreamTextView
        init(_ parent: CreatorStreamTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.onEdit?(editor.string)
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            return (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString).utf8.count <= CreatorCodeOutput.maximumSourceBytes
        }
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1))
        editor.isEditable = onEdit != nil; editor.delegate = context.coordinator; editor.allowsUndo = true; editor.isSelectable = true; editor.isRichText = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.setAccessibilityLabel(monospaced ? L("Source code") : L("Thinking process"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = onEdit != nil
        guard editor.string != text else { return }
        let previous = editor.string
        let follows = previous.isEmpty || scroll.contentView.bounds.maxY >= editor.bounds.height - 28
        if text.hasPrefix(previous), let storage = editor.textStorage {
            let tail = String(text.dropFirst(previous.count))
            storage.append(NSAttributedString(string: tail, attributes: [.font: editor.font!, .foregroundColor: NSColor.labelColor]))
        } else { editor.string = text }
        if follows { editor.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0)) }
    }
}
