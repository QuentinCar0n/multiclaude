// MultiClaude: menu bar manager for several Claude desktop instances, one per profile.
// Each profile is a separate --user-data-dir, so each one keeps its own account and chats.
// Same panel as Cocaine (header switch, collapsible sections, round icons), in Claude orange.
import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
let websiteURL = URL(string: "https://somalabs.me")!
let supportURL = URL(string: "mailto:quentin@somalabs.me?subject=MultiClaude")!
let claudeBundleID = "com.anthropic.claudefordesktop"
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let isPreview = ProcessInfo.processInfo.environment["MULTICLAUDE_PREVIEW"] != nil
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

    func dismissNotice() { notice = nil }
    func show(notice text: String) { notice = text }

    // MARK: running instances

    // Matches each Claude process to a profile through its --user-data-dir argument.
    func refresh() {
        guard !isDemo else { return }
        var found: [UUID: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleID && !app.isTerminated {
            let dir = ProcArgs.of(app.processIdentifier)
                .first { $0.hasPrefix("--user-data-dir=") }
                .map { URL(fileURLWithPath: String($0.dropFirst(16))).standardizedFileURL.path }
            if let p = profiles.first(where: { $0.dir.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == dir }) {
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
        let name = raw.trimmingCharacters(in: .whitespaces)
        let slug = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !slug.isEmpty, !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            NSSound.beep(); return false
        }
        let dir = supportDir.appendingPathComponent("Claude-\(slug)").path
        profiles.append(Profile(name: name, dir: dir, color: nextColor()))
        save()
        return true
    }

    func rename(_ p: Profile, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = profiles.firstIndex(of: p) else { return }
        profiles[i].name = name   // the data folder keeps its path, so sign-ins survive a rename
        save()
    }

    // Takes the profile off the list. Its data folder stays on disk.
    func remove(_ p: Profile) {
        guard !p.isDefault else { return }
        profiles.removeAll { $0.id == p.id }
        save()
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
        if !isDemo, let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
        updateHotKeys()
        onChange?()
    }
}

// Self-update from GitHub releases. Checks at launch and then once a day, installs in the background,
// and relaunches only while the panel is closed. Claude windows are left alone.
enum UpdateError: Error { case download, invalid, command(String) }

enum Updater {
    static let latestURL = URL(string: "https://api.github.com/repos/QuentinCar0n/multiclaude/releases/latest")!
    nonisolated(unsafe) static var relaunching = false
    nonisolated(unsafe) static var busy = false

    struct Release { let version: String; let zip: URL }

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
              let link = asset["browser_download_url"] as? String, let url = URL(string: link),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/QuentinCar0n/multiclaude/releases/download/")
        else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip: url)
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
            Button("Open Claude Code in Terminal") { engine.openClaudeCode(profile) }
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
            if !profile.isDefault {
                Divider()
                Button("Remove from List") { engine.remove(profile) }
            }
        }
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
                    Image(systemName: notice.hasPrefix("MultiClaude") ? "arrow.down.circle" : "arrow.clockwise")
                        .foregroundStyle(Color.claude)
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "xmark").foregroundStyle(.secondary).onTapGesture { engine.dismissNotice() }
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

    func applicationDidFinishLaunching(_ n: Notification) {
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
        case "about": AboutWindow.show()
        default: break
        }
    }

    func applicationWillTerminate(_ n: Notification) {
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
