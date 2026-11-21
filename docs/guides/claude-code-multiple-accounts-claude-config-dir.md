# How to use Claude Code with multiple accounts (CLAUDE_CONFIG_DIR)

Claude Code reads its sign-in, settings and history from the folder in `CLAUDE_CONFIG_DIR` (`~/.claude` when it is unset), so one folder per account gives one Claude Code sign-in per account. With MultiClaude, run `multiclaude code work` to start Claude Code as the Work account, or `eval "$(multiclaude env work)"` to point the current shell at it. Each MultiClaude profile gets its own `~/.claude-<name>` folder.

## The folders

| Profile | `CLAUDE_CONFIG_DIR` |
| --- | --- |
| Default account | unset, so `~/.claude` |
| A profile whose data folder is `Claude-Work` | `~/.claude-work` |
| A profile in a group named Client | `~/.claude-client` |
| A profile in the group named Personal | unset, so `~/.claude` |

A profile's Claude Code folder keeps its old path after a rename, so its sign-in survives.

## From the terminal

```console
$ multiclaude code work                 # runs `claude` with CLAUDE_CONFIG_DIR set for Work
$ multiclaude code work -- --resume     # extra arguments go to claude
$ eval "$(multiclaude env work)"        # export CLAUDE_CONFIG_DIR=... in this shell
$ multiclaude env claude                # the default account prints: unset CLAUDE_CONFIG_DIR
```

`multiclaude code` needs Claude Code installed (`claude` on your `PATH`). It creates the folder if needed and replaces itself with `claude`, so the session behaves as if you had typed `claude` yourself.

## From the menu bar

Right-click a profile:

- **Open Claude Code in Terminal** opens Terminal with the CLI signed in as that account.
- **Copy Claude Code Alias** copies a line such as `alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.claude-work" claude'` for your shell.

The first time you run Claude Code in a new folder, sign in once. Claude Code keeps a separate sign-in per folder after that.

## Without MultiClaude

The same works by hand:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
```

## The Code tab in the desktop app

Accounts in an [account group](share-claude-code-between-accounts-with-groups.md) are started with their group's folder as `CLAUDE_CONFIG_DIR`. MultiClaude then checks where that account's Code tab sessions really write. If they still use another folder, the panel tells you to open that account's Claude Settings, Claude Code, environment variables, set `CLAUDE_CONFIG_DIR` to the group's folder, then start a new session.

## Related

- [Share Claude Code between some accounts with account groups](share-claude-code-between-accounts-with-groups.md)
- [Track Claude Code token usage per account](track-claude-code-token-usage-per-account.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
