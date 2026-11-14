package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Keep-awake without the app: a detached caffeinate holds the same kind of assertion the app holds
// (idle sleep, and display sleep unless the app's "Allow Display Sleep" is on), for a set time or
// until `multiclaude awake off`. Its pid and end time live in cli-awake.json. With the app running,
// the app does it, so its panel and timers stay in charge.

type awakeState struct {
	PID   int   `json:"pid"`
	Until int64 `json:"until,omitempty"` // unix seconds; 0 = until turned off
}

func awakeStatePath() string {
	if f := testStore(); f != "" {
		return f + ".awake"
	}
	return filepath.Join(supportDir(), "MultiClaude/cli-awake.json")
}

func readAwake() (awakeState, bool) {
	var s awakeState
	b, err := os.ReadFile(awakeStatePath())
	if err != nil || json.Unmarshal(b, &s) != nil || s.PID <= 0 {
		return s, false
	}
	return s, isCaffeinate(s.PID)
}

// isCaffeinate guards against a reused pid: only a live caffeinate counts.
func isCaffeinate(pid int) bool {
	k, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || k.Proc.P_pid != int32(pid) {
		return false
	}
	return unix.ByteSliceToString(k.Proc.P_comm[:]) == "caffeinate"
}

func stopCLIAwake() bool {
	s, alive := readAwake()
	_ = os.Remove(awakeStatePath())
	if alive {
		_ = syscall.Kill(s.PID, syscall.SIGTERM)
	}
	return alive
}

func caffeinateArgs(minutes int, allowDisplaySleep bool) []string {
	args := []string{"-i"}
	if !allowDisplaySleep {
		args = append(args, "-d")
	}
	if minutes > 0 {
		args = append(args, "-t", strconv.Itoa(minutes*60))
	}
	return args
}

func startCLIAwake(minutes int) error {
	stopCLIAwake()
	cmd := exec.Command("/usr/bin/caffeinate", caffeinateArgs(minutes, readSettingBool("awake.allowDisplaySleep", false))...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // outlives the terminal
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("couldn't start caffeinate: %w", err)
	}
	s := awakeState{PID: cmd.Process.Pid}
	if minutes > 0 {
		s.Until = time.Now().Add(time.Duration(minutes) * time.Minute).Unix()
	}
	_ = cmd.Process.Release()
	b, _ := json.Marshal(s)
	_ = os.MkdirAll(filepath.Dir(awakeStatePath()), 0o755)
	return os.WriteFile(awakeStatePath(), b, 0o600)
}

func cmdAwake(args []string, out io.Writer) error {
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "status":
		fmt.Fprintln(out, awakeStatus(time.Now()))
		return nil
	case "off", "stop":
		stopCLIAwake()
		if awakeHeld() {
			return sendAwake(url.Values{"off": {"1"}}, false, out)
		}
		fmt.Fprintln(out, "Keep-awake is off")
		return nil
	case "on", "start":
		return turnAwakeOn(-1, out)
	}
	m, err := strconv.Atoi(strings.TrimSuffix(sub, "m"))
	if err != nil || m < 0 {
		return fmt.Errorf("awake takes on, off, status or a number of minutes, not %q", sub)
	}
	return turnAwakeOn(m, out)
}

// turnAwakeOn with minutes -1 uses the app's saved duration (awake.minutes, 0 = until off).
func turnAwakeOn(minutes int, out io.Writer) error {
	if multiClaudeRunning() {
		stopCLIAwake() // one keeper at a time
		q := url.Values{}
		if minutes >= 0 {
			q.Set("minutes", strconv.Itoa(minutes))
		}
		return sendAwake(q, true, out)
	}
	if minutes < 0 {
		minutes = max(0, readSettingInt("awake.minutes", 0))
	}
	if err := startCLIAwake(minutes); err != nil {
		return err
	}
	fmt.Fprintln(out, awakeStatus(time.Now()))
	return nil
}

func awakeStatus(now time.Time) string {
	if awakeHeld() {
		return "Keep-awake is on (MultiClaude)"
	}
	s, alive := readAwake()
	if !alive {
		return "Keep-awake is off"
	}
	if s.Until == 0 {
		return "Keep-awake is on until you turn it off"
	}
	left := time.Unix(s.Until, 0).Sub(now).Round(time.Minute)
	return fmt.Sprintf("Keep-awake is on for %s more", strings.TrimSuffix(left.String(), "0s"))
}

func sendAwake(q url.Values, on bool, out io.Writer) error {
	if err := openURL(link("awake", q)); err != nil {
		return err
	}
	deadline := time.Now().Add(5 * time.Second)
	for awakeHeld() != on {
		if time.Now().After(deadline) {
			return errors.New("MultiClaude didn't change keep-awake (update the app to 1.8 or later)")
		}
		time.Sleep(200 * time.Millisecond)
	}
	if on {
		fmt.Fprintln(out, "Keep-awake is on (MultiClaude)")
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
