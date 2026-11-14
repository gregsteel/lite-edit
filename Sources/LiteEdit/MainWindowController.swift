import AppKit

final class MainWindowController: NSWindowController,
    NSSplitViewDelegate,
    EditorViewControllerDelegate,
    TabBarViewDelegate,
    SidebarDelegate,
    FindBarDelegate,
    QuickOpenDelegate,
    NSWindowDelegate
{
    private var splitView: NSSplitView!
    private var editorSplit: NSSplitView!
    private var sidebarVC: SidebarViewController!
    private var tabBar: TabBarView!
    private var findBar: FindBarView!
    private var editorVC: EditorViewController!
    private var previewVC: MarkdownPreviewViewController!
    private var statusBar: StatusBarView!

    private var quickOpen: QuickOpenPanel?
    private var keyMonitor: Any?

    private var documents: [Document] = []
    private var curIdx: Int = -1
    private var sidebarManuallyCollapsed = false
    /// When true, preview auto-appears for Markdown files. Toggle with ⌘⇧V.
    private var markdownPreviewEnabled = true
    private var markdownPreviewVisible = false

    private var curDoc: Document? {
        guard curIdx >= 0, curIdx < documents.count else { return nil }
        return documents[curIdx]
    }

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.minSize = NSSize(width: 640, height: 420)
        w.title = "LiteEdit"
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName("MainWindow") { w.center() }
        w.setFrameAutosaveName("MainWindow")
        w.backgroundColor = Theme.background

        self.init(window: w)
        w.delegate = self
        buildUI()
        newDocument()
        installKeyMonitor()
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "p" {
                self.showQuickOpen()
                return nil
            }
            return event
        }
    }

    // MARK: - UI setup
    // Tab bar and status bar are OUTSIDE the NSSplitView (direct children of contentView).
    // This avoids NSSplitView layer compositing issues that made the tab bar invisible.

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let tabH: CGFloat = 32
        let statusH: CGFloat = 24

        tabBar = TabBarView()
        tabBar.delegate = self
        tabBar.autoresizingMask = [.minYMargin]
        tabBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH, width: cv.bounds.width, height: tabH)
        cv.addSubview(tabBar)

        statusBar = StatusBarView()
        statusBar.autoresizingMask = [.width, .maxYMargin]
        statusBar.frame = NSRect(x: 0, y: 0, width: cv.bounds.width, height: statusH)
        cv.addSubview(statusBar)

        findBar = FindBarView()
        findBar.delegate = self
        findBar.isHidden = true
        findBar.autoresizingMask = [.width, .minYMargin]
        findBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH, width: cv.bounds.width, height: 0)
        cv.addSubview(findBar)

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]
        splitView.frame = NSRect(x: 0, y: statusH, width: cv.bounds.width, height: cv.bounds.height - tabH - statusH)
        cv.addSubview(splitView)

        sidebarVC = SidebarViewController()
        sidebarVC.sidebarDelegate = self
        let sideView = sidebarVC.view
        sideView.setFrameSize(NSSize(width: 220, height: splitView.bounds.height))

        editorSplit = NSSplitView()
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.delegate = self
        editorSplit.autoresizingMask = [.width, .height]

        editorVC = EditorViewController()
        editorVC.delegate = self
        let editorView = editorVC.view

        previewVC = MarkdownPreviewViewController()
        _ = previewVC.view // load eagerly

        // Start with editor only; preview is added when a Markdown file is active.
        editorSplit.addSubview(editorView)
        editorView.frame = editorSplit.bounds
        editorView.autoresizingMask = NSView.AutoresizingMask([.width, .height])
        editorSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        splitView.addSubview(sideView)
        splitView.addSubview(editorSplit)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        updateTabBarFrame()

        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(220, ofDividerAt: 0)
        }
    }

    private func updateTabBarFrame() {
        guard let cv = window?.contentView else { return }
        let tabH: CGFloat = 32
        let editorX: CGFloat
        if sidebarVC.view.isHidden {
            editorX = 0
        } else {
            editorX = sidebarVC.view.frame.width + splitView.dividerThickness
        }
        tabBar.frame = NSRect(
            x: editorX,
            y: cv.bounds.height - tabH,
            width: cv.bounds.width - editorX,
            height: tabH
        )
    }

    // MARK: - Cursor persistence across tab switches

    private func saveCursorPosition() {
        guard let doc = curDoc else { return }
        doc.cursorPosition = editorVC.textView.selectedRange().location
        doc.scrollOffset = editorVC.scrollView.contentView.bounds.origin
    }

    private func restoreCursorPosition() {
        guard let doc = curDoc else { return }
        let tv = editorVC.textView!
        let sv = editorVC.scrollView!
        let len = (tv.string as NSString).length
        let pos = min(doc.cursorPosition, len)

        if let lm = tv.layoutManager, len > 0 {
            if doc.scrollOffset != .zero {
                // Full layout needed so the text view frame is tall enough
                // for the entire viewport, not just up to the cursor.
                lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: len))
            } else if pos > 0 {
                lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(pos + 1, len)))
            }
        }

        tv.setSelectedRange(NSRange(location: pos, length: 0))
        if doc.scrollOffset != .zero {
            sv.contentView.scroll(to: doc.scrollOffset)
            sv.reflectScrolledClipView(sv.contentView)
        } else {
            tv.scrollRangeToVisible(NSRange(location: pos, length: 0))
        }
    }

    /// Defers cursor restoration to the next run-loop iteration so it
    /// survives the layout pass that `replaceTextStorage` triggers.
    private func deferredRestoreCursor() {
        let targetDoc = curDoc
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.curDoc === targetDoc else { return }
            self.restoreCursorPosition()
        }
    }

    // MARK: - Document management

    func newDocument() {
        documents.append(Document())
        activateDocument(at: documents.count - 1)
    }

    /// Makes `index` the visible document, saving the outgoing tab's cursor first.
    private func activateDocument(at index: Int) {
        guard index >= 0, index < documents.count else { return }
        if index != curIdx { saveCursorPosition() }
        curIdx = index
        editorVC.document = documents[index]
        refreshTabs(); refreshStatus()
        if let url = documents[index].fileURL { sidebarVC.revealFile(url) }
        deferredRestoreCursor()
    }

    func openDocument() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        if let dir = curDoc?.fileURL?.deletingLastPathComponent() ?? sidebarVC.rootFolderURL {
            p.directoryURL = dir
        }
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK else { return }
            p.urls.forEach { self?.openFile($0) }
        }
    }

    /// Opens `url` in a new tab (or switches to it if already open).
    /// An untouched "Untitled" tab is replaced rather than left behind.
    func openFile(_ url: URL) {
        let target = url.standardizedFileURL
        if let i = documents.firstIndex(where: { $0.fileURL?.standardizedFileURL == target }) {
            activateDocument(at: i)
            RecentItems.addFile(url)
            return
        }
        let doc: Document
        do { doc = try Document.open(url: url) } catch {
            showError(error)
            return
        }
        if curDoc?.isPristine == true {
            documents[curIdx] = doc
            activateDocument(at: curIdx)
        } else {
            documents.append(doc)
            activateDocument(at: documents.count - 1)
        }
        RecentItems.addFile(url)
    }

    func saveDocument() {
        guard let doc = curDoc else { return }
        save(doc) { _ in }
    }

    func saveDocumentAs() {
        guard let doc = curDoc else { return }
        saveAs(doc) { _ in }
    }

    /// Saves in place, or asks for a location if the document is untitled.
    private func save(_ doc: Document, completion: @escaping (Bool) -> Void) {
        guard doc.fileURL != nil else { saveAs(doc, completion: completion); return }
        do {
            try doc.save()
            didSave(doc)
            completion(true)
        } catch {
            showError(error)
            completion(false)
        }
    }

    private func saveAs(_ doc: Document, completion: @escaping (Bool) -> Void) {
        guard let w = window else { completion(false); return }
        let p = NSSavePanel()
        p.canCreateDirectories = true
        p.nameFieldStringValue = doc.displayName
        if let dir = doc.fileURL?.deletingLastPathComponent() ?? sidebarVC.rootFolderURL {
            p.directoryURL = dir
        }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = p.url else { completion(false); return }
            do {
                try doc.save(to: url)
                RecentItems.addFile(url)
                if doc === self?.curDoc { self?.editorVC.reloadLanguage() }
                self?.didSave(doc)
                completion(true)
            } catch {
                self?.showError(error)
                completion(false)
            }
        }
    }

    private func didSave(_ doc: Document) {
        refreshTabs(); refreshStatus()
        sidebarVC.refreshGitStatus()
    }

    private func showError(_ error: Error) {
        if let w = window { NSAlert(error: error).beginSheetModal(for: w) }
        else { NSAlert(error: error).runModal() }
    }

    /// Asks Save / Don't Save / Cancel for a modified document.
    /// `proceed(true)` means the caller may close it (saved or discarded).
    private func confirmClose(_ doc: Document, proceed: @escaping (Bool) -> Void) {
        guard doc.isModified, let w = window else { proceed(true); return }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes you made to \(doc.displayName)?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        a.buttons[1].keyEquivalent = "\u{1b}"
        a.buttons[2].keyEquivalent = "d"
        a.buttons[2].keyEquivalentModifierMask = .command
        a.beginSheetModal(for: w) { [weak self] resp in
            a.window.orderOut(nil) // dismiss before a save panel sheet can appear
            switch resp {
            case .alertFirstButtonReturn: self?.save(doc, completion: proceed)
            case .alertThirdButtonReturn: proceed(true)
            default: proceed(false)
            }
        }
    }

    func closeCurrentTab() {
        closeDocument(at: curIdx)
    }

    private func closeDocument(at index: Int) {
        guard index >= 0, index < documents.count, window?.attachedSheet == nil else { return }
        let doc = documents[index]
        if doc.isModified && index != curIdx { activateDocument(at: index) } // show what's being asked about
        confirmClose(doc) { [weak self] ok in
            guard ok, let self = self, let i = self.documents.firstIndex(where: { $0 === doc }) else { return }
            let wasCurrent = i == self.curIdx
            if wasCurrent { self.saveCursorPosition() }
            self.documents.remove(at: i)
            if self.documents.isEmpty { self.curIdx = -1; self.newDocument(); return }
            if wasCurrent {
                self.curIdx = -1
                self.activateDocument(at: min(i, self.documents.count - 1))
            } else {
                if i < self.curIdx { self.curIdx -= 1 }
                self.refreshTabs()
            }
        }
    }

    /// Walks every modified document asking to save. `done(false)` if the user cancels.
    func reviewUnsavedChanges(_ done: @escaping (Bool) -> Void) {
        var pending = documents.filter { $0.isModified }
        func next() {
            guard !pending.isEmpty else { done(true); return }
            let doc = pending.removeFirst()
            if let i = documents.firstIndex(where: { $0 === doc }) { activateDocument(at: i) }
            confirmClose(doc) { ok in ok ? next() : done(false) }
        }
        next()
    }

    var hasUnsavedChanges: Bool { documents.contains { $0.isModified } }
    /// Set once the user has reviewed unsaved changes for a window close, so quit doesn't ask again.
    private(set) var unsavedChangesReviewed = false

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if unsavedChangesReviewed || !hasUnsavedChanges { return true }
        guard sender.attachedSheet == nil else { return false }
        reviewUnsavedChanges { [weak self] ok in
            guard ok else { return }
            self?.unsavedChangesReviewed = true
            sender.close()
        }
        return false
    }

    func openFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            self?.showSidebarAndOpen(url)
        }
    }

    func openFolderDirect(_ url: URL) {
        showSidebarAndOpen(url)
    }

    private func showSidebarAndOpen(_ url: URL) {
        sidebarManuallyCollapsed = false
        sidebarVC.view.isHidden = false
        splitView.adjustSubviews()
        splitView.setPosition(220, ofDividerAt: 0)
        RecentItems.addFolder(url)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.sidebarVC.view.frame.width < 10 {
                self.splitView.setPosition(220, ofDividerAt: 0)
            }
            self.sidebarVC.openFolder(url)
        }
    }

    func toggleSidebar() {
        if sidebarVC.view.isHidden || splitView.isSubviewCollapsed(sidebarVC.view) {
            sidebarManuallyCollapsed = false
            sidebarVC.view.isHidden = false
            splitView.adjustSubviews()
            splitView.setPosition(220, ofDividerAt: 0)
        } else {
            sidebarManuallyCollapsed = true
            splitView.setPosition(0, ofDividerAt: 0)
            sidebarVC.view.isHidden = true
        }
        updateTabBarFrame()
    }

    func toggleMarkdownPreview() {
        markdownPreviewEnabled.toggle()
        syncMarkdownPreview(immediate: true)
    }

    var canExportPreviewPDF: Bool { curDoc?.language.hasPreview == true }

    /// Exports the rendered Markdown of the current document as a paginated PDF.
    func exportPreviewPDF() {
        guard let w = window, let doc = curDoc, doc.language.hasPreview else { NSSound.beep(); return }
        let p = NSSavePanel()
        p.canCreateDirectories = true
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = (doc.displayName as NSString).deletingPathExtension + ".pdf"
        if let dir = doc.fileURL?.deletingLastPathComponent() ?? sidebarVC.rootFolderURL {
            p.directoryURL = dir
        }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = p.url, let self = self, self.curDoc === doc else { return }
            MarkdownPDFExporter.export(
                markdown: MarkdownHTML.previewSource(self.editorVC.textView.string, language: doc.language),
                baseURL: doc.fileURL,
                to: url,
                window: w
            ) { success in
                guard !success else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t export PDF"
                alert.informativeText = "The preview could not be saved to “\(url.lastPathComponent)”."
                alert.beginSheetModal(for: w)
            }
        }
    }

    /// Shows the preview for Markdown when enabled; removes it for every other file type.
    private func syncMarkdownPreview(immediate: Bool = false) {
        let wantVisible = markdownPreviewEnabled && curDoc?.language.hasPreview == true
        if wantVisible != markdownPreviewVisible {
            markdownPreviewVisible = wantVisible
            applyMarkdownPreviewVisibility(refresh: wantVisible)
        } else if wantVisible {
            refreshMarkdownPreview(immediate: immediate)
        }
    }

    private func applyMarkdownPreviewVisibility(refresh: Bool) {
        let editorView = editorVC.view
        let previewView = previewVC.view

        if markdownPreviewVisible {
            if previewView.superview !== editorSplit {
                // Ensure editor is first; then add preview beside it.
                if editorView.superview !== editorSplit {
                    editorSplit.addSubview(editorView)
                }
                editorSplit.addSubview(previewView)
                editorSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
                editorSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
            }
            editorSplit.adjustSubviews()
            let width = editorSplit.bounds.width
            if width > 160 {
                editorSplit.setPosition(width * 0.5, ofDividerAt: 0)
            }
            if refresh { refreshMarkdownPreview(immediate: true) }
        } else {
            if previewView.superview === editorSplit {
                previewView.removeFromSuperview()
            }
            if editorView.superview !== editorSplit {
                editorSplit.addSubview(editorView)
            }
            editorSplit.adjustSubviews()
            editorView.frame = editorSplit.bounds
            editorView.autoresizingMask = NSView.AutoresizingMask([.width, .height])
        }
    }

    private func refreshMarkdownPreview(immediate: Bool = false) {
        guard markdownPreviewVisible, let doc = curDoc, doc.language.hasPreview else { return }
        previewVC.update(
            markdown: MarkdownHTML.previewSource(editorVC.textView.string, language: doc.language),
            baseURL: doc.fileURL,
            debounce: !immediate
        )
    }

    /// Lays out find bar + split view; the find bar sits under the tab bar when visible.
    private func layoutFindBar() {
        guard let cv = window?.contentView else { return }
        let tabH: CGFloat = 32
        let statusH: CGFloat = 24
        let findH: CGFloat = findBar.isHidden ? 0 : findBar.preferredHeight
        findBar.frame = NSRect(x: 0, y: cv.bounds.height - tabH - findH, width: cv.bounds.width, height: findH)
        splitView.frame = NSRect(x: 0, y: statusH, width: cv.bounds.width, height: cv.bounds.height - tabH - findH - statusH)
    }

    func showFind(replace: Bool = false) {
        // Prefill with the selection when it's a single-line snippet.
        let ns = editorVC.textView.string as NSString
        let sel = editorVC.textView.selectedRange()
        var prefill: String?
        if sel.length > 0, sel.length < 500 {
            let s = ns.substring(with: sel)
            if !s.contains("\n") { prefill = s }
        }
        findBar.isHidden = false
        layoutFindBar()
        findBar.activate(prefill: prefill, replace: replace)
    }

    func findNextFromMenu(backwards: Bool) {
        guard !findBar.query.isEmpty else { showFind(); return }
        backwards ? findBar.doPrev() : findBar.doNext()
    }

    func showGoToLine() {
        let a = NSAlert()
        a.messageText = "Go to Line"
        a.addButton(withTitle: "Go")
        a.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Line number"
        a.accessoryView = input
        a.beginSheetModal(for: window!) { [weak self] r in
            guard r == .alertFirstButtonReturn, let ln = Int(input.stringValue) else { return }
            self?.editorVC.goToLine(ln)
        }
    }

    func beautifyDocument() {
        if !editorVC.beautify() {
            // Invalid JSON / already formatted — subtle, no alert spam
            NSSound.beep()
        }
    }

    func showQuickOpen() {
        guard let w = window else { return }
        guard let rootURL = sidebarVC.rootFolderURL else {
            let a = NSAlert()
            a.messageText = "No Folder Open"
            a.informativeText = "Open a folder first (Cmd+Shift+O) to use Quick Open."
            a.addButton(withTitle: "OK")
            a.beginSheetModal(for: w, completionHandler: nil)
            return
        }

        if let qo = quickOpen, qo.isVisible {
            qo.orderOut(nil)
            w.removeChildWindow(qo)
            w.makeFirstResponder(editorVC.textView)
            return
        }

        if quickOpen == nil {
            quickOpen = QuickOpenPanel(relativeTo: w)
            quickOpen?.quickOpenDelegate = self
        } else {
            let panelW: CGFloat = 520
            let panelH: CGFloat = 340
            let x = w.frame.midX - panelW / 2
            let y = w.frame.maxY - panelH - 60
            quickOpen?.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: false)
        }
        quickOpen?.loadFiles(from: rootURL)
        quickOpen?.activate()
        w.addChildWindow(quickOpen!, ordered: .above)
        quickOpen?.makeKeyAndOrderFront(nil)
    }

    // MARK: - QuickOpenDelegate

    func quickOpenDidSelectFile(_ url: URL) {
        openFile(url)
    }

    func quickOpenDismissed() {
        if let qo = quickOpen { window?.removeChildWindow(qo) }
        window?.makeFirstResponder(editorVC.textView)
    }

    // MARK: - Refresh

    private func refreshTabs() {
        let items = documents.map { TabItem(title: $0.displayName, isModified: $0.isModified) }
        tabBar.setTabs(items, selectedIndex: curIdx)
    }

    private func refreshStatus() {
        if let doc = curDoc {
            statusBar.updateLanguage(doc.language)
            window?.title = "LiteEdit — \(doc.displayName)"
            window?.isDocumentEdited = doc.isModified
        }
        syncMarkdownPreview(immediate: true)
        if !findBar.isHidden { findBar.refreshCount() }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ sv: NSSplitView, constrainMinCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        if sv === editorSplit {
            guard markdownPreviewVisible else { return 0 }
            return idx == 0 ? 180 : pos
        }
        return idx == 0 ? 150 : pos
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate pos: CGFloat, ofSubviewAt idx: Int) -> CGFloat {
        if sv === editorSplit {
            guard markdownPreviewVisible else { return sv.bounds.width }
            return idx == 0 ? max(180, sv.bounds.width - 180) : pos
        }
        return idx == 0 ? sv.bounds.width - 400 : pos
    }

    func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        if subview === sidebarVC.view { return sidebarManuallyCollapsed }
        if subview === previewVC.view { return true }
        return false
    }

    func splitView(_ sv: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        if subview === sidebarVC.view {
            sidebarManuallyCollapsed = true
            return true
        }
        if subview === previewVC.view {
            markdownPreviewEnabled = false
            markdownPreviewVisible = false
            applyMarkdownPreviewVisibility(refresh: false)
            return false // we already removed it
        }
        return false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        updateTabBarFrame()
    }

    // MARK: - EditorViewControllerDelegate

    func editorTextDidChange(_ vc: EditorViewController) {
        if let doc = curDoc {
            tabBar.updateTab(at: curIdx, item: TabItem(title: doc.displayName, isModified: doc.isModified))
            window?.isDocumentEdited = doc.isModified
        }
        refreshMarkdownPreview()
        if !findBar.isHidden { findBar.refreshCount() }
    }
    func editorCursorMoved(_ vc: EditorViewController, line: Int, col: Int) { statusBar.updateCursor(line: line, col: col) }

    // MARK: - TabBarViewDelegate

    func tabBarDidSelectTab(at index: Int) {
        activateDocument(at: index)
    }

    func tabBarDidCloseTab(at index: Int) {
        closeDocument(at: index)
    }

    // MARK: - SidebarDelegate

    func sidebarDidSelectFile(_ url: URL, inNewTab: Bool) {
        openFile(url)
    }

    // MARK: - FindBarDelegate

    func findBarNext(_ text: String, caseSensitive: Bool, regex: Bool) -> Bool {
        editorVC.findNext(text, caseSensitive: caseSensitive, regex: regex)
    }
    func findBarPrev(_ text: String, caseSensitive: Bool, regex: Bool) -> Bool {
        editorVC.findPrev(text, caseSensitive: caseSensitive, regex: regex)
    }
    func findBarReplace(_ search: String, with replacement: String, caseSensitive: Bool, regex: Bool) {
        if !editorVC.replaceCurrent(search, with: replacement, caseSensitive: caseSensitive, regex: regex) { NSSound.beep() }
    }
    func findBarReplaceAll(_ search: String, with replacement: String, caseSensitive: Bool, regex: Bool) {
        if editorVC.replaceAll(search, with: replacement, caseSensitive: caseSensitive, regex: regex) == 0 { NSSound.beep() }
    }
    func findBarDismissed() {
        findBar.isHidden = true
        layoutFindBar()
        window?.makeFirstResponder(editorVC.textView)
    }
    func findBarHeightChanged() {
        if !findBar.isHidden { layoutFindBar() }
    }
    func findBarMatchCount(_ text: String, caseSensitive: Bool, regex: Bool) -> Int {
        editorVC.matchCount(text, caseSensitive: caseSensitive, regex: regex)
    }

    // MARK: - Session persistence

    private static let sessionFolderKey  = "SessionFolder"
    private static let sessionFilesKey   = "SessionFiles"
    private static let sessionIndexKey   = "SessionActiveIndex"
    private static let sessionCursorsKey = "SessionCursors"
    private static let sessionZoomedKey  = "SessionWindowZoomed"

    func saveSession() {
        saveCursorPosition()
        let ud = UserDefaults.standard
        ud.set(sidebarVC.rootFolderURL?.path, forKey: Self.sessionFolderKey)
        ud.set(documents.compactMap { $0.fileURL?.path }, forKey: Self.sessionFilesKey)
        ud.set(curIdx, forKey: Self.sessionIndexKey)

        var cursors: [String: Int] = [:]
        for doc in documents {
            if let path = doc.fileURL?.path {
                cursors[path] = doc.cursorPosition
            }
        }
        ud.set(cursors, forKey: Self.sessionCursorsKey)
        ud.set(window?.isZoomed ?? false, forKey: Self.sessionZoomedKey)
    }

    func restoreSession() {
        let ud = UserDefaults.standard
        let folderPath = ud.string(forKey: Self.sessionFolderKey)
        let filePaths  = (ud.stringArray(forKey: Self.sessionFilesKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard folderPath != nil || !filePaths.isEmpty else { return }

        if let fp = folderPath, FileManager.default.fileExists(atPath: fp) {
            openFolderDirect(URL(fileURLWithPath: fp))
        }

        for path in filePaths {
            openFile(URL(fileURLWithPath: path))
        }

        let cursors = ud.dictionary(forKey: Self.sessionCursorsKey) as? [String: Int] ?? [:]
        for doc in documents {
            if let path = doc.fileURL?.path, let pos = cursors[path] {
                doc.cursorPosition = pos
            }
        }

        let savedIdx = ud.integer(forKey: Self.sessionIndexKey)
        curIdx = max(0, min(savedIdx, documents.count - 1))
        if curIdx < documents.count {
            editorVC.document = documents[curIdx]
        }
        refreshTabs()
        refreshStatus()

        DispatchQueue.main.async { [weak self] in
            self?.restoreCursorPosition()
            if let url = self?.curDoc?.fileURL {
                self?.sidebarVC.revealFile(url)
            }
            if ud.bool(forKey: Self.sessionZoomedKey), !(self?.window?.isZoomed ?? true) {
                self?.window?.zoom(nil)
            }
        }
    }
}
