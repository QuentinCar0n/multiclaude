import Foundation

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
}
