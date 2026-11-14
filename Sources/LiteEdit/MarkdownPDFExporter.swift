import AppKit
import WebKit

/// Renders Markdown into an offscreen web view and saves it as a paginated PDF.
/// Uses the print pipeline so the `@media print` styles in `MarkdownHTML` apply.
final class MarkdownPDFExporter: NSObject, WKNavigationDelegate {
    private static var active: Set<MarkdownPDFExporter> = []

    private let webView: WKWebView
    private let destination: URL
    private weak var window: NSWindow?
    private let completion: (Bool) -> Void
    private let printInfo: NSPrintInfo

    static func export(markdown: String, baseURL: URL?, to destination: URL,
                       window: NSWindow, completion: @escaping (Bool) -> Void) {
        let exporter = MarkdownPDFExporter(destination: destination, window: window, completion: completion)
        active.insert(exporter) // keep alive until the print job finishes
        let base = baseURL?.deletingLastPathComponent()
        func load() {
            var misses: [String] = []
            let body = MarkdownHTML.convert(markdown, plantuml: { src in
                if let f = PlantUML.fragment(for: src) { return f }
                misses.append(src)
                return nil
            })
            if misses.isEmpty {
                exporter.webView.loadHTMLString(MarkdownHTML.document(body: body, forPrint: true), baseURL: base)
                return
            }
            // Render missing PlantUML diagrams first, then build the page from the cache.
            let group = DispatchGroup()
            for src in Set(misses) {
                group.enter()
                PlantUML.render(src) { _ in group.leave() }
            }
            group.notify(queue: .main) { load() }
        }
        load()
    }

    private init(destination: URL, window: NSWindow, completion: @escaping (Bool) -> Void) {
        self.destination = destination
        self.window = window
        self.completion = completion

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        printInfo = info

        let page = NSRect(origin: .zero, size: info.paperSize)
        webView = WKWebView(frame: page, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForDiagrams(attempts: 75) { [weak self] in self?.print(webView) }
    }

    /// Mermaid renders client-side; wait for the page to report it is done (max ~15s).
    private func waitForDiagrams(attempts: Int, then go: @escaping () -> Void) {
        webView.evaluateJavaScript("window.__diagramsDone === true") { [weak self] result, _ in
            if (result as? Bool) == true || attempts <= 0 { go(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.waitForDiagrams(attempts: attempts - 1, then: go)
            }
        }
    }

    private func print(_ webView: WKWebView) {
        guard let window = window else { finish(false); return }
        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        // WebKit's print view has a zero frame by default, which yields blank pages.
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(false)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        finish(success)
    }

    private func finish(_ success: Bool) {
        guard MarkdownPDFExporter.active.remove(self) != nil else { return }
        completion(success)
    }
}
