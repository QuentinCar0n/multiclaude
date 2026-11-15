package main

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Updates go through the app binary itself (--check-update, --update-now), so the CLI checks the release
// signature, bundle id and code signature exactly as the app's own updater does. While the app runs, the
// CLI asks it to install (multiclaude://update?install=1) so it can restart itself once its panel is closed.

// appFromPath returns the MultiClaude.app holding path (its main binary or this helper), or "".
func appFromPath(path string) string {
	i := strings.Index(path, "MultiClaude.app/Contents/")
	if i < 0 {
		return ""
	}
	return path[:i+len("MultiClaude.app")]
}

func appBundle() (string, error) {
	for _, p := range processes("MultiClaude") {
		if a := appFromPath(p.Exe); a != "" {
			return a, nil
		}
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			if a := appFromPath(real); a != "" {
				return a, nil
			}
		}
	}
	for _, a := range []string{filepath.Join(home(), "Applications/MultiClaude.app"), "/Applications/MultiClaude.app"} {
		if _, err := os.Stat(filepath.Join(a, "Contents/MacOS/MultiClaude")); err == nil {
			return a, nil
		}
	}
	return "", errors.New("MultiClaude.app not found in ~/Applications or /Applications")
}

// bundleStamp changes whenever the bundle is replaced, even by a build of the same version.
func bundleStamp(app string) string {
	fi, err := os.Stat(filepath.Join(app, "Contents/Info.plist"))
	if err != nil {
		return ""
	}
	return bundleVersion(app) + "|" + fi.ModTime().String()
}

func bundleVersion(app string) string {
	b, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-",
		filepath.Join(app, "Contents/Info.plist")).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// appTool runs the app binary with one flag and returns its output.
func appTool(app, flag string) (string, error) {
	b, err := exec.Command(filepath.Join(app, "Contents/MacOS/MultiClaude"), flag).CombinedOutput()
	s := strings.TrimSpace(string(b))
	if err != nil {
		if s == "" {
			s = err.Error()
		}
		return "", errors.New(strings.TrimPrefix(s, "failed: "))
	}
	return s, nil
}

func cmdUpdate(args []string, out io.Writer) error {
	checkOnly := false
	for _, a := range args {
		switch a {
		case "--check", "-n":
			checkOnly = true
		default:
			return fmt.Errorf("update takes only --check, not %q", a)
		}
	}
	app, err := appBundle()
	if err != nil {
		return err
	}
	status, err := appTool(app, "--check-update")
	if err != nil {
		return fmt.Errorf("couldn't check for updates: %w", err)
	}
	fmt.Fprintln(out, status)
	if checkOnly || !strings.HasSuffix(status, "update available") {
		return nil
	}
	before := bundleStamp(app)
	if !multiClaudeRunning() {
		msg, err := appTool(app, "--update-now")
		if err != nil {
			return fmt.Errorf("update failed: %w", err)
		}
		fmt.Fprintln(out, lastLine(msg))
		return nil
	}
	if err := openURL(link("update", url.Values{"install": {"1"}})); err != nil {
		return err
	}
	fmt.Fprintln(out, "MultiClaude is installing it...")
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		time.Sleep(time.Second)
		if bundleStamp(app) != before {
			v := bundleVersion(app)
			fmt.Fprintf(out, "Installed %s. MultiClaude restarts once its panel is closed.\n", v)
			return nil
		}
	}
	return errors.New("MultiClaude didn't install it (before 1.10 the app updates itself within a day; quit it and run multiclaude update again)")
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}
