import AppKit

protocol FindBarDelegate: AnyObject {
    func findBarNext(_ text: String, caseSensitive: Bool, regex: Bool) -> Bool
    func findBarPrev(_ text: String, caseSensitive: Bool, regex: Bool) -> Bool
    func findBarReplace(_ search: String, with replacement: String, caseSensitive: Bool, regex: Bool)
    func findBarReplaceAll(_ search: String, with replacement: String, caseSensitive: Bool, regex: Bool)
    func findBarDismissed()
    func findBarHeightChanged()
    func findBarMatchCount(_ text: String, caseSensitive: Bool, regex: Bool) -> Int
}

final class FindBarView: NSView, NSTextFieldDelegate {
    weak var delegate: FindBarDelegate?

    let searchField  = NSTextField()
    let replaceField = NSTextField()
    private let matchLabel  = NSTextField(labelWithString: "")
    private let caseBtn     = NSButton()
    private let regexBtn    = NSButton()
    private let prevBtn     = NSButton()
    private let nextBtn     = NSButton()
    private let replBtn     = NSButton()
    private let replAllBtn  = NSButton()
    private let closeBtn    = NSButton()
    private let expandBtn   = NSButton()
    private var showReplace  = false
    private var replaceRow: NSView!

    var preferredHeight: CGFloat { showReplace ? 66 : 34 }
    var query: String { searchField.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.findBarBg.cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func buildUI() {
        func btn(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = Theme.uiFontSmall
            b.contentTintColor = Theme.tabText
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        searchField.placeholderString = "Find"
        searchField.font = Theme.uiFontSmall
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        replaceField.placeholderString = "Replace"
        replaceField.font = Theme.uiFontSmall
        replaceField.focusRingType = .none
        replaceField.delegate = self
        replaceField.translatesAutoresizingMaskIntoConstraints = false

        matchLabel.font = Theme.uiFontSmall
        matchLabel.textColor = Theme.statusText
        matchLabel.translatesAutoresizingMaskIntoConstraints = false

        let e = btn("⇅", "Toggle Replace", #selector(toggleReplace))
        expandBtn.title = e.title; expandBtn.bezelStyle = e.bezelStyle
        expandBtn.isBordered = e.isBordered; expandBtn.font = e.font
        expandBtn.contentTintColor = e.contentTintColor; expandBtn.toolTip = e.toolTip
        expandBtn.target = self; expandBtn.action = #selector(toggleReplace)
        expandBtn.translatesAutoresizingMaskIntoConstraints = false

        copyProps(from: btn("Aa", "Case Sensitive", #selector(toggleCase)), to: caseBtn)
        copyProps(from: btn(".*", "Regex", #selector(toggleRegex)), to: regexBtn)
        copyProps(from: btn("▲", "Previous", #selector(doPrev)), to: prevBtn)
        copyProps(from: btn("▼", "Next", #selector(doNext)), to: nextBtn)
        copyProps(from: btn("✕", "Close", #selector(doClose)), to: closeBtn)
        copyProps(from: btn("Replace", "Replace", #selector(doReplace)), to: replBtn)
        copyProps(from: btn("All", "Replace All", #selector(doReplaceAll)), to: replAllBtn)

        let searchRow = NSView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        for v: NSView in [expandBtn, searchField, matchLabel, caseBtn, regexBtn, prevBtn, nextBtn, closeBtn] {
            searchRow.addSubview(v)
        }

        replaceRow = NSView()
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.isHidden = true
        for v: NSView in [replaceField, replBtn, replAllBtn] {
            replaceRow.addSubview(v)
        }

        addSubview(searchRow)
        addSubview(replaceRow)

        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: topAnchor),
            searchRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: 34),

            expandBtn.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 6),
            expandBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            expandBtn.widthAnchor.constraint(equalToConstant: 24),

            searchField.leadingAnchor.constraint(equalTo: expandBtn.trailingAnchor, constant: 4),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchLabel.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            caseBtn.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 8),
            caseBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            regexBtn.leadingAnchor.constraint(equalTo: caseBtn.trailingAnchor, constant: 4),
            regexBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            prevBtn.leadingAnchor.constraint(equalTo: regexBtn.trailingAnchor, constant: 8),
            prevBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            nextBtn.leadingAnchor.constraint(equalTo: prevBtn.trailingAnchor, constant: 4),
            nextBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            replaceRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            replaceRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            replaceRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            replaceRow.heightAnchor.constraint(equalToConstant: 32),

            replaceField.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            replaceField.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),

            replBtn.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 8),
            replBtn.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),

            replAllBtn.leadingAnchor.constraint(equalTo: replBtn.trailingAnchor, constant: 6),
            replAllBtn.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
        ])
    }

    private func copyProps(from src: NSButton, to dst: NSButton) {
        dst.title = src.title
        dst.bezelStyle = src.bezelStyle
        dst.isBordered = src.isBordered
        dst.font = src.font
        dst.contentTintColor = src.contentTintColor
        dst.toolTip = src.toolTip
        dst.target = src.target
        dst.action = src.action
        dst.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Shows the bar focused on the search field, optionally prefilled and with the replace row.
    func activate(prefill: String? = nil, replace: Bool = false) {
        if let p = prefill, !p.isEmpty { searchField.stringValue = p }
        if replace && !showReplace { toggleReplace() }
        window?.makeFirstResponder(searchField)
        refreshCount()
    }

    private var isCase: Bool { caseBtn.state == .on }
    private var isRegex: Bool { regexBtn.state == .on }

    // MARK: - Actions

    @objc func doNext() {
        guard !query.isEmpty else { return }
        if delegate?.findBarNext(query, caseSensitive: isCase, regex: isRegex) != true { NSSound.beep() }
    }
    @objc func doPrev() {
        guard !query.isEmpty else { return }
        if delegate?.findBarPrev(query, caseSensitive: isCase, regex: isRegex) != true { NSSound.beep() }
    }
    @objc private func doClose() {
        delegate?.findBarDismissed()
    }
    @objc private func toggleCase() {
        caseBtn.state = isCase ? .off : .on
        caseBtn.contentTintColor = isCase ? .controlAccentColor : Theme.tabText
        refreshCount()
    }
    @objc private func toggleRegex() {
        regexBtn.state = isRegex ? .off : .on
        regexBtn.contentTintColor = isRegex ? .controlAccentColor : Theme.tabText
        refreshCount()
    }
    @objc private func doReplace() {
        guard !query.isEmpty else { return }
        delegate?.findBarReplace(query, with: replaceField.stringValue, caseSensitive: isCase, regex: isRegex)
        refreshCount()
    }
    @objc private func doReplaceAll() {
        guard !query.isEmpty else { return }
        delegate?.findBarReplaceAll(query, with: replaceField.stringValue, caseSensitive: isCase, regex: isRegex)
        refreshCount()
    }
    @objc private func toggleReplace() {
        showReplace.toggle()
        replaceRow.isHidden = !showReplace
        expandBtn.contentTintColor = showReplace ? .controlAccentColor : Theme.tabText
        delegate?.findBarHeightChanged()
    }

    func refreshCount() {
        if query.isEmpty { matchLabel.stringValue = ""; return }
        let n = delegate?.findBarMatchCount(query, caseSensitive: isCase, regex: isRegex) ?? 0
        matchLabel.stringValue = n == 0 ? "No results" : "\(n) match\(n == 1 ? "" : "es")"
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === searchField { refreshCount() }
    }

    func control(_ control: NSControl, textView tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { doClose(); return true }
        if sel == #selector(insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if control === replaceField {
                shift ? doReplaceAll() : doReplace()
            } else {
                shift ? doPrev() : doNext()
            }
            return true
        }
        return false
    }
}
