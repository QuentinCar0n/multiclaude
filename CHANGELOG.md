# MultiClaude release notes

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
