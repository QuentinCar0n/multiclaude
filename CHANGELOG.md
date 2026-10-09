# MultiClaude release notes

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
