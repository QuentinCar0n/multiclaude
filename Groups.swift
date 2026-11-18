import Foundation
import Darwin

// Account groups. Profiles in the same group share one Claude Code config folder (memory, CLAUDE.md,
// skills, plugins, settings and transcripts); a profile alone in its group keeps its own context.
// A profile with no group keeps the folder it always had, so nothing changes until a group is set.
enum Groups {
    // The group whose folder is ~/.claude, the folder Claude Code uses when nothing points it elsewhere.
    static let defaultName = "Personal"

    // A safe single path component: lowercase ASCII letters and digits, other runs turned into "-".
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var dash = false
        for ch in folded.lowercased().unicodeScalars {
            if ch.isASCII && (CharacterSet.alphanumerics.contains(ch)) {
                if dash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "group" : out
    }

    // The Claude Code config folder of a named group.
    static func folder(group: String, home: String) -> String {
        let s = slug(group)
        return s == slug(defaultName) ? home + "/.claude" : home + "/.claude-" + s
    }

    // What a new group folder gets from ~/.claude: the setup only, never history, memory or transcripts.
    static let setupItems = ["CLAUDE.md", "skills", "plugins", "agents", "commands", "settings.json"]

    static func seedPlan(from: String, to: String) -> [(from: String, to: String)] {
        setupItems.compactMap { item in
            let src = (from as NSString).appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: src) else { return nil }
            return (src, (to as NSString).appendingPathComponent(item))
        }
    }

    // Copies the setup into a group folder. Anything already there is kept, so it never overwrites.
    static func seed(from: String, to: String) throws {
        try ensureFolder(to)
        for (src, dst) in seedPlan(from: from, to: to) where !FileManager.default.fileExists(atPath: dst) {
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        }
    }

    // Creates a group folder readable only by the user (0700). An existing folder is left as it is.
    static func ensureFolder(_ path: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // Why a profile's group can't change now, or nil. An open account would keep writing to its old folder.
    static func changeRefusal(name: String, running: Bool) -> String? {
        running ? "Quit \(name) first, then change its group." : nil
    }

    // Running Claude Code processes started by a Claude app (<data folder>/claude-code/<version>/<hash>/
    // claude.app), with the CLAUDE_CONFIG_DIR each started with. Unreadable processes are left out.
    static func codeSessions() -> [(path: String, configDir: String?)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [(String, String?)] = []
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            guard path.hasSuffix("/claude.app/Contents/MacOS/claude"), path.contains("/claude-code/"),
                  let env = ProcArgs.env(pid) else { continue }
            out.append((path, env["CLAUDE_CONFIG_DIR"]))
        }
        return out
    }

    // How many running Claude Code sessions use another config folder than the group's.
    // `expected` nil = ~/.claude; a nil entry in `seen` = no CLAUDE_CONFIG_DIR, which is ~/.claude too.
    static func misplaced(expected: String?, seen: [String?], home: String) -> Int {
        func norm(_ p: String?) -> String {
            var s = p ?? home + "/.claude"
            if s.hasPrefix("~/") { s = home + s.dropFirst(1) }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let want = norm(expected)
        return seen.filter { norm($0) != want }.count
    }
}
