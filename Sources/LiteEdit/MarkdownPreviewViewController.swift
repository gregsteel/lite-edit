import AppKit
import WebKit

final class MarkdownPreviewViewController: NSViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var emptyLabel: NSTextField!
    private var updateWorkItem: DispatchWorkItem?
    private var lastHTML: String = ""

    private(set) var isShowingPreview = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = Theme.background
        webView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Open a Markdown file to preview")
        emptyLabel.font = Theme.uiFont
        emptyLabel.textColor = Theme.statusText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(webView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        view = root
    }

    func showEmpty(_ message: String = "Open a Markdown file to preview") {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        webView.isHidden = true
        isShowingPreview = false
    }

    func update(markdown: String, baseURL: URL?, debounce: Bool = true) {
        emptyLabel.isHidden = true
        webView.isHidden = false
        isShowingPreview = true

        updateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.render(markdown: markdown, baseURL: baseURL)
        }
        updateWorkItem = work
        if debounce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func render(markdown: String, baseURL: URL?) {
        let body = MarkdownHTML.convert(markdown)
        let html = MarkdownHTML.document(body: body)
        guard html != lastHTML else { return }
        lastHTML = html
        let base = baseURL?.deletingLastPathComponent()
        webView.loadHTMLString(html, baseURL: base)
    }

    // Keep clicks on links from navigating away; open externally.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
