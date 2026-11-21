import SwiftUI
import AppKit
import ScanQuery
import ScanTheme

/// A text view for SQL and filter expressions, colored as it is typed. SwiftUI's TextEditor cannot
/// color ranges of text, so this wraps AppKit's text view.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var highlight: Bool
    @Binding var focused: Bool
    /// Called for a plain Return. Return true when it was handled, so no new line is inserted.
    var onReturn: () -> Bool
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let view = EditorTextView()
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.insertionPointColor = ScanTheme.accent
        view.selectedTextAttributes = [.backgroundColor: ScanTheme.accent(0.3)]
        view.delegate = context.coordinator
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }
        view.string = text
        scroll.documentView = view
        context.coordinator.apply(to: view, highlight: highlight)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? EditorTextView else { return }
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        context.coordinator.apply(to: view, highlight: highlight)
        if focused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        private var lastHighlight: Bool?
        init(_ parent: SQLEditor) { self.parent = parent }
        func focusChanged(_ focused: Bool) {
            guard parent.focused != focused else { return }
            DispatchQueue.main.async { self.parent.focused = focused }
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            paint(view)
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                return !shift && parent.onReturn()
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
        /// Sets the font for the current mode and colors the text.
        func apply(to view: NSTextView, highlight: Bool) {
            let font = highlight ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : NSFont.systemFont(ofSize: 13)
            if lastHighlight != highlight || view.font != font { view.font = font; lastHighlight = highlight }
            view.typingAttributes = [.font: font, .foregroundColor: ScanTheme.primary]
            paint(view)
        }
        private func paint(_ view: NSTextView) {
            guard let storage = view.textStorage, let font = view.font else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: ScanTheme.primary], range: whole)
            if parent.highlight {
                for token in SQLTokenizer.tokens(in: storage.string) {
                    let color: NSColor
                    switch token.kind {
                    case .keyword: color = ScanTheme.syntaxKeyword
                    case .string: color = ScanTheme.syntaxString
                    case .number: color = ScanTheme.syntaxNumber
                    case .quotedIdentifier: color = ScanTheme.syntaxIdentifier
                    case .function: color = ScanTheme.syntaxFunction
                    case .comment: color = ScanTheme.syntaxComment
                    }
                    storage.addAttribute(.foregroundColor, value: color, range: token.range)
                    if token.kind == .keyword { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold), range: token.range) }
                    if token.kind == .comment { storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: token.range) }
                }
            }
            storage.endEditing()
        }
    }
}

/// Reports focus changes, so the panel knows whether the editor has the keyboard.
final class EditorTextView: NSTextView {
    var onFocusChange: (@MainActor (Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { MainActor.assumeIsolated { onFocusChange?(true) } }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { MainActor.assumeIsolated { onFocusChange?(false) } }; return ok }
}
