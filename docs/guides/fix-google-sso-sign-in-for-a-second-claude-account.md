# How to fix Google or SSO sign-in for a second Claude account

When several Claude windows are open, Google and SSO sign-in often never finishes in the second account: the browser sends you back through a `claude://` link, and macOS delivers that link to the first Claude window it finds. MultiClaude fixes this with **Sign In in Each Account's Window** (on by default): it holds the `claude://` links, so Claude signs in through Apple's sign-in sheet inside the window that asked. Click **Continue with Google** in the account that needs it; your other accounts stay open.

## Why it happens

Claude only sends Google and SSO sign-in through the browser when it is the `claude://` handler. The answer comes back as a `claude://` link, and with several instances running, macOS picks one, usually the first. The account that started the sign-in waits forever, or the wrong account receives it.

When Claude is not the `claude://` handler, it signs in with Apple's in-window sheet instead (Claude logs "Not the claude:// handler; keeping ASWebAuth"). MultiClaude uses that.

## What MultiClaude does

- It takes the `claude://` links a few seconds after any Claude window starts, since Claude claims them again as it starts.
- It passes other `claude://` links to the Claude window in front, or to the one used last. Links that aren't `claude://` are ignored.
- Links go back to Claude when the setting is off or MultiClaude quits.
- Relays and sign-ins are logged to `~/Library/Logs/MultiClaude.log`, without the links' parameters.

## If an account still can't sign in

1. Check that **Sign In in Each Account's Window** is on in MultiClaude's Settings.
2. Right-click the profile and choose **Sign In to <name>…**.
3. Or, from the terminal:

   ```console
   $ multiclaude login work
   ```

   Without the app running, `login` closes your other accounts, opens this one alone so the browser sign-in can only come back to it, waits for the sign-in in Claude's log, then reopens the others. With the app running, the command hands the sign-in to the app.

## Accounts that keep logging out

Claude asks every account to sign in again from time to time. That's Claude's own behavior. With the relay on, signing in again happens in the right window.

## Related

- [How to use two Claude accounts at the same time on a Mac](use-two-claude-accounts-at-the-same-time-on-mac.md)
- [Run Claude desktop with a separate profile using --user-data-dir](run-claude-desktop-with-user-data-dir.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
