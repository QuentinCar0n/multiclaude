# How to share MCP servers between Claude profiles

Each Claude desktop profile keeps its MCP servers in its own `claude_desktop_config.json`, inside that profile's data folder, so a server set up in one account is missing in the others. In MultiClaude, right-click the target profile and choose **Copy MCP Servers From**, then pick the source, or run `multiclaude mcp copy <from> <to>`. The target's config is backed up first.

## Where the config lives

| Profile | MCP config file |
| --- | --- |
| Default account | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| A profile named Work | `~/Library/Application Support/Claude-Work/claude_desktop_config.json` |

The servers are under the `mcpServers` key.

## From the menu bar

1. Set your MCP servers up once in one account.
2. Right-click another profile and choose **Copy MCP Servers From**, then the source profile.
3. If the target account is running, MultiClaude can reopen it in the same step so Claude loads the new servers.

## From the terminal

```console
$ multiclaude mcp work            # list Work's MCP servers
$ multiclaude mcp copy work acme  # copy Work's servers into Acme
```

## What the copy does

- Servers from the source are added to the target. A server with the same name is replaced.
- Every other key in the target file stays as it was.
- The target file is copied to `claude_desktop_config.json.bak-<YYYYMMDD-HHMMSS>` before it is written.
- If the source has no servers, the target file isn't touched.
- If either file exists but isn't valid JSON, the copy stops and nothing is written.

The app and the `multiclaude` command use the same rules.

## Scope

This copies the Claude desktop app's MCP servers. Claude Code's own configuration lives in the account's Claude Code folder (see [Use Claude Code with multiple accounts](claude-code-multiple-accounts-claude-config-dir.md)); accounts in the same [account group](share-claude-code-between-accounts-with-groups.md) share it.

## Related

- [How to use two Claude accounts at the same time on a Mac](use-two-claude-accounts-at-the-same-time-on-mac.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
