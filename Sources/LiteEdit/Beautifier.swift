import Foundation

/// Built-in document beautifier (no external formatters).
enum Beautifier {
    /// Returns formatted text, or `nil` if unchanged / unsupported / invalid.
    static func beautify(_ text: String, language: Document.Language) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch language {
        case .json:
            return beautifyJSON(text)
        case .xml, .html:
            return beautifyMarkup(text)
        case .css:
            return beautifyBraces(text, indentSize: 2)
        case .javascript, .typescript, .swift, .c, .cpp, .java, .go, .rust:
            return beautifyBraces(text, indentSize: 4)
        case .python, .ruby, .shell, .yaml, .toml, .sql, .markdown, .plainText:
            return normalizeWhitespace(text)
        }
    }

    // MARK: - JSON

    /// Indent-only tidy: keeps key order, string contents, and escapes as written.
    /// Does not re-encode through JSONSerialization (avoids sorted keys / `\/`).
    private static func beautifyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }

        let indentUnit = "  "
        var out = ""
        var depth = 0
        var i = text.startIndex
        var inString = false
        var escaped = false
        var needsIndent = false

        func writeIndent() {
            out += String(repeating: indentUnit, count: depth)
        }

        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)

            if inString {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i = next
                continue
            }

            switch ch {
            case "\"":
                if needsIndent {
                    writeIndent()
                    needsIndent = false
                }
                inString = true
                out.append(ch)

            case "{", "[":
                if needsIndent {
                    writeIndent()
                    needsIndent = false
                }
                out.append(ch)
                // Peek: empty container stays on one line
                var j = next
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                if j < text.endIndex, (text[j] == "}" && ch == "{") || (text[j] == "]" && ch == "[") {
                    out.append(text[j])
                    i = text.index(after: j)
                    continue
                }
                out.append("\n")
                depth += 1
                needsIndent = true

            case "}", "]":
                if !out.hasSuffix("\n") { out.append("\n") }
                depth = max(0, depth - 1)
                writeIndent()
                out.append(ch)
                needsIndent = false

            case ",":
                out.append(",")
                out.append("\n")
                needsIndent = true

            case ":":
                out.append(": ")
                // Skip any existing spaces after colon in the source
                var j = next
                while j < text.endIndex, text[j] == " " || text[j] == "\t" {
                    j = text.index(after: j)
                }
                i = j
                continue

            case " ", "\t", "\n", "\r":
                // Drop original whitespace outside strings
                break

            default:
                if needsIndent {
                    writeIndent()
                    needsIndent = false
                }
                out.append(ch)
            }

            i = next
        }

        if !out.hasSuffix("\n") { out += "\n" }
        // Match common style: no trailing spaces
        let cleaned = out.replacingOccurrences(of: " \n", with: "\n")
        return cleaned == text ? nil : cleaned
    }

    // MARK: - Markup (HTML / XML)

    private static func beautifyMarkup(_ text: String) -> String? {
        // Preserve void / self-closing feel; indent by tag depth.
        var result = ""
        var depth = 0
        let indentUnit = "  "
        var i = text.startIndex

        func indent() -> String { String(repeating: indentUnit, count: max(0, depth)) }

        while i < text.endIndex {
            if text[i] == "<" {
                // Skip leading whitespace before a tag on its own "token"
                let j = i
                guard let close = text[j...].firstIndex(of: ">") else {
                    result.append(contentsOf: text[i...])
                    break
                }
                let tag = String(text[j...close])
                let isClose = tag.hasPrefix("</")
                let isComment = tag.hasPrefix("<!--")
                let isDoctype = tag.uppercased().hasPrefix("<!DOCTYPE")
                let isSelfClosing = tag.hasSuffix("/>") || isVoidHTMLTag(tag)

                if isClose { depth = max(0, depth - 1) }

                if !result.isEmpty && !result.hasSuffix("\n") {
                    result += "\n"
                }
                result += indent() + tag

                if !isClose && !isSelfClosing && !isComment && !isDoctype {
                    depth += 1
                }

                i = text.index(after: close)

                // Inline text until next tag
                let textStart = i
                while i < text.endIndex && text[i] != "<" { i = text.index(after: i) }
                let between = String(text[textStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !between.isEmpty {
                    if between.contains("\n") {
                        result += "\n" + indent() + between.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n" + indent())
                    } else {
                        result += between
                        // Keep short text inline with closing tag if next is close
                    }
                }
            } else {
                i = text.index(after: i)
            }
        }

        if !result.hasSuffix("\n") { result += "\n" }
        return result == text ? nil : result
    }

    private static func isVoidHTMLTag(_ tag: String) -> Bool {
        let name = tag
            .dropFirst()
            .prefix(while: { $0.isLetter || $0 == "/" })
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let voids: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr",
        ]
        return voids.contains(name)
    }

    // MARK: - Brace languages

    private static func beautifyBraces(_ text: String, indentSize: Int) -> String? {
        let unit = String(repeating: " ", count: indentSize)
        var result = ""
        var depth = 0
        var i = text.startIndex
        var lineBuf = ""
        var inString: Character? = nil
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        func flushLine(extraOutdent: Bool = false) {
            let trimmed = lineBuf.trimmingCharacters(in: .whitespaces)
            lineBuf = ""
            guard !trimmed.isEmpty || result.hasSuffix("\n") == false || !result.isEmpty else { return }
            var d = depth
            if extraOutdent { d = max(0, d - 1) }
            // Closing brace alone: outdent first
            if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") || trimmed.hasPrefix(")") {
                d = max(0, d - 1)
            }
            result += String(repeating: unit, count: d) + trimmed + "\n"
        }

        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            let nextCh: Character? = next < text.endIndex ? text[next] : nil

            if inLineComment {
                lineBuf.append(ch)
                if ch == "\n" {
                    inLineComment = false
                    flushLine()
                }
                i = next
                continue
            }

            if inBlockComment {
                lineBuf.append(ch)
                if ch == "*", nextCh == "/" {
                    lineBuf.append("/")
                    i = text.index(after: next)
                    inBlockComment = false
                    continue
                }
                if ch == "\n" { flushLine() }
                i = next
                continue
            }

            if let q = inString {
                lineBuf.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == q {
                    inString = nil
                }
                i = next
                continue
            }

            if ch == "/" && nextCh == "/" {
                inLineComment = true
                lineBuf.append(ch)
                i = next
                continue
            }
            if ch == "/" && nextCh == "*" {
                inBlockComment = true
                lineBuf.append(ch)
                i = next
                continue
            }
            if ch == "\"" || ch == "'" || ch == "`" {
                inString = ch
                lineBuf.append(ch)
                i = next
                continue
            }

            if ch == "{" || ch == "[" {
                lineBuf.append(ch)
                flushLine()
                depth += 1
                i = next
                continue
            }
            if ch == "}" || ch == "]" {
                let trimmed = lineBuf.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    depth = max(0, depth - 1)
                    lineBuf.append(ch)
                    // Keep `},` / `);` on same line
                    i = next
                    while i < text.endIndex && (text[i] == "," || text[i] == ";" || text[i] == ")") {
                        lineBuf.append(text[i])
                        i = text.index(after: i)
                    }
                    flushLine()
                    continue
                } else {
                    lineBuf.append(ch)
                    i = next
                    continue
                }
            }

            if ch == "\n" {
                flushLine()
                i = next
                continue
            }

            lineBuf.append(ch)
            i = next
        }

        if !lineBuf.trimmingCharacters(in: .whitespaces).isEmpty {
            flushLine()
        }

        // Trim excessive blank lines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if result != text && !result.isEmpty {
            return result
        }
        return result == text ? nil : result
    }

    private static func normalizeWhitespace(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map {
            $0.replimmingTrailingSpaces()
        }
        var out = lines.joined(separator: "\n")
        // Collapse 3+ blank lines to 2
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if !out.hasSuffix("\n") { out += "\n" }
        return out == text ? nil : out
    }
}

private extension String {
    func replimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }
}
