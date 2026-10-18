<a href="https://github.com/QuentinCar0n/multiclaude/releases/latest">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview/hero-dark.png">
  <img src="preview/hero-light.png" width="100%" alt="MultiClaude: all your Claude accounts, open at once. The menu bar panel lists Personal, Work, Client and Research profiles, with Personal and Work running.">
</picture>
</a>

<div align="center">

# MultiClaude

**All your Claude accounts, open at once.** A free menu bar app for macOS.

[![Release](https://img.shields.io/github/v/release/QuentinCar0n/multiclaude?color=D97757)](https://github.com/QuentinCar0n/multiclaude/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-quentincar0n%2Ftap%2Fmulticlaude-D97757)](https://github.com/QuentinCar0n/homebrew-tap)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-555)
![Apple silicon and Intel](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-555)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-555)](LICENSE)

```bash
brew install --cask quentincar0n/tap/multiclaude
```

[**Download the latest release**](https://github.com/QuentinCar0n/multiclaude/releases/latest) &nbsp;&middot;&nbsp; [Website](https://quentincar0n.github.io/multiclaude/) &nbsp;&middot;&nbsp; [Why](#why) &nbsp;&middot;&nbsp; [Features](#features) &nbsp;&middot;&nbsp; [How it works](#how-it-works) &nbsp;&middot;&nbsp; [FAQ](#faq)

</div>

## Why

The Claude desktop app signs in to **one account at a time**. Plenty of people have more than one:

- a personal Pro or Max plan, and a Team or Enterprise seat from work,
- a separate organization per client, so their projects and data never mix,
- a test account to try a setup before rolling it out to a team.

Switching means signing out, signing back in, waiting for the email code and losing your place. The app can't run two accounts at once.

Claude desktop does accept `--user-data-dir`: give each copy its own folder and each one keeps its own sign-in, chats and settings. Power users wire that into shell aliases. It works, but you can't see what's open, re-running an alias doesn't bring the right window forward, and every new account means editing `~/.zshrc`.

MultiClaude is that trick with a proper interface.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview/before-after-dark.png">
  <img src="preview/before-after-light.png" width="100%" alt="Before: Claude aliases in ~/.zshrc and a terminal. After: the MultiClaude panel with live status for each account.">
</picture>

| | Shell aliases | MultiClaude |
| --- | :---: | :---: |
| Open an account | type its alias in a terminal | one click in the menu bar |
| See which accounts are open | no | yes, live |
| Bring an open account forward | re-run the alias and hope | click it again |
| Quit one account | find the right window, ⌘Q | hover, click ✕ |
| Add an account | edit `~/.zshrc`, reload the shell | type a name, press Return |
| Rename, reorder, find its data | by hand | right-click |
| Keep your existing aliases | | imported on first launch |
| Tell accounts apart | every window has the same icon | a color per account, active one named in the menu bar, a named and colored app per account for the Dock and Spotlight |
| After Claude updates itself | windows come back on the default account | profiles reopen on their own accounts |

## Features

- **One profile per account.** Each profile is its own Claude data folder, so sign-ins and chats never leak between accounts.
- **A color per account.** Each profile gets its own color, so you can tell Personal from Work at a glance. Right-click to change it.
- **An app and an icon for each account.** Turn on **App for Each Profile** and MultiClaude makes a small app per profile in `~/Applications/MultiClaude Launchers`, named "Claude Work", "Claude Client" and so on, with Claude's own icon recolored in the profile's color. Find them in Spotlight and Launchpad, or right-click a profile and choose **Add to Dock**. Rename one with **Rename App…**. Each account's window then runs with that icon too, in the Dock, ⌘-Tab and Mission Control, so you can tell them apart while they're open. The apps follow renames and color changes, and go away with their profile.
- **Know which account is in front.** While a Claude window is active, the menu bar shows its account name in that account's color.
- **Live status.** A filled badge marks every account that is running. The menu bar shows how many are open.
- **Survives Claude updates.** When Claude updates itself it relaunches on the default account, which breaks every `--user-data-dir` setup. MultiClaude notices and reopens each profile on its own account.
- **Claude Code per account.** Right-click a profile and choose **Open Claude Code in Terminal**: the CLI runs signed in as that account, with its own `CLAUDE_CONFIG_DIR`.
- **Click to open, click again to focus.** No duplicate windows.
- **Hover to quit** a single account. The header switch opens or quits all of them at once.
- **New Profile** in one line: type a name, press Return, sign in to the new account in the window that opens.
- **Copy MCP servers between accounts.** Set your MCP servers up once, then right-click another profile and choose **Copy MCP Servers From**. Its config is backed up first.
- **Open accounts at startup.** Right-click a profile and tick **Open When MultiClaude Starts**. With Launch at Login on, your accounts are waiting every morning.
- **Duplicate a profile.** **Duplicate as New Profile** clones a profile's whole data folder, sign-in and chats included, into a new one. Handy for keeping your current history under a name like "Personal" before signing the default app in to another account. On APFS the copy is instant and takes no extra space.
- **Right-click** a profile to rename it, move it, show its data folder in Finder, copy a shell alias for it, or take it off the list.
- **Imports your setup.** First launch picks up your default Claude account, any `--user-data-dir` aliases in `~/.zshrc`, and any `Claude-*` folder in Application Support. A `Claude-*` folder created later, by an alias for example, joins the list on its own.
- **Folders follow names.** Rename a profile and its folder becomes `Claude-<Name>` the next time that account is closed. A link stays at the old path, so old aliases and Claude's own saved paths keep working.
- **Sign-in that lands in the right window.** Claude's Google and SSO sign-in normally comes back to whichever Claude window opened first. MultiClaude makes each account sign in inside its own window, with nothing to click first.
- **Keep your Mac awake.** The **Keep Awake** section holds off sleep until you turn it off or for a set time (15 minutes to 8 hours, or anything up to 24 hours on the slider), with a countdown and a bolt in the menu bar. Options cover the display, a closed lid, power and battery triggers, a left-click toggle and ⌃⌥⌘A. Handy for long Claude Code runs.
- **Keep-awake only, if you like.** Turn off **Manage Claude Accounts** and MultiClaude leaves Claude alone and keeps just the keep-awake and scroll features. Your profiles wait for you to turn it back on.
- **Token usage per account and in all.** Claude Code logs every reply's tokens on your Mac (Code tab, Cowork and terminal). MultiClaude credits each session to the account it ran in and shows today's output per account in the panel, plus a window with a 6-month heatmap, each account's share, and a by-model table. Regular chats keep no token counts on the Mac; turn on **Show Chat Limits** for each account's 5-hour and weekly limits from claude.ai.
- **Keeps your Claude Code conversations.** Claude Code deletes transcripts after 30 days by default. MultiClaude keeps a copy of each one per account (an APFS clone, so no extra space while the original exists), lists them with search, shows them, and exports any one to Markdown.
- **Lid closed, done right.** Keep the Mac awake with the lid closed for long agent runs: the screen goes off, sound mutes, Slack, WhatsApp and Discord pause, and Low Power Mode steps in on low battery or heat. Opening the lid undoes it, and a recovery agent undoes it if MultiClaude is gone. Optional password-free mode. Design after [Insomnia](https://github.com/krishhgg/Insomnia).
- **Scroll your own way.** Reverse the scroll direction of a mouse and a trackpad separately, in Settings (needs Accessibility permission).
- **Global shortcuts.** ⌃⌥⌘M opens the panel; turn on Profile Shortcuts and ⌃⌥1 to ⌃⌥9 jump straight to each account.
- **Updates itself.** Once a day MultiClaude checks for a new release, installs it in the background and restarts while the panel is closed. Your Claude windows stay open.
- **Launch at login**, light and dark mode, colored menu bar icon.
- **Tiny.** A single Swift file, no dependencies, under 1.5 MB installed.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview/settings-dark.png">
  <img src="preview/settings-light.png" width="300" alt="The MultiClaude panel with its Settings section open">
</picture>
</p>

## Install

### Homebrew

```bash
brew install --cask quentincar0n/tap/multiclaude
```

### Manual

1. Download `MultiClaude-<version>.zip` from [Releases](https://github.com/QuentinCar0n/multiclaude/releases/latest) and unzip it.
2. Move `MultiClaude.app` to Applications.
3. MultiClaude is not notarized by Apple yet, so macOS blocks the first launch. Right-click the app and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MultiClaude.app
   ```

Requires macOS 15 or later and the [Claude desktop app](https://claude.ai/download) in `/Applications`.

## Use

1. Click the ✳ icon in the menu bar.
2. Click **New Profile**, type a name such as `Work`, press Return.
3. Click the new profile. A fresh Claude window opens: sign in to your work account there.
4. From now on, click `Work` to open or focus it, and hover it to quit it.

Your default Claude account is always the first profile. It uses the app's normal data folder, so nothing changes for it.

## How it works

- **Opening** a profile runs `open -n -b com.anthropic.claudefordesktop --args --user-data-dir=<folder>`, the alias with Claude found by its bundle id. The default profile runs `open -b com.anthropic.claudefordesktop`.
- **Profile apps** are tiny bundles whose executable is a shell script: it sends `multiclaude://open?profile=<id>` to MultiClaude, which opens or brings forward that account, and opens Claude directly if MultiClaude is gone.
- **Profile icons on open windows.** With profile apps on, each account runs from its own copy of Claude.app in `~/Library/Application Support/MultiClaude/Runtimes.noindex`. The copy is an APFS clone, so it takes no extra disk space, and it wears the profile icon as a Finder icon, outside the signed part of the bundle. Nothing inside the bundle changes: its signature stays Anthropic's, Gatekeeper accepts it, and Claude keeps its Keychain access and its own folders. A copy is refreshed from Claude.app after Claude updates, while that account is closed. If Claude's updater restarts a copy without its account folder, MultiClaude closes it and reopens the account. Claude.app itself is never touched.
- **Status** comes from the running Claude processes: MultiClaude reads each one's `--user-data-dir` argument and matches it to a profile.
- **Profiles** are a small list in MultiClaude's own preferences (`me.somalabs.multiclaude`). Data folders live in `~/Library/Application Support/Claude-<Name>`, next to Claude's own. MultiClaude never moves the folder of an account that is open. **Remove from List** keeps the folder and stops MultiClaude from adding it back.

### Privacy

MultiClaude has **no analytics**. Its only network requests are the daily update check and, if you turn on **Show Chat Limits**, claude.ai's usage numbers. The update check: it asks GitHub for this repo's latest release, and downloads it from GitHub when it's newer. Every release is signed with a private key kept outside this repository, and MultiClaude refuses any update whose signature doesn't match the public key built into the app. It also checks the bundle identifier, the version and the code signature before swapping itself. Turn off **Update MultiClaude Automatically** in Settings to stop it. **Usage and conversations** are read and kept on your Mac only: MultiClaude reads Claude Code's transcripts (in `~/.claude` and each account's folder) to count tokens, and keeps copies in `~/Library/Application Support/MultiClaude/Archive`, readable only by you. Turn off **Track Token Usage** and **Keep Claude Code Conversations** to stop both; delete that folder to remove the copies. **Show Chat Limits** is off until you turn it on and confirm: it then reads each account's claude.ai sign-in cookie (macOS asks you to allow "Claude Safe Storage" in the Keychain) and sends it to claude.ai only, never anywhere else; it is kept in memory and never written or logged. It does not modify the Claude app. The scroll reverser, when you turn it on, flips the direction of scroll events as they pass and keeps nothing. Removing a profile only takes it off the list: the folder stays on disk until you delete it yourself.

## FAQ

**Is this made by Anthropic?**
No. MultiClaude is an independent open source tool. It launches the official Claude app and does not change it.

**Does it work with Claude Code?**
Yes. In the desktop app, each Claude window and the Code tab inside it run with the account of its profile. For the CLI, right-click a profile and choose **Open Claude Code in Terminal**, or **Copy Claude Code Alias** for your shell. Each profile gets its own `~/.claude-<name>` folder, and Claude Code keeps a separate sign-in for each.

**Can I still use my aliases?**
Yes. MultiClaude reads the same folders, so an account opened from an alias shows as running in the panel. Right-click a profile and choose **Copy Shell Alias** to get one for a new profile.

**I already use the Claude app. How do I keep my chats when adding accounts?**
Right-click your default profile and choose **Duplicate as New Profile**, named for example `Personal`. The copy keeps your sign-in and history. You can then sign the default app out and in to another account, or simply add new profiles next to it.

**An account keeps logging out, or its sign-in never finishes.**
Claude asks every account to sign in again from time to time. Google and SSO sign-in returns from the browser through a `claude://` link that macOS gives to the first Claude window it finds, so with several accounts open it often lands in the wrong one. With **Sign In in Each Account's Window** on (the default), MultiClaude keeps the `claude://` links, and Claude then signs in through Apple's sign-in sheet inside the window that asked. Just click **Continue with Google** in the account that needs it; your other accounts stay open.

**Does an open account's window show its own name and icon?**
The icon, yes: with **App for Each Profile** on, each open account shows its profile icon in the Dock, ⌘-Tab and Mission Control. The name, no. A running app takes its name from inside its signed bundle, and renaming it there breaks the signature: Gatekeeper then reports the app as damaged. So an open window is still called Claude. The profile apps carry the name in Spotlight, Launchpad and on a pinned Dock tile, and the menu bar names the account in front.

**How do I remove an account completely?**
Right-click it and choose **Show Data Folder in Finder**, quit it, choose **Remove from List**, then trash the folder.

**What about Windows and Linux?**
MultiClaude is a native macOS app. A port is welcome.

## Build from source

```bash
git clone https://github.com/QuentinCar0n/multiclaude.git
cd multiclaude
./build.sh              # builds, installs to ~/Applications and launches
./build.sh --no-install # stops after build/MultiClaude-<version>.zip
```

Needs Xcode command line tools with Swift 6. Everything is in [`main.swift`](main.swift): SwiftUI views inside an AppKit menu bar panel.

Screenshots for this README come from a demo mode with sample profiles:

```bash
MULTICLAUDE_DEMO=1 MULTICLAUDE_PREVIEW=panel MULTICLAUDE_APPEARANCE=dark \
  ~/Applications/MultiClaude.app/Contents/MacOS/MultiClaude
```

## Releases

Push a `v*` tag and [GitHub Actions](.github/workflows/release.yml) builds a universal app, publishes the release with the matching [CHANGELOG](CHANGELOG.md) section, and bumps the Homebrew cask.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Ideas on the list: notarized builds, per-profile keyboard shortcuts, a profile color, and a Windows port.

## License

[Apache License 2.0](LICENSE). You can use, share and modify MultiClaude freely, including commercially. Contributors grant a patent license with their code, and anyone who sues over a patent in this project loses theirs.

The lid-closed part of Keep Awake follows [Insomnia](https://github.com/krishhgg/Insomnia) by Krish Garg (MIT); see [NOTICE](NOTICE).

Claude is a trademark of Anthropic, PBC. MultiClaude is not affiliated with or endorsed by Anthropic.

<div align="center"><sub>Made by <a href="https://somalabs.me">Soma Labs</a> in Palo Alto.</sub></div>
