import Foundation

/// Lightweight Markdown → HTML converter for preview (CommonMark subset + GFM extras).
enum MarkdownHTML {
    static func convert(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var html = ""
        var i = 0
        var inCodeBlock = false
        var codeLang = ""
        var codeLines: [String] = []
        var inList: ListKind?
        var para: [String] = []

        enum ListKind { case ul, ol }

        func flushPara() {
            guard !para.isEmpty else { return }
            let joined = para.joined(separator: " ")
            html += "<p>\(inline(joined))</p>\n"
            para = []
        }

        func closeList() {
            guard let kind = inList else { return }
            html += kind == .ul ? "</ul>\n" : "</ol>\n"
            inList = nil
        }

        while i < lines.count {
            let line = lines[i]

            if inCodeBlock {
                if line.hasPrefix("```") {
                    let body = escape(codeLines.joined(separator: "\n"))
                    let cls = codeLang.isEmpty ? "" : " class=\"language-\(escapeAttr(codeLang))\""
                    html += "<pre><code\(cls)>\(body)</code></pre>\n"
                    codeLines = []
                    codeLang = ""
                    inCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                i += 1
                continue
            }

            if line.hasPrefix("```") {
                flushPara()
                closeList()
                inCodeBlock = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushPara()
                closeList()
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara()
                closeList()
                html += "<hr>\n"
                i += 1
                continue
            }

            if let heading = matchHeading(line) {
                flushPara()
                closeList()
                html += "<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>\n"
                i += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushPara()
                closeList()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    if q.hasPrefix("> ") {
                        quote.append(String(q.dropFirst(2)))
                    } else if q == ">" {
                        quote.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                html += "<blockquote>\(convert(quote.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            if let item = matchUnordered(line) {
                flushPara()
                if inList != .ul {
                    closeList()
                    html += "<ul>\n"
                    inList = .ul
                }
                html += "<li>\(inline(item))</li>\n"
                i += 1
                continue
            }

            if let item = matchOrdered(line) {
                flushPara()
                if inList != .ol {
                    closeList()
                    html += "<ol>\n"
                    inList = .ol
                }
                html += "<li>\(inline(item))</li>\n"
                i += 1
                continue
            }

            // GFM table: header row, then a delimiter row like |---|:--:|
            if trimmed.contains("|"), i + 1 < lines.count,
               let aligns = tableAlignments(lines[i + 1]),
               tableCells(trimmed).count == aligns.count {
                flushPara()
                closeList()
                func row(_ cells: [String], _ tag: String) -> String {
                    var out = "<tr>"
                    for (c, align) in zip(cells + Array(repeating: "", count: max(0, aligns.count - cells.count)), aligns) {
                        let style = align.map { " style=\"text-align:\($0)\"" } ?? ""
                        out += "<\(tag)\(style)>\(inline(c))</\(tag)>"
                    }
                    return out + "</tr>\n"
                }
                html += "<table>\n<thead>\n" + row(tableCells(trimmed), "th") + "</thead>\n<tbody>\n"
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|") else { break }
                    html += row(tableCells(r), "td")
                    i += 1
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            closeList()
            para.append(trimmed)
            i += 1
        }

        flushPara()
        closeList()
        if inCodeBlock {
            let body = escape(codeLines.joined(separator: "\n"))
            html += "<pre><code>\(body)</code></pre>\n"
        }
        return html
    }

    static func document(body: String, title: String = "Preview") -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root {
            color-scheme: dark;
            --bg: #272822;
            --fg: #F8F8F2;
            --muted: #75715E;
            --accent: #66D9EF;
            --string: #E6DB74;
            --keyword: #F92672;
            --code-bg: #1e1f1c;
            --border: #3e3d32;
            --blockquote: #49483e;
          }
          * { box-sizing: border-box; }
          html, body {
            margin: 0; padding: 0;
            background: var(--bg); color: var(--fg);
            font: 14px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
          }
          body { padding: 20px 28px 40px; max-width: 860px; }
          h1, h2, h3, h4, h5, h6 {
            font-weight: 600; line-height: 1.25; margin: 1.4em 0 0.5em;
            color: var(--fg);
          }
          h1 { font-size: 1.85em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
          h2 { font-size: 1.45em; border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
          h3 { font-size: 1.2em; }
          h4 { font-size: 1.05em; }
          p { margin: 0.75em 0; }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          strong { color: #FD971F; font-weight: 600; }
          em { color: var(--string); }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 0.15em 0.4em;
            border-radius: 4px;
            color: var(--string);
          }
          pre {
            background: var(--code-bg);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 12px 14px;
            overflow-x: auto;
            margin: 1em 0;
          }
          pre code {
            background: none; padding: 0; color: var(--fg); font-size: 12.5px; line-height: 1.45;
          }
          blockquote {
            margin: 1em 0; padding: 0.2em 0 0.2em 1em;
            border-left: 3px solid var(--keyword);
            color: var(--muted);
          }
          blockquote p { margin: 0.4em 0; }
          ul, ol { padding-left: 1.6em; margin: 0.75em 0; }
          li { margin: 0.25em 0; }
          hr {
            border: none; border-top: 1px solid var(--border);
            margin: 1.5em 0;
          }
          img { max-width: 100%; height: auto; border-radius: 4px; }
          table {
            border-collapse: collapse; margin: 1em 0; width: 100%;
          }
          th, td {
            border: 1px solid var(--border); padding: 6px 10px; text-align: left;
          }
          th { background: var(--code-bg); }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Block helpers

    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level else { return nil }
        let idx = line.index(line.startIndex, offsetBy: level)
        guard line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func matchUnordered(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] {
            if t.hasPrefix(prefix) { return String(t.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static func matchOrdered(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let dot = t.firstIndex(of: ".") else { return nil }
        let num = t[..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
        let after = t[t.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Splits `| a | b |` into trimmed cells; `\|` stays a literal pipe.
    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], cur = "", prev: Character = " "
        for ch in t {
            if ch == "|" && prev != "\\" { cells.append(cur); cur = "" }
            else if ch == "|" { cur.removeLast(); cur.append(ch) }
            else { cur.append(ch) }
            prev = ch
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parses a delimiter row (`|---|:--:|--:|`) into per-column alignment, or nil if it isn't one.
    private static func tableAlignments(_ line: String) -> [String?]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") || t.contains("-") else { return nil }
        let cells = tableCells(t)
        var aligns: [String?] = []
        for c in cells {
            guard c.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            aligns.append(l && r ? "center" : r ? "right" : l ? "left" : nil)
        }
        return aligns
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var s = escape(text)

        // Images ![alt](url)
        s = replace(s, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { m in
            let alt = m[1], url = m[2]
            return "<img src=\"\(escapeAttr(url))\" alt=\"\(escapeAttr(alt))\">"
        }

        // Links [text](url)
        s = replace(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { m in
            let label = m[1], url = m[2]
            return "<a href=\"\(escapeAttr(url))\">\(label)</a>"
        }

        // Bold **text** or __text__
        s = replace(s, pattern: #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, pattern: #"__(.+?)__"#) { "<strong>\($0[1])</strong>" }

        // Italic *text* or _text_ (avoid matching inside words for _)
        s = replace(s, pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#) { "<em>\($0[1])</em>" }
        s = replace(s, pattern: #"(?<!\w)_(?!_)(.+?)(?<!_)_(?!\w)"#) { "<em>\($0[1])</em>" }

        // Strikethrough ~~text~~
        s = replace(s, pattern: #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }

        // Inline code `code`
        s = replace(s, pattern: #"`([^`]+)`"#) { "<code>\($0[1])</code>" }

        return s
    }

    private static func replace(_ input: String, pattern: String,
                                _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var result = input
        for match in matches.reversed() {
            var groups: [String] = [ns.substring(with: match.range)]
            for g in 1..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: transform(groups))
            }
        }
        return result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
