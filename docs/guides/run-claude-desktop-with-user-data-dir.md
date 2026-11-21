# How to run Claude desktop with a separate profile using --user-data-dir

Start a second copy of Claude with `open -n` and pass it its own data folder: `open -n -b com.anthropic.claudefordesktop --args --user-data-dir="$HOME/Library/Application Support/Claude-Work"`. That copy keeps its own sign-in, chats and settings in that folder. MultiClaude runs exactly this command for each profile and adds live status, sign-in routing and recovery after Claude updates.

## The manual way

```bash
open -n -b com.anthropic.claudefordesktop --args \
  --user-data-dir="$HOME/Library/Application Support/Claude-Work"
```

- `-n` starts a new instance even when Claude is already running.
- `-b com.anthropic.claudefordesktop` finds Claude by its bundle id, wherever it is installed.
- `--user-data-dir=<folder>` is passed to Claude. An empty folder starts signed out.

Many people keep this as a shell alias in `~/.zshrc`, for example:

```bash
alias claude-work='open -n -a "Claude" --args --user-data-dir="$HOME/Library/Application Support/Claude-Work"'
```

The default account needs no argument: `open -b com.anthropic.claudefordesktop` uses `~/Library/Application Support/Claude`.

## Limits of plain aliases

| | Shell aliases | MultiClaude |
| --- | :---: | :---: |
| See which accounts are open | no | yes, live |
| Bring an open account forward | re-run the alias | click it again |
| Add an account | edit `~/.zshrc` | type a name, press Return |
| After Claude updates itself | windows come back on the default account | profiles reopen on their own accounts |
| Google or SSO sign-in | returns to the first Claude window | returns to the window that asked |
| Tell windows apart | same icon everywhere | a color and icon per account |

## Moving from aliases to MultiClaude

On first launch MultiClaude imports your default Claude account, any `--user-data-dir` aliases in `~/.zshrc`, and any `Claude-*` folder in `~/Library/Application Support`. A `Claude-*` folder created later joins the list on its own. Accounts opened from an alias still show as running, since MultiClaude reads each Claude process's `--user-data-dir` argument.

To get an alias for a MultiClaude profile, right-click it and choose **Copy Shell Alias**.

## How MultiClaude names folders

- New profiles get `~/Library/Application Support/Claude-<Name>`.
- After a rename, the folder becomes `Claude-<Name>` the next time that account is closed, with a link left at the old path so old aliases and the absolute paths Claude saves keep working.
- MultiClaude never moves the folder of an account that is open.
- **Remove from List** keeps the folder. **Delete Profile…** moves it to the Trash after you confirm.

## Related

- [How to use two Claude accounts at the same time on a Mac](use-two-claude-accounts-at-the-same-time-on-mac.md)
- [Fix Google or SSO sign-in for a second Claude account](fix-google-sso-sign-in-for-a-second-claude-account.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
