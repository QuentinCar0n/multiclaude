# How to track Claude Code token usage per account

MultiClaude reads the token counts Claude Code writes for every reply on your Mac (Code tab, Cowork and terminal) and credits each session to the Claude account it ran in. The panel shows today's output per account, a window adds a 6-month heatmap, each account's share and a by-model table, and `multiclaude usage --days 30` prints the same from the terminal. Everything is read and kept on your Mac.

## From the terminal

```console
$ multiclaude usage              # last 7 days, per account
$ multiclaude usage --days 30
$ multiclaude usage --json       # for scripts
```

Without the app running, the command reads the transcripts itself and keeps the same counts file as the app.

## In the app

- **Usage Today** in the panel shows each account's output tokens.
- **Open Usage and Conversations…** opens a window with totals for today, 7 or 30 days or all time, each account's share, a 6-month heatmap (all accounts or one), output per reply, cache hit rate and a by-model table.
- Output is the default measure, since cache reads are most of the raw total. New Tokens and All Tokens are one click away.

## Where the numbers come from

- The JSONL transcripts Claude Code writes to `~/.claude/projects`, to each account's Claude Code folder and to each account's Cowork folder.
- A session is credited to the profile whose folder lists it, or to "Terminal" when none does.
- Replies seen twice are counted once.
- The first count reads every transcript once, then only what was added.

## Regular chats

Claude chats keep no token counts on the Mac. **Show Chat Limits** (off by default) asks claude.ai for each account's 5-hour and weekly limits, using that account's sign-in cookie. MultiClaude asks before turning it on, macOS asks for Keychain access to "Claude Safe Storage", and the cookie only goes to claude.ai. It uses an endpoint claude.ai doesn't document, so it may stop working.

## Keep Claude Code conversations past 30 days

Claude Code deletes transcripts after 30 days by default. **Keep Claude Code Conversations** (on by default) keeps an APFS clone of each one per account in `~/Library/Application Support/MultiClaude/Archive`, readable only by you. The window's **Conversations** tab lists them, searches them, shows each one and exports it to Markdown.

## Turn it off

Turn off **Track Token Usage** and **Keep Claude Code Conversations** in Settings. Delete the Archive folder to remove the copies.

## Related

- [Use Claude Code with multiple accounts (CLAUDE_CONFIG_DIR)](claude-code-multiple-accounts-claude-config-dir.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
