// MultiClaude: menu bar manager for several Claude desktop instances, one per profile.
// Each profile is a separate --user-data-dir, so each one keeps its own account and chats.
// Same panel as Cocaine (header switch, collapsible sections, round icons), in Claude orange.
import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import CryptoKit
import IOKit.pwr_mgt
import IOKit.ps
import UserNotifications
import CommonCrypto
import SQLite3
import CoreAudio
import Darwin

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
let websiteURL = URL(string: "https://somalabs.me")!
let supportURL = URL(string: "mailto:quentin@somalabs.me?subject=MultiClaude")!
let claudeBundleID = "com.anthropic.claudefordesktop"

// Claude.app itself. MultiClaude's per-profile copies share its bundle id, so never look it up by id alone.
func realClaudeApp() -> URL {
    let standard = URL(fileURLWithPath: "/Applications/Claude.app")
    if FileManager.default.fileExists(atPath: standard.path) { return standard }
    let ours = Runtimes.folder.standardizedFileURL.path
    return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: claudeBundleID)
        .first { !$0.standardizedFileURL.path.hasPrefix(ours) } ?? standard
}
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let isPreview = ProcessInfo.processInfo.environment["MULTICLAUDE_PREVIEW"] != nil
// Releases are signed in CI with the matching private key (repo secret UPDATE_SIGNING_KEY).
let updatePublicKey = "ovYVjB5Bst53pHaSwbk7KKX+JRAqv7zuponiduhHa+w="
// Command-line modes (--list, --selftest-*, ...) only read; the menu bar app owns the profile list.
// Only a --flag counts: macOS and Xcode can pass other arguments (-NSDocumentRevisionsDebugMode ...) to the app.
let isCLI = CommandLine.arguments.count > 1 && CommandLine.arguments[1].hasPrefix("--")
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
    var appName: String?   // name of this profile's Dock app; nil = "Claude <name>"

    init(id: UUID = UUID(), name: String, dir: String?, color: Int? = nil, openAtLaunch: Bool? = nil,
         codeDir: String? = nil, appName: String? = nil) {
        (self.id, self.name, self.dir, self.color) = (id, name, dir, color)
        (self.openAtLaunch, self.codeDir, self.appName) = (openAtLaunch, codeDir, appName)
    }

    // Lenient, so a list saved by another version still loads: a missing field falls back instead of
    // failing the whole list (which would lose every profile's id, color and settings).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        dir = try c.decodeIfPresent(String.self, forKey: .dir)   // a wrong dir would make it the default profile: fail
        name = (try? c.decodeIfPresent(String.self, forKey: .name))
            ?? dir.map { String(URL(fileURLWithPath: $0).lastPathComponent.replacingOccurrences(of: "Claude-", with: "")) } ?? "Claude"
        color = try? c.decodeIfPresent(Int.self, forKey: .color)
        openAtLaunch = try? c.decodeIfPresent(Bool.self, forKey: .openAtLaunch)
        codeDir = try? c.decodeIfPresent(String.self, forKey: .codeDir)
        appName = try? c.decodeIfPresent(String.self, forKey: .appName)
    }

    var isDefault: Bool { dir == nil }
    var initial: String { String(name.prefix(1)).uppercased() }
    var dockAppName: String {
        // Never plain "Claude": an app of that name could be taken for Claude itself.
        let custom = appName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !custom.isEmpty, custom.lowercased() != "claude" { return custom }
        if name.lowercased() == "claude" { return isDefault ? "Claude Default" : "Claude Profile" }
        return name.lowercased().hasPrefix("claude") ? name : "Claude \(name)"
    }
    var folderURL: URL { dir.map { URL(fileURLWithPath: $0) } ?? supportDir.appendingPathComponent("Claude") }
    var tint: Color { Color(nsColor: nsTint) }
    var nsTint: NSColor { Palette.colors[(color ?? 0) % Palette.colors.count].color }
    private var key: String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    private var aliasKey: String { key.isEmpty ? "claude" + id.uuidString.prefix(4).lowercased() : key }

    var shellAlias: String {
        guard let dir else { return "alias \(aliasKey)='open -a \"Claude\"'" }
        // The readable form when the path has nothing a shell would expand or that would end the quotes.
        if !dir.contains(where: { "'\"$`\\".contains($0) }) {
            return "alias \(aliasKey)='open -n -a \"Claude\" --args --user-data-dir=\"\(dir)\"'"
        }
        return "alias \(aliasKey)=" + shellQuote("open -n -a Claude --args " + shellQuote("--user-data-dir=" + dir))
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
        guard let codeConfigDir else { return "alias claude-\(aliasKey)='claude'" }
        if !codeConfigDir.contains(where: { "'\"$`\\".contains($0) }) {
            return "alias claude-\(aliasKey)='CLAUDE_CONFIG_DIR=\"\(codeConfigDir)\" claude'"
        }
        return "alias claude-\(aliasKey)=" + shellQuote("CLAUDE_CONFIG_DIR=" + shellQuote(codeConfigDir) + " claude")
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
        let re = try! NSRegularExpression(pattern: #"(?m)^\s*alias\s+(\w+)=['"]open -n -a "?Claude"? --args --user-data-dir="?([^"']+)"?['"]"#)
        for m in re.matches(in: rc, range: NSRange(rc.startIndex..., in: rc)) {
            guard let n = Range(m.range(at: 1), in: rc), let d = Range(m.range(at: 2), in: rc) else { continue }
            let dir = (String(rc[d]).replacingOccurrences(of: "${HOME}", with: home)
                .replacingOccurrences(of: "$HOME", with: home) as NSString).expandingTildeInPath
            guard dir.hasPrefix("/"), !seen.contains(dir) else { continue }
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
    case manageClaude, launchAtLogin, autoUpdate, routeSignIn, reopenAfterUpdate, shortcut, profileShortcuts, showActive, showCount, coloredIcon, dockApps, quitWithApp
    case trackUsage, archiveCode, chatLimits
    case reverseMouse, reverseTrackpad

    static let onByDefault: Set<Setting> = [.manageClaude, .trackUsage, .archiveCode, .autoUpdate, .routeSignIn, .reopenAfterUpdate, .showActive, .showCount]
    // Settings that only mean something while MultiClaude manages Claude accounts; hidden when it doesn't.
    static let claudeOnly: Set<Setting> = [.routeSignIn, .reopenAfterUpdate, .profileShortcuts, .showActive, .showCount, .dockApps, .quitWithApp,
                                         .trackUsage, .archiveCode, .chatLimits]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manageClaude: "Manage Claude Accounts"
        case .launchAtLogin: "Launch at Login"
        case .autoUpdate: "Update MultiClaude Automatically"
        case .routeSignIn: "Sign In in Each Account's Window"
        case .reopenAfterUpdate: "Reopen After Claude Updates"
        case .shortcut: "Keyboard Shortcut"
        case .profileShortcuts: "Profile Shortcuts"
        case .showActive: "Show Active Account in Menu Bar"
        case .showCount: "Show Count in Menu Bar"
        case .coloredIcon: "Colored Menu Bar Icon"
        case .dockApps: "App for Each Profile"
        case .quitWithApp: "Quit Profiles with MultiClaude"
        case .trackUsage: "Track Token Usage"
        case .archiveCode: "Keep Claude Code Conversations"
        case .chatLimits: "Show Chat Limits"
        case .reverseMouse: "Reverse Mouse Scroll"
        case .reverseTrackpad: "Reverse Trackpad Scroll"
        }
    }

    var symbol: String {
        switch self {
        case .manageClaude: "person.2"
        case .launchAtLogin: "power"
        case .autoUpdate: "arrow.down.circle"
        case .routeSignIn: "person.badge.key"
        case .reopenAfterUpdate: "arrow.clockwise"
        case .shortcut: "command"
        case .profileShortcuts: "keyboard"
        case .showActive: "menubar.rectangle"
        case .showCount: "number"
        case .coloredIcon: "paintpalette"
        case .dockApps: "dock.rectangle"
        case .quitWithApp: "xmark.circle"
        case .trackUsage: "chart.bar"
        case .archiveCode: "archivebox"
        case .chatLimits: "gauge.with.dots.needle.33percent"
        case .reverseMouse: "computermouse"
        case .reverseTrackpad: "rectangle.and.hand.point.up.left"
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
    private var userQuit: [UUID: Date] = [:]   // quits MultiClaude asked for; Claude may still refuse (quit dialog)
    private var stopLog: [UUID: Date] = [:]   // last unrequested stop per profile, kept after it relaunches
    private var strayHandled: Date?           // the update whose stray default window was already closed
    private var bareHandled: [UUID: Date] = [:]   // profile copies last reopened after a bare start
    private var busy: Set<UUID> = []          // profiles being duplicated: their folder must stay put
    private var inFlight: Set<String> = []    // folders being written by a duplicate, not to be adopted
    private var failedMoves: Set<String> = []

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
        let data = defaults.data(forKey: "profiles")
        var unreadable = false
        if let data, let list = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = list
        } else {
            // A list that can't be read is kept aside, never just written over by the fresh one.
            if let data, !isCLI {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                defaults.set(data, forKey: "profiles-unreadable-\(stamp)")
                Log.write("saved profile list could not be read; kept as profiles-unreadable-\(stamp), starting from the Claude folders")
                unreadable = true
            }
            profiles = Seed.profiles()
        }
        if unreadable { notice = "MultiClaude couldn't read its saved profiles and rebuilt the list from your Claude folders." }
        for i in profiles.indices where profiles[i].color == nil { profiles[i].color = nextColor() }
        if !isCLI {
            // Copies cut short by a quit or crash during Duplicate (see Duplicate.clone).
            for n in (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? [] where n.hasPrefix(".partial-") {
                try? FileManager.default.removeItem(at: supportDir.appendingPathComponent(n))
                Log.write("removed \(n), a duplicate cut short")
            }
        }
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
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let launchedClaude = name == NSWorkspace.didLaunchApplicationNotification && launched?.bundleIdentifier == claudeBundleID
                MainActor.assumeIsolated {
                    // A bare copy can hand off to the default window and quit before refresh() looks.
                    if launchedClaude, Engine.shared.managing, let app = launched, let owner = Engine.shared.runtimeOwner(app), !owner.isDefault,
                       let args = ProcArgs.of(app.processIdentifier), !args.contains(where: { $0.hasPrefix("--user-data-dir=") }) {
                        Engine.shared.reopenBareCopy(app, of: owner)
                    }
                    Engine.shared.refresh()
                    // Claude makes itself the claude:// handler as it starts; take the links back once it's up.
                    if launchedClaude {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Engine.shared.holdLinks() }
                    }
                }
            }
        }
        if !isDemo { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Engine.shared.holdLinks() } }
        let afterSelfUpdate = defaults.string(forKey: "updatedTo") != nil
        if let to = defaults.string(forKey: "updatedTo") {
            defaults.removeObject(forKey: "updatedTo")
            if to == appVersion { notice = "MultiClaude updated to \(to)." }
        }
        if !isDemo { Updater.start() }
        // Electron instances launched with `open -n` sometimes skip the launch notification; poll as a backstop.
        // In the common modes, so it keeps running while an alert or menu is up.
        RunLoop.main.add(Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { Engine.shared.refresh() }
        }, forMode: .common)
        refresh()
        // A restart after a self-update keeps whatever is open; it does not reopen startup profiles.
        if !isDemo && !afterSelfUpdate && managing {
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
        if s == .chatLimits && on && !Dialogs.confirmChatLimits() { return }
        objectWillChange.send()
        if s == .launchAtLogin {
            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSSound.beep() }
            return
        }
        defaults.set(on, forKey: s.rawValue)
        if s == .shortcut || s == .profileShortcuts { updateHotKeys() }
        if s == .routeSignIn { on ? holdLinks() : LinkRelay.giveBack() }
        if s == .dockApps { syncLaunchers() }
        if s == .reverseMouse || s == .reverseTrackpad { updateScroll() }
        if s == .manageClaude { setManaging(on) }
        if s == .trackUsage || s == .archiveCode || s == .chatLimits { Usage.shared.refresh(force: true) }
        onChange?()
    }

    // Off, MultiClaude is a keep-awake and scroll app only: it stops watching Claude, gives the claude://
    // links back, leaves Claude's windows and folders alone, and hides the profiles. Nothing is deleted.
    var managing: Bool { isOn(.manageClaude) }

    private func setManaging(_ on: Bool) {
        Log.write(on ? "managing Claude accounts again" : "stopped managing Claude accounts (keep-awake only)")
        if on {
            discoverFolders()
            holdLinks()
        } else {
            if signIn != nil { finishSignIn(cancelled: true) }
            LinkRelay.giveBack()
            pending = [:]
        }
        updateHotKeys()
        refresh()
    }

    func updateScroll() { ScrollReverser.update(mouse: isOn(.reverseMouse), trackpad: isOn(.reverseTrackpad)) }

    // ⌃⌥⌘M opens the panel; ⌃⌥⌘A turns keep-awake on or off; ⌃⌥1 to ⌃⌥9 open or focus the profiles in list order.
    func updateHotKeys() {
        var keys: [HotKey.Binding] = []
        if isOn(.shortcut) {
            keys.append(.init(key: kVK_ANSI_M, mods: cmdKey | optionKey | controlKey) { Engine.shared.onPanelHotKey?() })
        }
        if Awake.shared.isOn(.shortcut) {
            keys.append(.init(key: kVK_ANSI_A, mods: cmdKey | optionKey | controlKey) { Awake.shared.toggleActive() })
        }
        if managing && isOn(.profileShortcuts) {
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
        guard isOn(.profileShortcuts), let i = profiles.firstIndex(where: { $0.id == p.id }), i < 9 else { return nil }
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
    private var lastClaudePid: pid_t?   // the Claude window used last, for claude:// links outside a sign-in

    // While MultiClaude, not Claude, handles claude:// links, Claude signs in through an in-window
    // ASWebAuthenticationSession instead of the browser, so every account signs in in its own window.
    // (Claude: "[Auth] Not the claude:// handler; keeping ASWebAuth".)
    func holdLinks() {
        guard !isDemo, !isCLI, managing, isOn(.routeSignIn) || signIn != nil, !LinkRelay.isOurs() else { return }
        LinkRelay.take { _ in }
    }

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
            // Stop quitting accounts once the sign-in is over or cancelled; finishSignIn reopens the ones already closed.
            guard Engine.shared.signIn?.target == p.id else { return }
            guard let first = rest.first else { Engine.shared.open(p); return }
            Engine.shared.quitAndWait(first) { _ in next(Array(rest.dropFirst())) }
        }
        next(others)
    }

    // A claude:// link that reached MultiClaude: during a sign-in it goes to the target process,
    // otherwise to Claude as usual.
    func relay(_ link: String) {
        Log.write("link in: \(Log.redact(link)) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") last=\(lastClaudePid.map(String.init) ?? "-")")
        guard link.lowercased().hasPrefix("claude:") else { Log.write("ignored a link that isn't claude://"); return }
        if !managing, let url = URL(string: link) {
            LinkRelay.giveBack()
            NSWorkspace.shared.open([url], withApplicationAt: realClaudeApp(), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let s = signIn, s.routing, let app = running[s.target], !app.isTerminated, LinkRelay.send(link, to: app.processIdentifier) {
            signIn?.sawBrowser = true
            LinkRelay.bringForward(app)
            return
        }
        // Otherwise the Claude window in front, or the one used last.
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.bundleIdentifier == claudeBundleID ? front?.processIdentifier : lastClaudePid
        // The pid must still be a Claude: a pid can be reused by another app, and links can carry sign-in codes.
        if let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           app.bundleIdentifier == claudeBundleID, LinkRelay.send(link, to: pid) {
            Log.write("link sent to pid \(pid)")
            LinkRelay.bringForward(app)
            return
        }
        if let pid { Log.write("link not delivered to pid \(pid); handing it to Claude") }
        if !isOn(.routeSignIn) { LinkRelay.giveBack() }
        guard let url = URL(string: link) else { Log.write("link dropped: unparseable"); return }
        NSWorkspace.shared.open([url], withApplicationAt: LinkRelay.claudeApp, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { Log.write("link dropped: Claude didn't take it (\(err.localizedDescription))") }
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
        if !isOn(.routeSignIn) { LinkRelay.giveBack() }
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
        if isOn(.reverseMouse) || isOn(.reverseTrackpad) {
            let before = (ScrollReverser.cocaineMouse, ScrollReverser.cocaineTrackpad)
            updateScroll()
            if before != (ScrollReverser.cocaineMouse, ScrollReverser.cocaineTrackpad) { objectWillChange.send() }
        }
        guard managing else {
            if !running.isEmpty || frontID != nil { running = [:]; frontID = nil; onChange?() }
            return
        }
        var found: [UUID: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleID && !app.isTerminated {
            guard let args = ProcArgs.of(app.processIdentifier) else {
                // Unreadable for now: keep whatever this process was matched to before.
                if let known = running.first(where: { $0.value.processIdentifier == app.processIdentifier }) { found[known.key] = app }
                continue
            }
            let dir = args.first { $0.hasPrefix("--user-data-dir=") }.map { Folders.canonical(String($0.dropFirst(16))) }
            if dir == nil, let owner = runtimeOwner(app), !owner.isDefault {
                reopenBareCopy(app, of: owner)
                continue
            }
            if let p = profiles.first(where: { $0.dir.map(Folders.canonical) == dir }) {
                found[p.id] = app
            }
        }
        for id in found.keys { pending[id] = nil }
        pending = pending.filter { $0.value.timeIntervalSinceNow > -15 }

        let now = Date()
        for id in running.keys where found[id] == nil {
            let asked = userQuit.removeValue(forKey: id).map { now.timeIntervalSince($0) < 60 } ?? false
            if !asked {
                quitAt[id] = now
                stopLog[id] = now
            }
        }
        for id in found.keys { quitAt[id] = nil }
        userQuit = userQuit.filter { now.timeIntervalSince($0.value) < 60 }   // a quit Claude refused
        quitAt = quitAt.filter { now.timeIntervalSince($0.value) < 300 }
        stopLog = stopLog.filter { now.timeIntervalSince($0.value) < 600 }
        if let v = UpdateWatch.installedVersion(), v != claudeVersion {
            claudeVersion = v
            updatedAt = now
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let front, found.values.contains(where: { $0.processIdentifier == front }) { lastClaudePid = front }
        let newFront = found.first { $0.value.processIdentifier == front }?.key
        if found.mapValues(\.processIdentifier) != running.mapValues(\.processIdentifier) || newFront != frontID {
            running = found
            frontID = newFront
            onChange?()
        }
        reopenAfterUpdate(now: now)
        alignFolders()   // after `running` is current, so an open profile is never moved
    }

    // The profile whose own copy of Claude (see Runtimes) this process runs from, if any.
    func runtimeOwner(_ app: NSRunningApplication) -> Profile? {
        guard let url = app.bundleURL, let id = Runtimes.owner(of: url) else { return nil }
        return profiles.first { $0.id == id }
    }

    // A profile's copy started without --user-data-dir: Claude's updater relaunching it, or a Dock tile
    // kept from a running copy. It would show the default account in that profile's icon, so close it and
    // open the profile on its own account. Our own launches are pending and skipped.
    func reopenBareCopy(_ app: NSRunningApplication?, of p: Profile) {
        if pending[p.id] != nil { return }
        if let t = bareHandled[p.id], Date().timeIntervalSince(t) < 20 { return }
        bareHandled[p.id] = Date()
        Log.write("\(p.name)'s copy of Claude started without its folder; reopening it on its own account")
        app?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let e = Engine.shared
            if !e.isRunning(p) { e.open(p) }
        }
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
            LinkRelay.bringForward(app)
            return
        }
        guard pending[p.id] == nil else { return }   // already starting; a second open would start a second process
        let claude = realClaudeApp()
        guard FileManager.default.fileExists(atPath: claude.appendingPathComponent("Contents/Info.plist").path) else {
            notice = "Claude isn't installed. Install it from claude.ai/download, then open \(p.name) again."
            Log.write("open \(p.name): no Claude.app at \(claude.path)")
            return
        }
        if let dir = p.dir {
            do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
                notice = "Couldn't open \(p.name): its folder can't be created."
                Log.write("open \(p.name): can't create \(dir): \(error.localizedDescription)")
                return
            }
        }
        let anyClaude = !pending.isEmpty   // one still starting counts: `open -a` without -n would just bring it forward
            || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeBundleID && !$0.isTerminated }
        // With profile apps on, the profile runs in its own named copy of Claude (see Runtimes).
        let app = (isOn(.dockApps) && !isDemo ? Runtimes.ensure(p, from: claude) : nil) ?? claude
        let args = Launch.openArgs(app: app.path, dir: p.dir, anyClaudeRunning: anyClaude)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = args
        let id = p.id, name = p.name
        task.terminationHandler = { t in
            guard t.terminationStatus != 0 else { return }
            let status = t.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let e = Engine.shared
                    e.pending[id] = nil
                    e.notice = "Claude didn't start for \(name)."
                    Log.write("open \(name): /usr/bin/open exited with \(status)")
                    e.onChange?()
                }
            }
        }
        do { try task.run() } catch {
            notice = "Couldn't open \(p.name)."
            Log.write("open \(p.name): \(error.localizedDescription)")
            return
        }
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
        userQuit[d.id] = Date()
        app.terminate()
    }

    func quit(_ p: Profile) {
        guard let app = running[p.id] else { return }
        userQuit[p.id] = Date()
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
        guard let p = newProfile(named: raw), let dir = p.dir else {
            NSSound.beep()
            notice = raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : "Couldn't add \(raw.trimmingCharacters(in: .whitespaces)): the name needs a letter or digit and must not be taken."
            return false
        }
        // The folder of a profile taken off the list earlier: it comes back with its account and chats.
        if FileManager.default.fileExists(atPath: dir) {
            defaults.set(ignoredFolders.filter { $0.lowercased() != Folders.canonical(dir) }, forKey: "ignoredFolders")
            notice = "\(p.name)'s folder was already there, so it opens with the account and chats it had."
        }
        profiles.append(p)
        save()
        return true
    }

    // A profile with a Claude-<name> folder, or nil when the name is empty or taken by another profile
    // or its folder. The folder may already exist on disk (see add and duplicate).
    func newProfile(named raw: String) -> Profile? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let slug = Folders.slug(name)
        let dir = supportDir.appendingPathComponent("Claude-\(slug)").path
        guard !slug.isEmpty, !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !profiles.contains(where: { $0.dir.map(Folders.canonical) == Folders.canonical(dir) }),
              !inFlight.contains(dir) else { return nil }
        return Profile(name: name, dir: dir, color: nextColor())
    }

    func setOpenAtLaunch(_ p: Profile, _ on: Bool) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i].openAtLaunch = on
        save()
    }

    // Quits a running profile and calls back once its process is gone (true) or after 15 s (false: still open,
    // for example behind a quit dialog). The timeout is in seconds.
    func quitAndWait(_ p: Profile, timeout: Int = 15, then done: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard let app = running[p.id], !app.isTerminated else { done(true); return }
        userQuit[p.id] = Date()
        app.terminate()
        func poll(_ n: Int) {
            if app.isTerminated || n > timeout * 4 {
                let gone = app.isTerminated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { done(gone) } }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(n + 1) }
        }
        poll(0)
    }

    // Clones a profile's whole data folder, sign-in and chats included, into a new profile.
    // APFS clones make the copy instant and free until the two folders diverge.
    func duplicate(_ source: Profile, as name: String) {
        guard !busy.contains(source.id) else { NSSound.beep(); return }
        guard let p = newProfile(named: name), let dst = p.dir, !FileManager.default.fileExists(atPath: dst) else {
            notice = "Couldn't duplicate \(source.name): pick a name that no profile or folder uses yet."
            return
        }
        let wasRunning = isRunning(source)
        busy.insert(source.id)
        inFlight.insert(dst)
        notice = "Duplicating \(source.name)…"
        quitAndWait(source) { quit in
            let e = Engine.shared
            // Copying a folder its Claude is still writing would give the copy torn databases.
            let live = e.profiles.first { $0.id == source.id } ?? source
            guard quit, !Folders.inUse(live.folderURL.path) else {
                e.busy.remove(source.id)
                e.inFlight.remove(dst)
                e.notice = "Couldn't duplicate \(source.name): it didn't quit. Nothing was changed."
                return
            }
            let src = live.folderURL.path
            Task.detached {
                let result = Duplicate.clone(from: src, to: dst)
                await MainActor.run {
                    let e = Engine.shared
                    e.busy.remove(source.id)
                    e.inFlight.remove(dst)
                    switch result {
                    case .success where !e.profiles.contains(where: { $0.dir.map(Folders.canonical) == Folders.canonical(dst) }):
                        var added = p
                        added.color = e.nextColor()
                        e.profiles.append(added)
                        e.save()
                        e.notice = "Duplicated \(source.name) as \(p.name). Both are signed in to the same account until you sign one out."
                    case .success:
                        e.notice = "Duplicated \(source.name) as \(p.name)."
                    case .failure(let err):
                        Log.write("duplicate \(source.name): \(err)")
                        e.notice = "Couldn't duplicate \(source.name). Nothing was changed."
                    }
                    if wasRunning { e.open(live) }
                }
            }
        }
    }

    func copyMCPServers(from source: Profile, to target: Profile, restart: Bool) {
        do {
            let n = try MCP.copy(from: source, to: target)
            guard n > 0 else { notice = "\(source.name) has no MCP servers to copy."; return }
            notice = "Copied \(n) MCP server\(n == 1 ? "" : "s") from \(source.name) to \(target.name)."
                + (restart || !isRunning(target) ? "" : " Reopen \(target.name) to load them.")
            if restart && isRunning(target) { quitAndWait(target) { _ in Engine.shared.open(target) } }
        } catch MCP.Failure.unreadable(let who) {
            notice = "Couldn't copy MCP servers: \(who == .source ? source.name : target.name)'s config file isn't valid JSON."
        } catch {
            notice = "Couldn't copy MCP servers: \(error.localizedDescription)"
            Log.write("copy MCP servers \(source.name) to \(target.name): \(error)")
        }
    }

    // The folder follows the new name on its own (see alignFolders), once the profile is closed.
    func rename(_ p: Profile, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        guard !profiles.contains(where: { $0.id != p.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "Another profile is already called \(name)."
            return
        }
        profiles[i].name = name
        save()
        alignFolders()
    }

    // Takes the profile off the list. Its data folder stays on disk and is not added back.
    func remove(_ p: Profile) {
        guard !p.isDefault, let dir = p.dir else { return }
        defaults.set(Array(Set(ignoredFolders.map { $0.lowercased() } + [Folders.canonical(dir)])), forKey: "ignoredFolders")
        profiles.removeAll { $0.id == p.id }
        save()
    }

    // Quits the profile, then moves its data folder (and the links left by renames) and its Claude Code
    // folder to the Trash. The launcher app, Dock tile and runtime copy go with the list entry (see save).
    // The data folder goes first: if that fails, the profile stays on the list.
    func delete(_ p: Profile) {
        // Demo profiles share real ~/.claude-<name> folders by name, so the demo never deletes.
        guard !isDemo, !p.isDefault, !busy.contains(p.id) else { return }
        busy.insert(p.id)
        quitAndWait(p, timeout: 10) { quit in
            let e = Engine.shared
            defer { e.busy.remove(p.id) }
            guard let live = e.profiles.first(where: { $0.id == p.id }), let dir = live.dir else { return }
            guard quit, !Folders.inUse(dir) else {
                e.notice = "Couldn't delete \(live.name): it didn't quit. Nothing was changed."
                return
            }
            let fm = FileManager.default
            var links: [URL] = []   // paths that point at the folder: the old names from renames
            for name in (try? fm.contentsOfDirectory(atPath: supportDir.path)) ?? [] where name.hasPrefix("Claude-") {
                let url = supportDir.appendingPathComponent(name)
                if let to = try? fm.destinationOfSymbolicLink(atPath: url.path),
                   Folders.canonical(to) == Folders.canonical(dir) { links.append(url) }
            }
            let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath()
            let home = fm.homeDirectoryForCurrentUser.path
            let unsafe = [home, "/", supportDir.path, supportDir.appendingPathComponent("Claude").path,
                          home + "/Library", home + "/Library/Application Support"]
            guard !unsafe.contains(where: { Folders.canonical($0) == Folders.canonical(real.path) }) else {
                e.notice = "Couldn't delete \(live.name): its folder is \(real.path). Nothing was changed."
                return
            }
            do {
                if fm.fileExists(atPath: real.path) { try fm.trashItem(at: real, resultingItemURL: nil) }
            } catch {
                Log.write("delete \(live.name): \(error)")
                e.notice = "Couldn't move \(live.name)'s folder to the Trash. Nothing was changed."
                return
            }
            for url in links + [URL(fileURLWithPath: dir)] where (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
            var note = "Moved \(live.name) to the Trash."
            if let code = live.codeConfigDir, Folders.canonical(code) != Folders.canonical(home + "/.claude"),
               fm.fileExists(atPath: code) {
                if e.profiles.contains(where: { $0.id != p.id && $0.codeConfigDir.map(Folders.canonical) == Folders.canonical(code) }) {
                    note += " Its Claude Code folder stays, because another profile uses it."
                } else {
                    do { try fm.trashItem(at: URL(fileURLWithPath: code), resultingItemURL: nil) } catch {
                        Log.write("delete \(live.name) \(code): \(error)")
                        note = "Moved \(live.name) to the Trash, but not its Claude Code folder \(code)."
                    }
                }
            }
            e.profiles.removeAll { $0.id == p.id }
            e.save()
            e.notice = note
        }
    }

    private var ignoredFolders: [String] { defaults.stringArray(forKey: "ignoredFolders") ?? [] }

    // Adds every Claude-* folder in Application Support that no profile uses yet.
    func discoverFolders() {
        guard !isDemo, !isCLI else { return }
        let known = Set(profiles.compactMap(\.dir).map(Folders.canonical) + ignoredFolders.map { $0.lowercased() }
                        + inFlight.map(Folders.canonical))
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
        let claudes = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == claudeBundleID && !$0.isTerminated }
        let argv = claudes.map { ProcArgs.of($0.processIdentifier) }
        guard !argv.contains(where: { $0 == nil }) else { return }   // a Claude we can't read might be using any folder
        let live = Set(argv.compactMap { $0?.first { $0.hasPrefix("--user-data-dir=") } }
            .map { Folders.canonical(String($0.dropFirst(16))) })
        var changed = false
        for i in profiles.indices {
            let p = profiles[i]
            guard let dir = p.dir, !live.contains(Folders.canonical(dir)), !isRunning(p), pending[p.id] == nil,
                  !busy.contains(p.id), !Folders.inUse(dir),
                  let target = Folders.target(for: p.name, current: dir, in: supportDir.path),
                  !failedMoves.contains(dir + "\t" + target) else { continue }
            let oldCode = p.codeConfigDir
            switch Folders.move(dir, to: target) {
            case .moved:
                if p.codeDir == nil, let oldCode, FileManager.default.fileExists(atPath: oldCode) {
                    profiles[i].codeDir = oldCode   // its Keychain sign-in is tied to this path
                }
                profiles[i].dir = target
                changed = true
            case .stranded:
                // Moved, but neither the link nor the way back worked: follow the data to where it is.
                profiles[i].dir = target
                changed = true
                Log.write("folder \(dir) moved to \(target) but the link back failed")
            case .failed(let why):
                failedMoves.insert(dir + "\t" + target)   // tried again at the next launch, not every 3 s
                Log.write("couldn't rename \(dir) to \(target): \(why)")
            }
        }
        if changed { save() }
    }

    func setColor(_ p: Profile, _ c: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i].color = c
        save()
    }

    // MARK: profile apps

    // Keeps ~/Applications/MultiClaude Launchers in step with the list: one app per profile while the
    // setting is on, none while it's off. Apps that move or go away are moved or taken off the Dock too.
    func syncLaunchers() {
        guard !isDemo, !isCLI else { return }
        let result = Launchers.sync(isOn(.dockApps) ? profiles : [], in: Launchers.folder)
        Runtimes.prune(keeping: isOn(.dockApps) ? Set(profiles.map(\.id)) : [])
        // Restyle each profile's own Claude now rather than at its next launch (only the icon if it's open).
        if isOn(.dockApps) {
            let claude = realClaudeApp()
            for p in profiles where Runtimes.exists(p.id) { _ = Runtimes.ensure(p, from: claude) }
        }
        if !result.moved.isEmpty || !result.removed.isEmpty || !result.rewritten.isEmpty {
            Dock.update(moved: result.moved, removed: result.removed, refresh: result.rewritten)
        }
        if !result.failed.isEmpty { notice = "Couldn't write the app for \(result.failed.joined(separator: ", "))." }
    }

    func launcherURL(_ p: Profile) -> URL? {
        guard isOn(.dockApps) else { return nil }
        return Launchers.installed(in: Launchers.folder)[p.id]
    }

    func renameApp(_ p: Profile, to raw: String) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        let name = raw.trimmingCharacters(in: .whitespaces)
        profiles[i].appName = name.isEmpty || name == Profile(name: p.name, dir: p.dir).dockAppName ? nil : name
        save()
    }

    func addToDock(_ p: Profile) {
        if !isOn(.dockApps) { toggle(.dockApps) }
        guard let url = launcherURL(p) else { NSSound.beep(); return }
        if !Dock.add(url) { notice = "Couldn't add \(p.dockAppName) to the Dock. Drag it there from Finder instead." }
    }

    func removeFromDock(_ p: Profile) {
        guard let url = launcherURL(p) else { return }
        Dock.update(moved: [], removed: [url])
    }

    // multiclaude://open?profile=<id>, sent by a profile's app. Opens or brings forward that profile.
    func handleOwnLink(_ link: String) {
        guard let c = URLComponents(string: link), c.host == "open",
              let id = c.queryItems?.first(where: { $0.name == "profile" })?.value.flatMap(UUID.init(uuidString:)),
              let p = profiles.first(where: { $0.id == id }) else { NSSound.beep(); return }
        refresh()   // MultiClaude may have just been launched by this link
        open(p)
    }

    func move(_ p: Profile, by delta: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        let j = i + delta
        guard profiles.indices.contains(j) else { return }
        profiles.swapAt(i, j)
        save()
    }

    private func save() {
        if !isDemo, !isCLI, let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
        syncLaunchers()
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
    nonisolated(unsafe) static var installedPending: String?   // swapped in, waiting for the relaunch
    static let maxZipSize = 64 << 20

    // Its own session, so a stalled download gives up instead of blocking every later check.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

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
        guard Engine.shared.isOn(.autoUpdate), !busy, installedPending == nil else { return }
        if !force, let last = d.object(forKey: "lastUpdateCheck") as? Date, -last.timeIntervalSinceNow < 86_400 { return }
        // A test build (1.5-rc1, 0.0.0-ci) is never replaced by a release behind the tester's back.
        guard !currentVersion.contains("-") else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            if force { Log.write("update: skipped, \(target.deletingLastPathComponent().path) isn't writable") }
            return
        }
        busy = true
        Task.detached {
            let outcome: Result<String?, Error>
            do { outcome = .success(try await updateIfNewer(at: target)) } catch { outcome = .failure(error) }
            let installed = try? outcome.get(), failure = { if case .failure(let e) = outcome { return "\(e)" } else { return nil } }() as String?
            await MainActor.run {
                busy = false
                // A failed check is tried again in 3 hours rather than the next day (or every hour for a bad release).
                if let failure { Log.write("update failed: \(failure)") }
                d.set(failure == nil ? Date() : Date().addingTimeInterval(-86_400 + 3 * 3600), forKey: "lastUpdateCheck")
                if let installed = installed ?? nil {
                    installedPending = installed
                    Log.write("update: installed \(installed), relaunching when idle")
                    relaunchWhenIdle(version: installed, app: target)
                }
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
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.command("GitHub answered \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
              url.port == nil, url.user == nil, !url.path.contains(".."),
              url.path.hasPrefix("/QuentinCar0n/multiclaude/releases/download/") else { return nil }
        return url
    }

    // Dotted numbers; a pre-release (1.5-rc1) sorts below its release (1.5) and above the one before.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], Bool) {
            let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
            return (core.split(separator: ".").map { Int($0) ?? 0 }, v.contains("-"))
        }
        let (x, xPre) = parts(a), (y, yPre) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return yPre && !xPre
    }

    // Downloads the release zip, checks that it holds MultiClaude at the advertised version with an intact
    // signature, then swaps it in place of the running bundle.
    static func install(_ r: Release, at target: URL) async throws {
        let fm = FileManager.default
        // Staged on the same volume as the app, so the final swap is a rename and never a half-done copy.
        let work = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("MultiClaude-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (tmp, resp) = try await session.download(from: r.zip)
        defer { try? fm.removeItem(at: tmp) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? Int.max
        guard size < maxZipSize else { throw UpdateError.download }
        let bytes = try Data(contentsOf: tmp)
        // The zip must carry a signature made with the release key; HTTPS alone would trust whoever controls the repo.
        let (sigData, sigResp) = try await session.data(from: r.signature)
        guard (sigResp as? HTTPURLResponse)?.statusCode == 200,
              UpdateSignature.verify(bytes, signatureBase64: String(decoding: sigData, as: UTF8.self))
        else { throw UpdateError.signature }
        // Unpack the very bytes that were verified, not the file the download left behind.
        let zip = work.appendingPathComponent("update.zip")
        try bytes.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("MultiClaude.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "me.somalabs.multiclaude",
              info?["CFBundleShortVersionString"] as? String == r.version else { throw UpdateError.invalid }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try fm.replaceItemAt(target, withItemAt: app)
    }

    // Runs a tool and throws with the first lines of its error output when it fails.
    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let first = text.split(separator: "\n").prefix(3).joined(separator: " | ")
            throw UpdateError.command("\(URL(fileURLWithPath: tool).lastPathComponent) exited \(p.terminationStatus)\(first.isEmpty ? "" : ": " + first)")
        }
    }

    // Waits while the panel is open or a sign-in is relaying links (a restart would drop it). The new copy
    // starts once this process is gone, so `open` can't just bring the old one forward.
    @MainActor static func relaunchWhenIdle(version: String, app: URL) {
        guard !PanelController.shared.isOpen, Engine.shared.signIn == nil, !Awake.shared.lidApplied else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { relaunchWhenIdle(version: version, app: app) }
            return
        }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$0\"",
                        app.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try sh.run() } catch {
            Log.write("update: can't relaunch (\(error.localizedDescription)); \(version) starts next time")
            return
        }
        UserDefaults.standard.set(version, forKey: "updatedTo")
        Awake.shared.saveForRelaunch()
        relaunching = true
        NSApp.terminate(nil)
    }
}

// Every Claude instance writes to the same main.log, so new lines since the sign-in started tell when it lands.
// Takes over claude:// links for the length of a sign-in and forwards them to one Claude process.
// ~/Library/Logs/MultiClaude.log: link relays and sign-ins, for support. Links are logged without their query.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MultiClaude.log")
    static let maxSize: UInt64 = 1 << 20   // past 1 MB the log moves to MultiClaude.log.1 and starts over

    static func write(_ line: String) {
        guard !isCLI else { return }
        let text = ISO8601DateFormatter().string(from: Date()) + " " + String(line.prefix(400)) + "\n"
        let fm = FileManager.default
        if ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0 > maxSize {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close()
        } else {
            // Only the user reads it: links and folder names are private.
            fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
    // Scheme, host and the first path segment: enough to tell a sign-in from a chat link, and no codes,
    // ids or tokens, wherever in the link they sit.
    static func redact(_ link: String) -> String {
        guard let c = URLComponents(string: link), let scheme = c.scheme else { return "<unparseable>" }
        let first = c.path.split(separator: "/").first.map { "/" + $0 } ?? ""
        let more = c.path.split(separator: "/").count > 1 || c.query != nil || c.fragment != nil
        return "\(scheme)://\(c.host ?? "")\(first)\(more ? "/…" : "")"
    }
}

enum LinkRelay {
    static var claudeApp: URL { realClaudeApp() }

    static func handler() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "claude://claude.ai")!)
    }

    static func isOurs() -> Bool {
        handler()?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    static func take(_ done: @escaping @Sendable (Bool) -> Void) {
        Log.write("taking claude:// links")
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "claude") { err in
            done(err == nil && isOurs())
        }
    }

    static func giveBack() {
        guard isOurs() else { return }
        Log.write("giving claude:// links back to Claude")
        NSWorkspace.shared.setDefaultApplication(at: claudeApp, toOpenURLsWithScheme: "claude") { _ in }
    }

    // macOS 14+ only lets the active app hand focus over explicitly; MultiClaude is active while it takes a link.
    @MainActor static func bringForward(_ app: NSRunningApplication) {
        app.unhide()
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
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
            if l.contains("[Auth] Using system browser") || l.contains("[Auth] Starting ASWebAuth") { saw = true }
            if l.contains("[Auth] ASWebAuth completed") { return (true, true) }
            if l.contains("claudeURLHandler: login") { return (true, true) }
            if saw && l.contains("account active and logged in") { return (saw, true) }
        }
        return (saw, false)
    }
}

enum Folders {
    // A folder's identity for comparisons only (never for file operations): symlinks resolved, and lowercased
    // because the Mac's volumes ignore case, so "claude-work" typed in an alias is the same folder.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    // Electron keeps a SingletonLock link ("<host>-<pid>") in the folder while an instance uses it.
    // A lock left by a crash names a process that is gone, and doesn't count.
    static func inUse(_ dir: String) -> Bool {
        guard let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/SingletonLock") else { return false }
        guard let pid = lock.split(separator: "-").last.flatMap({ pid_t($0) }), pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
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

    enum MoveResult: Equatable { case moved, failed(String), stranded }

    static func move(_ from: String, to: String) -> MoveResult {
        let fm = FileManager.default
        do { try fm.moveItem(atPath: from, toPath: to) } catch { return .failed(error.localizedDescription) }
        do {
            try fm.createSymbolicLink(atPath: from, withDestinationPath: to)
            return .moved
        } catch {
            // No link means old paths inside Claude's data would break; put the folder back.
            if (try? fm.moveItem(atPath: to, toPath: from)) != nil { return .failed(error.localizedDescription) }
            return .stranded
        }
    }
}

enum MCP {
    enum Side { case source, target }
    enum Failure: Error { case unreadable(Side) }

    static func configURL(_ p: Profile) -> URL { p.folderURL.appendingPathComponent("claude_desktop_config.json") }

    // A missing or empty file is an empty config; a file that exists but isn't a JSON object throws.
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
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
        guard let src = try? read(configURL(source)) else { throw Failure.unreadable(.source) }
        let servers = src["mcpServers"] as? [String: Any] ?? [:]
        guard !servers.isEmpty else { return 0 }   // nothing to add: the target file isn't touched
        let url = configURL(target)
        guard let current = try? read(url) else { throw Failure.unreadable(.target) }
        let merged = merge(current, adding: servers)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            var backup = url.appendingPathExtension("bak-" + f.string(from: Date()))
            var n = 2
            while fm.fileExists(atPath: backup.path) { backup = url.appendingPathExtension("bak-" + f.string(from: Date()) + "-\(n)"); n += 1 }
            try fm.copyItem(at: url, to: backup)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return servers.count
    }
}

enum Duplicate {
    // `cp -c` clones on APFS. The destination must not exist yet. The copy is made under a hidden name and
    // renamed at the end, so a copy cut short (quit, crash, full disk) is never taken for a profile folder.
    static func clone(from source: String, to dst: String) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        // The source may be the link left by a folder rename; copy the folder it points to.
        let src = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { return .failure(.command("source missing or destination taken")) }
        let parent = URL(fileURLWithPath: dst).deletingLastPathComponent().path
        let partial = parent + "/.partial-" + UUID().uuidString
        do { try Updater.run("/bin/cp", ["-cR", src, partial]) } catch {
            try? fm.removeItem(atPath: partial)
            return .failure(error as? UpdateError ?? .command("\(error)"))
        }
        // Electron's single-instance lock files belong to the source process.
        for lock in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
            try? fm.removeItem(atPath: partial + "/" + lock)
        }
        do { try fm.moveItem(atPath: partial, toPath: dst) } catch {
            try? fm.removeItem(atPath: partial)
            return .failure(.command(error.localizedDescription))
        }
        return .success(())
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
    // `open -a` brings forward whichever Claude is already running, which may be another account.
    // With any instance up, the default account needs -n to start its own process.
    // `app` is a full path (Claude.app or the profile's own copy), so a profile app named like Claude
    // can never be opened in its place.
    static func openArgs(app: String, dir: String?, anyClaudeRunning: Bool) -> [String] {
        if let dir { return ["-n", "-a", app, "--args", "--user-data-dir=\(dir)"] }
        return anyClaudeRunning ? ["-n", "-a", app] : ["-a", app]
    }
}

enum UpdateWatch {
    static func installedVersion() -> String? {
        let app = realClaudeApp()
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
    // nil when the arguments can't be read (the process is exiting, or belongs to someone else), which
    // callers must not take for "started without --user-data-dir".
    static func of(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
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

// MARK: - Lid-closed sessions (ideas ported from Insomnia)

// The lid-closed part of Keep Awake follows Insomnia by Krish Garg (MIT, github.com/krishhgg/Insomnia):
// lid actions that undo themselves on open, battery and heat floors, and a recovery agent that undoes a
// session's changes if MultiClaude is gone. Rewritten here, smaller; see NOTICE.

// Root-only pmset changes. With the helper installed, a sudoers rule lets these four commands run without
// a password; otherwise macOS asks for the administrator password each time.
enum Root {
    static let sudoersPath = "/etc/sudoers.d/multiclaude"
    static let pmsetCommands = [["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"],
                                ["-b", "lowpowermode", "1"], ["-b", "lowpowermode", "0"]]

    static var installed: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    static func sudoersText(user: String) -> String {
        "# Installed by MultiClaude: lets \(user) keep the Mac awake with the lid closed without a password.\n"
            + "\(user) ALL=(root) NOPASSWD: " + pmsetCommands.map { "/usr/bin/pmset " + $0.joined(separator: " ") }.joined(separator: ", ") + "\n"
    }

    @discardableResult
    static func pmset(_ args: [String]) -> Bool {
        guard pmsetCommands.contains(args) else { return false }
        if installed {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "/usr/bin/pmset"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                if p.terminationStatus == 0 { return true }
            }
            Log.write("lid: sudo -n pmset \(args.joined(separator: " ")) refused, asking for the password instead")
        }
        return admin("/usr/bin/pmset " + args.joined(separator: " "))
    }

    // One administrator prompt for a shell command (macOS's own dialog; MultiClaude never sees the password).
    static func admin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        return err == nil
    }

    // Writes the rule to a temp file, checks it with visudo, then installs it root-owned and 0440.
    static func install() -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("multiclaude-sudoers-\(UUID().uuidString)")
        guard (try? sudoersText(user: NSUserName()).write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ok = admin("/usr/sbin/visudo -cf \(shellQuote(tmp.path)) && /usr/bin/install -m 0440 -o root -g wheel \(shellQuote(tmp.path)) \(sudoersPath)")
        Log.write(ok ? "lid helper installed (\(sudoersPath))" : "lid helper not installed")
        return ok && installed
    }

    static func uninstall() -> Bool {
        let ok = admin("/bin/rm -f \(sudoersPath)")
        Log.write(ok ? "lid helper removed" : "lid helper not removed")
        return ok
    }

    static func lowPowerOn() -> Bool {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.split(separator: "\n").contains { $0.split(separator: " ").first == "lowpowermode" && $0.hasSuffix("1") }
    }
}

// Lid open and closed, from IOPMrootDomain's AppleClamshellState, with a 2 s debounce so a lid that flaps
// while being moved doesn't trigger anything.
@MainActor
final class LidObserver {
    static let shared = LidObserver()
    var onChange: ((Bool) -> Void)?
    private(set) var closed = false
    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var note: io_object_t = 0
    private var pending: Timer?

    nonisolated static func read() -> Bool? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        guard let v = IORegistryEntryCreateCFProperty(s, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    func start() {
        guard port == nil else { return }
        closed = Self.read() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, { _, _, _, _ in
            MainActor.assumeIsolated { LidObserver.shared.changed() }
        }, nil, &note)
        if kr != KERN_SUCCESS { Log.write("lid: can't watch the lid (\(kr))") }
    }

    private func changed() {
        guard let now = Self.read(), now != closed else { pending?.invalidate(); pending = nil; return }
        pending?.invalidate()
        let t = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                let l = LidObserver.shared
                l.pending = nil
                guard let settled = LidObserver.read(), settled != l.closed else { return }
                l.closed = settled
                Log.write("lid \(settled ? "closed" : "opened")")
                l.onChange?(settled)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pending = t
    }
}

// Pauses chat apps (and their helper processes) with SIGSTOP while the lid is closed, so they stop
// syncing and pinging; SIGCONT on open. Meeting and recording apps are never paused.
enum Freezer {
    static let apps = ["com.tinyspeck.slackmacgap": "Slack", "net.whatsapp.WhatsApp": "WhatsApp",
                       "desktop.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord"]

    static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    // The app's process and every descendant (Electron helpers), children first.
    static func tree(_ root: pid_t, in table: [(pid: pid_t, ppid: pid_t)]) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [root]
        while let p = queue.popLast() {
            out.append(p)
            queue += table.filter { $0.ppid == p && $0.pid != p }.map(\.pid)
        }
        return out.reversed()
    }

    static func freeze() -> [pid_t] {
        let table = processTable()
        let me = getuid()
        var stopped: [pid_t] = []
        for app in NSWorkspace.shared.runningApplications {
            // MULTICLAUDE_FREEZE_EXTRA (preview runs only) adds one bundle id, to test with a harmless app.
            let extra = isPreview ? ProcessInfo.processInfo.environment["MULTICLAUDE_FREEZE_EXTRA"] : nil
            guard let id = app.bundleIdentifier, apps[id] != nil || id == extra, !app.isTerminated else { continue }
            for pid in tree(app.processIdentifier, in: table) {
                var info = proc_bsdinfo()
                // Only our own user's processes.
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == me else { continue }
                if kill(pid, SIGSTOP) == 0 { stopped.append(pid) }
            }
        }
        if !stopped.isEmpty { Log.write("lid: paused \(stopped.count) chat app processes") }
        return stopped
    }

    // SIGCONT never harms a running process, so a pid reused since is safe.
    static func thaw(_ pids: [pid_t]) {
        for p in pids { kill(p, SIGCONT) }
        if !pids.isEmpty { Log.write("lid: resumed \(pids.count) processes") }
    }
}

// Default output mute through Core Audio.
enum OutputMute {
    static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)

    static func defaultDevice() -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var d = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr, d != kAudioObjectUnknown else { return nil }
        return d
    }

    static func isMuted(_ d: AudioObjectID) -> Bool {
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &muteAddress, 0, nil, &size, &m) == noErr && m != 0
    }

    static func set(_ d: AudioObjectID, muted: Bool) -> Bool {
        var m: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(d, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

// What a session changed, on disk, so the recovery agent can undo it if MultiClaude is gone
// (crash, force quit, update gone wrong). Plain key=value lines the agent's shell script reads.
enum Recovery {
    static let label = "me.somalabs.multiclaude.recovery"
    static var folder: URL { supportDir.appendingPathComponent("MultiClaude") }
    static var stateURL: URL { folder.appendingPathComponent("awake-state") }
    static var scriptURL: URL { folder.appendingPathComponent("recovery.sh") }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    struct State: Equatable {
        var disableSleep = false, lowPower = false, muted = false
        var frozen: [pid_t] = []
        var isEmpty: Bool { !disableSleep && !lowPower && !muted && frozen.isEmpty }
        var text: String {
            "disablesleep=\(disableSleep ? 1 : 0)\nlowpower=\(lowPower ? 1 : 0)\nmuted=\(muted ? 1 : 0)\nfrozen=\(frozen.map(String.init).joined(separator: " "))\n"
        }
    }

    static func save(_ s: State) {
        if s.isEmpty { try? FileManager.default.removeItem(at: stateURL); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? s.text.write(to: stateURL, atomically: true, encoding: .utf8)
    }

    // Runs every minute; does nothing while MultiClaude runs or when there's nothing to undo.
    // Root changes only undo with the helper installed (sudo -n never prompts).
    static let script = """
    #!/bin/sh
    # MultiClaude recovery agent: undoes a keep-awake session's changes when MultiClaude isn't running.
    dir="$HOME/Library/Application Support/MultiClaude"
    state="$dir/awake-state"
    [ -f "$state" ] || exit 0
    /usr/bin/pgrep -qx MultiClaude && exit 0
    val() { /usr/bin/sed -n "s/^$1=//p" "$state" | /usr/bin/tr -cd '0-9 '; }
    log() { echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) recovery: $1" >> "$HOME/Library/Logs/MultiClaude.log"; }
    left=0
    if [ "$(val disablesleep)" = "1" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && log "sleep allowed again" || left=1
    fi
    if [ "$(val lowpower)" = "1" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 && log "Low Power Mode off" || left=1
    fi
    for p in $(val frozen); do /bin/kill -CONT "$p" 2>/dev/null; done
    [ -n "$(val frozen)" ] && log "resumed paused apps"
    if [ "$(val muted)" = "1" ]; then
      /usr/bin/osascript -e 'set volume without output muted' && log "sound back on"
    fi
    /usr/bin/sed -i '' -e 's/^frozen=.*/frozen=/' -e 's/^muted=.*/muted=0/' "$state"
    if [ "$left" = "0" ]; then
      /bin/rm -f "$state" "$dir/.recovery-warned"
    elif [ ! -f "$dir/.recovery-warned" ]; then
      log "sleep stays off until MultiClaude opens again, or run: sudo pmset -a disablesleep 0"
      /usr/bin/touch "$dir/.recovery-warned"
    fi
    """

    static func installAgent() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sh", scriptURL.path],
                                    "StartInterval": 60, "RunAtLoad": true, "ProcessType": "Background"]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let unchanged = (try? String(contentsOf: scriptURL, encoding: .utf8)) == script && (try? Data(contentsOf: plistURL)) == data
        guard !unchanged else { return }
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? data?.write(to: plistURL, options: .atomic)
        let domain = "gui/\(getuid())"
        for args in [["bootout", domain + "/" + label], ["bootstrap", domain, plistURL.path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        Log.write("recovery agent installed")
    }
}

// MARK: - Keep awake and scroll direction (ported from Cocaine)

enum AwakeSetting: String, CaseIterable, Identifiable {
    case activateAtLaunch, leftClick, shortcut, allowDisplaySleep, lidClosed
    case lidScreenOff, lidMute, lidFreeze, lidLowPower
    case notifications, powerConnect, powerDisconnect, lowBattery, batteryLowPower, heatRules

    // Insomnia's defaults: the lid actions that cost nothing are on; Low Power Mode needs the helper.
    static let onByDefault: Set<AwakeSetting> = [.lidScreenOff, .lidMute, .lidFreeze, .heatRules]
    static let needsHelper: Set<AwakeSetting> = [.lidLowPower, .batteryLowPower]
    static let groups: [(String, [AwakeSetting])] = [
        ("General", [.activateAtLaunch, .leftClick, .shortcut, .allowDisplaySleep, .notifications]),
        ("Lid", [.lidClosed, .lidScreenOff, .lidMute, .lidFreeze, .lidLowPower]),
        ("Power", [.powerConnect, .powerDisconnect, .lowBattery, .batteryLowPower, .heatRules]),
    ]
    static let lidActions: Set<AwakeSetting> = [.lidScreenOff, .lidMute, .lidFreeze, .lidLowPower]

    var id: String { rawValue }
    var key: String { "awake." + rawValue }   // apart from MultiClaude's own settings of the same name

    var title: String {
        switch self {
        case .activateAtLaunch: "Activate at Launch"
        case .leftClick: "Activate with Left Click"
        case .shortcut: "Keyboard Shortcut"
        case .allowDisplaySleep: "Allow Display Sleep"
        case .lidClosed: "Keep Awake with Lid Closed"
        case .lidScreenOff: "Turn the Screen Off"
        case .lidMute: "Mute Sound"
        case .lidFreeze: "Pause Chat Apps"
        case .lidLowPower: "Low Power Mode"
        case .batteryLowPower: "Low Power Mode Below 40%"
        case .heatRules: "Ease Off When Hot"
        case .notifications: "Notify When It Turns Off"
        case .powerConnect: "Activate on Power Connect"
        case .powerDisconnect: "Deactivate on Power Disconnect"
        case .lowBattery: "Deactivate When Below 20%"
        }
    }

    var symbol: String {
        switch self {
        case .activateAtLaunch: "switch.2"
        case .leftClick: "cursorarrow.click"
        case .shortcut: "command"
        case .allowDisplaySleep: "moon"
        case .lidClosed: "laptopcomputer.and.arrow.down"
        case .lidScreenOff: "display"
        case .lidMute: "speaker.slash"
        case .lidFreeze: "pause.circle"
        case .lidLowPower: "leaf"
        case .batteryLowPower: "battery.50"
        case .heatRules: "thermometer.medium"
        case .notifications: "bell"
        case .powerConnect: "bolt"
        case .powerDisconnect: "bolt.slash"
        case .lowBattery: "battery.25"
        }
    }

    var hint: String? {
        switch self {
        case .shortcut: "⌃⌥⌘A"
        case .lidFreeze: "Slack, Discord…"
        default: nil
        }
    }
}

// Holds an IOKit power assertion for a chosen duration or until turned off, like `caffeinate`.
@MainActor
final class Awake: ObservableObject {
    static let shared = Awake()

    @Published private(set) var active = false
    @Published private(set) var minutes: Int
    @Published private(set) var endDate: Date?
    @Published private(set) var tick = Date()

    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private(set) var lidApplied = false
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var lastOnAC = true

    private init() {
        minutes = defaults.object(forKey: "awake.minutes") as? Int ?? 0
    }

    func boot() {
        undoLeftovers()
        LidObserver.shared.onChange = { Awake.shared.lidChanged($0) }
        LidObserver.shared.start()
        if isOn(.lidClosed) { Recovery.installAgent() }
        lastOnAC = Power.snapshot().onAC
        powerSource = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { Awake.shared.powerChanged() }
        }, nil)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        // A self-update restart picks the keep-awake back up where it was.
        if let resume = defaults.object(forKey: "awake.resume") as? Double {
            defaults.removeObject(forKey: "awake.resume")
            if resume == 0 { start(until: nil) }
            else if resume > Date().timeIntervalSince1970 { start(until: Date(timeIntervalSince1970: resume)) }
        } else if isOn(.activateAtLaunch) {
            activate()
        }
    }

    // Called just before a self-update restart.
    func saveForRelaunch() {
        guard active else { return }
        defaults.set(endDate?.timeIntervalSince1970 ?? 0, forKey: "awake.resume")
    }

    func isOn(_ s: AwakeSetting) -> Bool {
        if AwakeSetting.onByDefault.contains(s) && defaults.object(forKey: s.key) == nil { return true }
        return defaults.bool(forKey: s.key)
    }

    // Lid actions only matter while the Mac stays awake with the lid closed.
    var lidActionsLive: Bool { active && (isOn(.lidClosed) || simulatedLid) }
    var simulatedLid = false   // MULTICLAUDE_PREVIEW=lidtest: lid actions without lid mode's root change

    // Closes and opens a pretend lid and logs what happened to each action, then quits.
    func runLidTest() {
        simulatedLid = true
        activate(minutes: 1)
        func pausedCount() -> Int {
            recovery.frozen.filter { pid in
                var info = proc_bsdinfo()
                return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_status == UInt32(SSTOP)
            }.count
        }
        let frozenBefore = { () -> [pid_t] in self.recovery.frozen }
        lidChanged(true)
        let paused = pausedCount(), stateSaved = FileManager.default.fileExists(atPath: Recovery.stateURL.path)
        let muted = OutputMute.defaultDevice().map(OutputMute.isMuted) ?? false
        Log.write("lidtest closed: muted=\(muted) paused=\(paused)/\(frozenBefore().count) state-file=\(stateSaved)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let pids = self.recovery.frozen
            self.lidChanged(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let still = pids.filter { pid in
                    var info = proc_bsdinfo()
                    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_status == UInt32(SSTOP)
                }.count
                let mutedNow = OutputMute.defaultDevice().map(OutputMute.isMuted) ?? false
                self.deactivate()
                let left = FileManager.default.fileExists(atPath: Recovery.stateURL.path)
                Log.write("lidtest opened: muted=\(mutedNow) still-paused=\(still) state-file=\(left)")
                NSApp.terminate(nil)
            }
        }
    }

    func toggle(_ s: AwakeSetting) {
        let on = !isOn(s)
        objectWillChange.send()
        if s == .notifications && on {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        defaults.set(on, forKey: s.key)
        if s == .shortcut { Engine.shared.updateHotKeys() }
        if s == .allowDisplaySleep && holding { takeAssertion() }
        if s == .lidClosed {
            if active { setLid(on) }
            if on { Recovery.installAgent() }
        }
        // Turning a lid action off while the lid is closed undoes it now.
        if lidActionsLive && LidObserver.shared.closed && !on {
            switch s {
            case .lidMute: unmute()
            case .lidFreeze: Freezer.thaw(recovery.frozen); recovery.frozen = []
            default: break
            }
        }
        updateLowPower()
        Engine.shared.onChange?()
    }

    func activate(minutes m: Int? = nil) {
        if let m { setMinutes(m) }
        start(until: minutes == 0 ? nil : Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func start(until end: Date?) {
        guard takeAssertion() else { return }
        if isOn(.lidClosed) && !lidApplied { setLid(true) }
        active = true
        endDate = end
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Awake.shared.onTick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        Engine.shared.onChange?()
    }

    func deactivate(reason: String? = nil) {
        guard active || holding || lidApplied || !recovery.isEmpty else { return }
        if holding { IOPMAssertionRelease(assertion) }
        holding = false
        undoLidActions()
        active = false
        updateLowPower()
        if lidApplied { setLid(false) }
        endDate = nil
        timer?.invalidate()
        timer = nil
        if let reason, isOn(.notifications) { notify(reason) }
        Engine.shared.onChange?()
    }

    func toggleActive() { active ? deactivate() : activate() }

    func setMinutes(_ m: Int) {
        minutes = m
        defaults.set(m, forKey: "awake.minutes")
    }

    var durationLabel: String {
        if minutes == 0 { return "∞" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)min" }
        return m == 0 ? "\(h)hr" : "\(h)hr \(m)min"
    }

    var remainingText: String? {
        guard active else { return nil }
        guard let endDate else { return "Until turned off" }
        let s = max(0, Int(endDate.timeIntervalSince(tick)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d left", h, m, sec) : String(format: "%d:%02d left", m, sec)
    }

    @discardableResult
    private func takeAssertion() -> Bool {
        if holding { IOPMAssertionRelease(assertion) }
        let type = (isOn(.allowDisplaySleep)
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString
        holding = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "MultiClaude keep-awake" as CFString, &assertion) == kIOReturnSuccess
        if !holding { NSSound.beep(); Log.write("keep-awake: power assertion refused") }
        return holding
    }

    private func onTick() {
        tick = Date()
        if let endDate, tick >= endDate { deactivate(reason: "Time is up, your Mac can sleep again."); return }
        // Floors every 30 s: critical heat ends the session, the rest is Low Power Mode.
        guard Int(tick.timeIntervalSince1970) % 30 == 0 else { return }
        if isOn(.heatRules) && ProcessInfo.processInfo.thermalState == .critical {
            deactivate(reason: "Your Mac got too hot, so it can sleep again.")
            return
        }
        updateLowPower()
    }

    // Lid-closed awake needs `pmset disablesleep`, which only root can set: password-free with the helper,
    // otherwise macOS asks for the administrator password.
    private func setLid(_ on: Bool) {
        if Root.pmset(["-a", "disablesleep", on ? "1" : "0"]) {
            lidApplied = on
            recovery.disableSleep = on
        }
    }

    // What this session changed, mirrored to disk for the recovery agent.
    private var recovery = Recovery.State() { didSet { if recovery != oldValue { Recovery.save(recovery) } } }
    private var mutedDevice: AudioObjectID?

    func lidChanged(_ closed: Bool) {
        guard lidActionsLive else { return }
        if closed {
            if isOn(.lidScreenOff) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                p.arguments = ["displaysleepnow"]
                try? p.run()
            }
            if isOn(.lidMute), let d = OutputMute.defaultDevice(), !OutputMute.isMuted(d), OutputMute.set(d, muted: true) {
                mutedDevice = d
                recovery.muted = true
            }
            if isOn(.lidFreeze) { recovery.frozen += Freezer.freeze() }
        } else {
            undoLidActions()
        }
        updateLowPower()
    }

    private func unmute() {
        guard recovery.muted else { return }
        if let d = mutedDevice ?? OutputMute.defaultDevice() { _ = OutputMute.set(d, muted: false) }
        mutedDevice = nil
        recovery.muted = false
    }

    private func undoLidActions() {
        Freezer.thaw(recovery.frozen)
        recovery.frozen = []
        unmute()
    }

    // Low Power Mode while the lid is closed, on battery below 40%, or when the Mac runs hot. Only with
    // the helper, so it never brings up a password prompt on its own. Turned off again only if we set it.
    private func updateLowPower() {
        let p = Power.snapshot()
        let hot = ProcessInfo.processInfo.thermalState
        let wanted = active && Root.installed && (
            (isOn(.lidLowPower) && lidActionsLive && LidObserver.shared.closed)
            || (isOn(.batteryLowPower) && !p.onAC && (p.percent ?? 100) < 40)
            || (isOn(.heatRules) && hot == .serious))
        if wanted && !recovery.lowPower && !Root.lowPowerOn() {
            if Root.pmset(["-b", "lowpowermode", "1"]) { recovery.lowPower = true; Log.write("Low Power Mode on") }
        } else if !wanted && recovery.lowPower {
            if Root.pmset(["-b", "lowpowermode", "0"]) { recovery.lowPower = false; Log.write("Low Power Mode off") }
        }
    }

    // A session MultiClaude didn't get to undo (crash, force quit): undo it at the next launch.
    private func undoLeftovers() {
        guard let text = try? String(contentsOf: Recovery.stateURL, encoding: .utf8) else { return }
        var v: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { v[kv[0]] = kv[1] }
        }
        Freezer.thaw((v["frozen"] ?? "").split(separator: " ").compactMap { pid_t($0) })
        if v["muted"] == "1", let d = OutputMute.defaultDevice() { _ = OutputMute.set(d, muted: false) }
        var left = Recovery.State()
        if v["lowpower"] == "1" { left.lowPower = !Root.pmset(["-b", "lowpowermode", "0"]) }
        if v["disablesleep"] == "1" { left.disableSleep = !Root.pmset(["-a", "disablesleep", "0"]) }
        Recovery.save(left)
        Log.write("undid the changes of a keep-awake session that ended without MultiClaude")
    }

    private func powerChanged() {
        let p = Power.snapshot()
        if p.onAC != lastOnAC {
            lastOnAC = p.onAC
            if p.onAC && isOn(.powerConnect) && !active { activate() }
            if !p.onAC && isOn(.powerDisconnect) && active { deactivate(reason: "Power disconnected.") }
        }
        if !p.onAC, active, isOn(.lowBattery), let pct = p.percent, pct < 20 {
            deactivate(reason: "Battery below 20%.")
        }
    }

    private func notify(_ body: String) {
        let c = UNMutableNotificationContent()
        c.title = "Keep Awake is off"
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

enum Power {
    static func snapshot() -> (onAC: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var pct: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                pct = cur * 100 / max
            }
        }
        return (type == kIOPMACPowerKey, pct)
    }
}

// Cocaine, the keep-awake app this part comes from, may run next to MultiClaude. Two scroll reversers
// would flip each event twice, so MultiClaude leaves a direction alone while Cocaine already reverses it.
enum Cocaine {
    static let bundleID = "me.somalabs.cocaine"

    static func reverses(mouse: Bool) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return false }
        CFPreferencesAppSynchronize(bundleID as CFString)
        return CFPreferencesGetAppBooleanValue((mouse ? "reverseMouse" : "reverseTrackpad") as CFString, bundleID as CFString, nil)
    }
}

// Flips scroll direction through a session event tap, which needs Accessibility permission.
// Trackpads send continuous events with a gesture phase (fingers down, then momentum). Wheel mice send
// line-based events, and mice with smooth scrolling (Logi Options+ on an MX Master) send continuous ones
// with no phase, so both follow the mouse switch. A Magic Mouse has phases, so it follows the trackpad switch.
@MainActor
enum ScrollReverser {
    // What the flip applies: the setting, minus any direction Cocaine already reverses.
    nonisolated(unsafe) static var reverseMouse = false
    nonisolated(unsafe) static var reverseTrackpad = false
    nonisolated(unsafe) static var tap: CFMachPort?
    static var source: CFRunLoopSource?
    static var waitTimer: Timer?
    static var cocaineMouse = false
    static var cocaineTrackpad = false

    static func update(mouse: Bool, trackpad: Bool) {
        cocaineMouse = mouse && Cocaine.reverses(mouse: true)
        cocaineTrackpad = trackpad && Cocaine.reverses(mouse: false)
        reverseMouse = mouse && !cocaineMouse
        reverseTrackpad = trackpad && !cocaineTrackpad
        guard reverseMouse || reverseTrackpad else { stop(); return }
        guard tap == nil else { return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            start()
        } else if waitTimer == nil {
            // Install the tap as soon as the person grants access in System Settings.
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    waitTimer?.invalidate()
                    waitTimer = nil
                    if reverseMouse || reverseTrackpad { start() }
                    Engine.shared.objectWillChange.send()
                }
            }
        }
    }

    // Shown next to the setting when it can't act yet.
    static func hint(mouse: Bool) -> String? {
        if mouse ? cocaineMouse : cocaineTrackpad { return "on in Cocaine" }
        if (mouse ? reverseMouse : reverseTrackpad) && tap == nil { return "needs Accessibility" }
        return nil
    }

    private static func start() {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = ScrollReverser.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .scrollWheel {
                ScrollReverser.flip(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { NSSound.beep(); Log.write("scroll: event tap refused"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func stop() {
        waitTimer?.invalidate()
        waitTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    nonisolated static func isTrackpad(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            && (e.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
                || e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
    }

    nonisolated static func flip(_ e: CGEvent) {
        guard isTrackpad(e) ? reverseTrackpad : reverseMouse else { return }
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ]
        for (line, fixed, point) in axes {
            let l = e.getIntegerValueField(line), f = e.getDoubleValueField(fixed), p = e.getIntegerValueField(point)
            e.setIntegerValueField(line, value: -l)
            e.setDoubleValueField(fixed, value: -f)
            e.setIntegerValueField(point, value: -p)
        }
    }
}

// MARK: - Usage and conversation archive

// Claude Code (the Code tab, Cowork and the terminal) logs every reply with its token counts in JSONL
// transcripts on this Mac. MultiClaude reads them, credits each session to the account whose folder lists
// it, and keeps a copy of every transcript, since Claude Code deletes old ones (30 days by default).
// Regular chats keep no token counts on the Mac; their usage limits come from claude.ai (see ChatLimits).

struct UsageTotals: Codable, Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, messages = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
             cacheRead: a.cacheRead + b.cacheRead, messages: a.messages + b.messages)
    }
}

// One transcript source: a folder of JSONL files, and whose files they are.
struct UsageSource {
    let root: URL
    let archiveName: String       // folder under Archive/<owner>/
    let owner: (_ file: URL) -> String   // profile id, or UsageScan.terminal
}

final class UsageScan: @unchecked Sendable {
    static let shared = UsageScan()
    static let terminal = "terminal"   // ~/.claude sessions no account folder lists: the CLI's own sign-in
    static let home = FileManager.default.homeDirectoryForCurrentUser

    struct FileMark: Codable { var offset: UInt64; var owner: String }
    struct State: Codable {
        var version = 1
        var files: [String: FileMark] = [:]
        var days: [String: [String: [String: UsageTotals]]] = [:]   // day -> owner -> model -> totals
    }

    let queue = DispatchQueue(label: "me.somalabs.multiclaude.usage", qos: .utility)
    var folder = supportDir.appendingPathComponent("MultiClaude")
    var archiveEnabled = true
    private var state = State()
    private var seen = Set<UInt64>()   // message ids already counted, so a reply copied into two files counts once
    private var loaded = false

    var stateURL: URL { folder.appendingPathComponent("usage.json") }
    var seenURL: URL { folder.appendingPathComponent("usage-seen.bin") }
    var archiveURL: URL { folder.appendingPathComponent("Archive") }

    // FNV-1a, stable across launches (Swift's own hash is not).
    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
        if let d = try? Data(contentsOf: seenURL) {
            d.withUnsafeBytes { raw in
                for i in 0..<(d.count / 8) { seen.insert(raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
            }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: stateURL, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        var ids = Array(seen)
        try? Data(bytes: &ids, count: ids.count * 8).write(to: seenURL, options: .atomic)
    }

    // Session id -> profile id, from each account's own list of Code and Cowork sessions.
    static func sessionOwners(_ profiles: [Profile]) -> [String: String] { sessionIndex(profiles).owners }

    // Also the titles Claude gave the sessions, for the conversation list.
    static func sessionIndex(_ profiles: [Profile]) -> (owners: [String: String], titles: [String: String]) {
        var map: [String: String] = [:], titles: [String: String] = [:]
        let fm = FileManager.default
        for p in profiles {
            let root = p.folderURL.appendingPathComponent("claude-code-sessions")
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in e where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                guard let d = try? Data(contentsOf: f),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let sid = j["cliSessionId"] as? String else { continue }
                map[sid] = p.id.uuidString
                if let title = j["title"] as? String, !title.isEmpty { titles[sid] = title }
            }
        }
        return (map, titles)
    }

    // The session a transcript belongs to: <id>.jsonl, or <id>/subagents/agent-*.jsonl.
    static func sessionID(of file: URL) -> String {
        let parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" { return parent.deletingLastPathComponent().lastPathComponent }
        return file.deletingPathExtension().lastPathComponent
    }

    static func sources(_ profiles: [Profile]) -> [UsageSource] {
        let owners = sessionOwners(profiles)
        var list = [UsageSource(root: home.appendingPathComponent(".claude/projects"), archiveName: "code") { f in
            owners[sessionID(of: f)] ?? terminal
        }]
        for p in profiles {
            let id = p.id.uuidString
            if let cfg = p.codeConfigDir {
                list.append(UsageSource(root: URL(fileURLWithPath: cfg).appendingPathComponent("projects"),
                                        archiveName: "code-" + URL(fileURLWithPath: cfg).lastPathComponent) { _ in id })
            }
            list.append(UsageSource(root: p.folderURL.appendingPathComponent("local-agent-mode-sessions"),
                                    archiveName: "cowork") { _ in id })
        }
        return list
    }

    // Reads what was added to each transcript since the last scan. Returns the totals for the panel.
    func scan(profiles: [Profile]) -> State { scan(sources: Self.sources(profiles)) }

    func scan(sources: [UsageSource]) -> State {
        load()
        let fm = FileManager.default
        var changed = false
        for src in sources {
            guard let e = fm.enumerator(at: src.root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let f as URL in e where f.pathExtension == "jsonl" {
                let path = f.path
                guard let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) else { continue }
                var mark = state.files[path] ?? FileMark(offset: 0, owner: src.owner(f))
                if size < mark.offset { mark.offset = 0 }   // rewritten: counted ids are skipped anyway
                guard size > mark.offset else { continue }
                mark.offset = autoreleasepool { read(f, from: mark.offset, owner: mark.owner) }
                state.files[path] = mark
                changed = true
                if archiveEnabled { archive(f, root: src.root, as: src.archiveName, owner: mark.owner) }
            }
        }
        if changed { save() }
        return state
    }

    // Parses complete lines from `offset`; returns the offset after the last complete line.
    private func read(_ f: URL, from offset: UInt64, owner: String) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: f) else { return offset }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        var pos = offset
        var carry = Data()
        let marker = Data("\"usage\"".utf8)
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                let line = carry[start..<nl]
                if line.range(of: marker) != nil { autoreleasepool { count(line, owner: owner) } }
                pos += UInt64(nl - start + 1)
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        return pos
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func count(_ line: Data, owner: String) {
        guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let m = j["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
              let model = m["model"] as? String, model != "<synthetic>" else { return }
        let key = (m["id"] as? String ?? "") + "|" + (j["requestId"] as? String ?? "")
        if key != "|" {
            guard seen.insert(Self.fnv(key)).inserted else { return }
        }
        let stamp = (j["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date()
        let day = Self.dayFormat.string(from: stamp)
        var t = UsageTotals()
        t.input = u["input_tokens"] as? Int ?? 0
        t.output = u["output_tokens"] as? Int ?? 0
        t.cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
        t.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
        t.messages = 1
        state.days[day, default: [:]][owner, default: [:]][model, default: UsageTotals()] =
            (state.days[day]?[owner]?[model] ?? UsageTotals()) + t
    }

    // APFS clone of the transcript under Archive/<owner>/<source>/<path>: takes no space while Claude
    // keeps the original, and survives Claude Code's cleanup.
    private func archive(_ f: URL, root: URL, as name: String, owner: String) {
        let rel = String(f.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dest = archiveURL.appendingPathComponent(owner).appendingPathComponent(name).appendingPathComponent(rel)
        let fm = FileManager.default
        // Transcripts hold whole conversations: only this user may open the archive.
        if !fm.fileExists(atPath: archiveURL.path) {
            try? fm.createDirectory(at: archiveURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".partial-" + dest.lastPathComponent)
        try? fm.removeItem(at: tmp)
        guard copyfile(f.path, tmp.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else { return }
        _ = try? fm.replaceItemAt(dest, withItemAt: tmp)
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
    }
}

// MARK: chat usage limits (opt-in)

// The share of each account's 5-hour and weekly limits, as claude.ai shows them. MultiClaude reads the
// account's claude.ai session cookie from its Claude folder (Chromium encrypts it with a key kept in the
// Keychain as "Claude Safe Storage", so macOS asks once) and asks claude.ai for the numbers. The cookie
// stays in memory, is only sent to claude.ai, and is never logged or written anywhere.
enum ChatLimits {
    struct Limit: Equatable { let percent: Double; let resetsAt: Date? }
    struct Snapshot: Equatable { var fiveHour: Limit?; var week: Limit?; var error: String? }

    nonisolated(unsafe) static var aesKey: Data?

    static func safeStorageKey() -> Data? {
        if let aesKey { return aesKey }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Safe Storage",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let pw = out as? Data else { return nil }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let rc = key.withUnsafeMutableBytes { k in
            pw.withUnsafeBytes { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     k.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard rc == kCCSuccess else { return nil }
        aesKey = key
        return key
    }

    // Chromium's v10 cookie format: "v10" + AES-128-CBC (IV of 16 spaces). Since cookie DB version 24 the
    // plaintext starts with a 32-byte hash of the domain.
    static func decrypt(_ blob: Data, key: Data, dbVersion: Int) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let body = blob.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = Data(count: body.count + 16)
        var moved = 0
        let outCount = out.count
        let rc = out.withUnsafeMutableBytes { o in
            body.withUnsafeBytes { b in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, 16, iv, b.baseAddress, body.count, o.baseAddress, outCount, &moved)
                }
            }
        }
        guard rc == kCCSuccess else { return nil }
        var plain = out.prefix(moved)
        if dbVersion >= 24 && plain.count > 32 { plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }

    static func sessionKey(in folder: URL, key: Data) -> String? {
        let db = folder.appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var h: OpaquePointer?
        // immutable=1 reads without taking Claude's lock.
        guard sqlite3_open_v2("file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?immutable=1", &h,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(h); return nil }
        defer { sqlite3_close(h) }
        var version = 0
        var st: OpaquePointer?
        if sqlite3_prepare_v2(h, "SELECT value FROM meta WHERE key='version'", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW {
            version = Int(String(cString: sqlite3_column_text(st, 0))) ?? 0
        }
        sqlite3_finalize(st)
        let q = "SELECT encrypted_value FROM cookies WHERE name='sessionKey' AND host_key LIKE '%claude.ai' ORDER BY expires_utc DESC LIMIT 1"
        guard sqlite3_prepare_v2(h, q, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        let blob = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
        return decrypt(blob, key: key, dbVersion: version)
    }

    static func get(_ path: String, _ cookie: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://claude.ai" + path)!, timeoutInterval: 20)
        req.setValue("sessionKey=" + cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("MultiClaude/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NSError(domain: "claude.ai", code: code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func parse(_ j: Any) -> Snapshot {
        func limit(_ k: String) -> Limit? {
            guard let d = (j as? [String: Any])?[k] as? [String: Any], let u = d["utilization"] as? Double else { return nil }
            return Limit(percent: u, resetsAt: (d["resets_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
        }
        return Snapshot(fiveHour: limit("five_hour"), week: limit("seven_day"))
    }

    static func fetch(folder: URL) async -> Snapshot {
        guard let key = safeStorageKey() else { return Snapshot(error: "Keychain access refused") }
        guard let cookie = sessionKey(in: folder, key: key) else { return Snapshot(error: "Not signed in") }
        do {
            guard let orgs = try await get("/api/organizations", cookie) as? [[String: Any]], !orgs.isEmpty else {
                return Snapshot(error: "No organization")
            }
            let org = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs[0]
            guard let uuid = org["uuid"] as? String else { return Snapshot(error: "No organization") }
            return parse(try await get("/api/organizations/\(uuid)/usage", cookie))
        } catch {
            let code = (error as NSError).code
            Log.write("chat limits: claude.ai answered \(code)")
            return Snapshot(error: code == 401 || code == 403 ? "claude.ai refused (\(code))" : "Couldn't reach claude.ai")
        }
    }
}

// MARK: usage model for the panel and the window

@MainActor
final class Usage: ObservableObject {
    static let shared = Usage()

    @Published private(set) var days: [String: [String: [String: UsageTotals]]] = [:]
    @Published private(set) var limits: [String: ChatLimits.Snapshot] = [:]   // profile id -> limits
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    private var timer: Timer?
    private var limitsAt: Date?

    // Sample numbers for README and website screenshots (MULTICLAUDE_DEMO=1): six months, busier on weekdays.
    func loadDemo() {
        let cal = Calendar.current
        var rng: UInt64 = 42
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
        var out: [String: [String: [String: UsageTotals]]] = [:]
        let profiles = Engine.shared.profiles
        for back in 0..<180 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let weekend = cal.isDateInWeekend(day)
            for (i, p) in profiles.enumerated() {
                let r = next()
                guard r > (weekend ? 0.6 : 0.15) + Double(i) * 0.12 else { continue }
                let scale = (1.0 - Double(i) * 0.22) * (0.3 + r) * (back < 90 ? 1.0 : 0.55)
                let o = Int(160_000 * scale)
                let model = r > 0.8 ? "claude-sonnet-5-5" : "claude-opus-5-5"
                out[UsageScan.dayFormat.string(from: day), default: [:]][p.id.uuidString] =
                    [model: UsageTotals(input: o / 30, output: o, cacheWrite: o * 6, cacheRead: o * 90, messages: max(1, o / 420))]
            }
        }
        days = out
        lastScan = Date()
    }

    func start() {
        if isDemo { loadDemo(); return }
        guard timer == nil else { return }
        timer = Timer(timeInterval: 120, repeats: true) { _ in MainActor.assumeIsolated { Usage.shared.refresh() } }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Usage.shared.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = false) {
        guard !isDemo else { return }
        let e = Engine.shared
        if e.isOn(.trackUsage) && !scanning {
            scanning = true
            let profiles = e.profiles
            let archive = e.isOn(.archiveCode)
            UsageScan.shared.queue.async {
                UsageScan.shared.archiveEnabled = archive
                let s = UsageScan.shared.scan(profiles: profiles)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Usage.shared.days = s.days
                        Usage.shared.scanning = false
                        Usage.shared.lastScan = Date()
                    }
                }
            }
        }
        if e.isOn(.chatLimits), force || limitsAt.map({ -$0.timeIntervalSinceNow > 290 }) ?? true {
            limitsAt = Date()
            let folders = e.profiles.map { ($0.id.uuidString, $0.folderURL) }
            Task.detached {
                var out: [String: ChatLimits.Snapshot] = [:]
                for (id, f) in folders { out[id] = await ChatLimits.fetch(folder: f) }
                let snapshot = out
                await MainActor.run { Usage.shared.limits = snapshot }
            }
        } else if !e.isOn(.chatLimits) && !limits.isEmpty {
            limits = [:]
            ChatLimits.aesKey = nil
        }
    }

    // Totals per owner (profile id or "terminal") over the last `days` days, today included; 0 = all time.
    func totals(days n: Int) -> [String: UsageTotals] {
        var out: [String: UsageTotals] = [:]
        for (day, owners) in days where Self.inRange(day, n) {
            for (owner, models) in owners { out[owner] = models.values.reduce(out[owner] ?? UsageTotals(), +) }
        }
        return out
    }

    func byModel(days n: Int) -> [(String, UsageTotals)] {
        var out: [String: UsageTotals] = [:]
        for (day, owners) in days where Self.inRange(day, n) {
            for models in owners.values { for (m, t) in models { out[m] = (out[m] ?? UsageTotals()) + t } }
        }
        return out.sorted { $0.value.total > $1.value.total }
    }

    // Day -> totals, for one account or all of them.
    func perDay(owner: String?) -> [String: UsageTotals] {
        days.mapValues { owners in
            owners.filter { owner == nil || $0.key == owner }.values.flatMap(\.values).reduce(UsageTotals(), +)
        }
    }

    static func inRange(_ day: String, _ n: Int) -> Bool {
        guard n > 0, let start = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Calendar.current.startOfDay(for: Date()))
        else { return true }
        return day >= UsageScan.dayFormat.string(from: start)
    }

    static func ownerName(_ owner: String) -> String {
        if owner == UsageScan.terminal { return "Terminal" }
        return Engine.shared.profiles.first { $0.id.uuidString == owner }?.name ?? "Removed profile"
    }

    static func ownerTint(_ owner: String) -> Color {
        Engine.shared.profiles.first { $0.id.uuidString == owner }?.tint ?? .secondary
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }
}

// MARK: archived conversations

struct ArchivedSession: Identifiable, Hashable {
    let id: String        // file path
    let owner: String
    let title: String
    let project: String
    let date: Date
    let size: Int
}

enum ArchiveIndex {
    // Main transcripts only (not subagents), newest first. Reads the first 256 KB of each for a title.
    static func list(titles: [String: String] = [:]) -> [ArchivedSession] {
        let root = UsageScan.shared.archiveURL
        let fm = FileManager.default
        var out: [ArchivedSession] = []
        guard let owners = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        for owner in owners where !owner.hasPrefix(".") {
            guard let e = fm.enumerator(at: root.appendingPathComponent(owner),
                                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let f as URL in e where f.pathExtension == "jsonl" && !f.path.contains("/subagents/")
                && !f.lastPathComponent.hasPrefix(".partial-") && f.lastPathComponent != "audit.jsonl" {
                let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let (title, project) = summary(f)
                guard let title else { continue }
                out.append(ArchivedSession(id: f.path, owner: owner, title: titles[UsageScan.sessionID(of: f)] ?? title, project: project,
                                           date: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    static func summary(_ f: URL) -> (String?, String) {
        guard let h = try? FileHandle(forReadingFrom: f) else { return (nil, "") }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 << 10)) ?? Data()
        var title: String?, custom: String?, cwd = ""
        for line in data.split(separator: 0x0A) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let t = j["customTitle"] as? String { custom = t }
            if cwd.isEmpty, let c = j["cwd"] as? String { cwd = c }
            if title == nil, j["type"] as? String == "user", (j["isMeta"] as? Bool) != true,
               let text = Transcript.text(of: j["message"]), !text.hasPrefix("<") {
                title = String(text.prefix(90)).replacingOccurrences(of: "\n", with: " ")
            }
            if title != nil && custom != nil { break }
        }
        return (custom ?? title, URL(fileURLWithPath: cwd).lastPathComponent)
    }
}

enum Transcript {
    struct Turn: Identifiable { let id: Int; let role: String; let text: String }

    static func text(of message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = m["content"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { b -> String? in
            switch b["type"] as? String {
            case "text": return b["text"] as? String
            case "tool_use": return "_[\(b["name"] as? String ?? "tool")]_"
            default: return nil
            }
        }
        let s = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // User prompts and Claude's replies, without tool results or system lines.
    static func turns(_ path: String) -> [Turn] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var out: [Turn] = []
        var lastAssistant: String?
        for line in data.split(separator: 0x0A) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = j["type"] as? String, type == "user" || type == "assistant",
                  (j["isMeta"] as? Bool) != true, (j["isSidechain"] as? Bool) != true,
                  let text = text(of: j["message"]), !text.hasPrefix("<") else { continue }
            // Claude Code writes one line per content block of a reply; merge them back.
            let mid = (j["message"] as? [String: Any])?["id"] as? String
            if type == "assistant", let mid, mid == lastAssistant, let last = out.popLast() {
                out.append(Turn(id: last.id, role: "assistant", text: last.text + "\n\n" + text))
                continue
            }
            lastAssistant = type == "assistant" ? mid : nil
            out.append(Turn(id: out.count, role: type, text: text))
        }
        return out
    }

    static func markdown(_ s: ArchivedSession, account: String) -> String {
        var md = "# \(s.title)\n\n"
        md += "\(account) · \(s.project) · \(s.date.formatted(date: .abbreviated, time: .shortened))\n\n"
        for t in turns(s.id) { md += "## \(t.role == "user" ? "You" : "Claude")\n\n\(t.text)\n\n" }
        return md
    }
}

// MARK: - App icon (drawn, so the bundle needs no image files)

enum AppIcon {
    // MultiClaude's own icon: the Claude asterisk on an orange tile.
    static func image(_ side: CGFloat) -> NSImage { tile(side, color: .claude, letter: nil) }

    // A tile in `color` with the white asterisk, or with `letter` and a small asterisk in the corner
    // (the icon of a profile's app).
    static func tile(_ side: CGFloat, color: NSColor, letter: String?) -> NSImage {
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
            color.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            let base = color.usingColorSpace(.sRGB) ?? color
            NSGradient(colors: [base.blended(withFraction: 0.18, of: .white) ?? base,
                                base.blended(withFraction: 0.12, of: .black) ?? base])?.draw(in: path, angle: -90)
            func asterisk(size: CGFloat, center: NSPoint) {
                let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                    .applying(.init(paletteColors: [.white]))
                guard let sym = NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
                let s = sym.size
                sym.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
            }
            guard let letter, !letter.isEmpty else {
                asterisk(size: tile.width * 0.5, center: NSPoint(x: tile.midX, y: tile.midY))
                return true
            }
            let font = NSFont.systemFont(ofSize: tile.width * 0.56, weight: .bold)
            let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
            let text = NSAttributedString(string: letter, attributes: [.font: rounded, .foregroundColor: NSColor.white])
            let ts = text.size()
            text.draw(at: NSPoint(x: tile.midX - ts.width / 2, y: tile.midY - ts.height / 2 - tile.height * 0.03))
            asterisk(size: tile.width * 0.15, center: NSPoint(x: tile.maxX - tile.width * 0.2, y: tile.maxY - tile.height * 0.2))
            return true
        }
    }

    // A profile's icon: Claude's own icon, read from Claude.app, with its orange turned to the profile's
    // color. The dark tile stays as it is. Falls back to a letter tile when Claude.app can't be read.
    static func profile(_ side: CGFloat, color: NSColor, letter: String) -> NSImage {
        claudeTinted(side, color: color) ?? tile(side, color: color, letter: letter)
    }

    static func claudeTinted(_ side: CGFloat, color: NSColor) -> NSImage? {
        // icon(forFile:) hands back a generic app icon for a missing path; the letter tile is better then.
        let claude = realClaudeApp()
        guard FileManager.default.fileExists(atPath: claude.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        let src = NSWorkspace.shared.icon(forFile: claude.path)
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let orange = NSColor.claude.usingColorSpace(.sRGB)!, target = color.usingColorSpace(.sRGB) ?? color
        var image = CIImage(cgImage: cg)
        // Rotate the hue from Claude orange to the target; a grey target drains the color instead.
        let hue = CIFilter(name: "CIHueAdjust")!
        hue.setValue(image, forKey: kCIInputImageKey)
        hue.setValue((target.hueComponent - orange.hueComponent) * 2 * .pi, forKey: kCIInputAngleKey)
        image = hue.outputImage ?? image
        let controls = CIFilter(name: "CIColorControls")!
        controls.setValue(image, forKey: kCIInputImageKey)
        controls.setValue(min(1.2, target.saturationComponent / max(orange.saturationComponent, 0.01)), forKey: kCIInputSaturationKey)
        image = controls.outputImage ?? image
        guard let out = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }

    // The profile icon as a Finder custom icon: one 8-bit sRGB bitmap per icns size. NSWorkspace.setIcon
    // faults inside IconServices when given a single large rep (seen on macOS 27), so every size is explicit.
    static func finderIcon(color: NSColor, letter: String) -> NSImage {
        let art = claudeTinted(1024, color: color)
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        for (pt, scale) in [16, 32, 128, 256, 512].flatMap({ pt in [(pt, 1), (pt, 2)] }) {
            let px = pt * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            (art ?? tile(CGFloat(px), color: color, letter: letter)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: pt, height: pt)
            icon.addRepresentation(rep)
        }
        return icon
    }

    static func png(_ image: NSImage, pixels px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // An .icns file with every size, written with ImageIO so no command-line tool is needed.
    static func icns(_ draw: (CGFloat) -> NSImage) -> Data? {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "com.apple.icns" as CFString, sizes.count, nil) else { return nil }
        for px in sizes {
            guard let data = png(draw(CGFloat(px)), pixels: px),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, nil)
        }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // build.sh calls `MultiClaude --export-iconset <dir>` to make the .icns.
    static func exportIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png(image(CGFloat(px)), pixels: px)?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
        }
    }
}

// MARK: - Profile apps

// The Claude that runs for a profile while profile apps are on: an APFS clone of Claude.app (clonefile,
// instant and free on disk) in a .noindex folder, so Spotlight lists only the launcher. The clone wears the
// profile's icon as a Finder custom icon (outside the signed Contents folder), which macOS shows for the
// running window in the Dock, ⌘-Tab and Mission Control. Nothing inside the bundle changes, so the
// signature stays valid: Gatekeeper accepts it, the Keychain still hands it "Claude Safe Storage", and
// Claude still names its own folders "Claude". Tested 2026-10-10: adding an InfoPlist.strings to rename the
// running app breaks the resource seal and Gatekeeper then calls the copy damaged at every launch, so the
// running window keeps the name Claude. A clone is refreshed from Claude.app when Claude updates, only
// while that profile is closed; one that Claude's updater moved ahead is restyled in place.
enum Runtimes {
    static let folder = supportDir.appendingPathComponent("MultiClaude/Runtimes.noindex")
    static let format = 3   // a stamp from another format means the copy is rebuilt from scratch

    // folder/<profile id>/<app name>.app: macOS names the running app after the bundle's file name.
    static func dir(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString) }
    static func stampURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("stamp") }
    static func target(_ p: Profile) -> URL { dir(p.id).appendingPathComponent(Launchers.fileName(p.dockAppName)) }
    static func current(_ id: UUID) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: dir(id), includingPropertiesForKeys: nil)) ?? [])
            .first { $0.pathExtension == "app" }
    }
    static func exists(_ id: UUID) -> Bool { current(id) != nil }

    // The profile id of a copy's bundle URL, or nil for any other Claude.
    static func owner(of app: URL) -> UUID? {
        let parent = app.standardizedFileURL.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return nil }
        return UUID(uuidString: parent.lastPathComponent)
    }

    static func version(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    static func stamp(_ p: Profile, version: String) -> String {
        "\(format)|\(version)|\(p.dockAppName)|\(p.initial)|\(p.color ?? 0)"
    }

    static func isRunning(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    // The profile's own Claude, made or refreshed as needed, or nil when it can't be (not APFS, no Claude).
    // Never touches a copy that is running.
    static func ensure(_ p: Profile, from claude: URL, running: (URL) -> Bool = isRunning) -> URL? {
        let fm = FileManager.default
        let want = target(p)
        guard let sourceVersion = version(claude) else { return current(p.id) }
        if var rt = current(p.id) {
            if running(rt) {
                // Only the icon can change under a running copy: it sits outside the bundle's code.
                let stamped = (try? String(contentsOf: stampURL(p.id), encoding: .utf8)) ?? ""
                let current = version(rt) ?? ""
                if stamped.hasPrefix("\(format)|"), stamped != stamp(p, version: current) {
                    applyLook(p, to: rt, version: current, register: false)
                }
                return rt
            }
            if rt.lastPathComponent != want.lastPathComponent, (try? fm.moveItem(at: rt, to: want)) != nil { rt = want }
            let current = version(rt) ?? ""
            let stamped = (try? String(contentsOf: stampURL(p.id), encoding: .utf8)) ?? ""
            if stamped.hasPrefix("\(format)|"), current == sourceVersion || Updater.isNewer(current, than: sourceVersion) {
                if stamped == stamp(p, version: current) && hasLook(rt) { return rt }
                // macOS guards an app bundle once it has run (App Management), so the icon can fail on an
                // older copy. A fresh clone isn't guarded yet: same version, so it is made again below.
                if applyLook(p, to: rt, version: current) || current != sourceVersion { return rt }
                Log.write("profile copy \(rt.lastPathComponent): made again to take its icon")
            }
            try? fm.removeItem(at: rt)
        }
        try? fm.createDirectory(at: dir(p.id), withIntermediateDirectories: true)
        // clonefile copies the whole bundle as one APFS clone; it fails rather than copy on other volumes.
        let source = claude.resolvingSymlinksInPath()
        guard clonefile(source.path, want.path, 0) == 0 else {
            let why = String(cString: strerror(errno))
            Log.write("profile copy for \(p.name) not made (\(why)); it runs from Claude.app")
            if (try? fm.contentsOfDirectory(atPath: dir(p.id).path))?.filter({ $0 != "stamp" }).isEmpty == true {
                try? fm.removeItem(at: dir(p.id))
            }
            return nil
        }
        applyLook(p, to: want, version: sourceVersion)
        return want
    }

    // A folder's custom icon lives in an "Icon\r" file at its root, outside the sealed Contents.
    static func hasLook(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent("Icon\r").path)
    }

    @discardableResult
    static func applyLook(_ p: Profile, to app: URL, version: String, register: Bool = true) -> Bool {
        let fm = FileManager.default
        let ok = NSWorkspace.shared.setIcon(AppIcon.finderIcon(color: p.nsTint, letter: p.initial), forFile: app.path, options: [])
        Log.write("profile copy \(app.lastPathComponent): icon \(ok ? "set" : "FAILED"), Claude \(version)")
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        if register { LSRegisterURL(app as CFURL, true) }
        // Written even when the icon failed: ensure() also checks hasLook, so a closed copy tries again.
        try? Data(stamp(p, version: version).utf8).write(to: stampURL(p.id))
        return ok
    }

    // Deletes the copies of profiles that are gone (or of all, with profile apps off), unless running.
    static func prune(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            if let rt = current(id), isRunning(rt) { continue }
            try? fm.removeItem(at: dir(id))
        }
    }
}


// One small app per profile in ~/Applications/MultiClaude Launchers, named and colored after the profile,
// so the Dock, Spotlight and Launchpad can tell accounts apart. Its executable is a shell script that asks
// MultiClaude to open the profile (multiclaude://open?profile=<id>) and opens Claude directly when
// MultiClaude is gone. Claude's own window keeps Claude's name and icon: editing Claude.app's Info.plist
// breaks its signature and macOS kills it at launch, and a copy of the bundle keeps Claude's icon (tested
// 2026-10-10 on Claude 1.x, macOS 27).
enum Launchers {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MultiClaude Launchers")
    static let idPrefix = "me.somalabs.multiclaude.launcher."
    static let format = 3   // bump when the bundle layout, the script or the icon changes, so every app is rewritten

    struct SyncResult {
        var moved: [(from: URL, to: URL)] = []
        var removed: [URL] = []
        var rewritten: [URL] = []   // existing apps whose name, color or folder changed
        var failed: [String] = []
    }

    // "Claude Work" -> "Claude Work.app", with the characters Finder can't show in a name replaced.
    static func fileName(_ name: String) -> String {
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // File names stop at 255 bytes; leave room for ".app", a " 2" and the hidden temporary names.
        while clean.utf8.count > 200 { clean.removeLast() }
        return (clean.isEmpty ? "Claude" : clean) + ".app"
    }

    static func script(for p: Profile) -> String {
        let rt = shellQuote(Runtimes.dir(p.id).path), real = shellQuote(realClaudeApp().path)
        let fallback = "app=$(ls -d \(rt)/*.app 2>/dev/null | head -n 1); [ -d \"$app\" ] || app=\(real)\n"
            + (p.dir.map { "exec /usr/bin/open -n -a \"$app\" --args \(shellQuote("--user-data-dir=" + $0))" } ?? "exec /usr/bin/open -a \"$app\"")
        return """
        #!/bin/sh
        # Made by MultiClaude for the profile \(shellQuote(String(p.name.filter { !$0.isNewline }))). MultiClaude rewrites this app; edits are lost.
        /usr/bin/open -g "multiclaude://open?profile=\(p.id.uuidString)" 2>/dev/null && exit 0
        \(fallback)

        """
    }

    // Everything that shows in the app; a change in any of it rewrites the app.
    static func stamp(for p: Profile, name: String) -> String {
        "\(format)|\(name)|\(p.initial)|\(p.color ?? 0)|\(p.dir ?? "")|\(p.name)"
    }

    static func info(for p: Profile, name: String) -> [String: Any] {
        [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": idPrefix + p.id.uuidString.lowercased(),
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "icon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "\(format)",
            "LSUIElement": true,   // the script quits at once; no Dock bounce of its own
            "MCProfileID": p.id.uuidString,
            "MCStamp": stamp(for: p, name: name),
        ]
    }

    static func readInfo(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // The profile apps in `folder`, by profile. Other apps a user puts there are left alone.
    static func installed(in folder: URL) -> [UUID: URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var out: [UUID: URL] = [:]
        for app in items where app.pathExtension == "app" {
            guard let info = readInfo(app), (info["CFBundleIdentifier"] as? String)?.hasPrefix(idPrefix) == true,
                  let id = (info["MCProfileID"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            out[id] = app
        }
        return out
    }

    // Builds the app next to its destination, then swaps it in, so a half-written app never shows up.
    static func write(_ p: Profile, name: String, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(p.id.uuidString).tmp.app")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }   // left over only when a step below failed
        let contents = tmp.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info(for: p, name: name), format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        let exe = contents.appendingPathComponent("MacOS/launch")
        try Data(script(for: p).utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        guard let icon = AppIcon.icns({ AppIcon.profile($0, color: p.nsTint, letter: p.initial) }) else { throw CocoaError(.fileWriteUnknown) }
        try icon.write(to: contents.appendingPathComponent("Resources/icon.icns"))
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        // New modification date + re-registration, so Finder, the Dock and Spotlight drop the old icon and name.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        LSRegisterURL(dest as CFURL, true)
    }

    // Makes `folder` hold exactly one up-to-date app per profile in `profiles`.
    static func sync(_ profiles: [Profile], in folder: URL) -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        var have = installed(in: folder)
        for (id, url) in have where !profiles.contains(where: { $0.id == id }) {
            if (try? fm.removeItem(at: url)) != nil { result.removed.append(url) }
            else { Log.write("profile app \(url.lastPathComponent): couldn't remove it") }
            have[id] = nil
        }
        // Hidden apps left by a run cut short (see write and the renames below).
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(".") && (name.hasSuffix(".tmp.app") || name.hasSuffix(".move.app")) {
            guard let id = UUID(uuidString: String(name.dropFirst().prefix(36))), have[id] == nil else { continue }
            let url = folder.appendingPathComponent(name)
            if name.hasSuffix(".move.app"), profiles.contains(where: { $0.id == id }) { have[id] = url } else { try? fm.removeItem(at: url) }
        }
        guard !profiles.isEmpty else { return result }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken: Set<String> = ["claude.app"]   // never shadow Claude itself
        var names: [UUID: String] = [:]
        for p in profiles {
            // Two profiles can't share a file name; the later one gets a number.
            // The base is shortened first so the number survives fileName's length cap.
            var name = p.dockAppName, n = 2
            var base = p.dockAppName
            while base.utf8.count > 180 { base.removeLast() }
            while taken.contains(fileName(name).lowercased()) {
                name = n < 1000 ? "\(base) \(n)" : "\(base) \(p.id.uuidString.prefix(8))"
                n += 1
            }
            taken.insert(fileName(name).lowercased())
            names[p.id] = name
        }
        // Apps that change name step aside under a hidden name first, so two profiles can swap names
        // (after a reorder) without each one finding the other's app in its way.
        var origin: [UUID: URL] = [:]
        for p in profiles {
            guard let current = have[p.id], let name = names[p.id],
                  current.lastPathComponent != fileName(name) else { continue }
            let aside = folder.appendingPathComponent(".\(p.id.uuidString).move.app")
            if current.lastPathComponent == aside.lastPathComponent { continue }   // already aside from a cut-short run
            try? fm.removeItem(at: aside)
            if (try? fm.moveItem(at: current, to: aside)) != nil { origin[p.id] = current; have[p.id] = aside }
        }
        for p in profiles {
            guard let name = names[p.id] else { continue }
            let dest = folder.appendingPathComponent(fileName(name))
            if let current = have[p.id] {
                let same = current.standardizedFileURL == dest.standardizedFileURL
                if same, readInfo(current)?["MCStamp"] as? String == stamp(for: p, name: name) { continue }
                if !same {
                    let from = origin[p.id] ?? current
                    if fm.fileExists(atPath: dest.path) {
                        // Something MultiClaude didn't make holds the name: put the app back and report it.
                        if let back = origin[p.id] { try? fm.moveItem(at: current, to: back) }
                        Log.write("profile app \(dest.lastPathComponent): the name is taken by another file")
                        result.failed.append(p.name); continue
                    }
                    do { try fm.moveItem(at: current, to: dest); result.moved.append((from, dest)) }
                    catch {
                        Log.write("profile app \(dest.lastPathComponent): \(error.localizedDescription)")
                        result.failed.append(p.name); continue
                    }
                }
            } else if fm.fileExists(atPath: dest.path) {
                result.failed.append(p.name); continue   // a file MultiClaude didn't make; leave it
            }
            do {
                try write(p, name: name, to: dest)
                if have[p.id] != nil { result.rewritten.append(dest) }
            } catch {
                Log.write("profile app \(dest.lastPathComponent): \(error.localizedDescription)")
                result.failed.append(p.name)
            }
        }
        return result
    }
}

// The Dock's pinned apps live in com.apple.dock's persistent-apps. MultiClaude only touches entries
// for its own profile apps, and only when the user pins one or one of them moves or goes away.
enum Dock {
    static let domain = "com.apple.dock" as CFString
    // Tiles taken off for an icon refresh and not put back yet; run at quit so they're never lost.
    nonisolated(unsafe) static var pendingRestore: (() -> Void)?

    // nil when the Dock's list can't be read; writing then would replace every pinned app.
    static func entries() -> [[String: Any]]? {
        guard let value = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) else { return [] }
        return value as? [[String: Any]]
    }

    static func path(of entry: [String: Any]) -> String? {
        guard let tile = entry["tile-data"] as? [String: Any], let file = tile["file-data"] as? [String: Any],
              let s = file["_CFURLString"] as? String else { return nil }
        return (URL(string: s)?.path ?? s).replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    static func entry(for app: URL) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["file-label": app.deletingPathExtension().lastPathComponent,
                       "file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15]]]
    }

    static func contains(_ app: URL) -> Bool {
        (entries() ?? []).contains { path(of: $0) == app.standardizedFileURL.path }
    }

    @discardableResult
    private static func write(_ list: [[String: Any]]) -> Bool {
        CFPreferencesSetAppValue("persistent-apps" as CFString, list as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { Log.write("Dock: couldn't save its app list"); return false }
        // The Dock reads its tiles at start only.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        return true
    }

    @discardableResult
    static func add(_ app: URL) -> Bool {
        guard var list = entries() else { Log.write("Dock: app list unreadable, not adding \(app.lastPathComponent)"); return false }
        if list.contains(where: { path(of: $0) == app.standardizedFileURL.path }) { return true }
        list.append(entry(for: app))
        return write(list)
    }

    // Points moved apps' tiles at their new path and drops the tiles of removed apps.
    // The Dock keeps a pinned app's old icon even across restarts, so a tile in `refresh` is taken off
    // the Dock and put back in the same place a moment later, which makes the Dock read the new icon.
    static func update(moved: [(from: URL, to: URL)], removed: [URL], refresh: [URL] = []) {
        let gone = Set(removed.map(\.standardizedFileURL.path))
        let moves = Dictionary(moved.map { ($0.from.standardizedFileURL.path, $0.to) }, uniquingKeysWith: { a, _ in a })
        let redo = Set(refresh.map(\.standardizedFileURL.path))
        guard let current = entries() else { Log.write("Dock: app list unreadable, left as it is"); return }
        var changed = false, refreshing = false
        var list: [[String: Any]] = [], without: [[String: Any]] = []
        for e in current {
            guard let p = path(of: e) else { list.append(e); without.append(e); continue }
            if gone.contains(p) { changed = true; continue }
            let to = moves[p]
            let path = to?.standardizedFileURL.path ?? p
            // A fresh entry, without the Dock's GUID, so it doesn't reuse the cached icon.
            let final = to != nil || redo.contains(path) ? entry(for: URL(fileURLWithPath: path)) : e
            if to != nil { changed = true }
            list.append(final)
            if redo.contains(path) { refreshing = true } else { without.append(final) }
        }
        guard refreshing else { if changed { write(list) }; return }
        write(without)
        // Once the Dock is back up, put the tiles back where they were. Re-read first so a change the user
        // made in between stays; only our own tiles are re-inserted.
        let back = list
        pendingRestore = {
            pendingRestore = nil
            guard var now = entries() else { return }
            let have = Set(now.compactMap(path(of:)))
            for (i, e) in back.enumerated() {
                guard let p = path(of: e), redo.contains(p), !have.contains(p) else { continue }
                now.insert(e, at: min(i, now.count))
            }
            write(now)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pendingRestore?() }
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
            if let app = engine.launcherURL(profile) {
                if Dock.contains(app) {
                    Button("Remove \(profile.dockAppName) from Dock") { engine.removeFromDock(profile) }
                } else {
                    Button("Add \(profile.dockAppName) to Dock") { engine.addToDock(profile) }
                }
                Button("Rename App…") { Dialogs.renameApp(profile) }
                Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
            } else {
                Button("Add \(profile.dockAppName) to Dock") { engine.addToDock(profile) }
            }
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
                Button("Delete Profile…", role: .destructive) { Dialogs.delete(profile) }
            }
        }
    }
}

// Confirmations for actions that quit a window or write into a profile's folder.
@MainActor
enum Dialogs {
    static func confirmHelper() -> Bool {
        alert("Keep the Mac awake with the lid closed, without a password?",
              "MultiClaude adds a rule in /etc/sudoers.d/multiclaude so four commands run without your password: pmset -a disablesleep 1 and 0, and pmset -b lowpowermode 1 and 0. They only change sleep and Low Power Mode, but any app running as you could run them too. macOS asks for your password once to install it. A recovery agent also checks every minute and undoes a session's changes if MultiClaude isn't running.",
              buttons: ["Install", "Cancel"]).0 == 0
    }

    static func confirmRemoveHelper() -> Bool {
        alert("Remove Password-Free Lid Mode?", "MultiClaude deletes /etc/sudoers.d/multiclaude. Keeping the Mac awake with the lid closed will ask for your password again.",
              buttons: ["Remove", "Cancel"]).0 == 0
    }

    // Chat limits read each account's claude.ai session cookie, so ask before the first time.
    static func confirmChatLimits() -> Bool {
        alert("Show each account's chat limits?",
              "claude.ai keeps the 5-hour and weekly limits, not your Mac. To ask for them, MultiClaude reads each account's claude.ai sign-in cookie from its Claude folder (macOS asks you to allow \"Claude Safe Storage\" in the Keychain) and sends it to claude.ai only, every few minutes. It is kept in memory, never written or logged. This uses an endpoint claude.ai doesn't document, so it may stop working.",
              buttons: ["Show Chat Limits", "Cancel"]).0 == 0
    }

    static func delete(_ p: Profile) {
        let running = Engine.shared.isRunning(p)
        let (choice, _) = alert("Delete \u{201C}\(p.name)\u{201D}?",
                                (running ? "\(p.name) will be closed. " : "")
                                + "Its data folder (the sign-in and chats), its Claude Code folder and its app are removed. The folders go to the Trash, so you can still put them back from there.",
                                buttons: ["Cancel", "Move to Trash"], style: .warning)
        guard choice == 1 else { return }
        Engine.shared.delete(p)
    }

    static func alert(_ title: String, _ text: String, buttons: [String], field: String? = nil, style: NSAlert.Style = .informational) -> (Int, String) {
        PanelController.shared.close()
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
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

    static func renameApp(_ p: Profile) {
        let (choice, name) = alert("Rename \(p.dockAppName)",
                                   "This name shows in the Dock, Spotlight and Launchpad. Leave it empty to go back to \"\(Profile(name: p.name, dir: p.dir).dockAppName)\". The Claude window itself keeps the name Claude.",
                                   buttons: ["Rename", "Cancel"], field: p.dockAppName)
        guard choice == 0 else { return }
        Engine.shared.renameApp(p, to: name)
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

struct ToggleRow: View {
    let symbol: String
    let title: String
    let hint: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Badge(on: on) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            Text(title).font(.system(size: 13)).foregroundStyle(.primary.opacity(on ? 1 : 0.75))
            Spacer(minLength: 4)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(HoverBackground(radius: 8))
        .onTapGesture(perform: action)
    }
}

struct SettingRow: View {
    let setting: Setting
    @ObservedObject var engine = Engine.shared

    var body: some View {
        let scrollHint = setting == .reverseMouse || setting == .reverseTrackpad
            ? ScrollReverser.hint(mouse: setting == .reverseMouse) : nil
        ToggleRow(symbol: setting.symbol, title: setting.title, hint: scrollHint ?? setting.hint,
                  on: engine.isOn(setting)) { engine.toggle(setting) }
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

struct Chip<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false

    var body: some View {
        label
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(selected ? Color.claude : Color.primary.opacity(hover ? 0.2 : 0.12)))
            .contentShape(Circle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

struct Dot: View {
    var body: some View { Circle().fill(Color.primary.opacity(0.25)).frame(width: 4, height: 4) }
}

// Duration chips: ∞, 15/30/45 min, 1/2/4/8 h, and a gear that opens a 5 min to 24 h slider.
struct DurationRow: View {
    @ObservedObject var awake = Awake.shared
    @AppStorage("awake.sliderOpen") private var sliderOpen = false

    private func chip(_ m: Int) -> some View {
        Chip(selected: !sliderOpen && awake.active && awake.minutes == m, action: {
            sliderOpen = false
            awake.activate(minutes: m)
        }) {
            if m == 0 {
                Image(systemName: "infinity").font(.system(size: 12, weight: .bold))
            } else {
                Text(m < 60 ? "\(m)" : String(format: "%02d", m / 60))
                    .font(.system(size: 13, weight: .semibold)).fontWidth(.condensed).monospacedDigit()
            }
        }
        .help(m == 0 ? "Until turned off" : m < 60 ? "\(m) minutes" : "\(m / 60) hour\(m == 60 ? "" : "s")")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                chip(0)
                Spacer(minLength: 3); Dot(); Spacer(minLength: 3)
                HStack(spacing: 3) { chip(15); chip(30); chip(45) }
                Spacer(minLength: 3); Dot(); Spacer(minLength: 3)
                HStack(spacing: 3) { chip(60); chip(120); chip(240); chip(480) }
                Spacer(minLength: 3); Dot(); Spacer(minLength: 3)
                Chip(selected: sliderOpen, action: {
                    withAnimation(.easeOut(duration: 0.18)) { sliderOpen.toggle() }
                }) {
                    Image(systemName: "gearshape.fill").font(.system(size: 12, weight: .semibold))
                }
                .help("Custom duration")
            }
            if sliderOpen {
                DurationSlider(minutes: awake.minutes == 0 ? 60 : awake.minutes,
                               onChange: { awake.setMinutes($0) },
                               onCommit: { awake.activate(minutes: $0) })
            }
        }
    }
}

// Custom duration, 5 min to 24 h in 5 min steps. Drag updates the header live, release starts the timer.
struct DurationSlider: View {
    static let range = 5...1440
    let minutes: Int
    let onChange: (Int) -> Void
    let onCommit: (Int) -> Void

    private let thumb = CGSize(width: 26, height: 16)

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = CGFloat(Self.range.upperBound - Self.range.lowerBound)
            let frac = CGFloat(min(max(minutes, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound) / span
            let x = frac * (w - thumb.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(Color.claude).frame(width: x + thumb.width / 2, height: 4)
                Capsule().fill(.white)
                    .frame(width: thumb.width, height: thumb.height)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(height: 20)
            .overlay(alignment: .bottom) {
                Canvas { ctx, size in
                    var px: CGFloat = thumb.width / 2
                    while px <= size.width - thumb.width / 2 {
                        ctx.fill(Path(ellipseIn: CGRect(x: px - 0.75, y: 0, width: 1.5, height: 1.5)),
                                 with: .color(.primary.opacity(0.25)))
                        px += 4
                    }
                }
                .frame(height: 2)
                .offset(y: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in onChange(value(at: v.location.x, width: w)) }
                .onEnded { v in onCommit(value(at: v.location.x, width: w)) })
        }
        .frame(height: 20)
        .padding(.bottom, 2)
    }

    private func value(at x: CGFloat, width w: CGFloat) -> Int {
        let f = min(max((x - thumb.width / 2) / (w - thumb.width), 0), 1)
        let steps = Int((f * CGFloat(Self.range.upperBound - Self.range.lowerBound) / 5).rounded())
        return Self.range.lowerBound + steps * 5
    }
}

// The Keep Awake section: the duration chips and its own options folded underneath. The bolt in the
// panel header turns it on and off.
struct AwakeSection: View {
    @ObservedObject var awake = Awake.shared
    @AppStorage("awake.optionsOpen") private var optionsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            DurationRow().padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 8)
            HStack(spacing: 6) {
                Text("Options").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(optionsOpen ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(HoverBackground(radius: 6))
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { optionsOpen.toggle() } }
            if optionsOpen {
                ForEach(AwakeSetting.groups, id: \.0) { group, settings in
                    Text(group == "Lid" ? "When the Lid Closes" : group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 1)
                    // The lid actions only show once lid mode is on.
                    ForEach(settings.filter { !AwakeSetting.lidActions.contains($0) || awake.isOn(.lidClosed) }) { s in
                        let blocked = AwakeSetting.needsHelper.contains(s) && !Root.installed
                        ToggleRow(symbol: s.symbol, title: s.title, hint: blocked ? "helper" : s.hint, on: awake.isOn(s)) { awake.toggle(s) }
                            .padding(.leading, AwakeSetting.lidActions.contains(s) ? 14 : 0)
                    }
                    if group == "Lid" { helperRow }
                }
            }
        }
    }

    private var helperRow: some View {
        ToggleRow(symbol: "key", title: "No Password Prompt", hint: Root.installed ? "installed" : "asks once",
                          on: Root.installed) {
                    if Root.installed {
                        if Dialogs.confirmRemoveHelper() { _ = Root.uninstall() }
                    } else if Dialogs.confirmHelper() {
                        _ = Root.install()
                        Recovery.installAgent()
                    }
                    awake.objectWillChange.send()
                }
                .padding(.leading, 14)
    }
}

// The panel's Usage section: today's Claude Code tokens per account and in all, and each account's
// chat limits when that setting is on.
struct UsageSection: View {
    @ObservedObject var usage = Usage.shared
    @ObservedObject var engine = Engine.shared

    var body: some View {
        let today = usage.totals(days: 1)
        let owners = engine.profiles.map(\.id.uuidString) + (today[UsageScan.terminal] != nil ? [UsageScan.terminal] : [])
        VStack(spacing: 0) {
            ForEach(owners, id: \.self) { owner in
                HStack(spacing: 9) {
                    Circle().fill(Usage.ownerTint(owner)).frame(width: 8, height: 8).frame(width: 24)
                    Text(Usage.ownerName(owner)).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 2)
                    if let l = usage.limits[owner] { LimitText(snapshot: l) }
                    Text(Usage.short(UsageMetric.current.value(today[owner] ?? UsageTotals()))).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            HStack {
                Text("Open Usage and Conversations…").font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(HoverBackground(radius: 6))
            .onTapGesture { PanelController.shared.close(); UsageWindow.show() }
        }
    }
}

struct LimitText: View {
    let snapshot: ChatLimits.Snapshot
    var body: some View {
        if let e = snapshot.error {
            Text(e).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        } else {
            HStack(spacing: 5) {
                if let h = snapshot.fiveHour { Meter(label: "5h", limit: h) }
                if let w = snapshot.week { Meter(label: "wk", limit: w) }
            }
        }
    }
}

struct Meter: View {
    let label: String
    let limit: ChatLimits.Limit
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(limit.percent >= 90 ? Color.red : Color.claude)
                    .frame(width: max(2, 22 * min(limit.percent, 100) / 100))
            }
            .frame(width: 22, height: 4)
            Text("\(Int(limit.percent.rounded()))%").font(.system(size: 9, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary).fixedSize()
        }
        .help("\(Int(limit.percent.rounded()))% used" + (limit.resetsAt.map { ", resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
    }
}

// MARK: usage window

struct UsageWindowView: View {
    @ObservedObject var usage = Usage.shared
    @AppStorage("usage.tab") private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Usage").tag(0)
                Text("Conversations").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260).padding(.vertical, 10)
            Divider()
            if tab == 0 { UsageStatsView() } else { ConversationsView() }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// What a number means. Cache reads are most of Claude Code's raw total (the same context read again on
// every turn), so the default is output: what Claude actually wrote.
enum UsageMetric: String, CaseIterable, Identifiable {
    case output, fresh, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .output: "Output"
        case .fresh: "New Tokens"
        case .all: "All Tokens"
        }
    }
    var unit: String {
        switch self {
        case .output: "out"
        case .fresh: "new"
        case .all: "tokens"
        }
    }
    var help: String {
        switch self {
        case .output: "Tokens Claude wrote."
        case .fresh: "Tokens processed for the first time: input, output and cache writes. Leaves out cache reads."
        case .all: "Everything, cache reads included. Cache reads are cheap and repeat the same context every turn."
        }
    }
    func value(_ t: UsageTotals) -> Int {
        switch self {
        case .output: t.output
        case .fresh: t.input + t.output + t.cacheWrite
        case .all: t.total
        }
    }
    static var current: UsageMetric { UsageMetric(rawValue: UserDefaults.standard.string(forKey: "usage.metric") ?? "") ?? .output }
}

struct UsageStatsView: View {
    @ObservedObject var usage = Usage.shared
    @ObservedObject var engine = Engine.shared
    @AppStorage("usage.range") private var range = 7
    @AppStorage("usage.metric") private var metricRaw = UsageMetric.output.rawValue
    @AppStorage("usage.heatOwner") private var heatOwner = ""   // "" = every account

    var body: some View {
        let metric = UsageMetric(rawValue: metricRaw) ?? .output
        let totals = usage.totals(days: range)
        let all = totals.values.reduce(UsageTotals(), +)
        let owners = totals.sorted { metric.value($0.value) > metric.value($1.value) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Picker("", selection: $range) {
                        Text("Today").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30); Text("All").tag(0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    Picker("", selection: $metricRaw) {
                        ForEach(UsageMetric.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 130)
                    .help(metric.help)
                    Spacer()
                    if usage.scanning { ProgressView().controlSize(.small) }
                    Button("Refresh") { usage.refresh(force: true) }
                }

                HStack(spacing: 10) {
                    Tile(title: metric.title, value: Usage.short(metric.value(all)), accent: true)
                    Tile(title: "Replies", value: Usage.short(all.messages))
                    Tile(title: "Output per reply", value: all.messages > 0 ? Usage.short(all.output / all.messages) : "0")
                    Tile(title: "Cache hit", value: all.input + all.cacheRead + all.cacheWrite > 0
                         ? "\(all.cacheRead * 100 / (all.input + all.cacheRead + all.cacheWrite))%" : "–")
                        .help("Share of input read from cache. Higher is cheaper and faster.")
                }

                // Share of the chosen metric per account, one thin bar.
                if metric.value(all) > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { g in
                            HStack(spacing: 2) {
                                ForEach(owners, id: \.key) { owner, t in
                                    let w = g.size.width * CGFloat(metric.value(t)) / CGFloat(metric.value(all))
                                    if w >= 1 {
                                        RoundedRectangle(cornerRadius: 3).fill(Usage.ownerTint(owner)).frame(width: max(w - 2, 1))
                                            .help("\(Usage.ownerName(owner)): \(metric.value(t).formatted())")
                                    }
                                }
                            }
                        }
                        .frame(height: 8)
                        HStack(spacing: 16) {
                            ForEach(owners, id: \.key) { owner, t in
                                HStack(spacing: 5) {
                                    Circle().fill(Usage.ownerTint(owner)).frame(width: 7, height: 7)
                                    Text(Usage.ownerName(owner)).font(.caption)
                                    Text("\(metric.value(t) * 100 / max(metric.value(all), 1))% · \(Usage.short(metric.value(t)))")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Picker("", selection: $heatOwner) {
                            Text("All accounts").tag("")
                            ForEach(engine.profiles) { Text($0.name).tag($0.id.uuidString) }
                            Text("Terminal").tag(UsageScan.terminal)
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    GeometryReader { g in
                        Heatmap(values: usage.perDay(owner: heatOwner.isEmpty ? nil : heatOwner).mapValues(metric.value),
                                tint: heatOwner.isEmpty ? .claude : Usage.ownerTint(heatOwner), unit: metric.unit,
                                weeks: max(8, min(53, Int(g.size.width / 15))))
                    }
                    .frame(height: 150)
                }

                Text("By model").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                    GridRow { header("Model"); header(metric.title); header("Replies"); header("Output per reply") }
                    ForEach(usage.byModel(days: range).sorted { metric.value($0.1) > metric.value($1.1) }, id: \.0) { m, t in
                        GridRow {
                            Text(m).font(.system(size: 12, design: .monospaced))
                            num(metric.value(t)); num(t.messages); num(t.messages > 0 ? t.output / t.messages : 0)
                        }
                    }
                }

                if !usage.limits.isEmpty {
                    Text("Chat limits").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                        ForEach(engine.profiles) { p in
                            if let l = usage.limits[p.id.uuidString] {
                                GridRow {
                                    HStack { Circle().fill(p.tint).frame(width: 8, height: 8); Text(p.name) }
                                    LimitText(snapshot: l)
                                }
                            }
                        }
                    }
                }

                Text("From Claude Code's own logs on this Mac: the Code tab, Cowork and the terminal. Regular chats keep no token counts on the Mac; Show Chat Limits adds each account's 5-hour and weekly limits from claude.ai.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func header(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }
    private func num(_ n: Int) -> some View { Text(Usage.short(n)).monospacedDigit() }
}

// GitHub-style calendar: one square per day, weeks as columns, darker for busier days.
// Levels are quartiles of the active days, so one huge day doesn't wash the rest out.
struct Heatmap: View {
    let values: [String: Int]   // yyyy-MM-dd -> value
    let tint: Color
    let unit: String
    var weeks = 26
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? today
        let active = values.values.filter { $0 > 0 }.sorted()
        let cuts = [0.25, 0.5, 0.75].map { q in active.isEmpty ? 0 : active[min(active.count - 1, Int(Double(active.count) * q))] }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { w in
                    let first = cal.date(byAdding: .weekOfYear, value: w, to: start) ?? start
                    VStack(spacing: gap) {
                        // Month name over the first week that starts in it.
                        Text(cal.component(.day, from: first) <= 7 ? first.formatted(.dateTime.month(.abbreviated)) : " ")
                            .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize().frame(width: cell, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: d, to: first) ?? first
                            let key = UsageScan.dayFormat.string(from: day)
                            let v = values[key] ?? 0
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(day > today ? Color.clear : color(v, cuts: cuts))
                                .frame(width: cell, height: cell)
                                .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(v == 0 ? "nothing" : v.formatted() + " " + unit)")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 2.5).fill(level(i)).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(width: CGFloat(weeks) * (cell + gap))
        }
    }

    private func level(_ i: Int) -> Color { i == 0 ? Color.primary.opacity(0.07) : tint.opacity([0, 0.3, 0.5, 0.75, 1][i]) }

    private func color(_ v: Int, cuts: [Int]) -> Color {
        guard v > 0 else { return level(0) }
        return level(1 + cuts.filter { v > $0 }.count)
    }
}

struct Tile: View {
    let title: String
    let value: String
    var accent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(accent ? Color.claude : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct ConversationsView: View {
    @State private var sessions: [ArchivedSession] = []
    @State private var query = ""
    @State private var selection: ArchivedSession.ID?
    @State private var loading = true
    @AppStorage("usage.hideOneShot") private var hideOneShot = true

    var body: some View {
        // Hooks and scripts that run `claude -p` start every session with the same prompt.
        let repeated = Dictionary(grouping: sessions, by: \.title).filter { $0.value.count >= 5 }
        let kept = hideOneShot ? sessions.filter { repeated[$0.title] == nil } : sessions
        let shown = query.isEmpty ? kept : kept.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.project.localizedCaseInsensitiveContains(query)
                || Usage.ownerName($0.owner).localizedCaseInsensitiveContains(query)
        }
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search titles, projects, accounts", text: $query).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 8)
                HStack {
                    Toggle("Hide automated runs", isOn: $hideOneShot).toggleStyle(.checkbox).font(.caption)
                        .help("Hides sessions that start with the same prompt 5 times or more: hooks and scripts running `claude -p`.")
                    Spacer()
                    Text("\(shown.count) of \(sessions.count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                if loading { ProgressView().padding() }
                List(shown, selection: $selection) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(Usage.ownerTint(s.owner)).frame(width: 6, height: 6)
                            Text("\(Usage.ownerName(s.owner)) · \(s.project) · \(s.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(s.id)
                }
            }
            .frame(minWidth: 300, idealWidth: 340)
            if let s = sessions.first(where: { $0.id == selection }) {
                TranscriptView(session: s).id(s.id)
            } else {
                Text(sessions.isEmpty && !loading ? "No conversations kept yet." : "Pick a conversation.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let profiles = Engine.shared.profiles
            let list = await Task.detached { ArchiveIndex.list(titles: UsageScan.sessionIndex(profiles).titles) }.value
            sessions = list
            loading = false
        }
    }
}

struct TranscriptView: View {
    let session: ArchivedSession
    @State private var turns: [Transcript.Turn] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)]) }
                Button("Export Markdown…") { export() }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.role == "user" ? "You" : "Claude").font(.caption.weight(.semibold))
                                .foregroundStyle(t.role == "user" ? Color.claude : .secondary)
                            Text(t.text.count > 6000 ? t.text.prefix(6000) + "…" : t.text).textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { turns = await Task.detached { [path = session.id] in Transcript.turns(path) }.value }
    }

    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = String(session.title.prefix(60)).replacingOccurrences(of: "/", with: "-") + ".md"
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? Transcript.markdown(session, account: Usage.ownerName(session.owner)).write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum UsageWindow {
    static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "MultiClaude Usage"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UsageWindowView())
            w.center()
            window = w
        }
        Usage.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuView: View {
    @ObservedObject var engine = Engine.shared
    @ObservedObject var panel = PanelController.shared
    @AppStorage("profilesOpen") private var profilesOpen = true
    @AppStorage("settingsOpen") private var settingsOpen = false
    @AppStorage("awakeOpen") private var awakeOpen = false
    @ObservedObject var awake = Awake.shared
    @ObservedObject var usage = Usage.shared
    @AppStorage("usageOpen") private var usageOpen = true
    @State private var editing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The switch reads "any profile running": on opens every profile, off quits them all.
            HStack {
                Text("MultiClaude").font(.system(size: 13, weight: .bold))
                Spacer()
                // Keep-awake on or off at a glance; durations and options are in the section below.
                Chip(selected: awake.active, action: { awake.toggleActive() }) {
                    Image(systemName: awake.active ? "bolt.fill" : "bolt").font(.system(size: 12, weight: .semibold))
                }
                .help(awake.active ? "Stop keeping your Mac awake" : "Keep your Mac awake")
                .padding(.trailing, engine.managing ? 6 : 0)
                if engine.managing {
                    Toggle("", isOn: Binding(get: { engine.runningCount > 0 },
                                             set: { $0 ? engine.openAll() : engine.quitAll() }))
                        .toggleStyle(.switch).controlSize(.regular).labelsHidden().tint(.claude)
                        .help("On opens every profile, off quits them all")
                }
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
            SectionHeader(title: "Keep Awake (\(awake.durationLabel))", trailing: awake.remainingText, open: $awakeOpen)
            if awakeOpen {
                AwakeSection().padding(.horizontal, 6).padding(.bottom, 5)
            }

            if engine.managing {
                Divider().padding(.horizontal, 14)
                SectionHeader(title: "Profiles (\(engine.profiles.count))",
                              trailing: engine.runningCount > 0 ? "\(engine.runningCount) running" : "None running",
                              open: $profilesOpen)
                if profilesOpen {
                    VStack(spacing: 0) {
                        ForEach(engine.profiles) { ProfileRow(profile: $0, editing: $editing) }
                        NewProfileRow().id(panel.closed)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
                }
                if engine.isOn(.trackUsage) || engine.isOn(.chatLimits) {
                    Divider().padding(.horizontal, 14)
                    SectionHeader(title: "Usage Today",
                                  trailing: Usage.short(UsageMetric.current.value(usage.totals(days: 1).values.reduce(UsageTotals(), +))) + " " + UsageMetric.current.unit,
                                  open: $usageOpen)
                    if usageOpen { UsageSection().padding(.horizontal, 6).padding(.bottom, 5) }
                }
            }

            Divider().padding(.horizontal, 14)
            SectionHeader(title: "Settings", open: $settingsOpen)
            if settingsOpen {
                VStack(spacing: 0) {
                    ForEach(Setting.allCases.filter { engine.managing || !Setting.claudeOnly.contains($0) }) { SettingRow(setting: $0) }
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
        .onChange(of: panel.closed) { editing = nil }
        .onExitCommand { PanelController.shared.close() }
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
final class PanelController: ObservableObject {
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
        if Engine.shared.managing { Engine.shared.discoverFolders() }
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
        closed += 1   // drops a half-typed rename or new profile, so the panel reopens clean
    }
    @Published var closed = 0

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

// The menu bar image: Claude's asterisk, plus a bolt while keep-awake is on. With no color it is a template
// image, so macOS draws it in the menu bar's own color; with any color both marks are drawn as given.
@MainActor
enum MenuBarIcon {
    static func symbol(_ name: String, _ color: NSColor?) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let color else { return img }
        return img?.withSymbolConfiguration(.init(paletteColors: [color]))
    }

    static func make(tint: NSColor?, bolt: NSColor??) -> NSImage? {
        guard let bolt else {
            let img = symbol("asterisk", tint)
            img?.isTemplate = tint == nil
            img?.accessibilityDescription = "MultiClaude"
            return img
        }
        let template = tint == nil && bolt == nil
        let colored = !template
        guard let a = symbol("asterisk", colored ? tint ?? .labelColor : nil),
              let z = symbol("bolt.fill", colored ? bolt ?? .labelColor : nil) else { return nil }
        let gap: CGFloat = 2
        let size = NSSize(width: a.size.width + gap + z.size.width, height: max(a.size.height, z.size.height))
        let img = NSImage(size: size, flipped: false) { _ in
            a.draw(in: NSRect(x: 0, y: (size.height - a.size.height) / 2, width: a.size.width, height: a.size.height))
            z.draw(in: NSRect(x: a.size.width + gap, y: (size.height - z.size.height) / 2, width: z.size.width, height: z.size.height))
            return true
        }
        img.isTemplate = template
        img.accessibilityDescription = "MultiClaude, keeping your Mac awake"
        return img
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
        if link.lowercased().hasPrefix("multiclaude:") { Engine.shared.handleOwnLink(link); return }
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
        engine.updateScroll()
        if !isDemo { Awake.shared.boot() }
        Usage.shared.start()
        refreshIcon()
        // Preview hook for screenshots: MULTICLAUDE_PREVIEW=panel|settings|awake|about
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
        case "awake":   // a 1 minute keep-awake with its options open, to check the timer ends on its own
            UserDefaults.standard.set(true, forKey: "awake.optionsOpen")
            Awake.shared.activate(minutes: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let b = self?.item.button { PanelController.shared.open(below: b) }
            }
        case "lidtest": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Awake.shared.runLidTest() }
        case "usage":
            UserDefaults.standard.set(0, forKey: "usage.tab")
            UsageWindow.show()
        case "conversations":
            UserDefaults.standard.set(1, forKey: "usage.tab")
            UsageWindow.show()
        case "about": AboutWindow.show()
        default: break
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        Dock.pendingRestore?()
        LinkRelay.giveBack()
        if Engine.shared.managing && Engine.shared.isOn(.quitWithApp) && !Updater.relaunching { Engine.shared.quitAll() }
        Awake.shared.deactivate()
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        let right = NSApp.currentEvent?.type == .rightMouseUp
        if Awake.shared.isOn(.leftClick) && !right {
            Awake.shared.toggleActive()
        } else {
            PanelController.shared.toggle(below: button)
        }
    }

    private func refreshIcon() {
        guard let b = item.button else { return }
        let engine = Engine.shared
        let count = engine.runningCount
        // While a Claude window is in front, the menu bar names its account in the profile's color.
        let front = engine.isOn(.showActive) ? engine.profiles.first { $0.id == engine.frontID } : nil
        let tint: NSColor? = front?.nsTint ?? (count > 0 && engine.isOn(.coloredIcon) ? .claude : nil)
        // Keep-awake adds a bolt next to the asterisk, orange with Colored Menu Bar Icon on.
        let bolt: NSColor?? = Awake.shared.active ? .some(engine.isOn(.coloredIcon) ? .claude : nil) : .none
        b.image = MenuBarIcon.make(tint: tint, bolt: bolt)
        if let front {
            b.title = " " + (front.name.count > 18 ? front.name.prefix(17) + "…" : front.name)
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
        ("default, nothing running", nil, false, ["-a", "/A/Claude.app"]),
        ("default, another account running", nil, true, ["-n", "-a", "/A/Claude.app"]),
        ("profile", "/x/Claude-Work", true, ["-n", "-a", "/A/Claude.app", "--args", "--user-data-dir=/x/Claude-Work"]),
    ]
    for (name, dir, any, want) in opens {
        let got = Launch.openArgs(app: "/A/Claude.app", dir: dir, anyClaudeRunning: any)
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
    check("clone succeeds", (try? Duplicate.clone(from: src.path, to: dst.path).get()) != nil)
    check("clone copies data", (try? String(contentsOf: dst.appendingPathComponent("Local Storage/db"), encoding: .utf8)) == "chats")
    check("clone drops lock", (try? FileManager.default.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("SingletonLock").path)) == nil)
    check("clone refuses existing destination", (try? Duplicate.clone(from: src.path, to: dst.path).get()) == nil)
    check("clone leaves no partial folder", !((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).contains { $0.hasPrefix(".partial-") })
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
    check("move succeeds", Folders.move(sup + "/Claude-Work", to: sup + "/Claude-Augura") == .moved)
    check("old path is a symlink to the new one", (try? FileManager.default.destinationOfSymbolicLink(atPath: sup + "/Claude-Work")) == sup + "/Claude-Augura")
    check("candidates skip the symlink", Folders.candidates(in: sup).map { URL(fileURLWithPath: $0).lastPathComponent } == ["Claude-Augura", "Claude-Moonsun"])
    check("canonical resolves the old path", Folders.canonical(sup + "/Claude-Work") == Folders.canonical(sup + "/Claude-Augura"))
    check("no target onto a leftover symlink", Folders.target(for: "Work", current: sup + "/Claude-Augura", in: sup) == nil)
    check("canonical ignores case", Folders.canonical(sup + "/claude-augura") == Folders.canonical(sup + "/Claude-Augura"))
    check("a missing move source fails cleanly", Folders.move(sup + "/Claude-Nope", to: sup + "/Claude-Nope2") != .moved
          && !FileManager.default.fileExists(atPath: sup + "/Claude-Nope2"))
    let lockDir = sup + "/Claude-Moonsun"
    try? FileManager.default.createSymbolicLink(atPath: lockDir + "/SingletonLock", withDestinationPath: "host-\(ProcessInfo.processInfo.processIdentifier)")
    check("a lock held by a live process is in use", Folders.inUse(lockDir))
    try? FileManager.default.removeItem(atPath: lockDir + "/SingletonLock")
    try? FileManager.default.createSymbolicLink(atPath: lockDir + "/SingletonLock", withDestinationPath: "host-99999999")
    check("a lock left by a dead process is not", !Folders.inUse(lockDir))
    // MCP: a broken source is refused, an empty one leaves the target alone.
    try? Data("not json".utf8).write(to: MCP.configURL(pa))
    let pc = Profile(name: "C", dir: tmp.appendingPathComponent("Claude-C").path)
    try? FileManager.default.createDirectory(atPath: pc.dir!, withIntermediateDirectories: true)
    var refusedSource = false
    do { _ = try MCP.copy(from: pa, to: pc) } catch MCP.Failure.unreadable(.source) { refusedSource = true } catch {}
    check("copy refuses a broken source file", refusedSource && !FileManager.default.fileExists(atPath: MCP.configURL(pc).path))
    try? Data(#"{"preferences":{}}"#.utf8).write(to: MCP.configURL(pa))
    check("copy with no servers writes nothing", (try? MCP.copy(from: pa, to: pc)) == 0 && !FileManager.default.fileExists(atPath: MCP.configURL(pc).path))
    // A saved list from another version: missing fields fall back instead of losing every profile.
    let saved = #"[{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"Work","dir":"/x/Claude-Work","color":2,"future":true},{"dir":"/x/Claude-Old"}]"#
    let decoded = try? JSONDecoder().decode([Profile].self, from: Data(saved.utf8))
    check("lenient decode keeps known profiles", decoded?.count == 2 && decoded?[0].name == "Work" && decoded?[0].color == 2
          && decoded?[0].id.uuidString == "6F1C2D3E-0000-4000-8000-000000000001")
    check("lenient decode names a profile from its folder", decoded?[1].name == "Old")
    check("a profile with a malformed folder fails the list instead of becoming the default",
          (try? JSONDecoder().decode([Profile].self, from: Data(#"[{"name":"X","dir":42}]"#.utf8))) == nil)
    // The alias must give Claude the folder exactly, quotes and dollar signs included.
    let quoted = Profile(name: "Q", dir: "/x/it's $HOME/Claude-Q")
    let sh = Process(), out = Pipe()
    sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
    sh.arguments = ["-fc", quoted.shellAlias + "\nfunction open { print -r -- \"${@[-1]}\" }\neval q"]
    sh.standardOutput = out
    try? sh.run(); sh.waitUntilExit()
    check("alias passes an odd folder through intact",
          String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "--user-data-dir=/x/it's $HOME/Claude-Q\n")
    check("alias stays readable for a plain folder", Profile(name: "W", dir: "/x/Claude-W").shellAlias
          == #"alias w='open -n -a "Claude" --args --user-data-dir="/x/Claude-W"'"#)
    check("alias has a name even for a name without letters", Profile(name: "---", dir: "/x/Claude-z").shellAlias.hasPrefix("alias claude"))
    check("log keeps only the first path segment", Log.redact("claude://claude.ai/login/SECRET?code=1#t") == "claude://claude.ai/login/…"
          && Log.redact("claude://claude.ai/new") == "claude://claude.ai/new")
    check("update URLs must be plain github.com release paths",
          Updater.trusted("https://github.com/QuentinCar0n/multiclaude/releases/download/v1/x.zip") != nil
          && Updater.trusted("https://github.com/QuentinCar0n/multiclaude/releases/download/../../../evil/x.zip") == nil
          && Updater.trusted("https://github.com:8443/QuentinCar0n/multiclaude/releases/download/v1/x.zip") == nil)
    try? FileManager.default.removeItem(at: tmp)
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-signin" {
    // Lines taken from Claude's main.log on 2026-10-10.
    let launchBounce = ["[info] claude.ai account active and logged in", "[info] [account] Navigated to /logout, synthesizing logged-out"]
    let browser = ["[info] [Auth] Using system browser for: /login/app-google-auth"]
    let back = ["[info] claudeURLHandler: login loadURL superseded (teardown race)"]
    let loggedIn = ["[info] claude.ai account active and logged in"]
    let sheet = ["[info] [Auth] Not the claude:// handler; keeping ASWebAuth",
                 "[info] [Auth] Starting ASWebAuth for: /login/app-google-auth (default browser: safari)"]
    let sheetDone = ["[info] [Auth] ASWebAuth completed: {"]
    let cases: [(String, [String], Bool, Bool)] = [
        ("launch 'logged in' before /logout is not done", launchBounce, false, false),
        ("browser step alone is not done", browser, false, false),
        ("login link handled is done", back, false, true),
        ("logged in after browser step is done", browser + loggedIn, false, true),
        ("browser seen in an earlier read, logged in now", loggedIn, true, true),
        ("in-window sheet started is not done", sheet, false, false),
        ("in-window sheet completed is done", sheet + sheetDone, false, true),
    ]
    var ok = true
    for (name, lines, saw, want) in cases {
        let got = SignInLog.scan(lines, sawBrowser: saw).done
        print(got == want ? "PASS" : "FAIL", name)
        ok = ok && got == want
    }
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-launchers" {
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); ok = ok && cond }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("mc-launchers-\(UUID().uuidString)")
    var work = Profile(name: "Work", dir: "/tmp/it's/Claude-Work", color: 1)
    let home = Profile(name: "Claude", dir: nil, color: 0)
    check("default app name", work.dockAppName == "Claude Work" && home.dockAppName == "Claude Default")
    var plain = work; plain.appName = " claude "
    check("an app is never named plain Claude", plain.dockAppName == "Claude Work")
    check("file name drops slashes", Launchers.fileName("A/B: C.") == "A-B- C.app")
    check("script asks MultiClaude first", Launchers.script(for: work).contains("multiclaude://open?profile=\(work.id.uuidString)"))
    check("script falls back with the quoted folder", Launchers.script(for: work).contains("'--user-data-dir=/tmp/it'\\''s/Claude-Work'"))
    check("default profile falls back without -n", Launchers.script(for: home).contains("exec /usr/bin/open -a \"$app\"\n"))
    check("fallback prefers the profile's own Claude", Launchers.script(for: work).contains(Runtimes.dir(work.id).path))
    var r = MainActor.assumeIsolated { Launchers.sync([work, home], in: tmp) }
    let apps = Launchers.installed(in: tmp)
    check("one app per profile", apps.count == 2 && r.failed.isEmpty)
    let workApp = tmp.appendingPathComponent("Claude Work.app")
    check("app named after the profile", apps[work.id]?.lastPathComponent == "Claude Work.app")
    check("script is executable", fm.isExecutableFile(atPath: workApp.path + "/Contents/MacOS/launch"))
    check("icon written", ((try? Data(contentsOf: workApp.appendingPathComponent("Contents/Resources/icon.icns")))?.count ?? 0) > 10_000)
    let before = (try? fm.attributesOfItem(atPath: workApp.path + "/Contents/Info.plist")[.modificationDate]) as? Date
    r = MainActor.assumeIsolated { Launchers.sync([work, home], in: tmp) }
    let after = (try? fm.attributesOfItem(atPath: workApp.path + "/Contents/Info.plist")[.modificationDate]) as? Date
    check("unchanged profile is not rewritten", before == after && r.moved.isEmpty)
    work.appName = "Claude Client"
    r = MainActor.assumeIsolated { Launchers.sync([work, home], in: tmp) }
    check("rename moves the app", r.moved.count == 1 && Launchers.installed(in: tmp)[work.id]?.lastPathComponent == "Claude Client.app")
    check("rename rewrites the app", r.rewritten.count == 1)
    work.color = 4
    r = MainActor.assumeIsolated { Launchers.sync([work, home], in: tmp) }
    check("recolor rewrites only that app", r.rewritten.map(\.lastPathComponent) == ["Claude Client.app"] && r.moved.isEmpty)
    check("renamed app carries the new name", Launchers.readInfo(tmp.appendingPathComponent("Claude Client.app"))?["CFBundleName"] as? String == "Claude Client")
    var twin = Profile(name: "Twin", dir: "/tmp/Claude-Twin", color: 2)
    twin.appName = "Claude Client"
    r = MainActor.assumeIsolated { Launchers.sync([work, home, twin], in: tmp) }
    var dot = work; dot.appName = "Claude."
    check("a name that becomes Claude.app gets a number", Launchers.fileName(dot.dockAppName) == "Claude.app"
          && MainActor.assumeIsolated { Launchers.sync([dot], in: tmp.appendingPathComponent("dot")) }.failed.isEmpty
          && Launchers.installed(in: tmp.appendingPathComponent("dot"))[dot.id]?.lastPathComponent == "Claude. 2.app")
    check("clashing names get a number", Launchers.installed(in: tmp)[twin.id]?.lastPathComponent == "Claude Client 2.app")
    try? fm.createDirectory(at: tmp.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
    r = MainActor.assumeIsolated { Launchers.sync([home], in: tmp) }
    check("removed profiles lose their app", r.removed.count == 2 && Launchers.installed(in: tmp).count == 1)
    check("other apps in the folder stay", fm.fileExists(atPath: tmp.appendingPathComponent("Other.app").path))
    r = MainActor.assumeIsolated { Launchers.sync([], in: tmp) }
    check("turning the setting off removes every app", Launchers.installed(in: tmp).isEmpty && r.removed.count == 1)
    // Runtimes, against a fake Claude.app (the real folder isn't touched: these use explicit paths).
    func fakeClaude(_ v: String) -> URL {
        let c = tmp.appendingPathComponent("src-\(v)/Claude.app")
        try? fm.createDirectory(at: c.appendingPathComponent("Contents/Resources/fr.lproj"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": v, "CFBundleIdentifier": claudeBundleID]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: c.appendingPathComponent("Contents/Info.plist"))
        return c
    }
    let rp = Profile(name: "Runtime Test \(UUID().uuidString.prefix(6))", dir: "/tmp/x", color: 3)
    defer { try? fm.removeItem(at: Runtimes.dir(rp.id)) }
    let v1 = fakeClaude("1.0"), v2 = fakeClaude("2.0")
    let rt = Runtimes.ensure(rp, from: v1, running: { _ in false })
    check("runtime is cloned", rt != nil && Runtimes.version(rt!) == "1.0")
    check("runtime is named after the profile and wears its icon", Runtimes.current(rp.id)!.lastPathComponent == Launchers.fileName(rp.dockAppName)
          && Runtimes.hasLook(Runtimes.current(rp.id)!))
    check("runtime contents untouched", !fm.fileExists(atPath: Runtimes.current(rp.id)!.path + "/Contents/Resources/fr.lproj/InfoPlist.strings"))
    check("runtime Info.plist untouched", (try? Data(contentsOf: Runtimes.current(rp.id)!.appendingPathComponent("Contents/Info.plist")))
          == (try? Data(contentsOf: v1.appendingPathComponent("Contents/Info.plist"))))
    _ = Runtimes.ensure(rp, from: v2, running: { _ in true })
    check("running runtime is left alone", Runtimes.version(Runtimes.current(rp.id)!) == "1.0")
    var recolored = rp; recolored.color = 5
    let nameBefore = Runtimes.current(rp.id)!.lastPathComponent
    _ = Runtimes.ensure(recolored, from: v1, running: { _ in true })
    check("running runtime gets the new icon in place", ((try? String(contentsOf: Runtimes.stampURL(rp.id), encoding: .utf8)) ?? "").hasSuffix("|5")
          && Runtimes.current(rp.id)!.lastPathComponent == nameBefore)
    _ = Runtimes.ensure(rp, from: v2, running: { _ in false })
    check("closed runtime follows a Claude update", Runtimes.version(Runtimes.current(rp.id)!) == "2.0")
    _ = Runtimes.ensure(rp, from: v1, running: { _ in false })
    check("runtime ahead of Claude is kept", Runtimes.version(Runtimes.current(rp.id)!) == "2.0")
    var renamed = rp; renamed.appName = "Claude \"Quoted\""
    _ = Runtimes.ensure(renamed, from: v2, running: { _ in false })
    check("rename renames the bundle", Runtimes.current(rp.id)!.lastPathComponent == "Claude \"Quoted\".app")
    try? Data("1|2.0|old".utf8).write(to: Runtimes.stampURL(rp.id))
    _ = Runtimes.ensure(renamed, from: v1, running: { _ in false })
    check("a copy from an older format is rebuilt", Runtimes.version(Runtimes.current(rp.id)!) == "1.0")
    let others = ((try? fm.contentsOfDirectory(atPath: Runtimes.folder.path)) ?? [])
        .compactMap { UUID(uuidString: $0) }.filter { $0 != rp.id }
    Runtimes.prune(keeping: Set(others))   // only the test copy goes
    check("prune removes a closed runtime", !Runtimes.exists(rp.id))
    let ownerURL = Runtimes.dir(rp.id).appendingPathComponent("Claude X.app")
    check("a copy's bundle names its profile", Runtimes.owner(of: ownerURL) == rp.id
          && Runtimes.owner(of: URL(fileURLWithPath: "/Applications/Claude.app")) == nil)
    // Two profiles with the same app name swap places in the list: their apps swap names instead of failing.
    let swapDir = tmp.appendingPathComponent("swap")
    var s1 = Profile(name: "S1", dir: "/tmp/Claude-S1", color: 1), s2 = Profile(name: "S2", dir: "/tmp/Claude-S2", color: 2)
    s1.appName = "Claude Same"; s2.appName = "Claude Same"
    _ = MainActor.assumeIsolated { Launchers.sync([s1, s2], in: swapDir) }
    r = MainActor.assumeIsolated { Launchers.sync([s2, s1], in: swapDir) }
    let swapped = Launchers.installed(in: swapDir)
    check("reordered twins swap app names", r.failed.isEmpty && swapped[s2.id]?.lastPathComponent == "Claude Same.app"
          && swapped[s1.id]?.lastPathComponent == "Claude Same 2.app")
    check("no hidden leftovers after a swap", !((try? fm.contentsOfDirectory(atPath: swapDir.path)) ?? []).contains { $0.hasPrefix(".") })
    check("a very long name still makes a valid file name", Launchers.fileName(String(repeating: "é", count: 300)).utf8.count <= 204
          && Launchers.fileName("A\nB") == "AB.app")
    var long1 = Profile(name: "L1", dir: "/tmp/Claude-L1", color: 1), long2 = Profile(name: "L2", dir: "/tmp/Claude-L2", color: 2)
    long1.appName = String(repeating: "x", count: 250); long2.appName = long1.appName
    r = MainActor.assumeIsolated { Launchers.sync([long1, long2], in: tmp.appendingPathComponent("long")) }
    check("two identical long app names both get an app", r.failed.isEmpty && Launchers.installed(in: tmp.appendingPathComponent("long")).count == 2)
    let entry = Dock.entry(for: URL(fileURLWithPath: "/Users/x/Applications/MultiClaude Launchers/Claude Work.app"))
    check("dock entry round-trips its path", Dock.path(of: entry) == "/Users/x/Applications/MultiClaude Launchers/Claude Work.app")
    try? fm.removeItem(at: tmp)
    exit(ok ? 0 : 1)
}
if args.count == 3, args[1] == "--export-profile-icon" {   // --export-profile-icon <out.png>, for README art
    MainActor.assumeIsolated {
        let tiles = Palette.colors.map { AppIcon.profile(256, color: $0.color, letter: "X") }
        let strip = NSImage(size: NSSize(width: 256 * tiles.count, height: 256), flipped: false) { _ in
            for (i, t) in tiles.enumerated() { t.draw(in: NSRect(x: i * 256, y: 0, width: 256, height: 256)) }
            return true
        }
        let rep = NSBitmapImageRep(data: strip.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}
if args.count == 2, args[1] == "--selftest-awake" {
    // Scroll flip on synthetic wheel (line), smooth mouse (continuous, no phase) and trackpad (continuous
    // with a gesture phase) events, and the keep-awake labels.
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); ok = ok && cond }
    func make(_ unit: CGScrollEventUnit, continuous: Bool, phase: Int64 = 0) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: unit, wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0)!
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return e
    }
    func y(_ e: CGEvent) -> Int64 { e.getIntegerValueField(.scrollWheelEventDeltaAxis1) }
    func x(_ e: CGEvent) -> Int64 { e.getIntegerValueField(.scrollWheelEventDeltaAxis2) }
    func fy(_ e: CGEvent) -> Double { e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) }
    for (mouse, pad) in [(true, false), (false, true), (true, true), (false, false)] {
        ScrollReverser.reverseMouse = mouse
        ScrollReverser.reverseTrackpad = pad
        let wheel = make(.line, continuous: false), track = make(.pixel, continuous: true, phase: 2)
        let smooth = make(.pixel, continuous: true)
        let (wy, wx, wf, ty, tx, sy) = (y(wheel), x(wheel), fy(wheel), y(track), x(track), y(smooth))
        ScrollReverser.flip(wheel)
        ScrollReverser.flip(track)
        ScrollReverser.flip(smooth)
        let tag = "mouse=\(mouse) trackpad=\(pad)"
        check("\(tag): wheel \(mouse ? "flipped" : "kept")", y(wheel) == (mouse ? -wy : wy) && x(wheel) == (mouse ? -wx : wx)
              && fy(wheel) == (mouse ? -wf : wf))
        check("\(tag): trackpad \(pad ? "flipped" : "kept")", y(track) == (pad ? -ty : ty) && x(track) == (pad ? -tx : tx))
        check("\(tag): smooth mouse \(mouse ? "flipped" : "kept")", y(smooth) == (mouse ? -sy : sy))
    }
    MainActor.assumeIsolated {
        let a = Awake.shared
        let saved = a.minutes
        for (m, want) in [(0, "∞"), (15, "15min"), (60, "1hr"), (135, "2hr 15min"), (1440, "24hr")] {
            a.setMinutes(m)
            check("duration label \(m) = \(want)", a.durationLabel == want)
        }
        a.setMinutes(saved)
        check("not active at start", !a.active && a.remainingText == nil)
        check("keep-awake-only mode keeps its way back and the scroll settings",
              Setting.claudeOnly.isDisjoint(with: [.manageClaude, .reverseMouse, .reverseTrackpad, .launchAtLogin, .autoUpdate]))
        check("managing Claude is on by default", Setting.onByDefault.contains(.manageClaude))
        // Lid sessions (Insomnia port).
        let rule = Root.sudoersText(user: "tester")
        let ruleURL = FileManager.default.temporaryDirectory.appendingPathComponent("mc-sudoers-\(UUID().uuidString)")
        try? rule.write(to: ruleURL, atomically: true, encoding: .utf8)
        let visudo = Process()
        visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        visudo.arguments = ["-cf", ruleURL.path]
        visudo.standardOutput = FileHandle.nullDevice
        visudo.standardError = FileHandle.nullDevice
        try? visudo.run(); visudo.waitUntilExit()
        try? FileManager.default.removeItem(at: ruleURL)
        check("sudoers rule passes visudo", visudo.terminationStatus == 0)
        check("sudoers rule allows only the four pmset commands",
              rule.components(separatedBy: "/usr/bin/pmset").count - 1 == 4 && !rule.contains("ALL, ") && rule.contains("NOPASSWD"))
        check("pmset refuses commands outside the list", !Root.pmset(["-a", "sleep", "0"]))
        // Freeze and thaw a child process tree of our own.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30 & wait"]
        try? child.run()
        usleep(300_000)
        let tree = Freezer.tree(child.processIdentifier, in: Freezer.processTable())
        check("process tree includes the child's own children", tree.count >= 2 && tree.last == child.processIdentifier)
        func state(_ pid: pid_t) -> UInt32 {
            var info = proc_bsdinfo()
            _ = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            return info.pbi_status
        }
        for pid in tree { kill(pid, SIGSTOP) }
        usleep(100_000)
        check("tree paused", tree.allSatisfy { state($0) == UInt32(SSTOP) })
        Freezer.thaw(tree)
        usleep(100_000)
        check("tree resumed", tree.allSatisfy { state($0) != UInt32(SSTOP) })
        for pid in tree { kill(pid, SIGTERM) }
        check("recovery state text", Recovery.State(disableSleep: true, lowPower: false, muted: true, frozen: [12, 34]).text
              == "disablesleep=1\nlowpower=0\nmuted=1\nfrozen=12 34\n")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-n", "-c", Recovery.script]
        try? sh.run(); sh.waitUntilExit()
        check("recovery script parses", sh.terminationStatus == 0)
        check("lid actions on by default, Low Power Mode needs the helper",
              Awake.shared.isOn(.lidMute) && AwakeSetting.needsHelper == [.lidLowPower, .batteryLowPower])
        check("shortcut keys apart from MultiClaude's", Set(AwakeSetting.allCases.map(\.key)).isDisjoint(with: Setting.allCases.map(\.rawValue)))
    }
    exit(ok ? 0 : 1)
}
if args.count == 3, args[1] == "--usage-report" {
    // --usage-report <store folder>: scans this Mac's transcripts into that folder (no archive) and prints totals.
    let scan = UsageScan()
    scan.folder = URL(fileURLWithPath: args[2])
    scan.archiveEnabled = false
    let start = Date()
    let s = MainActor.assumeIsolated { scan.scan(profiles: Engine.shared.profiles) }
    print("scanned \(s.files.count) files in \(Int(-start.timeIntervalSinceNow)) s")
    var owners: [String: UsageTotals] = [:]
    for (_, o) in s.days { for (owner, models) in o { owners[owner] = models.values.reduce(owners[owner] ?? UsageTotals(), +) } }
    MainActor.assumeIsolated {
        for (o, t) in owners.sorted(by: { $0.value.total > $1.value.total }) {
            print(Usage.ownerName(o), "total", Usage.short(t.total), "in", Usage.short(t.input), "out", Usage.short(t.output), "replies", t.messages)
        }
    }
    exit(0)
}
if args.count == 2, args[1] == "--selftest-usage" {
    // Token counting on synthetic transcripts, the archive copy, and the cookie decryption round trip.
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); ok = ok && cond }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("mc-usage-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let root = tmp.appendingPathComponent("projects/-p")
    try? fm.createDirectory(at: root.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
    func reply(_ id: String, _ req: String, _ out: Int, day: String = "2026-10-15") -> String {
        #"{"type":"assistant","requestId":"\#(req)","timestamp":"\#(day)T12:00:00Z","message":{"id":"\#(id)","model":"claude-test","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"output_tokens":\#(out),"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}"#
    }
    let user = #"{"type":"user","message":{"role":"user","content":"Hello there"},"cwd":"/tmp/proj"}"#
    let s1 = root.appendingPathComponent("s1.jsonl"), s2 = root.appendingPathComponent("s2.jsonl")
    // m1 appears twice in a row (one line per content block), m2 again in s2 (a copied history).
    try? ([user, reply("m1", "r1", 5), reply("m1", "r1", 5), reply("m2", "r2", 7)].joined(separator: "\n") + "\n").write(to: s1, atomically: true, encoding: .utf8)
    try? ([reply("m2", "r2", 7), reply("m3", "r3", 11, day: "2026-10-14")].joined(separator: "\n") + "\n").write(to: s2, atomically: true, encoding: .utf8)
    try? (reply("m4", "r4", 13) + "\n").write(to: root.appendingPathComponent("s1/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)
    let scan = UsageScan()
    scan.folder = tmp.appendingPathComponent("store")
    let src = UsageSource(root: tmp.appendingPathComponent("projects"), archiveName: "code") { f in
        UsageScan.sessionID(of: f) == "s1" ? "A" : "B"
    }
    var s = scan.scan(sources: [src])
    func out(_ o: String) -> Int { s.days.values.compactMap { $0[o]?.values.reduce(0) { $0 + $1.output } }.reduce(0, +) }
    // Files are read in any order, so m2 goes to whichever file came first; it must count once either way.
    check("duplicate lines and copied replies counted once", out("A") + out("B") == 5 + 7 + 11 + 13)
    check("subagent credited to its session", out("A") >= 5 + 13 && out("B") >= 11)
    check("days kept apart", s.days["2026-10-14"]?["B"]?["claude-test"]?.output == 11)
    check("cache counted", s.days.values.flatMap { $0.values.flatMap(\.values) }.reduce(0) { $0 + $1.cacheRead } == 4000)
    // A half-written line waits for the next scan.
    if let h = try? FileHandle(forWritingTo: s1) {
        h.seekToEndOfFile()
        let line = reply("m5", "r5", 17)
        h.write(Data(line.prefix(40).utf8)); s = scan.scan(sources: [src])
        check("partial line not counted yet", out("A") + out("B") == 36)
        h.write(Data((line.dropFirst(40) + "\n").utf8)); try? h.close()
        s = scan.scan(sources: [src])
        check("appended reply counted once complete", out("A") + out("B") == 53)
    }
    let again = UsageScan(); again.folder = scan.folder
    s = again.scan(sources: [src])
    check("state survives a restart without double counting", out("A") + out("B") == 53)
    let archived = scan.archiveURL.appendingPathComponent("A/code/-p/s1.jsonl")
    check("transcript archived under its account", (try? String(contentsOf: archived, encoding: .utf8))?.contains("m5") == true)
    check("archive keeps a transcript Claude deleted", { try? fm.removeItem(at: s1); return fm.fileExists(atPath: archived.path) }())
    check("transcript turns merge a reply's blocks", Transcript.turns(archived.path).map(\.role) == ["user", "assistant", "assistant", "assistant"])
    // Cookie format: encrypt like Chromium, decrypt with ChatLimits.
    let key = Data((0..<16).map { UInt8($0) })
    for version in [23, 24] {
        let plain = (version >= 24 ? Data(repeating: 7, count: 32) : Data()) + Data("sk-ant-sid01-test".utf8)
        var enc = Data(count: plain.count + 16); var n = 0
        let encCount = enc.count
        _ = enc.withUnsafeMutableBytes { o in plain.withUnsafeBytes { p in key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 16,
                    [UInt8](repeating: 0x20, count: 16), p.baseAddress, plain.count, o.baseAddress, encCount, &n) } } }
        check("cookie decrypts (db version \(version))", ChatLimits.decrypt(Data("v10".utf8) + enc.prefix(n), key: key, dbVersion: version) == "sk-ant-sid01-test")
    }
    let sample = #"{"five_hour":{"utilization":42.0,"resets_at":"2026-10-15T15:00:00Z"},"seven_day":{"utilization":7.5,"resets_at":null}}"#
    let parsed = ChatLimits.parse(try! JSONSerialization.jsonObject(with: Data(sample.utf8)))
    check("limits parsed", parsed.fiveHour?.percent == 42 && parsed.week?.percent == 7.5 && parsed.fiveHour?.resetsAt != nil)
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "--selftest-version" {
    let cases = [("1.2", "1.1", true), ("1.10", "1.9", true), ("1.2", "1.2", false), ("1.2", "1.2.1", false), ("2.0", "1.9.9", true),
                 ("1.5", "1.5-rc1", true), ("1.5-rc1", "1.5", false), ("1.4", "1.5-rc1", false), ("1.5-rc1", "1.4", true)]
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
