import AppKit

protocol EditorViewControllerDelegate: AnyObject {
    func editorTextDidChange(_ vc: EditorViewController)
    func editorCursorMoved(_ vc: EditorViewController, line: Int, col: Int)
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class EditorViewController: NSViewController, NSTextViewDelegate {
    weak var delegate: EditorViewControllerDelegate?

    private(set) var scrollView: NSScrollView!
    private(set) var textView: NSTextView!
    private var lineNumbers: LineNumberView?
    private var highlighter: SyntaxHighlighter?

    private static var highlighterCache: [Document.Language: SyntaxHighlighter] = [:]
    private static let fullHighlightThreshold = 100_000
    private var highlightWorkItem: DispatchWorkItem?
    private var scrollHighlightItem: DispatchWorkItem?

    private var suppressTextChange = false
    private var suppressAutoIndent = false

    var document: Document? {
        didSet { if isViewLoaded && document !== oldValue { loadDoc() } }
    }

    private static func cachedHighlighter(for language: Document.Language) -> SyntaxHighlighter {
        if let h = highlighterCache[language] { return h }
        let h = SyntaxHighlighter(language: language)
        highlighterCache[language] = h
        return h
    }

    // MARK: - View lifecycle

    override func loadView() {
        let wrapper = FlippedView()

        scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView = scrollView.documentView as? NSTextView
        // Force TextKit 1 so layout manager APIs work reliably
        _ = textView.layoutManager

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = false
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: Theme.foreground,
        ]
        textView.font = Theme.editorFont
        textView.textColor = Theme.foreground
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self

        let tabW = " ".size(withAttributes: [.font: Theme.editorFont]).width * 4
        let para = NSMutableParagraphStyle()
        para.tabStops = []
        para.defaultTabInterval = tabW
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [
            .font: Theme.editorFont,
            .foregroundColor: Theme.foreground,
            .paragraphStyle: para,
        ]

        lineNumbers = LineNumberView(textView: textView)

        wrapper.addSubview(lineNumbers!)
        wrapper.addSubview(scrollView)
        NSLayoutConstraint.activate([
            lineNumbers!.topAnchor.constraint(equalTo: wrapper.topAnchor),
            lineNumbers!.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            lineNumbers!.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: lineNumbers!.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        view = wrapper
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
    }

    @objc private func boundsChanged(_ n: Notification) {
        lineNumbers?.needsDisplay = true
        scheduleScrollHighlight()
    }

    private func scheduleScrollHighlight() {
        scrollHighlightItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.highlightVisible()
        }
        scrollHighlightItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
    }

    // MARK: - Document

    private func loadDoc() {
        guard let doc = document else { return }
        highlightWorkItem?.cancel()
        scrollHighlightItem?.cancel()
        highlighter = Self.cachedHighlighter(for: doc.language)

        let lm = textView.layoutManager!
        suppressTextChange = true

        if let cached = doc.cachedTextStorage {
            lm.replaceTextStorage(cached)
        } else {
            let para = textView.defaultParagraphStyle ?? NSParagraphStyle.default
            let ts = NSTextStorage(string: doc.content, attributes: [
                .font: Theme.editorFont,
                .foregroundColor: Theme.foreground,
                .paragraphStyle: para,
            ])
            lm.replaceTextStorage(ts)
            doc.cachedTextStorage = ts
        }

        suppressTextChange = false
        lineNumbers?.needsDisplay = true
        deferredHighlightVisible()
    }

    /// Call after the document's language changes (e.g. Save As with a new extension).
    func reloadLanguage() {
        guard let doc = document else { return }
        highlighter = Self.cachedHighlighter(for: doc.language)
        rehighlightAll()
    }

    /// Deferred to next run-loop so the scroll view geometry is settled
    /// after replaceTextStorage.  For small files the full document is
    /// highlighted; large files get viewport-only (scroll handles the rest).
    private func deferredHighlightVisible() {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let ts = self.textView.textStorage, ts.length > 0 else { return }

            let visible = self.visibleCharacterRange()
            if ts.length <= Self.fullHighlightThreshold {
                ts.beginEditing()
                self.highlighter?.highlight(ts, in: NSRange(location: 0, length: ts.length))
                ts.endEditing()
            } else if visible.length > 0 {
                ts.beginEditing()
                self.highlighter?.highlight(ts, in: visible)
                ts.endEditing()
            }
        }
        highlightWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    /// Highlights the visible range plus a buffer for smooth scrolling.
    private func highlightVisible() {
        guard let ts = textView.textStorage, ts.length > 0 else { return }
        let visible = visibleCharacterRange()
        guard visible.length > 0 else { return }

        let buffer = 3000
        let start = max(0, visible.location - buffer)
        let end = min(ts.length, NSMaxRange(visible) + buffer)
        let range = NSRange(location: start, length: end - start)

        ts.beginEditing()
        highlighter?.highlight(ts, in: range)
        ts.endEditing()
    }

    private func visibleCharacterRange() -> NSRange {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        }
        let visibleRect = scrollView.documentVisibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        return lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    private func rehighlightAll() {
        guard let ts = textView.textStorage, ts.length > 0 else { return }
        if ts.length > Self.fullHighlightThreshold {
            highlightVisible()
            return
        }
        ts.beginEditing()
        highlighter?.highlight(ts, in: NSRange(location: 0, length: ts.length))
        ts.endEditing()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString text: String?) -> Bool {
        guard !suppressAutoIndent, let text = text, text == "\n" else { return true }

        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0))
        let line = ns.substring(with: lineRange)

        var indent = ""
        for ch in line {
            if ch == " " || ch == "\t" { indent.append(ch) }
            else { break }
        }
        guard !indent.isEmpty else { return true }

        suppressAutoIndent = true
        textView.insertText("\n" + indent, replacementRange: range)
        suppressAutoIndent = false
        return false
    }

    func textDidChange(_ n: Notification) {
        guard !suppressTextChange else { return }
        let content = textView.string
        document?.content = content
        document?.markModified()
        delegate?.editorTextDidChange(self)
        lineNumbers?.needsDisplay = true
        emitCursor()

        if let ts = textView.textStorage, ts.length > 0 {
            let rehighlightRange: NSRange
            if document?.language == .markdown {
                rehighlightRange = visibleCharacterRange()
            } else {
                let sel = textView.selectedRange()
                let ns = content as NSString
                rehighlightRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            }
            ts.beginEditing()
            highlighter?.highlight(ts, in: rehighlightRange)
            ts.endEditing()
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document?.undoManager
    }

    func textViewDidChangeSelection(_ n: Notification) {
        lineNumbers?.needsDisplay = true
        emitCursor()
    }

    private func emitCursor() {
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        var line = 1
        var i = 0
        while i < sel.location && i < ns.length {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        let lineStart = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0)).location
        delegate?.editorCursorMoved(self, line: line, col: sel.location - lineStart + 1)
    }

    // MARK: - Find / Replace

    /// Plain-text searches are escaped so one regex engine handles both modes.
    private func searchRegex(_ text: String, caseSensitive: Bool, regex: Bool) -> NSRegularExpression? {
        guard !text.isEmpty else { return nil }
        var opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        if regex { opts.insert(.anchorsMatchLines) }
        let pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Non-empty matches only (zero-length regex matches can't be selected or stepped through).
    private func matches(of re: NSRegularExpression) -> [NSTextCheckingResult] {
        let s = textView.string
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            .filter { $0.range.length > 0 }
    }

    private func selectMatch(_ r: NSRange) {
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)
    }

    func findNext(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> Bool {
        guard let re = searchRegex(text, caseSensitive: caseSensitive, regex: regex) else { return false }
        let ms = matches(of: re)
        let start = NSMaxRange(textView.selectedRange())
        guard let m = ms.first(where: { $0.range.location >= start }) ?? ms.first else { return false }
        selectMatch(m.range)
        return true
    }

    func findPrev(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> Bool {
        guard let re = searchRegex(text, caseSensitive: caseSensitive, regex: regex) else { return false }
        let ms = matches(of: re)
        let end = textView.selectedRange().location
        guard let m = ms.last(where: { $0.range.location < end }) ?? ms.last else { return false }
        selectMatch(m.range)
        return true
    }

    /// Replaces the selection if it is a match, then moves to the next match.
    func replaceCurrent(_ search: String, with repl: String, caseSensitive: Bool = false, regex: Bool = false) -> Bool {
        guard let re = searchRegex(search, caseSensitive: caseSensitive, regex: regex) else { return false }
        let sel = textView.selectedRange()
        if let m = matches(of: re).first(where: { $0.range == sel }) {
            let template = regex ? repl : NSRegularExpression.escapedTemplate(for: repl)
            let replacement = re.replacementString(for: m, in: textView.string, offset: 0, template: template)
            replaceUndoably(sel, with: replacement)
        }
        return findNext(search, caseSensitive: caseSensitive, regex: regex)
    }

    @discardableResult
    func replaceAll(_ search: String, with repl: String, caseSensitive: Bool = false, regex: Bool = false) -> Int {
        guard let re = searchRegex(search, caseSensitive: caseSensitive, regex: regex) else { return 0 }
        let original = textView.string
        let full = NSRange(location: 0, length: (original as NSString).length)
        let count = re.numberOfMatches(in: original, range: full)
        guard count > 0 else { return 0 }
        let template = regex ? repl : NSRegularExpression.escapedTemplate(for: repl)
        let result = re.stringByReplacingMatches(in: original, range: full, withTemplate: template)
        let caret = textView.selectedRange().location
        replaceUndoably(full, with: result)
        textView.setSelectedRange(NSRange(location: min(caret, (result as NSString).length), length: 0))
        rehighlightAll()
        return count
    }

    func matchCount(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> Int {
        guard let re = searchRegex(text, caseSensitive: caseSensitive, regex: regex) else { return 0 }
        return matches(of: re).count
    }

    /// Goes through shouldChangeText/didChangeText so the edit is undoable and the document updates.
    private func replaceUndoably(_ range: NSRange, with str: String) {
        suppressAutoIndent = true
        defer { suppressAutoIndent = false }
        guard textView.shouldChangeText(in: range, replacementString: str) else { return }
        textView.replaceCharacters(in: range, with: str)
        textView.didChangeText()
    }

    func goToLine(_ line: Int) {
        let ns = textView.string as NSString
        var cur = 1, idx = 0
        while cur < line && idx < ns.length {
            if ns.character(at: idx) == 0x0A { cur += 1 }
            idx += 1
        }
        if cur == line {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            textView.setSelectedRange(NSRange(location: lr.location, length: 0))
            textView.scrollRangeToVisible(lr)
        }
    }

    // MARK: - Beautify

    /// Formats the current document. Returns `false` if nothing changed or formatting failed.
    @discardableResult
    func beautify() -> Bool {
        guard let doc = document else { return false }
        let original = textView.string
        guard let formatted = Beautifier.beautify(original, language: doc.language),
              formatted != original else { return false }

        let full = NSRange(location: 0, length: (original as NSString).length)
        if textView.shouldChangeText(in: full, replacementString: formatted) {
            textView.replaceCharacters(in: full, with: formatted)
            textView.didChangeText()
        } else {
            textView.string = formatted
            doc.content = formatted
            doc.markModified()
            delegate?.editorTextDidChange(self)
        }
        // Full replace leaves only the caret line highlighted via textDidChange — redo all colours.
        rehighlightAll()
        lineNumbers?.needsDisplay = true
        return true
    }
}
