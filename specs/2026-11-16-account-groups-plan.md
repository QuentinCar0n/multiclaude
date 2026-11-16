# Account Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Profiles belong to groups; a group shares one Claude Code config folder and its Code tab sessions, a lone group stays isolated, and a near-limit account offers "Continue on <B>" inside its group.

**Architecture:** Pure logic (folder resolution, record copy rules, relay target choice, limit detection) goes in a new `Groups.swift`, tested by `--selftest-groups`. `main.swift` wires it into `Profile`, `Engine.open`, the usage refresh and the UI. The Go CLI mirrors the folder rule.

**Tech Stack:** Swift 6.1 (single `swiftc` call, AppKit/SwiftUI, FSEvents, UserNotifications), Go 1.26 CLI.

**Spec:** `specs/2026-11-16-account-groups-design.md`

## Global Constraints

- Branch `feat/account-groups`. Never a git worktree. No attribution lines in commits. No em dash anywhere (code, docs, commits).
- Default group: `nil` group, display name "Personal", config folder `~/.claude`. Behaviour for a user with no group set must not change.
- Named group folder: `~/.claude-<slug(group)>`, created mode 0700. A pinned `codeDir` wins.
- Relay threshold default 90 %, per group. Notification for the same session and trigger not repeated within 30 minutes.
- Fields stripped from a copied record: `bridgeSessionIds`, `remoteControlSpawn`, `remoteMcpServersConfig`, `steeredByRemoteClient`.
- Setup copied on migration: `CLAUDE.md`, `skills/`, `plugins/`, `agents/`, `commands/`, `settings.json`. Never `projects/`, `todos/`, history, memory, transcripts.
- Every new selftest runs in `.github/workflows/release.yml`. Version bump 1.11 build per `build.sh` convention, CHANGELOG section "Unreleased".

## Review Focus

1. Two profiles of a group open the same session at once: a copy must never overwrite a record whose session runs in the target (`--resume=<cliSessionId>` in a live `claude` process). Test in Task 5.
2. Group renamed or profile moved while its app runs: refuse with a notice, folder untouched. Test in Task 3.
3. Target profile has no `claude-code-sessions/<acct>/<org>` yet (never opened a Code session): skip it, no crash, no guessed path. Test in Task 5.
4. Group name with spaces, accents or slashes: slug stays a safe single path component, two names with the same slug share a folder and the editor warns. Test in Task 2.
5. Limits unknown (signed out, `Snapshot.error` set): never a relay target, never a trigger. Test in Task 6.

---

### Task 1: Spikes (gate, no product code)

**Files:**
- Modify: `specs/2026-11-16-account-groups-design.md` (add a "Spike results" section)

- [ ] **Step 1: Config folder passthrough.** Quit a throwaway profile, then run `open -n -a "<its Runtimes copy>" --env CLAUDE_CONFIG_DIR=$HOME/.claude-spike --args --user-data-dir=<its folder>`. Start a Code tab session, then `ps -E -p <claude pid> -o command= | tr ' ' '\n' | grep '^CLAUDE_CONFIG_DIR='`. Pass: prints `CLAUDE_CONFIG_DIR=/Users/.../.claude-spike` and a new transcript appears under `~/.claude-spike/projects`.
- [ ] **Step 2: Copied record.** With app B quit, copy one throwaway `local_<id>.json` from A to B's `claude-code-sessions/<B acct>/<B org>/`, minus the four stripped keys. Open B. Pass: the session is listed and resumes with its history.
- [ ] **Step 3: Deep link.** Read Claude.app's `app.asar` for `claude://` routes (`npx asar list` into the scratchpad, grep for `code/` or `session`). Record whether a route opens a Code session by id.
- [ ] **Step 4: Limit marker.** Find a real limit message in a transcript (`grep -rl '"isApiErrorMessage":true' ~/.claude/projects`), record its exact JSON keys and values.
- [ ] **Step 5: Record results** in the spec. If Step 1 fails with every fallback, stop and return to the user. Commit: `git commit -m "Spec: spike results for account groups"`.

### Task 2: Group model and folder resolution

**Files:**
- Create: `Groups.swift`
- Modify: `main.swift:49-119` (`Profile`), `main.swift` selftests block, `build.sh:12` (compile `main.swift Groups.swift`)
- Modify: `cli/profiles.go` (`Profile`, `CodeConfigDir`), Test: `cli/profiles_test.go` (new)

**Interfaces:**
- Produces (Swift): `Profile.group: String?`; `enum Groups { static func slug(_ name: String) -> String; static func folder(group: String?, home: String) -> String; static let defaultName = "Personal" }`; `Profile.codeConfigDir` now returns `codeDir ?? (group == nil ? nil : Groups.folder(...))` where `nil` still means `~/.claude`.
- Produces (Go): `Profile.Group *string \`json:"group,omitempty"\``; `func groupFolder(group *string) string` (empty for default); `CodeConfigDir()` uses it after `CodeDir`.

- [ ] **Step 1: Failing selftest** `--selftest-groups` with checks:
  - `slug("Entreprise") == "entreprise"`, `slug("Mon Groupe/é") == "mon-groupe-e"`, `slug("  ") == "group"`
  - `folder(group: nil, home: "/h") == "/h/.claude"`, `folder(group: "Work", home: "/h") == "/h/.claude-work"`
  - profile with `codeDir: "/x"` and `group: "Work"` gives `codeConfigDir == "/x"`
  - profile with `dir` set and `group: nil` gives `codeConfigDir == nil` (was `~/.claude-<suffix>`: intended change)
  - decoding a saved profile without `group` keeps `group == nil`
- [ ] **Step 2:** `./build.sh --no-install && build/MultiClaude.app/Contents/MacOS/MultiClaude --selftest-groups`. Expected: build error or FAIL lines.
- [ ] **Step 3:** Implement `Groups.slug` (lowercase, fold diacritics, non alphanumerics to `-`, trim `-`, empty gives `group`), `Groups.folder`, the `group` field (lenient decode like the others), new `codeConfigDir`.
- [ ] **Step 4:** Same Go cases in `cli/profiles_test.go` (`TestGroupFolder`, `TestCodeConfigDirGroup`); update `cli/main_test.go:149-153` expectations to the new rule. Run `cd cli && go test ./...`: PASS.
- [ ] **Step 5:** Rerun selftest: all PASS. Commit `Groups: profile group field and group config folder`.

### Task 3: Launch with the group folder, group change guard, setup copy

**Files:**
- Modify: `main.swift:1795-1804` (`Launch.openArgs`), `main.swift:712-760` (`Engine.open`), profile editing path in `Dialogs`/`Engine`
- Modify: `Groups.swift`

**Interfaces:**
- Consumes: `Profile.codeConfigDir`, `Groups.folder`.
- Produces: `Launch.openArgs(app: String, dir: String?, codeDir: String?, anyClaudeRunning: Bool) -> [String]` adds `"--env", "CLAUDE_CONFIG_DIR=<codeDir>"` before `--args` when `codeDir != nil`; `Groups.ensureFolder(_ path: String) throws` (0700); `Groups.seedPlan(from: String, to: String) -> [(String, String)]` listing only the six allowed items that exist; `Engine.setGroup(_ id: UUID, _ group: String?) -> Bool` (false and a notice when the profile runs).

- [ ] **Step 1: Failing checks** in `--selftest-groups`: `openArgs(app:"/A.app", dir:"/d", codeDir:"/c", anyClaudeRunning:false) == ["-n","-a","/A.app","--env","CLAUDE_CONFIG_DIR=/c","--args","--user-data-dir=/d"]`; `codeDir: nil` gives today's output exactly (update the existing call at `main.swift:5257`); `seedPlan` on a temp `~/.claude` holding `CLAUDE.md`, `skills/`, `projects/`, `history.jsonl` returns only `CLAUDE.md` and `skills`; `ensureFolder` creates mode `0o700`; `setGroup` on an id in `running` returns false and leaves `group` unchanged.
- [ ] **Step 2:** Run selftest: FAIL.
- [ ] **Step 3:** Implement. `Engine.open` calls `ensureFolder` before launch (failure: notice + log, no launch). After `setGroup` to a group whose folder is new, `Dialogs` asks once "Copy your skills, plugins and CLAUDE.md into <group>?" and copies with `cp -cR` semantics (`FileManager.copyItem`).
- [ ] **Step 4:** Selftest PASS, `--selftest-launchers` and `--selftest-profiles` still PASS.
- [ ] **Step 5:** Commit `Groups: launch each profile with its group's Claude Code folder`.

### Task 4: Profile editor and grouped panel

**Files:**
- Modify: `main.swift` (`ProfileRow` 3911, profile edit dialog in `Dialogs` 4021, `MenuView` 4783, `Setting` 163)

**Interfaces:**
- Consumes: `Engine.setGroup`, `Groups.slug`, `Groups.defaultName`.
- Produces: per group threshold stored in UserDefaults `groupThresholds` as `[String: Int]` keyed by slug, default 90; `Engine.threshold(group: String?) -> Int`.

- [ ] **Step 1:** Add a "Group" field to the edit dialog: text with existing group names offered, empty means default. Warn inline when another group has the same slug.
- [ ] **Step 2:** `MenuView` shows a small `SectionHeader` per group, only when more than one group exists; order: default first, then by name.
- [ ] **Step 3:** Settings: "Relay at" slider 50 to 100 % per group with two or more profiles.
- [ ] **Step 4:** Screenshot with `MULTICLAUDE_DEMO=1 MULTICLAUDE_PREVIEW=panel` (demo profiles get two groups) and check headers render in light and dark.
- [ ] **Step 5:** Commit `Groups: group field, grouped panel, relay threshold`.

### Task 5: Shared session records

**Files:**
- Modify: `Groups.swift` (pure rules), `main.swift` (watcher in `Engine`)

**Interfaces:**
- Consumes: profiles' `folderURL`, `group`, `ProcArgs`.
- Produces: `enum SessionShare { static let stripped: [String]; static func accountFolders(in sessionsRoot: URL) -> [URL]; static func copy(record: [String: Any], strip: [String]) -> [String: Any]; static func shouldWrite(incoming: [String: Any], existing: [String: Any]?, runningSessionIDs: Set<String>) -> Bool; static func write(_ record: [String: Any], to url: URL) throws }` (atomic). `final class SessionWatcher { init(engine: Engine); func start(); func stop() }`.

- [ ] **Step 1: Failing checks:** `copy` drops exactly the four stripped keys and keeps `cliSessionId`, `lastActivityAt`, `title`; `shouldWrite` true when `existing == nil`, true when incoming `lastActivityAt` is newer, false when older or equal, false when `cliSessionId` is in `runningSessionIDs`; `accountFolders` of an empty root is `[]`; `write` leaves no temp file and the result parses back equal.
- [ ] **Step 2:** Run selftest: FAIL.
- [ ] **Step 3:** Implement the rules, then `SessionWatcher`: one FSEvents stream over every grouped profile's `claude-code-sessions`, 1 s latency. On a changed `local_*.json` in profile A: for each other profile B in A's group (never another group), skip B when `accountFolders` is empty, skip when the record's transcript `<group folder>/projects/*/<cliSessionId>.jsonl` doesn't exist, else `write` to `<B acct>/<B org>/local_<sessionId>.json` when `shouldWrite`. Running session ids come from `ProcArgs` of B's `claude` children (`--resume=`). Errors go to `Log.write`, never a notice.
- [ ] **Step 4:** Selftest PASS. Live: two personal profiles, new throwaway session in A appears in B's sidebar within a few seconds; nothing appears under the company profile.
- [ ] **Step 5:** Commit `Groups: share Code tab sessions inside a group`.

### Task 6: Relay

**Files:**
- Modify: `Groups.swift` (pure rules), `main.swift` (`Usage.refresh` near 3132, `UsageScan`, notifications, `Engine`)

**Interfaces:**
- Consumes: `Usage.limits: [String: ChatLimits.Snapshot]`, `Engine.threshold(group:)`, `SessionShare`, `Engine.open`.
- Produces: `enum Relay { static func pressure(_ s: ChatLimits.Snapshot) -> Double?; static func target(from: UUID, group: [UUID], limits: [UUID: ChatLimits.Snapshot], threshold: Int) -> UUID?; static func isLimitLine(_ line: String) -> Bool; static func shouldNotify(key: String, now: Date, last: [String: Date]) -> Bool }`.

- [ ] **Step 1: Failing checks:** `pressure` is `max(fiveHour, week)` and nil when `error != nil` or both nil; `target` picks the lowest pressure below the threshold, never `from`, nil when all are at or above it, nil for a one-profile group, ignores profiles with nil pressure; `isLimitLine` true on the marker recorded in Task 1 Step 4, false on an ordinary assistant line; `shouldNotify` false 29 minutes after the last one for the same key, true at 31.
- [ ] **Step 2:** Run selftest: FAIL.
- [ ] **Step 3:** Implement. After each limits fetch and each usage scan, for each grouped profile at or above its threshold (or with a new limit line in a session of its group), post one `UNNotification` with category action "Continue on <B>" or the "Whole <group> group is at its limit. Resets at <time>." text. Action handler: copy the record if B lacks it, refuse with a notice if the session runs in A, `Engine.open(B)`, then the deep link if Task 1 Step 3 found one. Turning on a second profile in a group with `chatLimits` off offers to turn it on.
- [ ] **Step 4:** Selftest PASS. Live: set the threshold to 1 %, check the notification, click it, B opens on the session.
- [ ] **Step 5:** Commit `Groups: relay a session to another account of the group`.

### Task 7: CLI

**Files:**
- Modify: `cli/main.go` (`cmdList`, `cmdCode`), `cli/usage.go`; Test: `cli/main_test.go`

**Interfaces:**
- Consumes: `groupFolder`, cached limits in `~/Library/Application Support/MultiClaude/usage.json` (add `limits` to what the app writes there if absent, keyed by profile id with `fiveHour`/`week` percentages).
- Produces: `listRow.Group string`; `multiclaude code --group <name>`; `func pickInGroup(list []Profile, group string, limits map[string]float64) (Profile, error)`.

- [ ] **Step 1: Failing tests:** `TestListShowsGroup` (default shows `Personal`); `TestPickInGroup` (lowest pressure wins, unknown limits skipped, unknown group returns an error naming it, all saturated returns an error).
- [ ] **Step 2:** `go test ./...`: FAIL.
- [ ] **Step 3:** Implement; no network call in the CLI.
- [ ] **Step 4:** `go vet ./... && go test ./...`: PASS.
- [ ] **Step 5:** Commit `cli: groups in list, code --group`.

### Task 8: Ship prep

**Files:**
- Modify: `.github/workflows/release.yml:58-64`, `build.sh` (VERSION 1.11, BUILD +1), `CHANGELOG.md`, `README.md` (short "Account groups" section, the terms warning in plain words)

- [ ] **Step 1:** Add `--selftest-groups` to the workflow list.
- [ ] **Step 2:** `./build.sh --no-install`, run every `--selftest-*` and `go test ./...`: all PASS.
- [ ] **Step 3:** Live test from the spec's Testing section on the author's Mac; record results in the CHANGELOG entry only as user-facing changes.
- [ ] **Step 4:** Commit `1.11: account groups`. No push, no tag: the user decides.
