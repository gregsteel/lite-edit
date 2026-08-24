import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Registers LiteEdit as the default opener for a curated set of common
/// text / config types — after a single in-app confirmation.
///
/// Uses Launch Services preference writes + the legacy role-handler API so
/// macOS does not show one system prompt per extension.
enum DefaultAppRegistrar {
    static let bundleID = "com.liteedit.app"

    /// Filename extensions we claim as defaults.
    static let extensions: [String] = [
        "txt", "text", "md", "markdown",
        "json", "yaml", "yml", "xml", "toml",
        "csv", "tsv", "log",
        "conf", "config", "cfg", "ini", "env",
        "plist", "properties", "gitignore", "editorconfig",
    ]

    /// Content-type UTIs we claim as defaults (kept narrow — not public.text / source-code).
    static let contentTypes: [String] = [
        "public.plain-text",
        "public.utf8-plain-text",
        "public.json",
        "public.xml",
        "public.yaml",
        "net.daringfireball.markdown",
        "public.comma-separated-values-text",
        "com.apple.property-list",
        "com.apple.log",
    ]

    /// Never claim these as defaults (Open With only via Alternate rank in Info.plist).
    private static let blockedContentTypes: Set<String> = [
        "public.text",
        "public.source-code",
        "public.script",
        "public.shell-script",
        "public.python-script",
        "public.ruby-script",
        "public.perl-script",
        "public.html",
        "public.css",
        "public.swift-source",
        "public.c-source",
        "public.c-header",
        "public.c-plus-plus-source",
        "public.c-plus-plus-header",
        "public.objective-c-source",
        "public.objective-c-plus-plus-source",
        "com.sun.java-source",
        "com.netscape.javascript-source",
        "public.make-source",
    ]

    private static let blockedExtensions: Set<String> = [
        "swift", "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx",
        "html", "htm", "css", "scss", "less",
        "go", "rs", "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm",
        "java", "kt", "kts", "cs", "php", "rb", "sh", "bash", "zsh", "fish",
        "sql", "r", "lua",
    ]

    static var extensionListDisplay: String {
        extensions.map { ".\($0)" }.joined(separator: ", ")
    }

    /// Presents a single confirmation, then registers handlers.
    static func confirmAndRegister(from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Register as Default for Common Types?"
        alert.informativeText = """
            LiteEdit will become the default app for:

            \(extensionListDisplay)

            This updates your Launch Services preferences once. macOS will not ask again for each type.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Register")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let result = register()
            let done = NSAlert()
            if result.ok {
                done.messageText = "Registered"
                done.informativeText = "LiteEdit is now the default for common text and config files."
            } else {
                done.messageText = "Registration Incomplete"
                done.informativeText = result.message
            }
            done.addButton(withTitle: "OK")
            if let window {
                done.beginSheetModal(for: window)
            } else {
                done.runModal()
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @discardableResult
    static func register() -> (ok: Bool, message: String) {
        ensureInstalledInApplications()

        var errors: [String] = []

        for uti in contentTypes {
            let status = LSSetDefaultRoleHandlerForContentType(
                uti as CFString,
                LSRolesMask.all,
                bundleID as CFString
            )
            if status != noErr {
                errors.append("\(uti) (\(status))")
            }
        }

        for ext in extensions {
            guard !blockedExtensions.contains(ext) else { continue }
            if let type = UTType(filenameExtension: ext) {
                let id = type.identifier
                guard !blockedContentTypes.contains(id) else { continue }
                // Skip anything that conforms to source-code / script.
                if type.conforms(to: .sourceCode) || type.conforms(to: .script) { continue }
                let status = LSSetDefaultRoleHandlerForContentType(
                    id as CFString,
                    LSRolesMask.all,
                    bundleID as CFString
                )
                if status != noErr {
                    errors.append(".\(ext) (\(status))")
                }
            }
        }

        do {
            try writeLaunchServicesHandlers()
        } catch {
            errors.append(error.localizedDescription)
        }

        // Refresh Launch Services view of our bundle.
        let appURL = URL(fileURLWithPath: "/Applications/LiteEdit.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            LSRegisterURL(appURL as CFURL, true)
        }
        if let running = Bundle.main.bundleURL as CFURL? {
            LSRegisterURL(running, true)
        }

        if errors.isEmpty {
            return (true, "")
        }
        return (false, "Some handlers could not be set:\n" + errors.prefix(8).joined(separator: "\n"))
    }

    // MARK: - Install

    private static func ensureInstalledInApplications() {
        let dst = URL(fileURLWithPath: "/Applications/LiteEdit.app")
        let fm = FileManager.default
        // Prefer the running .app bundle when packaged; skip bare executable runs.
        let src = Bundle.main.bundleURL
        guard src.pathExtension == "app" else { return }
        guard src.standardizedFileURL != dst.standardizedFileURL else {
            LSRegisterURL(dst as CFURL, true)
            return
        }
        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            try? fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dst.appendingPathComponent("Contents/MacOS/LiteEdit").path
            )
            LSRegisterURL(dst as CFURL, true)
        } catch {
            // Non-fatal — registration by bundle ID can still work.
        }
    }

    // MARK: - Preferences write (no per-type UI)

    private static func writeLaunchServicesHandlers() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("com.apple.launchservices.secure.plist")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            root = parsed
        }

        var handlers = (root["LSHandlers"] as? [[String: Any]]) ?? []

        // Drop any prior LiteEdit defaults for source / script types.
        handlers.removeAll { entry in
            guard (entry["LSHandlerRoleAll"] as? String) == bundleID else { return false }
            if let uti = entry["LSHandlerContentType"] as? String,
               blockedContentTypes.contains(uti) {
                return true
            }
            if let tag = entry["LSHandlerContentTag"] as? String,
               (entry["LSHandlerContentTagClass"] as? String) == "public.filename-extension",
               blockedExtensions.contains(tag) {
                return true
            }
            return false
        }

        func upsertContentType(_ uti: String) {
            guard !blockedContentTypes.contains(uti) else { return }
            handlers.removeAll {
                ($0["LSHandlerContentType"] as? String) == uti
            }
            handlers.append([
                "LSHandlerContentType": uti,
                "LSHandlerRoleAll": bundleID,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
            ])
        }

        func upsertExtension(_ ext: String) {
            guard !blockedExtensions.contains(ext) else { return }
            handlers.removeAll {
                ($0["LSHandlerContentTag"] as? String) == ext
                    && ($0["LSHandlerContentTagClass"] as? String) == "public.filename-extension"
            }
            handlers.append([
                "LSHandlerContentTag": ext,
                "LSHandlerContentTagClass": "public.filename-extension",
                "LSHandlerRoleAll": bundleID,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
            ])
        }

        for uti in contentTypes { upsertContentType(uti) }
        for ext in extensions {
            upsertExtension(ext)
            if let type = UTType(filenameExtension: ext) {
                let id = type.identifier
                guard !blockedContentTypes.contains(id) else { continue }
                if type.conforms(to: .sourceCode) || type.conforms(to: .script) { continue }
                upsertContentType(id)
            }
        }

        root["LSHandlers"] = handlers
        let out = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        try out.write(to: url, options: .atomic)
    }
}
