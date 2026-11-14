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
            let hasDiagrams = markdown.contains("```mermaid") || markdown.contains("```plantuml") || markdown.contains("```puml")
                || markdown.hasPrefix("@start") || lastHTML.contains("class=\"mermaid\"")
            DispatchQueue.main.asyncAfter(deadline: .now() + (hasDiagrams ? 0.6 : 0.12), execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func render(markdown: String, baseURL: URL?) {
        var pending: [String] = []
        let body = MarkdownHTML.convert(markdown, plantuml: { src in
            if let f = PlantUML.fragment(for: src) { return f }
            pending.append(src)
            return nil
        })
        let html = MarkdownHTML.document(body: body)
        guard html != lastHTML else { return }
        lastHTML = html
        let base = baseURL?.deletingLastPathComponent()
        webView.loadHTMLString(html, baseURL: base)

        // Diagrams render in the background and are swapped in without reloading the page.
        for src in Set(pending) {
            PlantUML.render(src) { [weak self] fragment in
                self?.inject(fragment, forKey: PlantUML.key(src))
            }
        }
    }

    private func inject(_ fragment: String, forKey key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [fragment, key]),
              let arg = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
        (function(a){document.querySelectorAll('[data-key="'+a[1]+'"]').forEach(function(e){e.classList.remove('pending');e.innerHTML=a[0];});})(\(arg));
        """)
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
