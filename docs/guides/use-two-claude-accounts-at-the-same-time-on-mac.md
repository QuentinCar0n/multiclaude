# How to use two Claude accounts at the same time on a Mac

The Claude desktop app signs in to one account at a time, but it accepts a `--user-data-dir` argument: each copy started with its own folder keeps its own sign-in, chats and settings. MultiClaude, a free open source menu bar app, turns that into one profile per account, so you can keep a personal plan and a work seat (or one organization per client) open side by side and switch with a click.

MultiClaude is an independent project. It is not affiliated with or endorsed by Anthropic, and it launches the official Claude app without changing it.

## What you need

- macOS 15 or later, Apple silicon or Intel.
- The [Claude desktop app](https://claude.ai/download) in `/Applications`.
- MultiClaude 1.11 or later (see [Install MultiClaude with Homebrew](install-multiclaude-with-homebrew.md)).

## Steps

1. Install MultiClaude:

   ```bash
   brew install --cask quentincar0n/tap/multiclaude
   ```

2. Click the ✳ icon in the menu bar.
3. Click **New Profile**, type a name such as `Work`, press Return.
4. Click the new profile. A fresh Claude window opens with an empty data folder: sign in to your second account there.
5. From now on, click `Work` to open it or bring it forward, and hover it to quit it. Your default account stays the first profile and keeps Claude's normal data folder.

The same from the terminal:

```console
$ multiclaude add Work      # new account with its own Claude folder
$ multiclaude login work    # sign in to it in its own window
$ multiclaude open work     # open it, or bring it forward
$ multiclaude list
```

## Where each account lives

| Account | Claude data folder | Claude Code folder |
| --- | --- | --- |
| Default | `~/Library/Application Support/Claude` | `~/.claude` |
| A profile named Work | `~/Library/Application Support/Claude-Work` | `~/.claude-work` |

Sign-ins, chats and settings never leak between folders. Accounts in an [account group](share-claude-code-between-accounts-with-groups.md) share one Claude Code folder instead.

## Telling the accounts apart

- Each profile has a color, used for its badge and in the menu bar.
- While a Claude window is in front, the menu bar shows that account's name in its color.
- With **Colored Claude Icon per Account** on, each account gets a small app in `~/Applications/MultiClaude Launchers` (for example "Claude Work") with Claude's icon recolored, and its open window shows that icon in the Dock, ⌘-Tab and Mission Control. The running window is still called Claude, because renaming it would break Anthropic's code signature.

## Things that otherwise break with several accounts

- **Sign-in lands in the wrong window.** Google and SSO sign-in comes back through a `claude://` link that macOS hands to the first Claude window. MultiClaude fixes this; see [Fix Google or SSO sign-in for a second Claude account](fix-google-sso-sign-in-for-a-second-claude-account.md).
- **Claude updates reopen on the default account.** When Claude updates itself it relaunches without `--user-data-dir`. MultiClaude notices and reopens each profile on its own account.

## Keep your current chats

If you already use Claude with one account, right-click the default profile and choose **Duplicate as New Profile** (for example `Personal`). The copy keeps your sign-in and history, made with APFS clones so it takes no extra space. You can then sign the default app in to another account.

## Related

- [Run Claude desktop with a separate profile using --user-data-dir](run-claude-desktop-with-user-data-dir.md)
- [Use Claude Code with multiple accounts (CLAUDE_CONFIG_DIR)](claude-code-multiple-accounts-claude-config-dir.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
