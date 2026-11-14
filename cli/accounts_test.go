package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// acctSandbox points HOME and the account list at a temp folder.
func acctSandbox(t *testing.T) (homeDir, store string) {
	t.Helper()
	homeDir = t.TempDir()
	t.Setenv("HOME", homeDir)
	store = filepath.Join(homeDir, "profiles.json")
	t.Setenv("MULTICLAUDE_PROFILES_JSON", store)
	if err := os.MkdirAll(filepath.Join(homeDir, "Library/Application Support"), 0o755); err != nil {
		t.Fatal(err)
	}
	return homeDir, store
}

func runCLI(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(args, &out); err != nil {
		t.Fatalf("multiclaude %s: %v", strings.Join(args, " "), err)
	}
	return out.String()
}

func TestProfileKeepsUnknownKeys(t *testing.T) {
	in := `[{"id":"ABCD-1","name":"Work","dir":"/x/Claude-Work","openAtLaunch":true,"future":{"a":1}}]`
	list, err := decodeProfiles([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	list[0].Name = "Job"
	b, _ := json.Marshal(list)
	var got []map[string]any
	_ = json.Unmarshal(b, &got)
	if got[0]["name"] != "Job" || got[0]["openAtLaunch"] != true || got[0]["future"] == nil {
		t.Fatalf("round trip lost data: %s", b)
	}
	if _, ok := got[0]["color"]; ok {
		t.Fatalf("nil color should be left out like Swift does: %s", b)
	}
}

func TestDefaultProfileHasNoDirKey(t *testing.T) {
	b, _ := json.Marshal([]Profile{{ID: "A", Name: "Claude"}})
	if strings.Contains(string(b), `"dir"`) {
		t.Fatalf("default profile wrote a dir key: %s", b)
	}
}

func TestSeedAndDiscover(t *testing.T) {
	h, _ := acctSandbox(t)
	sup := filepath.Join(h, "Library/Application Support")
	for _, d := range []string{"Claude-Work", "Claude-3p", "Claude-Old"} {
		_ = os.Mkdir(filepath.Join(sup, d), 0o755)
	}
	_ = os.WriteFile(filepath.Join(h, ".zshrc"), []byte(`alias perso='open -n -a "Claude" --args --user-data-dir="$HOME/Library/Application Support/Claude-Perso"'`+"\n"), 0o644)
	_ = setIgnoredFolders([]string{canonical(filepath.Join(sup, "Claude-Old"))})
	out := runCLI(t, "list")
	for _, want := range []string{"Claude", "Perso", "Work"} {
		if !strings.Contains(out, want) {
			t.Fatalf("list misses %s:\n%s", want, out)
		}
	}
	// Seed takes every Claude-* folder (like the app's first run); discover then skips ignored ones.
	list, _ := loadProfiles()
	colors := map[int]bool{}
	for _, p := range list {
		if p.Color == nil || colors[*p.Color] {
			t.Fatalf("each account needs its own color: %+v", list)
		}
		colors[*p.Color] = true
		if p.Name == "3p" {
			t.Fatal("Claude-3p is Claude's own folder")
		}
	}
}

func TestAddRenameMoveRemove(t *testing.T) {
	h, store := acctSandbox(t)
	_ = os.WriteFile(store, []byte(`[{"id":"D","name":"Claude","color":0}]`), 0o600)
	runCLI(t, "add", "Side Project")
	list, _ := loadProfiles()
	if len(list) != 2 || list[1].Name != "Side Project" || *list[1].Dir != filepath.Join(h, "Library/Application Support/Claude-SideProject") {
		t.Fatalf("add: %+v", list)
	}
	if err := run([]string{"add", "side project"}, &bytes.Buffer{}); err == nil {
		t.Fatal("a taken name should fail")
	}
	runCLI(t, "rename", "side", "Client")
	runCLI(t, "move", "client", "up")
	runCLI(t, "color", "client", "teal")
	list, _ = loadProfiles()
	if list[0].Name != "Client" || *list[0].Color != 5 {
		t.Fatalf("rename/move/color: %+v", list)
	}
	runCLI(t, "remove", "client")
	list, _ = loadProfiles()
	if len(list) != 1 || !reflect.DeepEqual(ignoredFolders(), []string{canonical(filepath.Join(h, "Library/Application Support/Claude-SideProject"))}) {
		t.Fatalf("remove: %+v %v", list, ignoredFolders())
	}
	if err := run([]string{"remove", "claude"}, &bytes.Buffer{}); err == nil {
		t.Fatal("the default account can't be removed")
	}
}

func TestFolderTargetAndAlign(t *testing.T) {
	h, _ := acctSandbox(t)
	sup := filepath.Join(h, "Library/Application Support")
	old := filepath.Join(sup, "Claude-Work")
	_ = os.Mkdir(old, 0o755)
	if got := folderTarget("Work", old, sup); got != "" {
		t.Fatalf("already aligned, got %q", got)
	}
	if got := folderTarget("Job", "/elsewhere/Claude-Work", sup); got != "" {
		t.Fatalf("outside support, got %q", got)
	}
	p := Profile{Name: "Job", Dir: strPtr(old)}
	alignFolder(&p, false)
	if *p.Dir != filepath.Join(sup, "Claude-Job") {
		t.Fatalf("dir = %s", *p.Dir)
	}
	if to, err := os.Readlink(old); err != nil || to != *p.Dir {
		t.Fatalf("old path should link to the new folder: %q %v", to, err)
	}
	if p.CodeDir != nil {
		t.Fatal("no Claude Code folder existed, nothing to pin")
	}
}

func TestFolderInUse(t *testing.T) {
	d := t.TempDir()
	if folderInUse(d) {
		t.Fatal("no lock")
	}
	_ = os.Symlink("host-"+itoa(os.Getpid()), filepath.Join(d, "SingletonLock"))
	if !folderInUse(d) {
		t.Fatal("lock of a live pid")
	}
	_ = os.Remove(filepath.Join(d, "SingletonLock"))
	_ = os.Symlink("host-999999", filepath.Join(d, "SingletonLock"))
	if folderInUse(d) {
		t.Fatal("stale lock")
	}
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func TestCopyMCP(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	src, dst := Profile{Name: "A", Dir: &a}, Profile{Name: "B", Dir: &b}
	_ = os.WriteFile(mcpConfig(src), []byte(`{"mcpServers":{"x":{"command":"x"},"y":{"command":"y"}}}`), 0o600)
	_ = os.WriteFile(mcpConfig(dst), []byte(`{"mcpServers":{"x":{"command":"old"},"z":{}},"other":1}`), 0o600)
	n, err := copyMCP(src, dst, time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC))
	if err != nil || n != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	m, _ := readMCP(mcpConfig(dst))
	s := m["mcpServers"].(map[string]any)
	if len(s) != 3 || s["x"].(map[string]any)["command"] != "x" || m["other"] != float64(1) {
		t.Fatalf("merged = %v", m)
	}
	if _, err := os.Stat(mcpConfig(dst) + ".bak-20261113-100000"); err != nil {
		t.Fatal("no backup")
	}
	_ = os.WriteFile(mcpConfig(dst), []byte(`[`), 0o600)
	if _, err := copyMCP(src, dst, time.Now()); err == nil {
		t.Fatal("invalid target JSON must fail")
	}
}

func TestScanSignIn(t *testing.T) {
	cases := []struct {
		lines     []string
		saw, done bool
	}{
		{[]string{"account active and logged in"}, false, false},
		{[]string{"[Auth] Using system browser", "account active and logged in"}, true, true},
		{[]string{"claudeURLHandler: login"}, true, true},
		{[]string{"[Auth] Starting ASWebAuth"}, true, false},
	}
	for _, c := range cases {
		saw, done := scanSignIn(c.lines, false)
		if saw != c.saw || done != c.done {
			t.Errorf("%v: saw=%v done=%v", c.lines, saw, done)
		}
	}
	f := filepath.Join(t.TempDir(), "main.log")
	_ = os.WriteFile(f, []byte("a\nb\n"), 0o600)
	lines, off := readFrom(f, 2)
	if off != 4 || lines[0] != "b" {
		t.Fatalf("lines=%q off=%d", lines, off)
	}
	if _, off := readFrom(f, 99); off != 4 { // rotated log starts over
		t.Fatalf("off=%d", off)
	}
}

func TestCaffeinateArgs(t *testing.T) {
	if got := caffeinateArgs(0, false); !reflect.DeepEqual(got, []string{"-i", "-d"}) {
		t.Fatal(got)
	}
	if got := caffeinateArgs(30, true); !reflect.DeepEqual(got, []string{"-i", "-t", "1800"}) {
		t.Fatal(got)
	}
}

func TestNames(t *testing.T) {
	l := []Profile{{Name: "A"}, {Name: "B"}, {Name: "C"}}
	if names(l) != "A, B and C" || names(l[:1]) != "A" {
		t.Fatal(names(l))
	}
}
