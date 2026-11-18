# Account groups: shared Claude Code context and session relay

Date: 2026-11-16
Status: draft, awaiting review
Scope: phase 1 only (groups, isolation, shared sessions, relay). The proxy is phase 2 and gets its own spec.

## Goal

Get the most out of Claude Code across several Claude accounts on one Mac.

- Accounts in the same group (for example two personal Max accounts) share one Claude Code context: memory, `CLAUDE.md`, skills, plugins, settings and session transcripts.
- When one account in a group runs low on quota, the user can continue the same session on another account of the group with one click.
- An account in its own group (for example a company Team account) stays fully isolated: its own context, its own history, never a relay source or target.

Chats on claude.ai are out of scope. The target surface is the Code tab of the Claude desktop app. The `multiclaude` CLI follows the same groups.

Success: the user never stops on "limit reached" while another account of the same group still has quota, and no file from the company group ever lands in a personal group's folder, or the reverse.

## Facts this design rests on (observed 2026-11-16, Claude desktop with Claude Code 2.1.325)

- The Code tab spawns `claude` with the account's token in `CLAUDE_CODE_OAUTH_TOKEN`, `--resume=<cliSessionId>` and no `CLAUDE_CONFIG_DIR`. Every desktop instance therefore reads and writes `~/.claude`, including a company account (subscription type `team`). There is no isolation today.
- The sidebar of each desktop instance lists the session records in `<app data folder>/claude-code-sessions/<account uuid>/<org uuid>/local_<sessionId>.json`. A record points to its transcript through `cliSessionId`. Records are per app, transcripts are per config folder.
- Claude Code on a Max plan counts against the same five-hour and weekly limits that MultiClaude already reads from `claude.ai /api/organizations/{uuid}/usage` (opt-in setting `chatLimits`, polled about every 5 minutes).

## Unproven points (spikes, done before any other work)

1. **Config folder passthrough.** Launch a profile copy with `CLAUDE_CONFIG_DIR` in its launch environment, open a Code tab session, read the spawned `claude` process environment. Pass: the variable reaches `claude` and new transcripts land in that folder.
   Fallback if it fails: point the instance at its folder some other way (for example a per-profile user `settings.json` `env` entry, if Claude Code honours it for `CLAUDE_CONFIG_DIR`). If no way works, isolation of the company account is blocked and the spec returns to review.
2. **Copied session record.** Copy a throwaway session record from app A into app B's `<account>/<org>` folder with the account-bound fields removed. Pass: B lists it and resumes it with full history.
   Fallback if it fails: no shared sidebar; the relay opens B and the user resumes from the transcript with `/resume` inside a new Code tab session. The relay still works, with one more step.
3. **Deep link to a session.** Check whether a `claude://` link opens a given Code tab session in a running instance. Pass: the relay opens the session directly. Fallback: the copied record has the newest `lastActivityAt`, so it sits at the top of B's sidebar.

## Design

### 1. Groups

- New optional field `group: String?` on `Profile` (Swift app and Go CLI read the same profiles). `nil` means the default group, named "Personal".
- Each group has one Claude Code config folder:
  - the default group keeps `~/.claude` (no change for anyone who never creates a group);
  - any other group gets `~/.claude-<slug(group name)>`.
- A pinned `codeDir` on a profile still wins over the group folder.
- `Profile.codeConfigDir` becomes the group folder (today it is `~/.claude-<folder suffix>` per profile). This changes the CLI's `multiclaude code` and `env` output and the shell aliases accordingly.
- UI: a "Group" field in the profile editor (text with suggestions from existing groups). The panel shows profiles grouped under a small group header when more than one group exists.

### 2. Isolation

- When MultiClaude launches a profile copy (Runtimes) it adds `CLAUDE_CONFIG_DIR=<group folder>` to the launch environment, unless the group folder is `~/.claude`, in which case it removes the variable.
- Bare launches of Claude.app that MultiClaude does not start get no variable and use `~/.claude`. That is the default group, which is what such a launch is today.
- Migration of an existing account moved to a new group: the new folder starts empty. MultiClaude offers, once, to copy the global setup from `~/.claude`: `CLAUDE.md`, `skills/`, `plugins/`, `agents/`, `commands/`, `settings.json`. It never copies `projects/`, `todos/`, history, memory or any transcript. Old history stays where it is.
- The account must be quit while its group changes. MultiClaude refuses the change for a running profile and says why.

### 3. Shared sessions inside a group

- A watcher (FSEvents on each profile's `claude-code-sessions`) runs for every group with two or more profiles.
- When a record appears or changes in profile A, MultiClaude writes a copy into each other profile B of the same group, under B's own `<account uuid>/<org uuid>` folder (read from B's existing record folders; if B has none yet, B is skipped until it has one).
- Fields removed from the copy because they belong to A's account or app: `bridgeSessionIds`, `remoteControlSpawn`, `remoteMcpServersConfig`, `steeredByRemoteClient`. The list is a constant, adjusted after spike 2.
- Conflict rule: the record with the newer `lastActivityAt` wins. A copy never overwrites a record whose session is running in B (a `claude` process of B's instance with `--resume=<cliSessionId>`).
- A copy never crosses a group boundary. A record whose `cliSessionId` transcript is not in the group folder is not copied.
- Copies are written atomically (temp file, then rename).

### 4. Relay

- Triggers, for any profile in a group of two or more:
  1. a five-hour or weekly limit at or above the group threshold (default 90 %, setting per group);
  2. a limit message in a transcript of that group (the usage scanner already reads these JSONL files). This trigger fires at once, without waiting for the next poll.
- Target: the profile of the same group with the most headroom, meaning the lowest value of max(five-hour %, weekly %), and below the threshold. Profiles whose limits are unknown (not signed in, error) are not targets.
- Notification (macOS user notification, one per session and trigger, not repeated within 30 minutes):
  - "<A> is at 92 %. Continue on <B>?" with the action "Continue on <B>";
  - if no target has headroom: "Whole <group> group is at its limit. Resets at <time>." with no action.
- Action "Continue on B":
  1. make sure B has the record (copy now if needed);
  2. refuse with a message if the session is still running in A (two writers corrupt a transcript); the user stops it first;
  3. open or focus B's instance;
  4. open the session by deep link if spike 3 passed, else leave it at the top of B's sidebar.
- The relay requires the `chatLimits` setting. Turning on a group with two or more profiles offers to turn it on.
- Single-profile groups (the company account) never get relay notifications or relay targets.

### 5. CLI

- `multiclaude code <profile>` and `multiclaude env <profile>` use the group folder.
- `multiclaude list` shows the group of each profile.
- `multiclaude code --group <name>` picks the profile of that group with the most headroom (from the cached limits in `usage.json`, no network call), then starts `claude` as that account.

## Error handling

- Group folder missing: created with mode 0700 on first launch of a profile in that group.
- Watcher or copy failure: logged to `~/Library/Logs/MultiClaude.log`, never blocks a launch.
- Unknown record shape (a future Claude version): the copier only removes the listed fields and copies the rest. If B rejects the record, spike 2's fallback applies and a log line says so.
- Limits unavailable: no relay notification for that profile, no guess.

## Testing

- `--selftest-groups` (run in CI like the other selftests): group folder resolution (default, named, pinned `codeDir`), launch environment for each case, record copy (fields removed, target path, atomic write), no copy across groups, conflict rule, target choice with headroom and unknown limits, notification throttling.
- Go tests for `codeEnv`, `env`, `list` and `code --group`.
- Live test on the author's Mac with two personal accounts and one throwaway session: share, relay by threshold, relay by limit message, company account untouched (no file written under its folder by the personal group, and the reverse).

## Not in phase 1

- Phase 2, local proxy: Claude Code requests go through a local proxy that swaps the account inside a group mid-turn on a 429 or at the threshold. Off by default, needs stored tokens per account (`claude setup-token`), its own spec, and a decision on Anthropic's terms before it ships in the public build. Switching accounts to get around usage limits may break those terms and put both accounts at risk.
- claude.ai chats and Cowork sessions.
- Merging or sorting the history already mixed in `~/.claude`.

## Spike results (2026-11-18, Claude desktop 5.11492.5, Claude Code 2.1.325)

Test rig: a clone of the default profile's folder (`Claude-Spike`, APFS clone, same personal account) launched with `open -n -a Claude.app --env CLAUDE_CONFIG_DIR=~/.claude-spike --args --user-data-dir=...`. No second personal account exists yet, so nothing was tested across two real accounts.

1. **Config folder passthrough: partly proven.** The variable reaches the desktop main process (`ps -E`) and the app itself uses it: it created `sessions/`, `plugins/` and `backups/` in `~/.claude-spike`, and its import dialog read from there. The app's code reads `process.env.CLAUDE_CONFIG_DIR` and also offers `CLAUDE_CONFIG_DIR` in Desktop Settings. Not yet seen: the variable on a spawned Code tab `claude` process (needs one session started by hand in the clone).
2. **Hand-written session record: not listed.** A record copied into the clone's `<account>/<org>` folder with the four account fields removed survived a relaunch, but the sidebar did not show it (accessibility tree search). Its `cwd` was outside the trusted folders, which may be the reason; not retested.
3. **Deep link: a supported import exists.** `claude://claude.ai/resume?session=<cliSessionId>` makes the app import a Claude Code CLI session from its config folder (`importCliSession`). It only imports sessions whose folder is trusted: for an untrusted folder the app shows "No sessions to import. Only sessions in your trusted folders can be imported". A retry in a trusted folder gave no visible result through accessibility; not confirmed. Other routes: `claude://code/new?folder=...&prompt=...`, `claude://code/continue?session=last`.
4. **Limit marker: found.** An assistant line with `"isApiErrorMessage":true` and `"error":"rate_limit"`, text "You've hit your session limit · resets <time>" or "You've hit your weekly limit · resets <time>".

Consequence for the design: the relay should use the app's own import link (`claude://claude.ai/resume?session=<cliSessionId>`, sent to the target instance's pid) instead of hand-written records, once it is confirmed by hand. Task 5 (record copying) is then not needed.
