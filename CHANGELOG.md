# MultiClaude release notes

## 1.5 (build 10), 2026-10-14

### New
- **Keep your Mac awake.** The bolt next to the switch at the top of the panel turns it on and off. The **Keep Awake** section just below it holds off sleep until you turn it off, or for 15, 30 or 45 minutes, 1, 2, 4 or 8 hours, or any time from 5 minutes to 24 hours with the slider under the gear. The section header counts down, and a bolt joins the asterisk in the menu bar while it's on. A restart for a MultiClaude update keeps it going. Its **Options**: activate at launch, activate with a left click on the menu bar icon (right-click still opens the panel), a ⌃⌥⌘A shortcut, let the display sleep, stay awake with the lid closed (macOS asks for your password, since it takes `pmset disablesleep`), a notification when it turns off, turn on when power is connected, turn off when it's disconnected or the battery drops below 20%.
- **Reverse scroll direction**, for a mouse and a trackpad separately, in Settings. A wheel mouse and a trackpad can then each scroll the way you like, which macOS can't do on its own. It needs Accessibility permission (MultiClaude asks the first time, and the setting shows "needs Accessibility" until it's granted). A Magic Mouse follows the trackpad setting.

- **Keep-awake only.** Turn off **Manage Claude Accounts** in Settings and MultiClaude becomes a keep-awake and scroll app: the profiles and their settings leave the panel, the `claude://` links go back to Claude, and MultiClaude stops watching, reopening, renaming or quitting Claude windows. Your profiles and folders stay as they are; turn the setting back on to pick up where you were.

Both come from Cocaine, our keep-awake app. If Cocaine runs too and already reverses a direction, MultiClaude leaves that direction alone (the setting says "on in Cocaine") so scrolling isn't flipped twice.

## 1.4.1 (build 9), 2026-10-11

A robustness release: no new features, many ways things could quietly go wrong now can't, or say so.

### Fixed
- **No more crash reports from profile icons.** Setting a profile copy's icon made macOS log an IconServices fault (and write an `ExcUserFault_MultiClaude` report) every time. Icons are now handed over at every standard size, which macOS takes without complaint.
- **A transient read of a Claude process no longer closes it.** When macOS couldn't read a Claude process's arguments for a moment, MultiClaude took it for a profile copy started without its folder and closed it. Now it waits for a clean read, and folder renames wait too.
- **Your profiles survive a saved list that can't be read.** A list from another version now loads field by field, and a list that still can't be read is kept aside (`profiles-unreadable-<date>` in MultiClaude's preferences) with a note in the panel, instead of being replaced.
- **Duplicate never copies an account that is still open.** If the account doesn't quit (a quit dialog, a hang), nothing is copied. The copy is made under a hidden name and only takes its real name once complete, so a copy cut short is never picked up as a profile, and duplicating a renamed profile copies its folder, not the link left at the old name.
- **Open tells you when Claude doesn't start**, for example when Claude.app is missing, instead of showing "starting" and then nothing. Pressing a profile again while it starts no longer starts a second copy, and opening the default account right after another one now works.
- **Folder renames that fail are logged and retried at the next launch**, not every 3 seconds, and a folder moved without its link back is followed to where it is. A `SingletonLock` left by a crash no longer blocks renames forever, and folder names are compared without regard to case.
- **Profile apps can swap names.** Two profiles with the same app name that swap places in the list used to fail to rewrite their apps on every save. Very long or multi-line names make valid app names, and half-written apps left by an interrupted run are cleaned up.
- **The Dock is safer to edit.** MultiClaude never writes the Dock's app list when it can't read it, keeps changes you make while it refreshes a tile, and puts a tile it took off back before quitting. **Add to Dock** reports a failure instead of claiming success.
- **Copy MCP Servers From** refuses a source whose config isn't valid JSON (it used to report "Copied 0" and rewrite the target), leaves the target untouched when there's nothing to copy, and no longer fails when run twice in the same second.
- **Updates** give up on a stalled download instead of blocking later checks, retry within the hour after a failure (logged), unpack exactly the bytes whose signature was checked, never replace a test build (1.5-rc1) with an older release, and don't restart MultiClaude during a sign-in. If the relaunch can't start, MultiClaude stays open.
- `claude://` links only go to Claude processes, and other kinds of links are ignored.
- Aliases copied from a profile work for folder names with quotes or `$`, and a profile whose name has no letters still gets one.
- The panel forgets a half-typed rename when it closes, Esc closes it, and the account name in the menu bar is shortened past 18 characters. MultiClaude keeps tracking Claude windows while an alert is open.

### Changed
- `~/Library/Logs/MultiClaude.log` is readable only by you, starts over past 1 MB (the previous one is kept as `MultiClaude.log.1`), and logs only the first part of a link's path. Failures that used to be silent (folder renames, profile copies, profile apps, the Dock, updates, links) now leave a line there.
- Release builds check the tag's version format, give the Homebrew token only to the step that uses it, and don't mark a fix for an older line as the latest release.

## 1.4 (build 8), 2026-10-10

### New
- **An app for each profile.** Turn on **App for Each Profile** in Settings and MultiClaude makes a small app per profile in `~/Applications/MultiClaude Launchers`, named "Claude <Profile>" with Claude's own icon recolored in the profile's color. Spotlight and Launchpad find them, and right-click **Add to Dock** pins one. **Rename App…** gives it another name. The apps are rewritten when a profile is renamed or recolored, pinned Dock tiles pick up the new icon in place, and an app goes away with its profile (and its Dock tile with it). Opening one asks MultiClaude to open or bring forward that account, starting MultiClaude if needed; without MultiClaude it opens Claude directly. Asked for in #1.
- **Open accounts wear their profile icon.** With profile apps on, each account runs from its own copy of Claude: an APFS clone (no extra disk space) with the profile icon as its Finder icon, so the Dock, ⌘-Tab and Mission Control show which account is which. The copy's signed contents are untouched, so Gatekeeper, the Keychain and Claude's own folders behave as with Claude.app. Copies follow Claude updates while their account is closed. A copy restarted by Claude's updater without its account folder is closed and reopened on its account. The running window keeps the name Claude: renaming it would break the signature.

### Changed
- MultiClaude finds Claude by its bundle id (`open -b`) rather than its name, so nothing called "Claude" can be opened in its place.

## 1.3.3 (build 7), 2026-10-10

### Fixed
- **Every account signs in in its own window, with nothing to click first.** Claude only sends its Google and SSO sign-in through the browser (and back through a `claude://` link that macOS gives to the first Claude window) when it is the `claude://` handler. When it isn't, it signs in with Apple's in-window sheet instead (Claude logs "Not the claude:// handler; keeping ASWebAuth"). MultiClaude now keeps the `claude://` links, takes them back a few seconds after any Claude window starts, and passes other `claude://` links to the Claude window in front or the one used last. Setting: **Sign In in Each Account's Window**, on by default; links go back to Claude when it's off or MultiClaude quits.
- Sign In to… recognises the in-window sheet finishing, so it no longer waits for its 10-minute limit.
- Bringing a window forward after a link works on macOS 14 and later.

### Changed
- MultiClaude writes link relays and sign-ins to `~/Library/Logs/MultiClaude.log`, without the links' parameters.

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
