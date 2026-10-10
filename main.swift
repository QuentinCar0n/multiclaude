// MultiClaude: menu bar manager for several Claude desktop instances, one per profile.
// Each profile is a separate --user-data-dir, so each one keeps its own account and chats.
// Same panel as Cocaine (header switch, collapsible sections, round icons), in Claude orange.
import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import CryptoKit

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
let websiteURL = URL(string: "https://somalabs.me")!
let supportURL = URL(string: "mailto:quentin@somalabs.me?subject=MultiClaude")!
let claudeBundleID = "com.anthropic.claudefordesktop"
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let isPreview = ProcessInfo.processInfo.environment["MULTICLAUDE_PREVIEW"] != nil
// Releases are signed in CI with the matching private key (repo secret UPDATE_SIGNING_KEY).
let updatePublicKey = "ovYVjB5Bst53pHaSwbk7KKX+JRAqv7zuponiduhHa+w="
// Command-line modes (--list, --selftest-*, ...) only read; the menu bar app owns the profile list.
let isCLI = CommandLine.arguments.count > 1
let isDemo = ProcessInfo.processInfo.environment["MULTICLAUDE_DEMO"] != nil   // sample profiles for README screenshots

extension Color {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
}

extension NSColor {
    static let claude = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
}

// MARK: - Profiles

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var dir: String?   // nil = the default Claude profile, launched without --user-data-dir
    var color: Int?    // index into Palette.colors; nil until the first load assigns one
    var openAtLaunch: Bool?
    var codeDir: String?   // pinned Claude Code folder, kept when the data folder is renamed

    var isDefault: Bool { dir == nil }
    var initial: String { String(name.prefix(1)).uppercased() }
    var folderURL: URL { dir.map { URL(fileURLWithPath: $0) } ?? supportDir.appendingPathComponent("Claude") }
    var tint: Color { Color(nsColor: nsTint) }
    var nsTint: NSColor { Palette.colors[(color ?? 0) % Palette.colors.count].color }
    private var key: String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    var shellAlias: String {
        guard let dir else { return "alias \(key)='open -a \"Claude\"'" }
        return "alias \(key)='open -n -a \"Claude\" --args --user-data-dir=\"\(dir)\"'"
    }

    // Claude Code keeps its sign-in per config folder (and per Keychain entry on macOS),
    // so each profile gets ~/.claude-<folder suffix>. The default profile keeps ~/.claude.
    var codeConfigDir: String? {
        guard let dir else { return nil }
        if let codeDir { return codeDir }
        let suffix = URL(fileURLWithPath: dir).lastPathComponent.replacingOccurrences(of: "Claude-", with: "").lowercased()
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-" + suffix
    }

    var codeAlias: String {
        guard let codeConfigDir else { return "alias claude-\(key)='claude'" }
        return "alias claude-\(key)='CLAUDE_CONFIG_DIR=\"\(codeConfigDir)\" claude'"
    }
}

enum Palette {
    static let colors: [(name: String, color: NSColor)] = [
        ("Orange", .claude),
        ("Blue", NSColor(srgbRed: 0.29, green: 0.55, blue: 0.96, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.27, green: 0.69, blue: 0.44, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.62, green: 0.45, blue: 0.91, alpha: 1)),
        ("Pink", NSColor(srgbRed: 0.91, green: 0.41, blue: 0.62, alpha: 1)),
        ("Teal", NSColor(srgbRed: 0.18, green: 0.66, blue: 0.71, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 0.88, green: 0.67, blue: 0.18, alpha: 1)),
        ("Graphite", NSColor(srgbRed: 0.52, green: 0.52, blue: 0.55, alpha: 1)),
    ]
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum Seed {
    // First run: the default profile, the Claude aliases in ~/.zshrc, then any other Claude-* folder.
    static func profiles() -> [Profile] {
        var list = [Profile(name: "Claude", dir: nil)]
        var seen = Set<String>()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rc = (try? String(contentsOfFile: home + "/.zshrc", encoding: .utf8)) ?? ""
        let re = try! NSRegularExpression(pattern: #"alias\s+(\w+)=['"]open -n -a "?Claude"? --args --user-data-dir="?([^"']+)"?['"]"#)
        for m in re.matches(in: rc, range: NSRange(rc.startIndex..., in: rc)) {
            guard let n = Range(m.range(at: 1), in: rc), let d = Range(m.range(at: 2), in: rc) else { continue }
            let dir = String(rc[d]).replacingOccurrences(of: "$HOME", with: home)
            list.append(Profile(name: String(rc[n]).capitalized, dir: dir))
            seen.insert(dir)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? []
        for n in names.sorted() where n.hasPrefix("Claude-") && n != "Claude-3p" {
            let dir = supportDir.appendingPathComponent(n).path
            if !seen.contains(dir) { list.append(Profile(name: String(n.dropFirst(7)), dir: dir)) }
        }
        return list
    }
}

// MARK: - Settings

enum Setting: String, CaseIterable, Identifiable {
    case launchAtLogin, autoUpdate, reopenAfterUpdate, shortcut, profileShortcuts, showActive, showCount, coloredIcon, quitWithApp

    static let onByDefault: Set<Setting> = [.autoUpdate, .reopenAfterUpdate, .showActive, .showCount]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launchAtLogin: "Launch at Login"
        case .autoUpdate: "Update MultiClaude Automatically"
        case .reopenAfterUpdate: "Reopen After Claude Updates"
        case .shortcut: "Keyboard Shortcut"
        case .profileShortcuts: "Profile Shortcuts"
        case .showActive: "Show Active Account in Menu Bar"
        case .showCount: "Show Count in Menu Bar"
        case .coloredIcon: "Colored Menu Bar Icon"
        case .quitWithApp: "Quit Profiles with MultiClaude"
        }
    }

    var symbol: String {
        switch self {
        case .launchAtLogin: "power"
        case .autoUpdate: "arrow.down.circle"
        case .reopenAfterUpdate: "arrow.clockwise"
        case .shortcut: "command"
        case .profileShortcuts: "keyboard"
        case .showActive: "menubar.rectangle"
        case .showCount: "number"
        case .coloredIcon: "paintpalette"
        case .quitWithApp: "xmark.circle"
        }
    }

    var hint: String? {
        switch self {
        case .shortcut: "⌃⌥⌘M"
        case .profileShortcuts: "⌃⌥1 to 9"
        default: nil
        }
    }
}

// MARK: - Engine

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var profiles: [Profile]
    @Published private(set) var running: [UUID: NSRunningApplication] = [:]
    @Published private(set) var frontID: UUID?     // profile of the frontmost Claude window
    @Published private(set) var notice: String?    // one-line message at the top of the panel

    var onChange: (() -> Void)?
    var onPanelHotKey: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var pending: [UUID: Date] = [:]   // launched, process not seen yet
    private var demoRunning: Set<UUID> = []
    private var claudeVersion = UpdateWatch.installedVersion()
    private var updatedAt: Date?
    private var quitAt: [UUID: Date] = [:]    // profiles that stopped without MultiClaude quitting them
    private var userQuit: Set<UUID> = []
    private var stopLog: [UUID: Date] = [:]   // last unrequested stop per profile, kept after it relaunches
    private var strayHandled: Date?           // the update whose stray default window was already closed

    private init() {
        if isDemo {
            profiles = ["Personal", "Work", "Client", "Research"].enumerated().map { i, n in
                Profile(name: n, dir: i == 0 ? nil : "/tmp/multiclaude-demo/Claude-\(n)")
            }
            for i in profiles.indices { profiles[i].color = i }
            demoRunning = [profiles[0].id, profiles[1].id]
            frontID = profiles[1].id
            return
        }
        if let data = defaults.data(forKey: "profiles"), let list = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = list
        } else {
            profiles = Seed.profiles()
        }
        for i in profiles.indices where profiles[i].color == nil { profiles[i].color = nextColor() }
        discoverFolders()
    }

    private func nextColor() -> Int {
        let used = Set(profiles.compactMap(\.color))
        return Palette.colors.indices.first { !used.contains($0) } ?? profiles.count % Palette.colors.count
    }

    func boot() {
        save()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Engine.shared.refresh() }
            }
        }
        let afterSelfUpdate = defaults.string(forKey: "updatedTo") != nil
        if let to = defaults.string(forKey: "updatedTo") {
            defaults.removeObject(forKey: "updatedTo")
            if to == appVersion { notice = "MultiClaude updated to \(to)." }
        }
        if !isDemo { Updater.start() }
        // Electron instances launched with `open -n` sometimes skip the launch notification; poll as a backstop.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { Engine.shared.refresh() }
        }
        refresh()
        // A restart after a self-update keeps whatever is open; it does not reopen startup profiles.
        if !isDemo && !afterSelfUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let e = Engine.shared
                e.profiles.filter { $0.openAtLaunch == true && !e.isRunning($0) }.forEach(e.open)
            }
        }
    }

    // MARK: settings

    func isOn(_ s: Setting) -> Bool {
        if s == .launchAtLogin { return SMAppService.mainApp.status == .enabled }
        if Setting.onByDefault.contains(s) && defaults.object(forKey: s.rawValue) == nil { return true }
        return defaults.bool(forKey: s.rawValue)
    }

    func toggle(_ s: Setting) {
        let on = !isOn(s)
        objectWillChange.send()
        if s == .launchAtLogin {
            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSSound.beep() }
            return
        }
        defaults.set(on, forKey: s.rawValue)
        if s == .shortcut || s == .profileShortcuts { updateHotKeys() }
        onChange?()
    }

    // ⌃⌥⌘M opens the panel; ⌃⌥1 to ⌃⌥9 open or focus the profiles in list order.
    func updateHotKeys() {
        var keys: [HotKey.Binding] = []
        if isOn(.shortcut) {
            keys.append(.init(key: kVK_ANSI_M, mods: cmdKey | optionKey | controlKey) { Engine.shared.onPanelHotKey?() })
        }
        if isOn(.profileShortcuts) {
            for (i, p) in profiles.prefix(9).enumerated() {
                let id = p.id
                keys.append(.init(key: HotKey.digits[i], mods: optionKey | controlKey) {
                    if let p = Engine.shared.profiles.first(where: { $0.id == id }) { Engine.shared.open(p) }
                })
            }
        }
        HotKey.register(keys)
    }

    func shortcutHint(for p: Profile) -> String? {
        guard isOn(.profileShortcuts), let i = profiles.firstIndex(of: p), i < 9 else { return nil }
        return "⌃⌥\(i + 1)"
    }

    func dismissNotice() {
        if signIn != nil { finishSignIn(cancelled: true) }
        notice = nil
    }

    // MARK: sign-in

    // Claude's Google and SSO sign-in leaves through the browser and comes back as a claude:// link, which
    // macOS hands to the first Claude window it finds. During a sign-in MultiClaude takes over claude:// links
    // and passes them to the one process that asked, then gives the links back to Claude.
    // If MultiClaude can't take the links, it falls back to closing the other accounts for the duration.
    struct SignIn {
        let target: UUID
        var reopen: [UUID] = []
        var logOffset: UInt64
        var sawBrowser = false
        var routing = false
        let started = Date()
    }
    @Published private(set) var signIn: SignIn?
    private var signInTimer: Timer?

    func beginSignIn(_ p: Profile) {
        guard signIn == nil else { return }
        signIn = SignIn(target: p.id, logOffset: SignInLog.size())
        notice = "Getting \(p.name) ready to sign in…"
        if !isRunning(p) { open(p) }
        signInTimer?.invalidate()
        signInTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Engine.shared.checkSignIn() }
        }
        // Claude makes itself the claude:// handler as it starts, so take over only once the target is up.
        func waitForTarget(_ n: Int) {
            let e = Engine.shared
            guard e.signIn?.target == p.id else { return }
            e.refresh()
            if e.isRunning(p) || n > 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Engine.shared.takeOverLinks(for: p) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForTarget(n + 1) }
        }
        waitForTarget(0)
    }

    private func takeOverLinks(for p: Profile) {
        guard signIn?.target == p.id else { return }
        LinkRelay.take { ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let e = Engine.shared
                    guard e.signIn?.target == p.id else { LinkRelay.giveBack(); return }
                    if ok {
                        e.signIn?.routing = true
                        e.notice = "Sign in to \(p.name) now. MultiClaude sends the sign-in back to its window."
                        if let app = e.running[p.id] { app.unhide(); app.activate() }
                    } else {
                        e.closeOthersForSignIn(p)
                    }
                }
            }
        }
    }

    // Fallback: with only the target open, the link can only land there.
    private func closeOthersForSignIn(_ p: Profile) {
        let others = profiles.filter { $0.id != p.id && isRunning($0) }
        signIn?.reopen = others.map(\.id)
        let names = ListFormatter.localizedString(byJoining: others.map(\.name))
        notice = others.isEmpty ? "Sign in to \(p.name) in its window."
            : "Sign in to \(p.name) in its window. \(names) reopen\(others.count == 1 ? "s" : "") once you're signed in."
        func next(_ rest: [Profile]) {
            guard let first = rest.first else { Engine.shared.open(p); return }
            Engine.shared.quitAndWait(first) { next(Array(rest.dropFirst())) }
        }
        next(others)
    }

    // A claude:// link that reached MultiClaude: during a sign-in it goes to the target process,
    // otherwise to Claude as usual.
    func relay(_ link: String) {
        if let s = signIn, s.routing, let app = running[s.target], LinkRelay.send(link, to: app.processIdentifier) {
            signIn?.sawBrowser = true
            app.unhide()
            app.activate()
            return
        }
        LinkRelay.giveBack()
        if let url = URL(string: link) {
            NSWorkspace.shared.open([url], withApplicationAt: LinkRelay.claudeApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func checkSignIn() {
        guard var s = signIn else { return }
        if -s.started.timeIntervalSinceNow > 600 { finishSignIn(cancelled: true); return }
        let (lines, offset) = SignInLog.read(from: s.logOffset)
        s.logOffset = offset
        let (sawBrowser, done) = SignInLog.scan(lines, sawBrowser: s.sawBrowser)
        s.sawBrowser = sawBrowser
        signIn = s
        if done { finishSignIn(cancelled: false) }
    }

    func finishSignIn(cancelled: Bool) {
        guard let s = signIn else { return }
        signInTimer?.invalidate()
        signInTimer = nil
        signIn = nil
        LinkRelay.giveBack()
        let reopen = profiles.filter { s.reopen.contains($0.id) && !isRunning($0) }
        reopen.forEach(open)
        let target = profiles.first { $0.id == s.target }?.name ?? "the account"
        if cancelled { notice = nil; return }
        notice = "Signed in to \(target)."
            + (reopen.isEmpty ? "" : " Reopened " + ListFormatter.localizedString(byJoining: reopen.map(\.name)) + ".")
    }
    func show(notice text: String) { notice = text }

    // MARK: running instances

    // Matches each Claude process to a profile through its --user-data-dir argument.
    func refresh() {
        guard !isDemo else { return }
        var found: [UUID: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleID && !app.isTerminated {
            let dir = ProcArgs.of(app.processIdentifier)
                .first { $0.hasPrefix("--user-data-dir=") }
                .map { Folders.canonical(String($0.dropFirst(16))) }
            if let p = profiles.first(where: { $0.dir.map(Folders.canonical) == dir }) {
                found[p.id] = app
            }
        }
        for id in found.keys { pending[id] = nil }
        pending = pending.filter { $0.value.timeIntervalSinceNow > -15 }

        let now = Date()
        for id in running.keys where found[id] == nil {
            if userQuit.remove(id) == nil {
                quitAt[id] = now
                stopLog[id] = now
            }
        }
        for id in found.keys { quitAt[id] = nil }
        quitAt = quitAt.filter { now.timeIntervalSince($0.value) < 300 }
        stopLog = stopLog.filter { now.timeIntervalSince($0.value) < 600 }
        if let v = UpdateWatch.installedVersion(), v != claudeVersion {
            claudeVersion = v
            updatedAt = now
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let newFront = found.first { $0.value.processIdentifier == front }?.key
        if Set(found.keys) != Set(running.keys) || newFront != frontID {
            running = found
            frontID = newFront
            onChange?()
        }
        reopenAfterUpdate(now: now)
        alignFolders()   // after `running` is current, so an open profile is never moved
    }

    // Claude relaunches itself without --user-data-dir when it installs an update, so profile windows
    // come back on the default account. Reopen each profile that stopped around the update.
    private func reopenAfterUpdate(now: Date) {
        guard isOn(.reopenAfterUpdate), let updatedAt else { return }
        let relaunched = running.values.contains { ($0.launchDate ?? .distantPast) > updatedAt.addingTimeInterval(-10) }
        closeStrayDefault(updatedAt: updatedAt)
        let due = UpdateWatch.due(quitAt: quitAt, updatedAt: updatedAt, relaunched: relaunched, now: now)
        let reopen = profiles.filter { due.contains($0.id) && !$0.isDefault }
        guard !reopen.isEmpty else { return }
        for p in reopen {
            quitAt[p.id] = nil
            open(p)
        }
        notice = "Claude updated. Reopened " + ListFormatter.localizedString(byJoining: reopen.map(\.name)) + "."
        onChange?()
    }

    func isRunning(_ p: Profile) -> Bool { running[p.id] != nil || demoRunning.contains(p.id) }
    func isStarting(_ p: Profile) -> Bool { pending[p.id] != nil && running[p.id] == nil }
    var runningCount: Int { running.count + demoRunning.count }

    // MARK: actions

    func open(_ p: Profile) {
        if let app = running[p.id] {
            app.unhide()
            app.activate()
            return
        }
        if let dir = p.dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let anyClaude = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeBundleID && !$0.isTerminated }
        let args = Launch.openArgs(dir: p.dir, anyClaudeRunning: anyClaude)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = args
        do { try task.run() } catch { NSSound.beep(); return }
        objectWillChange.send()
        pending[p.id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Engine.shared.refresh() }
    }

    // Claude's relaunch after an update opens the default account even when it was not open before.
    // Close that window, but only when the default did not stop around the update itself.
    private func closeStrayDefault(updatedAt: Date) {
        guard strayHandled != updatedAt, let d = profiles.first(where: \.isDefault), let app = running[d.id],
              pending[d.id] == nil else { return }
        let others = stopLog.filter { $0.key != d.id }.map(\.value)
        guard UpdateWatch.isStrayDefault(defaultLaunch: app.launchDate, defaultStop: stopLog[d.id],
                                         profileStops: others, updatedAt: updatedAt) else { return }
        strayHandled = updatedAt
        userQuit.insert(d.id)
        app.terminate()
    }

    func quit(_ p: Profile) {
        guard let app = running[p.id] else { return }
        userQuit.insert(p.id)
        app.terminate()
    }

    // Opens Terminal running Claude Code signed in as this profile's account.
    func openClaudeCode(_ p: Profile) {
        var lines = ["#!/bin/zsh"]
        if let dir = p.codeConfigDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            lines.append("export CLAUDE_CONFIG_DIR=\(shellQuote(dir))")
        }
        lines += ["clear", "echo \(shellQuote("Claude Code as " + p.name))", "cd ~", "claude", "exec $SHELL -l"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MultiClaude-\(p.id.uuidString.prefix(8)).command")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    func openAll() { profiles.filter { !isRunning($0) }.forEach(open) }
    func quitAll() { profiles.forEach(quit) }

    // MARK: editing

    @discardableResult
    func add(name raw: String) -> Bool {
        guard let p = newProfile(named: raw) else { NSSound.beep(); return false }
        profiles.append(p)
        save()
        return true
    }

    // A profile with a fresh Claude-<name> folder, or nil when the name is empty, taken or its folder exists.
    func newProfile(named raw: String) -> Profile? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let slug = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let dir = supportDir.appendingPathComponent("Claude-\(slug)").path
        guard !slug.isEmpty, !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !profiles.contains(where: { $0.dir == dir }) else { return nil }
        return Profile(name: name, dir: dir, color: nextColor())
    }

    func setOpenAtLaunch(_ p: Profile, _ on: Bool) {
        guard let i = profiles.firstIndex(of: p) else { return }
        profiles[i].openAtLaunch = on
        save()
    }

    // Quits a running profile and calls back once its process is gone (or after 15 s).
    func quitAndWait(_ p: Profile, then done: @escaping @Sendable @MainActor () -> Void) {
        guard let app = running[p.id] else { done(); return }
        userQuit.insert(p.id)
        app.terminate()
        func poll(_ n: Int) {
            if app.isTerminated || n > 60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { done() } }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(n + 1) }
        }
        poll(0)
    }

    // Clones a profile's whole data folder, sign-in and chats included, into a new profile.
    // APFS clones make the copy instant and free until the two folders diverge.
    func duplicate(_ source: Profile, as name: String) {
        guard let p = newProfile(named: name), let dst = p.dir else { NSSound.beep(); return }
        let wasRunning = isRunning(source)
        notice = "Duplicating \(source.name)…"
        quitAndWait(source) {
            Task.detached {
                let ok = Duplicate.clone(from: source.folderURL.path, to: dst)
                await MainActor.run {
                    let e = Engine.shared
                    if ok {
                        e.profiles.append(p)
                        e.save()
                        e.notice = "Duplicated \(source.name) as \(p.name). Both are signed in to the same account until you sign one out."
                    } else {
                        e.notice = "Couldn't duplicate \(source.name). Nothing was changed."
                    }
                    if wasRunning { e.open(source) }
                }
            }
        }
    }

    func copyMCPServers(from source: Profile, to target: Profile, restart: Bool) {
        do {
            let n = try MCP.copy(from: source, to: target)
            notice = "Copied \(n) MCP server\(n == 1 ? "" : "s") from \(source.name) to \(target.name)."
                + (restart || !isRunning(target) ? "" : " Reopen \(target.name) to load them.")
            if restart && isRunning(target) { quitAndWait(target) { Engine.shared.open(target) } }
        } catch {
            notice = "Couldn't copy MCP servers: \(target.name)'s config file isn't valid JSON."
        }
    }

    // The folder follows the new name on its own (see alignFolders), once the profile is closed.
    func rename(_ p: Profile, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = profiles.firstIndex(of: p) else { return }
        profiles[i].name = name
        save()
        alignFolders()
    }

    // Takes the profile off the list. Its data folder stays on disk and is not added back.
    func remove(_ p: Profile) {
        guard !p.isDefault, let dir = p.dir else { return }
        defaults.set(Array(Set(ignoredFolders + [Folders.canonical(dir)])), forKey: "ignoredFolders")
        profiles.removeAll { $0.id == p.id }
        save()
    }

    private var ignoredFolders: [String] { defaults.stringArray(forKey: "ignoredFolders") ?? [] }

    // Adds every Claude-* folder in Application Support that no profile uses yet.
    func discoverFolders() {
        guard !isDemo, !isCLI else { return }
        let known = Set(profiles.compactMap(\.dir).map(Folders.canonical) + ignoredFolders)
        let found = Folders.candidates(in: supportDir.path).filter { !known.contains(Folders.canonical($0)) }
        guard !found.isEmpty else { return }
        for dir in found {
            let name = String(URL(fileURLWithPath: dir).lastPathComponent.dropFirst(7))
            profiles.append(Profile(name: name, dir: dir, color: nextColor()))
        }
        save()
    }

    // Renames each closed profile's folder to Claude-<name>. A symlink stays at the old path because
    // Claude writes absolute paths into its data (agent sessions, git config), and old aliases keep working.
    func alignFolders() {
        guard !isDemo, !isCLI, signIn == nil else { return }
        // Read the live processes here rather than trusting `running`, which may not be filled in yet.
        let live = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == claudeBundleID && !$0.isTerminated }
            .compactMap { ProcArgs.of($0.processIdentifier).first { $0.hasPrefix("--user-data-dir=") } }
            .map { Folders.canonical(String($0.dropFirst(16))) })
        var changed = false
        for i in profiles.indices {
            let p = profiles[i]
            guard let dir = p.dir, !live.contains(Folders.canonical(dir)), !isRunning(p), pending[p.id] == nil,
                  !Folders.inUse(dir),
                  let target = Folders.target(for: p.name, current: dir, in: supportDir.path) else { continue }
            let oldCode = p.codeConfigDir
            if Folders.move(dir, to: target) {
                if p.codeDir == nil, let oldCode, FileManager.default.fileExists(atPath: oldCode) {
                    profiles[i].codeDir = oldCode   // its Keychain sign-in is tied to this path
                }
                profiles[i].dir = target
                changed = true
            }
        }
        if changed { save() }
    }

    func setColor(_ p: Profile, _ c: Int) {
        guard let i = profiles.firstIndex(of: p) else { return }
        profiles[i].color = c
        save()
    }

    func move(_ p: Profile, by delta: Int) {
        guard let i = profiles.firstIndex(of: p) else { return }
        let j = i + delta
        guard profiles.indices.contains(j) else { return }
        profiles.swapAt(i, j)
        save()
    }

    private func save() {
        if !isDemo, !isCLI, let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
        updateHotKeys()
        onChange?()
    }
}

// Self-update from GitHub releases. Checks at launch and then once a day, installs in the background,
// and relaunches only while the panel is closed. Claude windows are left alone.
enum UpdateError: Error { case download, invalid, signature, command(String) }

enum Updater {
    static let latestURL = URL(string: "https://api.github.com/repos/QuentinCar0n/multiclaude/releases/latest")!
    nonisolated(unsafe) static var relaunching = false
    nonisolated(unsafe) static var busy = false

    struct Release { let version: String; let zip: URL; let signature: URL }

    static var currentVersion: String { ProcessInfo.processInfo.environment["MULTICLAUDE_FAKE_VERSION"] ?? appVersion }

    @MainActor static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { checkIfDue(force: true) }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { checkIfDue(force: false) }
        }
    }

    @MainActor static func checkIfDue(force: Bool) {
        let d = UserDefaults.standard
        guard Engine.shared.isOn(.autoUpdate), !busy else { return }
        if !force, let last = d.object(forKey: "lastUpdateCheck") as? Date, -last.timeIntervalSinceNow < 86_400 { return }
        d.set(Date(), forKey: "lastUpdateCheck")
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { return }
        busy = true
        Task.detached {
            let installed = try? await updateIfNewer(at: target)
            await MainActor.run {
                busy = false
                if let installed { relaunchWhenIdle(version: installed, app: target) }
            }
        }
    }

    // Returns the version it installed, or nil when the app is already up to date.
    static func updateIfNewer(at target: URL) async throws -> String? {
        guard let r = try await latest(), isNewer(r.version, than: currentVersion) else { return nil }
        try await install(r, at: target)
        return r.version
    }

    static func latest() async throws -> Release? {
        var req = URLRequest(url: latestURL, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MultiClaude/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let name = asset["name"] as? String,
              let sigAsset = assets.first(where: { $0["name"] as? String == name + ".sig" }),
              let url = trusted(asset["browser_download_url"]), let sigURL = trusted(sigAsset["browser_download_url"])
        else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip: url, signature: sigURL)
    }

    static func trusted(_ any: Any?) -> URL? {
        guard let s = any as? String, let url = URL(string: s), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/QuentinCar0n/multiclaude/releases/download/") else { return nil }
        return url
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // Downloads the release zip, checks that it holds MultiClaude at the advertised version with an intact
    // signature, then swaps it in place of the running bundle.
    static func install(_ r: Release, at target: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MultiClaude-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (tmp, resp) = try await URLSession.shared.download(from: r.zip)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: tmp, to: zip)
        // The zip must carry a signature made with the release key; HTTPS alone would trust whoever controls the repo.
        let (sigData, sigResp) = try await URLSession.shared.data(from: r.signature)
        guard (sigResp as? HTTPURLResponse)?.statusCode == 200,
              UpdateSignature.verify(try Data(contentsOf: zip), signatureBase64: String(decoding: sigData, as: UTF8.self))
        else { throw UpdateError.signature }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("MultiClaude.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "me.somalabs.multiclaude",
              info?["CFBundleShortVersionString"] as? String == r.version else { throw UpdateError.invalid }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try fm.replaceItemAt(target, withItemAt: app)
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.command(tool) }
    }

    @MainActor static func relaunchWhenIdle(version: String, app: URL) {
        guard !PanelController.shared.isOpen else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { relaunchWhenIdle(version: version, app: app) }
            return
        }
        UserDefaults.standard.set(version, forKey: "updatedTo")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? sh.run()
        relaunching = true
        NSApp.terminate(nil)
    }
}

// Every Claude instance writes to the same main.log, so new lines since the sign-in started tell when it lands.
// Takes over claude:// links for the length of a sign-in and forwards them to one Claude process.
enum LinkRelay {
    static var claudeApp: URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) ?? URL(fileURLWithPath: "/Applications/Claude.app")
    }

    static func handler() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "claude://claude.ai")!)
    }

    static func isOurs() -> Bool {
        handler()?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    static func take(_ done: @escaping @Sendable (Bool) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "claude") { err in
            done(err == nil && isOurs())
        }
    }

    static func giveBack() {
        guard isOurs() else { return }
        NSWorkspace.shared.setDefaultApplication(at: claudeApp, toOpenURLsWithScheme: "claude") { _ in }
    }

    // The same "open URL" Apple Event macOS would send, aimed at one process instead of the first one found.
    static func send(_ link: String, to pid: pid_t) -> Bool {
        let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(NSAppleEventDescriptor(string: link), forKeyword: keyDirectObject)
        return (try? ev.sendEvent(options: [.noReply], timeout: 5)) != nil
    }
}

enum SignInLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")

    static func size() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func read(from offset: UInt64) -> ([String], UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? offset
        let start = end < offset ? 0 : offset   // the log rotated
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return (String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init), end)
    }

    // Done once the browser sign-in has come back: the claude:// login link was handled, or the
    // account reports logged in after the browser step (a plain "logged in" at launch is not enough,
    // Claude logs it right before bouncing a stale session to /logout).
    static func scan(_ lines: [String], sawBrowser: Bool) -> (sawBrowser: Bool, done: Bool) {
        var saw = sawBrowser
        for l in lines {
            if l.contains("[Auth] Using system browser") { saw = true }
            if l.contains("claudeURLHandler: login") { return (true, true) }
            if saw && l.contains("account active and logged in") { return (saw, true) }
        }
        return (saw, false)
    }
}

enum Folders {
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // Electron keeps a SingletonLock link in the folder while an instance uses it.
    static func inUse(_ dir: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/SingletonLock")) != nil
    }

    static func slug(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // Real Claude-* folders (not the symlinks left by renames, not Claude's own Claude-3p).
    static func candidates(in support: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: support)) ?? []).sorted().compactMap { n in
            guard n.hasPrefix("Claude-"), n != "Claude-3p", n.count > 7 else { return nil }
            let path = support + "/" + n
            let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            return type == .typeDirectory ? path : nil
        }
    }

    // Where a profile's folder should live, or nil when it already does or the name is taken.
    static func target(for name: String, current: String, in support: String) -> String? {
        let slug = self.slug(name)
        guard !slug.isEmpty else { return nil }
        let target = support + "/Claude-" + slug
        let fm = FileManager.default
        guard URL(fileURLWithPath: current).lastPathComponent != "Claude-" + slug,
              URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
                == URL(fileURLWithPath: support).standardizedFileURL.path,
              fm.fileExists(atPath: current), !fm.fileExists(atPath: target),
              (try? fm.destinationOfSymbolicLink(atPath: target)) == nil else { return nil }
        return target
    }

    static func move(_ from: String, to: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.moveItem(atPath: from, toPath: to)
            try fm.createSymbolicLink(atPath: from, withDestinationPath: to)
            return true
        } catch {
            if !fm.fileExists(atPath: from), fm.fileExists(atPath: to) { try? fm.moveItem(atPath: to, toPath: from) }
            return false
        }
    }
}

enum MCP {
    static func configURL(_ p: Profile) -> URL { p.folderURL.appendingPathComponent("claude_desktop_config.json") }

    static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return obj
    }

    static func servers(_ p: Profile) -> [String: Any] {
        ((try? read(configURL(p)))?["mcpServers"] as? [String: Any]) ?? [:]
    }

    // Adds the source servers to the target config; a server with the same name is replaced. Other keys stay.
    static func merge(_ target: [String: Any], adding servers: [String: Any]) -> [String: Any] {
        var out = target
        var current = target["mcpServers"] as? [String: Any] ?? [:]
        for (k, v) in servers { current[k] = v }
        out["mcpServers"] = current
        return out
    }

    @discardableResult
    static func copy(from source: Profile, to target: Profile) throws -> Int {
        let servers = self.servers(source)
        let url = configURL(target)
        let merged = merge(try read(url), adding: servers)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            try fm.copyItem(at: url, to: url.appendingPathExtension("bak-" + f.string(from: Date())))
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return servers.count
    }
}

enum Duplicate {
    // `cp -c` clones on APFS. The destination must not exist yet.
    static func clone(from src: String, to dst: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { return false }
        do { try Updater.run("/bin/cp", ["-cR", src, dst]) } catch {
            try? fm.removeItem(atPath: dst)
            return false
        }
        // Electron's single-instance lock files belong to the source process.
        for lock in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
            try? fm.removeItem(atPath: dst + "/" + lock)
        }
        return true
    }
}

enum UpdateSignature {
    static func sign(_ data: Data, keyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateError.invalid }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw).signature(for: data).base64EncodedString()
    }

    static func verify(_ data: Data, signatureBase64: String, publicKeyBase64: String = updatePublicKey) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

enum Launch {
    // `open -a Claude` brings forward whichever Claude is already running, which may be another account.
    // With any instance up, the default account needs -n to start its own process.
    static func openArgs(dir: String?, anyClaudeRunning: Bool) -> [String] {
        if let dir { return ["-n", "-a", "Claude", "--args", "--user-data-dir=\(dir)"] }
        return anyClaudeRunning ? ["-n", "-a", "Claude"] : ["-a", "Claude"]
    }
}

enum UpdateWatch {
    static func installedVersion() -> String? {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)
            ?? URL(fileURLWithPath: "/Applications/Claude.app")
        // Read the plist directly: Bundle caches its info dictionary and would miss the update.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        return short + "+" + (info?["CFBundleVersion"] as? String ?? "")
    }

    // Profiles to reopen: stopped within 3 minutes of the version change, at least 4 s ago (so the new
    // bundle is in place), and only when Claude relaunched itself. That last check skips the case where
    // an update installs as someone quits Claude on purpose.
    // The default window is a stray when it started right after other profiles stopped for the update,
    // and the default itself did not stop around the update (so it was not open before).
    static func isStrayDefault(defaultLaunch: Date?, defaultStop: Date?, profileStops: [Date], updatedAt: Date) -> Bool {
        guard let launch = defaultLaunch else { return false }
        let near = profileStops.filter { abs($0.timeIntervalSince(updatedAt)) < 180 }
        guard let first = near.min(), let last = near.max() else { return false }
        if let defaultStop, abs(defaultStop.timeIntervalSince(updatedAt)) < 180 { return false }
        return launch >= first.addingTimeInterval(-2) && launch <= last.addingTimeInterval(30)
    }

    static func due(quitAt: [UUID: Date], updatedAt: Date, relaunched: Bool, now: Date) -> Set<UUID> {
        guard relaunched else { return [] }
        return Set(quitAt.filter { abs($0.value.timeIntervalSince(updatedAt)) < 180 && now.timeIntervalSince($0.value) >= 4 }.keys)
    }
}

// Reads a process's argv through sysctl, so no `ps` has to run.
enum ProcArgs {
    static func of(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // executable path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

// Global shortcuts through Carbon, which needs no Accessibility permission.
@MainActor
enum HotKey {
    struct Binding {
        let key: Int
        let mods: Int
        let action: () -> Void
    }

    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static var refs: [EventHotKeyRef] = []
    static var actions: [UInt32: () -> Void] = [:]
    static var installed = false

    static func register(_ list: [Binding]) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        if !installed && !list.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                MainActor.assumeIsolated { HotKey.actions[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        for (i, b) in list.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D43_4C44), id: UInt32(i + 1))
            if RegisterEventHotKey(UInt32(b.key), UInt32(b.mods), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = b.action
            }
        }
    }
}

// MARK: - App icon (drawn, so the bundle needs no image files)

enum AppIcon {
    static func image(_ side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let inset = r.width * 0.1
            let tile = r.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = r.width * 0.025
            shadow.shadowOffset = NSSize(width: 0, height: -r.width * 0.01)
            shadow.set()
            NSColor.claude.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.58, blue: 0.45, alpha: 1),
                                NSColor(srgbRed: 0.78, green: 0.38, blue: 0.26, alpha: 1)])?.draw(in: path, angle: -90)
            let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = sym.size
                sym.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    // build.sh calls `MultiClaude --export-iconset <dir>` to make the .icns.
    static func exportIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
        }
    }
}

// MARK: - Panel views

struct HoverBackground: ViewModifier {
    @State private var hover = false
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    @Binding var open: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }
    }
}

// Round 24 pt badge, filled orange when on, like Cocaine's chips.
struct Badge<Label: View>: View {
    let on: Bool
    var tint: Color = .claude
    var offTint: Color = .primary
    @ViewBuilder let label: Label
    var body: some View {
        label
            .foregroundStyle(on ? Color.white : offTint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(on ? tint : Color.primary.opacity(0.12)))
    }
}

struct NameField: View {
    @State var text: String
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onExitCommand(perform: onCancel)
            .onAppear {
                NSApp.activate()
                DispatchQueue.main.async { focused = true }
            }
    }
}

struct ProfileRow: View {
    let profile: Profile
    @ObservedObject var engine = Engine.shared
    @Binding var editing: UUID?
    @State private var hover = false

    var body: some View {
        let on = engine.isRunning(profile)
        HStack(spacing: 9) {
            Badge(on: on, tint: profile.tint, offTint: profile.tint) {
                if engine.isStarting(profile) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(profile.initial).font(.system(size: 12, weight: .bold))
                }
            }
            if editing == profile.id {
                NameField(text: profile.name, placeholder: "Profile name",
                          onCommit: { engine.rename(profile, to: $0); editing = nil },
                          onCancel: { editing = nil })
            } else {
                Text(profile.name).font(.system(size: 13)).foregroundStyle(.primary.opacity(on ? 1 : 0.75))
                if profile.isDefault {
                    Text("Default").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let hint = engine.shortcutHint(for: profile) {
                    Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if on && hover {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
                    .onTapGesture { engine.quit(profile) }
                    .help("Quit \(profile.name)")
            } else if on {
                Text(engine.frontID == profile.id ? "Active" : "Running").font(.system(size: 10)).foregroundStyle(profile.tint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(HoverBackground(radius: 8))
        .onHover { hover = $0 }
        .onTapGesture {
            guard editing != profile.id else { return }
            engine.open(profile)
            if !on { PanelController.shared.close() }
        }
        .contextMenu {
            Button(on ? "Show \(profile.name)" : "Open \(profile.name)") { engine.open(profile) }
            if on { Button("Quit \(profile.name)") { engine.quit(profile) } }
            Button("Sign In to \(profile.name)…") { Dialogs.signIn(profile) }
            Button("Open Claude Code in Terminal") { engine.openClaudeCode(profile) }
            Toggle("Open When MultiClaude Starts", isOn: Binding(get: { profile.openAtLaunch == true },
                                                                 set: { engine.setOpenAtLaunch(profile, $0) }))
            Divider()
            Button("Rename…") { editing = profile.id }
            Menu("Color") {
                ForEach(Palette.colors.indices, id: \.self) { i in
                    Toggle(Palette.colors[i].name, isOn: Binding(get: { (profile.color ?? 0) == i },
                                                                 set: { _ in engine.setColor(profile, i) }))
                }
            }
            Button("Move Up") { engine.move(profile, by: -1) }
            Button("Move Down") { engine.move(profile, by: 1) }
            Divider()
            Button("Show Data Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.folderURL]) }
            Button("Copy Shell Alias") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(profile.shellAlias, forType: .string)
            }
            Button("Copy Claude Code Alias") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(profile.codeAlias, forType: .string)
            }
            Divider()
            Menu("Copy MCP Servers From") {
                let sources = engine.profiles.filter { $0.id != profile.id }.map { ($0, MCP.servers($0).count) }.filter { $0.1 > 0 }
                if sources.isEmpty {
                    Text("No other profile has MCP servers")
                }
                ForEach(sources, id: \.0.id) { src, n in
                    Button("\(src.name) (\(n))") { Dialogs.copyMCP(from: src, to: profile) }
                }
            }
            Button("Duplicate as New Profile…") { Dialogs.duplicate(profile) }
            if !profile.isDefault {
                Divider()
                Button("Remove from List") { engine.remove(profile) }
            }
        }
    }
}

// Confirmations for actions that quit a window or write into a profile's folder.
@MainActor
enum Dialogs {
    static func alert(_ title: String, _ text: String, buttons: [String], field: String? = nil) -> (Int, String) {
        PanelController.shared.close()
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        var input: NSTextField?
        if let field {
            let f = NSTextField(string: field)
            f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            a.accessoryView = f
            a.window.initialFirstResponder = f
            input = f
        }
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return (r, input?.stringValue ?? "")
    }

    static func copyMCP(from src: Profile, to dst: Profile) {
        let e = Engine.shared
        let n = MCP.servers(src).count
        let running = e.isRunning(dst)
        let buttons = running ? ["Copy and Reopen \(dst.name)", "Copy", "Cancel"] : ["Copy", "Cancel"]
        let (choice, _) = alert("Copy \(n) MCP server\(n == 1 ? "" : "s") from \(src.name) to \(dst.name)?",
                                "Servers with the same name in \(dst.name) are replaced. \(dst.name)'s current config is backed up next to it first. Keys and tokens in the server settings are copied too.",
                                buttons: buttons)
        if choice == buttons.count - 1 { return }
        e.copyMCPServers(from: src, to: dst, restart: running && choice == 0)
    }

    static func signIn(_ p: Profile) {
        Engine.shared.beginSignIn(p)
    }

    static func duplicate(_ src: Profile) {
        let e = Engine.shared
        let running = e.isRunning(src)
        let text = "The new profile gets a copy of \(src.name)'s data: its sign-in, chats and settings. "
            + "The copy is instant and uses no extra disk space until the two change."
            + (running ? " \(src.name) has to quit while it's copied, then it reopens." : "")
        let (choice, name) = alert("Duplicate \(src.name)", text,
                                   buttons: [running ? "Quit \(src.name) and Duplicate" : "Duplicate", "Cancel"],
                                   field: src.name + " copy")
        guard choice == 0 else { return }
        guard e.newProfile(named: name) != nil else {
            _ = alert("Pick another name", "\"\(name)\" is empty or already used by a profile or folder.", buttons: ["OK"])
            return
        }
        e.duplicate(src, as: name)
    }
}

struct NewProfileRow: View {
    @ObservedObject var engine = Engine.shared
    @State private var adding = false

    var body: some View {
        HStack(spacing: 9) {
            Badge(on: false) { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
            if adding {
                NameField(text: "", placeholder: "Profile name, then Return",
                          onCommit: { if engine.add(name: $0) { adding = false } },
                          onCancel: { adding = false })
            } else {
                Text("New Profile").font(.system(size: 13)).foregroundStyle(.primary.opacity(0.75))
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(HoverBackground(radius: 8))
        .onTapGesture { adding = true }
    }
}

struct SettingRow: View {
    let setting: Setting
    @ObservedObject var engine = Engine.shared

    var body: some View {
        let on = engine.isOn(setting)
        HStack(spacing: 9) {
            Badge(on: on) { Image(systemName: setting.symbol).font(.system(size: 12, weight: .medium)) }
            Text(setting.title).font(.system(size: 13)).foregroundStyle(.primary.opacity(on ? 1 : 0.75))
            Spacer(minLength: 4)
            if let hint = setting.hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(HoverBackground(radius: 8))
        .onTapGesture { engine.toggle(setting) }
    }
}

struct PlainRow: View {
    let title: String
    let action: () -> Void
    var body: some View {
        HStack { Text(title).font(.system(size: 13)); Spacer() }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .modifier(HoverBackground(radius: 6))
            .onTapGesture(perform: action)
    }
}

struct MenuView: View {
    @ObservedObject var engine = Engine.shared
    @AppStorage("profilesOpen") private var profilesOpen = true
    @AppStorage("settingsOpen") private var settingsOpen = false
    @State private var editing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The switch reads "any profile running": on opens every profile, off quits them all.
            HStack {
                Text("MultiClaude").font(.system(size: 13, weight: .bold))
                Spacer()
                Toggle("", isOn: Binding(get: { engine.runningCount > 0 },
                                         set: { $0 ? engine.openAll() : engine.quitAll() }))
                    .toggleStyle(.switch).controlSize(.regular).labelsHidden().tint(.claude)
                    .help("On opens every profile, off quits them all")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if let notice = engine.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: engine.signIn != nil ? "person.badge.key" : notice.hasPrefix("MultiClaude") ? "arrow.down.circle" : "arrow.clockwise")
                        .foregroundStyle(Color.claude)
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if engine.signIn != nil {
                        Text("Done").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(Color.claude))
                            .onTapGesture { engine.finishSignIn(cancelled: false) }
                            .help("Reopen the other accounts now")
                    } else {
                        Image(systemName: "xmark").foregroundStyle(.secondary).onTapGesture { engine.dismissNotice() }
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 14)
            SectionHeader(title: "Profiles (\(engine.profiles.count))",
                          trailing: engine.runningCount > 0 ? "\(engine.runningCount) running" : "None running",
                          open: $profilesOpen)
            if profilesOpen {
                VStack(spacing: 0) {
                    ForEach(engine.profiles) { ProfileRow(profile: $0, editing: $editing) }
                    NewProfileRow()
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
            }

            Divider().padding(.horizontal, 14)
            SectionHeader(title: "Settings", open: $settingsOpen)
            if settingsOpen {
                VStack(spacing: 0) {
                    ForEach(Setting.allCases) { SettingRow(setting: $0) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
            }

            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                PlainRow(title: "About") { PanelController.shared.close(); AboutWindow.show() }
                PlainRow(title: "Quit") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            DispatchQueue.main.async { PanelController.shared.resize(to: size) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Panel window

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    static let shared = PanelController()

    private var panel: KeyPanel?
    private var host: NSHostingView<MenuView>?
    private var monitor: Any?
    private var anchor = NSPoint.zero   // top-left corner in screen coordinates

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(below button: NSStatusBarButton) { isOpen ? close() : open(below: button) }

    func open(below button: NSStatusBarButton) {
        let p = panel ?? makePanel()
        panel = p
        guard let win = button.window, let screen = win.screen else { return }
        let b = win.convertToScreen(button.convert(button.bounds, to: nil))
        let width: CGFloat = 300
        let x = min(max(b.minX - 12, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - width - 6)
        anchor = NSPoint(x: x, y: b.minY - 6)
        resize(to: host?.fittingSize ?? NSSize(width: width, height: 300))
        Engine.shared.discoverFolders()
        Engine.shared.refresh()
        p.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { PanelController.shared.close() }
        }
    }

    func close() {
        // Preview runs keep the panel up for screenshots while someone uses the Mac.
        if isPreview && panel?.isVisible == true { return }
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func resize(to size: CGSize) {
        guard let panel, size.height > 0 else { return }
        panel.setFrame(NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                         backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Host fills the panel and never sizes it; MenuView reports its height and resize(to:) moves the frame.
        let host = NSHostingView(rootView: MenuView())
        host.sizingOptions = []
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        self.host = host
        p.contentView = fx
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            // A context menu takes key for a moment; only close once the menu is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated {
                    if NSApp.keyWindow == nil || NSApp.keyWindow is AboutWindowType { PanelController.shared.close() }
                }
            }
        }
        return p
    }
}

// MARK: - About window

final class AboutWindowType: NSWindow {}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 150, height: 42)
            .background(Capsule().fill(LinearGradient(colors: [Color(red: 0.93, green: 0.55, blue: 0.42), Color(red: 0.80, green: 0.40, blue: 0.28)],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct AboutView: View {
    var body: some View {
        HStack(spacing: 34) {
            Image(nsImage: AppIcon.image(512)).resizable().frame(width: 170, height: 170)
            VStack(alignment: .leading, spacing: 4) {
                Text("MultiClaude").font(.system(size: 32, weight: .semibold))
                Text("Version \(appVersion)").font(.system(size: 13))
                Text("MultiClaude is made with care by Soma Labs, a small health tech studio based in Palo Alto, California.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                HStack(spacing: 18) {
                    Button("Support") { NSWorkspace.shared.open(supportURL) }
                    Button("Website") { NSWorkspace.shared.open(websiteURL) }
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 18)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 44)
        .frame(width: 620, height: 330)
        .overlay(alignment: .bottom) {
            Text("Copyright © 2026 Soma Labs. Licensed under Apache 2.0.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.bottom, 22)
        }
    }
}

@MainActor
enum AboutWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = AboutWindowType(contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
                                    styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            let host = NSHostingView(rootView: AboutView())
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            w.contentView = fx
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleLink(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let link = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        Engine.shared.relay(link)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // A crash during a sign-in would leave MultiClaude as the claude:// handler; hand the links back.
        LinkRelay.giveBack()
        switch ProcessInfo.processInfo.environment["MULTICLAUDE_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
        }
        let engine = Engine.shared
        engine.onChange = { [weak self] in self?.refreshIcon() }
        engine.onPanelHotKey = { [weak self] in
            if let b = self?.item.button { PanelController.shared.toggle(below: b) }
        }
        engine.boot()
        refreshIcon()
        // Preview hook for screenshots: MULTICLAUDE_PREVIEW=panel|settings|about
        switch ProcessInfo.processInfo.environment["MULTICLAUDE_PREVIEW"] {
        case "panel", "settings":
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["MULTICLAUDE_PREVIEW"] == "settings", forKey: "settingsOpen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let b = self?.item.button { PanelController.shared.open(below: b) }
            }
        case "signin":   // MULTICLAUDE_SIGNIN_TARGET=<profile name> starts Sign In for that profile, for live tests
            let name = ProcessInfo.processInfo.environment["MULTICLAUDE_SIGNIN_TARGET"] ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let p = Engine.shared.profiles.first(where: { $0.name == name }) { Engine.shared.beginSignIn(p) }
            }
        case "about": AboutWindow.show()
        default: break
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        LinkRelay.giveBack()
        if Engine.shared.isOn(.quitWithApp) && !Updater.relaunching { Engine.shared.quitAll() }
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        PanelController.shared.toggle(below: button)
    }

    private func refreshIcon() {
        guard let b = item.button else { return }
        let engine = Engine.shared
        let count = engine.runningCount
        let img = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "MultiClaude")
        // While a Claude window is in front, the menu bar names its account in the profile's color.
        let front = engine.isOn(.showActive) ? engine.profiles.first { $0.id == engine.frontID } : nil
        if let front {
            b.image = img?.withSymbolConfiguration(.init(paletteColors: [front.nsTint]))
            b.image?.isTemplate = false
        } else if count > 0 && engine.isOn(.coloredIcon) {
            b.image = img?.withSymbolConfiguration(.init(paletteColors: [.claude]))
            b.image?.isTemplate = false
        } else {
            b.image = img
            b.image?.isTemplate = true
        }
        if let front {
            b.title = " " + front.name
        } else {
            b.title = count > 0 && engine.isOn(.showCount) ? " \(count)" : ""
        }
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }
}

let args = CommandLine.arguments
if args.count == 2, args[1] == "--list" {
    // Prints each profile and whether it runs, for a quick check from the terminal.
    MainActor.assumeIsolated {
        let e = Engine.shared
        e.refresh()
        for p in e.profiles {
            let state = e.frontID == p.id ? "active" : e.isRunning(p) ? "running" : "-"
            print("\(e.isRunning(p) ? "●" : "○") \(p.name)\t\(state)\t\(Palette.colors[(p.color ?? 0) % Palette.colors.count].name)\t\(p.dir ?? "(default)")")
        }
    }
    exit(0)
}
if args.count == 2, args[1] == "--selftest-update" {
    // Checks which profiles get reopened around a Claude update.
    let a = UUID(), b = UUID(), c = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let quitAt = [a: t0.addingTimeInterval(-2), b: t0.addingTimeInterval(-400), c: t0.addingTimeInterval(20)]
    let cases: [(String, Bool, Date, Set<UUID>)] = [
        ("relaunched, 30 s later", true, t0.addingTimeInterval(30), [a, c]),
        ("relaunched, c quit 1 s ago", true, t0.addingTimeInterval(21), [a]),
        ("no relaunch (quit on purpose)", false, t0.addingTimeInterval(30), []),
    ]
    var ok = true
    for (name, relaunched, now, want) in cases {
        let got = UpdateWatch.due(quitAt: quitAt, updatedAt: t0, relaunched: relaunched, now: now)
        print(got == want ? "PASS" : "FAIL", name)
        ok = ok && got == want
    }
    let stops = [t0.addingTimeInterval(-3), t0.addingTimeInterval(-1)]
    let strays: [(String, Date?, Date?, [Date], Bool)] = [
        ("stray: default starts right after profiles stop", t0.addingTimeInterval(2), nil, stops, true),
        ("kept: default also stopped for the update", t0.addingTimeInterval(2), t0.addingTimeInterval(-2), stops, false),
        ("kept: default opened a minute later by hand", t0.addingTimeInterval(60), nil, stops, false),
        ("kept: default running since before the update", t0.addingTimeInterval(-3600), nil, stops, false),
        ("kept: no profile stopped around the update", t0.addingTimeInterval(2), nil, [], false),
    ]
    for (name, launch, dstop, ps, want) in strays {
        let got = UpdateWatch.isStrayDefault(defaultLaunch: launch, defaultStop: dstop, profileStops: ps, updatedAt: t0)
        print(got == want ? "PASS" : "FAIL", name)
        ok = ok && got == want
    }
    let opens: [(String, String?, Bool, [String])] = [
        ("default, nothing running", nil, false, ["-a", "Claude"]),
        ("default, another account running", nil, true, ["-n", "-a", "Claude"]),
        ("profile", "/x/Claude-Work", true, ["-n", "-a", "Claude", "--args", "--user-data-dir=/x/Claude-Work"]),
    ]
    for (name, dir, any, want) in opens {
        let got = Launch.openArgs(dir: dir, anyClaudeRunning: any)
        print(got == want ? "PASS" : "FAIL", name)
        ok = ok && got == want
    }
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--check-update" || args[1] == "--update-now" {
    // --check-update prints the latest release; --update-now also installs it over this app bundle.
    let install = args[1] == "--update-now"
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached {
        do {
            guard let r = try await Updater.latest() else { print("no release found"); code = 1; sem.signal(); return }
            let newer = Updater.isNewer(r.version, than: Updater.currentVersion)
            print("installed \(Updater.currentVersion), latest \(r.version)\(newer ? ", update available" : ", up to date")")
            if install && newer {
                try await Updater.install(r, at: Bundle.main.bundleURL)
                print("installed \(r.version) at \(Bundle.main.bundleURL.path)")
            }
        } catch { print("failed: \(error)"); code = 1 }
        sem.signal()
    }
    sem.wait()
    exit(code)
}
if args.count == 3, args[1] == "--sign-update" {
    // CI: prints the base64 signature of a release zip; the key comes from MULTICLAUDE_SIGNING_KEY.
    guard let key = ProcessInfo.processInfo.environment["MULTICLAUDE_SIGNING_KEY"], !key.isEmpty,
          let data = FileManager.default.contents(atPath: args[2]), let sig = try? UpdateSignature.sign(data, keyBase64: key)
    else { FileHandle.standardError.write(Data("signing failed\n".utf8)); exit(1) }
    print(sig)
    exit(0)
}
if args.count == 4, args[1] == "--verify-update" {
    let data = FileManager.default.contents(atPath: args[2]) ?? Data()
    let sig = (try? String(contentsOfFile: args[3], encoding: .utf8)) ?? ""
    let ok = UpdateSignature.verify(data, signatureBase64: sig)
    print(ok ? "valid" : "INVALID")
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-profiles" {
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); ok = ok && cond }
    let target: [String: Any] = ["preferences": ["x": 1], "mcpServers": ["a": ["command": "old"], "keep": ["command": "k"]]]
    let merged = MCP.merge(target, adding: ["a": ["command": "new"], "b": ["command": "b"]])
    let m = merged["mcpServers"] as? [String: [String: String]] ?? [:]
    check("merge replaces same name", m["a"]?["command"] == "new")
    check("merge adds new server", m["b"] != nil)
    check("merge keeps other servers", m["keep"] != nil)
    check("merge keeps other keys", merged["preferences"] != nil)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-clone-\(UUID().uuidString)")
    let src = tmp.appendingPathComponent("Claude"), dst = tmp.appendingPathComponent("Claude-Copy")
    try? FileManager.default.createDirectory(at: src.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
    try? Data("chats".utf8).write(to: src.appendingPathComponent("Local Storage/db"))
    try? FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-123")
    check("clone succeeds", Duplicate.clone(from: src.path, to: dst.path))
    check("clone copies data", (try? String(contentsOf: dst.appendingPathComponent("Local Storage/db"), encoding: .utf8)) == "chats")
    check("clone drops lock", (try? FileManager.default.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("SingletonLock").path)) == nil)
    check("clone refuses existing destination", !Duplicate.clone(from: src.path, to: dst.path))
    let pa = Profile(name: "A", dir: tmp.appendingPathComponent("Claude-A").path)
    let pb = Profile(name: "B", dir: tmp.appendingPathComponent("Claude-B").path)
    try? FileManager.default.createDirectory(atPath: pa.dir!, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: pb.dir!, withIntermediateDirectories: true)
    try? Data(#"{"mcpServers":{"fs":{"command":"npx","args":["server-fs","/tmp"]}}}"#.utf8).write(to: MCP.configURL(pa))
    try? Data(#"{"preferences":{"x":1}}"#.utf8).write(to: MCP.configURL(pb))
    let copied = (try? MCP.copy(from: pa, to: pb)) ?? -1
    check("copy reports 1 server", copied == 1)
    check("copy writes server into target", MCP.servers(pb)["fs"] != nil)
    check("copy keeps target preferences", ((try? MCP.read(MCP.configURL(pb)))?["preferences"]) != nil)
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: pb.dir!))?.filter { $0.contains(".bak-") } ?? []
    check("copy leaves a backup", backups.count == 1)
    try? Data("not json".utf8).write(to: MCP.configURL(pb))
    check("copy refuses a broken target file", (try? MCP.copy(from: pa, to: pb)) == nil)
    let sup = tmp.appendingPathComponent("Support").path
    try? FileManager.default.createDirectory(atPath: sup + "/Claude-Work/Local Storage", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: sup + "/Claude-3p", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: sup + "/Claude-Moonsun", withIntermediateDirectories: true)
    check("candidates skip Claude-3p", Folders.candidates(in: sup).map { URL(fileURLWithPath: $0).lastPathComponent } == ["Claude-Moonsun", "Claude-Work"])
    let tgt = Folders.target(for: "Augura", current: sup + "/Claude-Work", in: sup)
    check("target follows the name", tgt == sup + "/Claude-Augura")
    check("no target when already aligned", Folders.target(for: "Moonsun", current: sup + "/Claude-Moonsun", in: sup) == nil)
    check("no target onto another profile's folder", Folders.target(for: "Moonsun", current: sup + "/Claude-Work", in: sup) == nil)
    check("move succeeds", Folders.move(sup + "/Claude-Work", to: sup + "/Claude-Augura"))
    check("old path is a symlink to the new one", (try? FileManager.default.destinationOfSymbolicLink(atPath: sup + "/Claude-Work")) == sup + "/Claude-Augura")
    check("candidates skip the symlink", Folders.candidates(in: sup).map { URL(fileURLWithPath: $0).lastPathComponent } == ["Claude-Augura", "Claude-Moonsun"])
    check("canonical resolves the old path", Folders.canonical(sup + "/Claude-Work") == Folders.canonical(sup + "/Claude-Augura"))
    check("no target onto a leftover symlink", Folders.target(for: "Work", current: sup + "/Claude-Augura", in: sup) == nil)
    try? FileManager.default.removeItem(at: tmp)
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-signin" {
    // Lines taken from Claude's main.log on 2026-10-10.
    let launchBounce = ["[info] claude.ai account active and logged in", "[info] [account] Navigated to /logout, synthesizing logged-out"]
    let browser = ["[info] [Auth] Using system browser for: /login/app-google-auth"]
    let back = ["[info] claudeURLHandler: login loadURL superseded (teardown race)"]
    let loggedIn = ["[info] claude.ai account active and logged in"]
    let cases: [(String, [String], Bool, Bool)] = [
        ("launch 'logged in' before /logout is not done", launchBounce, false, false),
        ("browser step alone is not done", browser, false, false),
        ("login link handled is done", back, false, true),
        ("logged in after browser step is done", browser + loggedIn, false, true),
        ("browser seen in an earlier read, logged in now", loggedIn, true, true),
    ]
    var ok = true
    for (name, lines, saw, want) in cases {
        let got = SignInLog.scan(lines, sawBrowser: saw).done
        print(got == want ? "PASS" : "FAIL", name)
        ok = ok && got == want
    }
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-version" {
    let cases = [("1.2", "1.1", true), ("1.10", "1.9", true), ("1.2", "1.2", false), ("1.2", "1.2.1", false), ("2.0", "1.9.9", true)]
    var ok = true
    for (a, b, want) in cases {
        let got = Updater.isNewer(a, than: b)
        print(got == want ? "PASS" : "FAIL", a, ">", b, got)
        ok = ok && got == want
    }
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--unregister-login" {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
if args.count == 3, args[1] == "--export-iconset" {
    MainActor.assumeIsolated { AppIcon.exportIconset(to: args[2]) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
