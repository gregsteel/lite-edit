import Foundation

enum GitFileStatus: Equatable {
    case modified
    case added
    case deleted

    /// Prefer the most severe status when combining staged + unstaged.
    static func merge(_ a: GitFileStatus?, _ b: GitFileStatus) -> GitFileStatus {
        guard let a else { return b }
        let rank: (GitFileStatus) -> Int = {
            switch $0 {
            case .deleted: return 3
            case .added: return 2
            case .modified: return 1
            }
        }
        return rank(b) >= rank(a) ? b : a
    }
}

/// Lightweight `git status --porcelain` cache for sidebar icon tinting.
final class GitStatusStore {
    private(set) var statuses: [String: GitFileStatus] = [:]
    private(set) var gitRoot: URL?
    private var folderURL: URL?
    private var workItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.liteedit.git-status", qos: .utility)

    func setFolder(_ url: URL?) {
        folderURL = url
        gitRoot = nil
        statuses = [:]
        refresh(immediate: true)
    }

    func status(for fileURL: URL) -> GitFileStatus? {
        guard let root = gitRoot else { return nil }
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        var rel = String(filePath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return statuses[rel]
    }

    func refresh(immediate: Bool = false, then onMain: (() -> Void)? = nil) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scan()
            DispatchQueue.main.async { onMain?() }
        }
        workItem = item
        if immediate {
            queue.async(execute: item)
        } else {
            queue.asyncAfter(deadline: .now() + 0.4, execute: item)
        }
    }

    private func scan() {
        guard let folder = folderURL else {
            gitRoot = nil
            statuses = [:]
            return
        }

        guard let root = resolveGitRoot(from: folder) else {
            gitRoot = nil
            statuses = [:]
            return
        }
        gitRoot = root

        let output = runGit(["-C", root.path, "status", "--porcelain", "-z", "-u"])
        guard let output, !output.isEmpty else {
            statuses = [:]
            return
        }

        var map: [String: GitFileStatus] = [:]
        let parts = output.split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < parts.count {
            let entry = String(parts[i])
            i += 1
            guard entry.count >= 3 else { continue }
            let xy = entry.prefix(2)
            var path = String(entry.dropFirst(3))

            // Rename: "R  old\0new" — porcelain -z emits old then new as next record sometimes;
            // with -z, rename is "R  oldpath\0newpath".
            if xy.first == "R" || xy.first == "C" || xy.last == "R" || xy.last == "C" {
                if i < parts.count {
                    path = String(parts[i])
                    i += 1
                }
            }

            if let st = decode(xy) {
                map[path] = GitFileStatus.merge(map[path], st)
            }
        }
        statuses = map
    }

    private func decode(_ xy: Substring) -> GitFileStatus? {
        let chars = Array(xy)
        guard chars.count == 2 else { return nil }
        if xy == "??" || xy == "A " || xy == "AM" || xy == "AD" { return .added }
        for ch in chars {
            switch ch {
            case "D": return .deleted
            case "A", "?": return .added
            case "M", "U", "T", "R", "C": return .modified
            default: break
            }
        }
        return nil
    }

    private func resolveGitRoot(from folder: URL) -> URL? {
        guard let out = runGit(["-C", folder.path, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out)
    }

    private func runGit(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 || args.contains("status") else { return nil }
            // status returns 0 even with changes; non-repo returns 128
            if proc.terminationStatus == 128 { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
