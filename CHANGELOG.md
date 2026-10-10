# MultiClaude release notes

## 1.3.2 (build 6), 2026-10-10

### Changed
- **Sign In no longer closes your other accounts.** For the minute of a sign-in, MultiClaude takes over `claude://` links and hands the one coming back from the browser straight to the account that asked, by process. Your other Claude windows stay open. Links go back to Claude as soon as the sign-in lands, after 10 minutes at most, when MultiClaude quits, and at its next launch after a crash. If macOS refuses the handover, MultiClaude falls back to closing the others as in 1.3.1.

## 1.3.1 (build 5), 2026-10-10

### New
- **Sign In to a profile.** Claude's Google and SSO sign-in comes back from the browser through a `claude://` link, and macOS delivers it to whichever Claude window is open first, so a second account could never finish signing in. Right-click a profile and choose **Sign In to…**: MultiClaude closes your other accounts, opens this one, notices when the sign-in lands and reopens the others. **Done** in the panel reopens them by hand.

## 1.3 (build 4), 2026-10-09

### New
- **Copy MCP servers between profiles.** Right-click a profile, **Copy MCP Servers From**, pick the source. Servers with the same name are replaced, the target's config is backed up first, and a running target can be reopened in the same step.
- **Open When MultiClaude Starts**, per profile. A restart after a MultiClaude update doesn't reopen them.
- **Duplicate as New Profile.** Clones a profile's data folder, sign-in and chats included, into a new profile with APFS clones (instant, no extra space). A running source quits for the copy and reopens after.
- **The list matches your folders.** Any `Claude-*` folder in Application Support that no profile uses yet is added to the list. Folders removed with **Remove from List** stay out.
- **Folders follow profile names.** After a rename, the profile's folder becomes `Claude-<Name>` once that account is closed, with a link left at the old path for old aliases and the absolute paths Claude saves in its data. A profile's Claude Code folder keeps its old path so its sign-in survives.
- **Signed updates.** Each release zip is signed with an Ed25519 key held as a repository secret. MultiClaude only installs an update whose signature matches the public key built into the app.

### Fixed
- Clicking the default account while another account was open brought that other account forward instead of opening the default one. It now starts its own window.
- After a Claude update, Claude's relaunch could leave an extra default window open even though the default account wasn't open before. MultiClaude now closes it, and keeps it when the default account was open before the update.

### Changed
- Release builds run the built-in tests before publishing.
- Release builds refuse to publish without the signing key, and publish `MultiClaude-<version>.zip.sig` next to the zip.

## 1.2 (build 3), 2026-10-09

### New
- **Reopen after Claude updates.** Claude relaunches on the default account when it installs an update, so profile windows came back signed in as the wrong account. MultiClaude now reopens each profile that closed around the update, and says so at the top of the panel. On by default; switch it off in Settings.
- **Claude Code per account.** Right-click a profile: **Open Claude Code in Terminal** runs the CLI with `CLAUDE_CONFIG_DIR=~/.claude-<name>`, so it signs in and keeps history separately for that account. **Copy Claude Code Alias** gives the same as a shell alias.
- **A color per profile.** Badges, the running label and the menu bar use it. Change it from the right-click menu.
- **Active account in the menu bar.** While a Claude window is in front, the menu bar shows its account name in the profile's color, and the row says Active.
- **Profile Shortcuts.** ⌃⌥1 to ⌃⌥9 open or bring forward the profiles in list order. Off by default.
- **Automatic updates.** MultiClaude checks GitHub for a new release at launch and then once a day, installs it in the background and restarts while the panel is closed. Claude windows stay open. Switch it off with **Update MultiClaude Automatically** in Settings. Updating from 1.1 or earlier still needs one manual install (or `brew upgrade`).

### Changed
- `MultiClaude --list` also prints whether each profile is active and its color.
- `MultiClaude --check-update` prints the installed and latest versions.

## 1.1 (build 2), 2026-10-09

- Open source under the Apache License 2.0.
- Demo mode for screenshots: `MULTICLAUDE_DEMO=1` shows sample profiles, `MULTICLAUDE_APPEARANCE=light|dark` forces the look.
- About shows the license instead of "All rights reserved".

## 1.0 (build 1), 2026-10-09

- Menu bar manager for several Claude desktop accounts on one Mac. Each profile is its own `--user-data-dir`, so each one keeps its own sign-in and chats.
- First run imports the default Claude profile, the `open -n -a "Claude" --args --user-data-dir=...` aliases in `~/.zshrc` (augura, moonsun), and any other `Claude-*` folder in Application Support.
- Click a profile to open it, or to bring it forward when it already runs. Hover a running profile to quit it.
- Right-click a profile: Rename, Move Up/Down, Show Data Folder in Finder, Copy Shell Alias, Remove from List (the data folder stays on disk).
- New Profile creates `~/Library/Application Support/Claude-<Name>`; sign in to the new account in the window that opens.
- Header switch: on opens every profile, off quits them all.
- Settings: Launch at Login, Keyboard Shortcut (⌃⌥⌘M opens the panel), Show Count in Menu Bar, Colored Menu Bar Icon, Quit Profiles with MultiClaude.
- `MultiClaude --list` prints each profile and whether it runs.
