# How to share Claude Code between some Claude accounts and keep others apart

Put the accounts in the same MultiClaude account group: right-click a profile and choose **Group…**. Accounts in one group share one Claude Code folder (memory, `CLAUDE.md`, skills, plugins, settings and session history), and an account alone in its group keeps all of that to itself. A typical setup is two personal accounts in the group Personal and a company account in a group of its own. Account groups arrived in MultiClaude 1.11.

## Group folders

| Group | Claude Code folder (`CLAUDE_CONFIG_DIR`) |
| --- | --- |
| Personal | `~/.claude` (Claude Code's default) |
| Any other name, for example Client | `~/.claude-client` |
| No group | the profile's own folder, as before 1.11 |

The folder name is the group name in lowercase ASCII letters and digits, with accents folded and other characters turned into `-`. The app and the `multiclaude` command use the same rule. New group folders are created readable only by you.

## Set a group

1. Right-click a profile and choose **Group…**, then type or pick a group name.
2. For a new group, MultiClaude offers **Copy Setup** or **Start Empty**. Copy Setup copies `CLAUDE.md`, `skills`, `plugins`, `agents`, `commands` and `settings.json` from `~/.claude`, without overwriting anything already there. History, memory and transcripts never move.
3. Once more than one group exists, the panel lists profiles under their group names, and `multiclaude list` shows a GROUP column.

## How the isolation works

- MultiClaude opens a grouped account with its group's folder as `CLAUDE_CONFIG_DIR` (or with the variable removed for Personal).
- It then checks where that account's Code tab sessions really write. If they still use another folder, the panel says what to set: in that account's Claude, open Settings, Claude Code, environment variables, set `CLAUDE_CONFIG_DIR` to the group's folder, then start a new session.
- `multiclaude code <account>`, `multiclaude env <account>`, **Open Claude Code in Terminal** and **Copy Claude Code Alias** all follow the group.

## Leaving a group

If you had set `CLAUDE_CONFIG_DIR` in that account's Claude settings for the old group, change or remove it, then start a new session. Otherwise its sessions keep writing to the old group's folder.

## Related

- [Use Claude Code with multiple accounts (CLAUDE_CONFIG_DIR)](claude-code-multiple-accounts-claude-config-dir.md)
- [Track Claude Code token usage per account](track-claude-code-token-usage-per-account.md)
- [README](../../README.md)
