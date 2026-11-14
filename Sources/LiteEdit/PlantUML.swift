import Foundation

/// Renders PlantUML source to SVG via the locally installed `plantuml` CLI.
/// Nothing here runs until a document actually contains a PlantUML diagram.
enum PlantUML {
    private static let searchPaths = [
        "/opt/homebrew/bin/plantuml", "/usr/local/bin/plantuml", "/usr/bin/plantuml",
    ]
    private static var cache: [String: String] = [:]   // key → HTML fragment (main thread only)
    private static var inFlight: [String: [(String) -> Void]] = [:]

    static func key(_ source: String) -> String {
        String(UInt(bitPattern: source.hashValue), radix: 36)
    }

    private static func executable() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Cached result, or the "not installed" notice. `nil` means a render is needed.
    static func fragment(for source: String) -> String? {
        if let hit = cache[key(source)] { return hit }
        if executable() == nil {
            return "<div class=\"note\">PlantUML is not installed — run <code>brew install plantuml</code> to see this diagram.</div>"
                + "<pre><code>\(MarkdownHTML.escape(source))</code></pre>"
        }
        return nil
    }

    /// Renders on a background queue; `completion` is called on the main queue with an HTML fragment.
    static func render(_ source: String, completion: @escaping (String) -> Void) {
        let k = key(source)
        if inFlight[k] != nil { inFlight[k]?.append(completion); return }
        inFlight[k] = [completion]
        guard let exe = executable() else { finish(k, source, nil, "plantuml not found"); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let (svg, err) = run(exe, source)
            DispatchQueue.main.async { finish(k, source, svg, err) }
        }
    }

    private static func finish(_ k: String, _ source: String, _ svg: String?, _ err: String?) {
        let fragment: String
        if let svg = svg {
            fragment = svg
        } else {
            fragment = "<div class=\"note\">PlantUML failed: \(MarkdownHTML.escape(err ?? "unknown error"))</div>"
                + "<pre><code>\(MarkdownHTML.escape(source))</code></pre>"
        }
        if cache.count > 50 { cache.removeAll() }
        cache[k] = fragment
        let waiters = inFlight.removeValue(forKey: k) ?? []
        waiters.forEach { $0(fragment) }
    }

    private static func run(_ exe: String, _ source: String) -> (String?, String?) {
        let text = source.contains("@start") ? source : "@startuml\n\(source)\n@enduml"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-tsvg", "-pipe", "-charset", "UTF-8"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PLANTUML_SECURITY_PROFILE"] = "SANDBOX"   // no !include of arbitrary files/URLs
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() } catch { return (nil, error.localizedDescription) }

        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        inPipe.fileHandleForWriting.write(Data(text.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        timeout.cancel()

        let out = String(decoding: outData, as: UTF8.self)
        if let r = out.range(of: "<svg") {
            return (String(out[r.lowerBound...]), nil)
        }
        let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, msg.isEmpty ? "no output (exit \(p.terminationStatus))" : msg)
    }
}
