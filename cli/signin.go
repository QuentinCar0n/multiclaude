package main

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Sign-in without the app. Claude's browser sign-in comes back as a claude:// link, which macOS hands
// to whichever Claude is open first. The app can relay it to the right window; the CLI uses the app's
// fallback instead: close the other accounts, open this one alone, wait for the sign-in, reopen them.

func signInLog() string { return filepath.Join(home(), "Library/Logs/Claude/main.log") }

func fileSize(path string) int64 {
	fi, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return fi.Size()
}

// readFrom returns the log lines after offset and the new offset (from 0 when the log rotated).
func readFrom(path string, offset int64) ([]string, int64) {
	f, err := os.Open(path)
	if err != nil {
		return nil, offset
	}
	defer f.Close()
	end, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return nil, offset
	}
	if end < offset {
		offset = 0
	}
	buf := make([]byte, end-offset)
	n, _ := f.ReadAt(buf, offset)
	return strings.Split(string(buf[:n]), "\n"), offset + int64(n)
}

// scanSignIn matches SignInLog.scan: done once the browser sign-in came back, or the account reports
// logged in after the browser step (a plain "logged in" at launch is not enough).
func scanSignIn(lines []string, sawBrowser bool) (saw, done bool) {
	saw = sawBrowser
	for _, l := range lines {
		if strings.Contains(l, "[Auth] Using system browser") || strings.Contains(l, "[Auth] Starting ASWebAuth") {
			saw = true
		}
		if strings.Contains(l, "[Auth] ASWebAuth completed") || strings.Contains(l, "claudeURLHandler: login") {
			return true, true
		}
		if saw && strings.Contains(l, "account active and logged in") {
			return saw, true
		}
	}
	return saw, false
}

func cmdLogin(args []string, out io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: multiclaude login <account>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, err := find(list, args[0])
	if err != nil {
		return err
	}
	if multiClaudeRunning() {
		if err := openURL(link("signin", url.Values{"profile": {p.ID}})); err != nil {
			return err
		}
		fmt.Fprintf(out, "MultiClaude is getting %s ready: sign in in its window.\n", p.Name)
		return nil
	}
	running := runningClaudes(list)
	var others []Profile
	for _, o := range list {
		if o.ID != p.ID && running[o.ID] != 0 {
			others = append(others, o)
		}
	}
	reopen := func() {
		for _, o := range others {
			if runningClaudes(list)[o.ID] == 0 {
				_ = openDirect(o, true)
			}
		}
		if len(others) > 0 {
			fmt.Fprintf(out, "Reopened %s\n", names(others))
		}
	}
	if len(others) > 0 {
		fmt.Fprintf(out, "Closing %s so the sign-in can only come back to %s\n", names(others), p.Name)
	}
	var closed []Profile
	for _, o := range others {
		if !quitAndWait(o, list, 15*time.Second) {
			others = closed
			reopen()
			return fmt.Errorf("%s didn't quit (it may be asking something in its window)", o.Name)
		}
		closed = append(closed, o)
	}
	logPath := signInLog()
	offset := fileSize(logPath)
	if running[p.ID] == 0 {
		if err := openDirect(p, false); err != nil {
			reopen()
			return err
		}
	} else {
		_ = bringForward(running[p.ID])
	}
	fmt.Fprintf(out, "Sign in to %s in its window. Waiting for it (Ctrl-C to stop)...\n", p.Name)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stop)
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	deadline := time.After(10 * time.Minute)
	saw := false
	for {
		select {
		case <-stop:
			reopen()
			return errors.New("sign-in stopped")
		case <-deadline:
			reopen()
			return errors.New("no sign-in after 10 minutes")
		case <-tick.C:
			var lines []string
			lines, offset = readFrom(logPath, offset)
			var done bool
			if saw, done = scanSignIn(lines, saw); done {
				fmt.Fprintf(out, "Signed in to %s\n", p.Name)
				reopen()
				return nil
			}
		}
	}
}

func names(list []Profile) string {
	n := make([]string, len(list))
	for i, p := range list {
		n[i] = p.Name
	}
	switch len(n) {
	case 0:
		return ""
	case 1:
		return n[0]
	}
	return strings.Join(n[:len(n)-1], ", ") + " and " + n[len(n)-1]
}
