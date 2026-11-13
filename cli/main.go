// multiclaude is the command line side of MultiClaude: list, open and quit your Claude accounts,
// start Claude Code signed in as one of them, read token usage and drive keep-awake.
//
// It reads the accounts the MultiClaude app saved and hands actions to the app through
// multiclaude:// links, so the app's own logic (profile copies, sign-in relay, Dock apps) still runs.
// When the app isn't installed, open and quit fall back to starting and signalling Claude directly.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"
)

var version = "dev" // set by build.sh with -ldflags "-X main.version=..."

const usageText = `multiclaude: your Claude accounts from the terminal

Usage:
  multiclaude list [--json]              accounts, open or closed
  multiclaude open <account>... | --all  open or bring forward
  multiclaude quit <account>... | --all  quit
  multiclaude code <account> [args...]   run Claude Code signed in as that account
  multiclaude env <account>              shell line that points Claude Code at it:
                                           eval "$(multiclaude env work)"
  multiclaude path <account>             the account's Claude data folder
  multiclaude usage [--days N] [--json]  Claude Code tokens per account (default 7 days)
  multiclaude awake [on|off|<minutes>|status]
                                         keep the Mac awake (0 minutes = until off)
  multiclaude version

<account> is a name (any case), the start of one, or its number in "multiclaude list".
`

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "multiclaude:", err)
		os.Exit(1)
	}
}

func run(args []string, out io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(out, usageText)
		return nil
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "list", "ls":
		return cmdList(rest, out)
	case "open":
		return cmdOpenQuit(rest, out, true)
	case "quit", "close":
		return cmdOpenQuit(rest, out, false)
	case "code", "claude":
		return cmdCode(rest)
	case "env":
		return cmdEnv(rest, out)
	case "path":
		return withOne(rest, func(p Profile) error { fmt.Fprintln(out, p.Folder()); return nil })
	case "usage":
		return cmdUsage(rest, out)
	case "awake":
		return cmdAwake(rest, out)
	case "version", "--version", "-v":
		fmt.Fprintln(out, "multiclaude", version)
		return nil
	case "help", "--help", "-h":
		fmt.Fprint(out, usageText)
		return nil
	}
	return fmt.Errorf("unknown command %q (try `multiclaude help`)", cmd)
}

func withOne(args []string, f func(Profile) error) error {
	if len(args) != 1 {
		return errors.New("name one account")
	}
	list, err := loadProfiles()
	if err != nil {
		return err
	}
	p, err := find(list, args[0])
	if err != nil {
		return err
	}
	return f(p)
}

// MARK: list

type listRow struct {
	Number  int    `json:"number"`
	ID      string `json:"id"`
	Name    string `json:"name"`
	Open    bool   `json:"open"`
	PID     int    `json:"pid,omitempty"`
	Folder  string `json:"folder"`
	CodeDir string `json:"codeConfigDir"`
	Default bool   `json:"default"`
}

func cmdList(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	list, err := loadProfiles()
	if err != nil {
		return err
	}
	running := runningClaudes(list)
	rows := make([]listRow, len(list))
	for i, p := range list {
		code := p.CodeConfigDir()
		if code == "" {
			code = home() + "/.claude"
		}
		rows[i] = listRow{Number: i + 1, ID: p.ID, Name: p.Name, PID: running[p.ID], Open: running[p.ID] != 0,
			Folder: p.Folder(), CodeDir: code, Default: p.IsDefault()}
	}
	if *asJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "#\tACCOUNT\tSTATE\tFOLDER")
	for _, r := range rows {
		state := "closed"
		if r.Open {
			state = "open"
		}
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\n", r.Number, r.Name, state, tildePath(r.Folder))
	}
	return tw.Flush()
}

// MARK: open / quit

func cmdOpenQuit(args []string, out io.Writer, opening bool) error {
	name := "open"
	if !opening {
		name = "quit"
	}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	all := fs.Bool("all", false, "every account")
	noWait := fs.Bool("no-wait", false, "don't wait for Claude to start or stop")
	if err := fs.Parse(args); err != nil {
		return err
	}
	list, err := loadProfiles()
	if err != nil {
		return err
	}
	var targets []Profile
	if *all {
		targets = list
	} else {
		if fs.NArg() == 0 {
			return fmt.Errorf("name an account, or use --all")
		}
		for _, q := range fs.Args() {
			p, err := find(list, q)
			if err != nil {
				return err
			}
			targets = append(targets, p)
		}
	}
	running := runningClaudes(list)
	app := multiClaudeRunning()
	var failed []string
	for _, p := range targets {
		var err error
		if opening {
			err = openOne(p, list, running, !*noWait, out)
		} else {
			err = quitOne(p, list, running, app, !*noWait, out)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "multiclaude: %s: %v\n", p.Name, err)
			failed = append(failed, p.Name)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("%s failed for %s", name, strings.Join(failed, ", "))
	}
	return nil
}

func link(action string, q url.Values) string {
	return "multiclaude://" + action + "?" + q.Encode()
}

func openURL(u string) error {
	return exec.Command("/usr/bin/open", "-g", u).Run()
}

func openOne(p Profile, list []Profile, running map[string]int, wait bool, out io.Writer) error {
	was := running[p.ID] != 0
	// Through the app first, like a profile's Dock app: it opens MultiClaude if needed, then the
	// account from its own copy of Claude, or brings a running one forward.
	if err := openURL(link("open", url.Values{"profile": {p.ID}})); err != nil {
		if err := openDirect(p, len(running) > 0); err != nil {
			return err
		}
	}
	if was {
		fmt.Fprintf(out, "%s brought forward\n", p.Name)
		return nil
	}
	if !wait {
		fmt.Fprintf(out, "Opening %s\n", p.Name)
		return nil
	}
	if pid := waitFor(p, list, true, 30*time.Second); pid != 0 {
		fmt.Fprintf(out, "%s is open (pid %d)\n", p.Name, pid)
		return nil
	}
	return errors.New("Claude didn't start within 30 s")
}

// openDirect starts Claude without MultiClaude, with the same arguments as Launch.openArgs.
func openDirect(p Profile, anyClaudeRunning bool) error {
	var args []string
	switch {
	case p.Dir != nil:
		if err := os.MkdirAll(*p.Dir, 0o755); err != nil {
			return err
		}
		args = []string{"-n", "-b", "com.anthropic.claudefordesktop", "--args", "--user-data-dir=" + *p.Dir}
	case anyClaudeRunning:
		args = []string{"-n", "-b", "com.anthropic.claudefordesktop"}
	default:
		args = []string{"-b", "com.anthropic.claudefordesktop"}
	}
	if err := exec.Command("/usr/bin/open", args...).Run(); err != nil {
		return errors.New("Claude isn't installed (get it at claude.ai/download)")
	}
	return nil
}

func quitOne(p Profile, list []Profile, running map[string]int, app, wait bool, out io.Writer) error {
	pid := running[p.ID]
	if pid == 0 {
		fmt.Fprintf(out, "%s isn't open\n", p.Name)
		return nil
	}
	// The app quits it the way its panel does, so it doesn't take the quit for a crash.
	asked := app && openURL(link("quit", url.Values{"profile": {p.ID}})) == nil
	if !asked {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	if !wait {
		fmt.Fprintf(out, "Quitting %s\n", p.Name)
		return nil
	}
	if waitFor(p, list, false, 10*time.Second) == 0 {
		fmt.Fprintf(out, "%s quit\n", p.Name)
		return nil
	}
	if asked { // an older MultiClaude ignores quit links
		_ = syscall.Kill(pid, syscall.SIGTERM)
		if waitFor(p, list, false, 10*time.Second) == 0 {
			fmt.Fprintf(out, "%s quit\n", p.Name)
			return nil
		}
	}
	return errors.New("Claude is still running (it may be asking something in its window)")
}

// waitFor polls until the account is open (returns its pid) or closed (returns 0), or time runs out.
func waitFor(p Profile, list []Profile, open bool, timeout time.Duration) int {
	deadline := time.Now().Add(timeout)
	for {
		pid := runningClaudes(list)[p.ID]
		if (pid != 0) == open || time.Now().After(deadline) {
			return pid
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// MARK: Claude Code

// codeEnv is the environment for Claude Code as this account: CLAUDE_CONFIG_DIR set to its folder,
// or removed for the default account, which keeps ~/.claude.
func codeEnv(p Profile, env []string) []string {
	out := make([]string, 0, len(env)+1)
	for _, e := range env {
		if !strings.HasPrefix(e, "CLAUDE_CONFIG_DIR=") {
			out = append(out, e)
		}
	}
	if dir := p.CodeConfigDir(); dir != "" {
		out = append(out, "CLAUDE_CONFIG_DIR="+dir)
	}
	return out
}

func cmdCode(args []string) error {
	if len(args) == 0 {
		return errors.New("name an account: multiclaude code <account> [claude arguments]")
	}
	list, err := loadProfiles()
	if err != nil {
		return err
	}
	p, err := find(list, args[0])
	if err != nil {
		return err
	}
	rest := args[1:]
	if len(rest) > 0 && rest[0] == "--" {
		rest = rest[1:]
	}
	if dir := p.CodeConfigDir(); dir != "" {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	bin, err := exec.LookPath("claude")
	if err != nil {
		return errors.New("Claude Code isn't installed (no `claude` on your PATH)")
	}
	return syscall.Exec(bin, append([]string{"claude"}, rest...), codeEnv(p, os.Environ()))
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func cmdEnv(args []string, out io.Writer) error {
	return withOne(args, func(p Profile) error {
		if dir := p.CodeConfigDir(); dir != "" {
			fmt.Fprintf(out, "export CLAUDE_CONFIG_DIR=%s\n", shellQuote(dir))
		} else {
			fmt.Fprintln(out, "unset CLAUDE_CONFIG_DIR")
		}
		return nil
	})
}

// MARK: usage

func cmdUsage(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("usage", flag.ContinueOnError)
	days := fs.Int("days", 7, "how many days, today included")
	asJSON := fs.Bool("json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	list, _ := loadProfiles() // names only; usage still prints with ids when the list is missing
	s, err := loadUsage()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errors.New("no usage yet: MultiClaude counts tokens while it runs")
		}
		return err
	}
	rows := summarize(s, sinceDay(time.Now(), *days), list)
	if *asJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	if len(rows) == 0 {
		fmt.Fprintf(out, "No Claude Code usage in the last %d days\n", *days)
		return nil
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', tabwriter.AlignRight)
	// Names stay left-aligned: pad them to one width, so right alignment has nothing to move.
	w := len("ACCOUNT")
	for _, r := range rows {
		w = max(w, len(r.Name))
	}
	fmt.Fprintf(tw, "%-*s\tOUTPUT\tINPUT\tCACHE WRITE\tCACHE READ\tMESSAGES\t\n", w, "ACCOUNT")
	var sum Totals
	for _, r := range rows {
		t := r.Totals
		sum.add(t)
		fmt.Fprintf(tw, "%-*s\t%s\t%s\t%s\t%s\t%d\t\n", w, r.Name, short(t.Output), short(t.Input), short(t.CacheWrite), short(t.CacheRead), t.Messages)
	}
	if len(rows) > 1 {
		fmt.Fprintf(tw, "%-*s\t%s\t%s\t%s\t%s\t%d\t\n", w, "All", short(sum.Output), short(sum.Input), short(sum.CacheWrite), short(sum.CacheRead), sum.Messages)
	}
	if err := tw.Flush(); err != nil {
		return err
	}
	fmt.Fprintf(out, "Last %d days, Claude Code only (chats keep no token counts on the Mac)\n", *days)
	return nil
}

// short prints 1234 as 1.2K and 5600000 as 5.6M.
func short(n int) string {
	switch {
	case n >= 1_000_000_000:
		return strconv.FormatFloat(float64(n)/1e9, 'f', 1, 64) + "B"
	case n >= 1_000_000:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + "M"
	case n >= 1_000:
		return strconv.FormatFloat(float64(n)/1e3, 'f', 1, 64) + "K"
	}
	return strconv.Itoa(n)
}

// MARK: keep-awake

func cmdAwake(args []string, out io.Writer) error {
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "status":
		if awakeHeld() {
			fmt.Fprintln(out, "Keep-awake is on")
		} else {
			fmt.Fprintln(out, "Keep-awake is off")
		}
		return nil
	case "off", "stop":
		return sendAwake(url.Values{"off": {"1"}}, false, out)
	case "on", "start":
		return sendAwake(url.Values{}, true, out)
	}
	m, err := strconv.Atoi(strings.TrimSuffix(sub, "m"))
	if err != nil || m < 0 {
		return fmt.Errorf("awake takes on, off, status or a number of minutes, not %q", sub)
	}
	return sendAwake(url.Values{"minutes": {strconv.Itoa(m)}}, true, out)
}

func sendAwake(q url.Values, on bool, out io.Writer) error {
	if err := openURL(link("awake", q)); err != nil {
		return errors.New("keep-awake needs the MultiClaude app (brew install --cask quentincar0n/tap/multiclaude)")
	}
	deadline := time.Now().Add(5 * time.Second)
	for awakeHeld() != on {
		if time.Now().After(deadline) {
			return errors.New("MultiClaude didn't change keep-awake (update the app to 1.8 or later)")
		}
		time.Sleep(200 * time.Millisecond)
	}
	if on {
		fmt.Fprintln(out, "Keep-awake is on")
	} else {
		fmt.Fprintln(out, "Keep-awake is off")
	}
	return nil
}

// awakeHeld is true while MultiClaude holds a sleep assertion, which is what its keep-awake is.
func awakeHeld() bool {
	b, err := exec.Command("/usr/bin/pmset", "-g", "assertions").Output()
	if err != nil {
		return false
	}
	return assertionHeld(string(b))
}

func assertionHeld(pmset string) bool {
	for _, line := range strings.Split(pmset, "\n") {
		if strings.Contains(line, "(MultiClaude)") && strings.Contains(line, "PreventUserIdle") {
			return true
		}
	}
	return false
}
