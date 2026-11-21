# multiclaude command line reference

`multiclaude` is MultiClaude's command line tool, written in Go and shipped inside the app. It lists, opens, quits, adds and signs in Claude desktop accounts, runs Claude Code as one of them, reports Claude Code token usage per account, keeps the Mac awake and updates MultiClaude. It works with or without the MultiClaude app running, and both share one account list.

## Get it on your PATH

Homebrew links it for you. With a manual install:

```bash
ln -s /Applications/MultiClaude.app/Contents/Helpers/multiclaude /usr/local/bin/multiclaude
```

Building from source with `./build.sh` links it into `~/.local/bin` when that folder is on your `PATH`.

## Naming an account

`<account>` is a name in any case, the start of a name, or its number in `multiclaude list`.

## Accounts

| Command | What it does |
| --- | --- |
| `multiclaude list [--json]` | accounts, open or closed (alias `ls`) |
| `multiclaude open <account>... \| --all` | open or bring forward |
| `multiclaude quit <account>... \| --all` | quit (alias `close`) |
| `multiclaude login <account>` | sign in to the account in its own window (alias `signin`) |
| `multiclaude add <name>` | new account with its own Claude folder (alias `new`) |
| `multiclaude rename <account> <name>` | rename; the folder follows once it's closed |
| `multiclaude duplicate <account> <name>` | copy an account, sign-in and chats included (alias `dup`) |
| `multiclaude remove <account>` | take off the list, keep its folder (alias `rm`) |
| `multiclaude delete <account> [--yes]` | move its folder and Claude Code sign-in to the Trash |
| `multiclaude color <account> <color>` | orange, blue, green, purple, pink, teal, yellow, graphite |
| `multiclaude move <account> <up\|down\|N>` | reorder (alias `mv`) |
| `multiclaude mcp <account>` | list its MCP servers |
| `multiclaude mcp copy <from> <to>` | copy MCP servers between accounts |

## Claude Code

| Command | What it does |
| --- | --- |
| `multiclaude code <account> [args...]` | run Claude Code signed in as that account; extra arguments go to `claude` |
| `multiclaude env <account>` | shell line that points Claude Code at it: `eval "$(multiclaude env work)"` |
| `multiclaude path <account>` | the account's Claude data folder |
| `multiclaude usage [--days N] [--json]` | Claude Code tokens per account (default 7 days) |

## Mac and app

| Command | What it does |
| --- | --- |
| `multiclaude awake [on\|off\|<minutes>\|status]` | keep the Mac awake; `0` minutes means until `off` |
| `multiclaude update [--check]` | install the latest MultiClaude; `--check` only looks (alias `upgrade`) |
| `multiclaude version` | print the version |
| `multiclaude help` | print the usage text |

## Example session

```console
$ multiclaude list
#  ACCOUNT  COLOR   STATE   FOLDER
1  Claude   orange  open    ~/Library/Application Support/Claude
2  Work     blue    closed  ~/Library/Application Support/Claude-Work

$ multiclaude add Client
$ multiclaude login client
$ multiclaude open work
$ multiclaude code work
$ multiclaude awake 90
```

## With and without the app

While MultiClaude runs, the command hands it each action through `multiclaude://` links, so profile icons and the sign-in relay keep working, and it tells the app to reload the list after a change. Without the app, the command does the work itself and never starts the app:

- it builds the first account list and adopts new `Claude-*` folders, like the app does at launch;
- `open` starts Claude with the account's folder, `quit` asks Claude to quit;
- `login` closes your other accounts, opens this one alone, waits for the sign-in in Claude's log, then reopens the others;
- `usage` reads the Claude Code transcripts itself and keeps the same counts file as the app;
- `awake` runs `caffeinate` in the background, for the set minutes or until `awake off`;
- `update` asks the app bundle to check and install.

## multiclaude:// links

Scripts and Shortcuts can send the same links the command uses:

| Link | Effect |
| --- | --- |
| `multiclaude://open?profile=<id>` | open or bring forward that profile |
| `multiclaude://quit?profile=<id>` | quit it |
| `multiclaude://signin?profile=<id>` | sign in to it in its own window |
| `multiclaude://awake?minutes=<n>` | start keep-awake (`0` = until turned off) |
| `multiclaude://awake?off=1` | stop keep-awake |
| `multiclaude://reload` | reload the account list |
| `multiclaude://update` | same as Check for Updates; `?install=1` installs without asking |

Profile ids are in `multiclaude list --json`.

## Related

- [Use Claude Code with multiple accounts (CLAUDE_CONFIG_DIR)](claude-code-multiple-accounts-claude-config-dir.md)
- [Share MCP servers between Claude profiles](copy-mcp-servers-between-claude-profiles.md)
- [Track Claude Code token usage per account](track-claude-code-token-usage-per-account.md)
- [Install MultiClaude with Homebrew](install-multiclaude-with-homebrew.md)
- [README](../../README.md)
