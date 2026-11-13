package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func str(s string) *string { return &s }

const sample = `[{"color":0,"id":"0bbf135a-518d-43de-bc9d-3d9b8e268028","name":"Augura","dir":"/x/Claude-Augura"},
 {"id":"11111111-2222-3333-4444-555555555555","name":"Claude"},
 {"id":"22222222-2222-3333-4444-555555555555","dir":"/x/Claude-Moonsun","codeDir":"/y/.claude-pinned"},
 {"id":"33333333-2222-3333-4444-555555555555","name":"Client Work","dir":"/x/Claude-ClientWork"}]`

func sampleProfiles(t *testing.T) []Profile {
	t.Helper()
	list, err := decodeProfiles([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	return list
}

func TestDecode(t *testing.T) {
	list := sampleProfiles(t)
	if len(list) != 4 {
		t.Fatalf("got %d profiles", len(list))
	}
	if list[0].ID != "0BBF135A-518D-43DE-BC9D-3D9B8E268028" {
		t.Errorf("id not uppercased: %s", list[0].ID)
	}
	if !list[1].IsDefault() || list[0].IsDefault() {
		t.Error("default profile wrong")
	}
	if list[2].Name != "Moonsun" {
		t.Errorf("missing name should fall back to folder, got %q", list[2].Name)
	}
}

func TestCodeConfigDir(t *testing.T) {
	list := sampleProfiles(t)
	h := home()
	cases := map[int]string{0: h + "/.claude-augura", 1: "", 2: "/y/.claude-pinned", 3: h + "/.claude-clientwork"}
	for i, want := range cases {
		if got := list[i].CodeConfigDir(); got != want {
			t.Errorf("%s: got %q want %q", list[i].Name, got, want)
		}
	}
}

func TestFind(t *testing.T) {
	list := sampleProfiles(t)
	ok := map[string]string{
		"augura": "Augura", "AUG": "Augura", "2": "Claude", "client work": "Client Work",
		"clientwork": "Client Work", "client-work": "Client Work", "moon": "Moonsun", "0bbf": "Augura",
	}
	for q, want := range ok {
		p, err := find(list, q)
		if err != nil || p.Name != want {
			t.Errorf("find(%q) = %q, %v; want %q", q, p.Name, err, want)
		}
	}
	for _, q := range []string{"5", "0", "zzz", "c"} { // "c" matches Claude and Client Work
		if _, err := find(list, q); err == nil {
			t.Errorf("find(%q) should fail", q)
		}
	}
}

func procargs(exe string, args ...string) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, int32(len(args)))
	b.WriteString(exe)
	b.Write([]byte{0, 0, 0, 0})
	for _, a := range args {
		b.WriteString(a)
		b.WriteByte(0)
	}
	b.WriteString("HOME=/x")
	b.WriteByte(0)
	return b.Bytes()
}

func TestParseProcArgs(t *testing.T) {
	exe, args, err := parseProcArgs(procargs("/A/Claude.app/Contents/MacOS/Claude", "/A/Claude.app/Contents/MacOS/Claude", "--user-data-dir=/x/it's here/Claude-W"))
	if err != nil || exe != "/A/Claude.app/Contents/MacOS/Claude" || len(args) != 2 || userDataDir(args) != "/x/it's here/Claude-W" {
		t.Fatalf("got %q %q %v", exe, args, err)
	}
	if _, _, err := parseProcArgs([]byte{1}); err == nil {
		t.Error("short buffer should fail")
	}
}

func TestMatchRunning(t *testing.T) {
	list := sampleProfiles(t)
	rt := home() + "/Library/Application Support/MultiClaude/Runtimes.noindex/"
	claude := "/Applications/Claude.app/Contents/MacOS/Claude"
	procs := []Proc{
		{10, claude, []string{claude}}, // default
		{11, claude, []string{claude, "--type=renderer", "--user-data-dir=/x/Claude-Augura"}}, // helper
		{12, rt + "0bbf135a-518d-43de-bc9d-3d9b8e268028/Claude Augura.app/Contents/MacOS/Claude",
			[]string{"x", "--user-data-dir=/X/claude-augura"}}, // case folded
		{13, rt + "33333333-2222-3333-4444-555555555555/Claude Client Work.app/Contents/MacOS/Claude",
			[]string{"x"}}, // bare copy: not the default
		{14, "/usr/bin/other", []string{"--user-data-dir=/x/Claude-Moonsun"}},
	}
	got := matchRunning(list, procs)
	want := map[string]int{"11111111-2222-3333-4444-555555555555": 10, "0BBF135A-518D-43DE-BC9D-3D9B8E268028": 12}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: got %d want %d", k, got[k], v)
		}
	}
}

func TestRuntimeOwner(t *testing.T) {
	if got := runtimeOwner("/Users/q/Library/Application Support/MultiClaude/Runtimes.noindex/abc-def/X.app/Contents/MacOS/Claude"); got != "ABC-DEF" {
		t.Errorf("got %q", got)
	}
	if runtimeOwner("/Applications/Claude.app/Contents/MacOS/Claude") != "" {
		t.Error("real Claude has no owner")
	}
}

func TestCanonical(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "Claude-Real")
	_ = os.Mkdir(real, 0o755)
	link := filepath.Join(dir, "Claude-Old")
	_ = os.Symlink(real, link)
	if canonical(link) != canonical(strings.ToUpper(real[:1])+real[1:]) && canonical(link) != canonical(real) {
		t.Error("symlink should resolve")
	}
	if canonical("~/a") != strings.ToLower(filepath.Join(home(), "a")) && !strings.HasSuffix(canonical("~/a"), "/a") {
		t.Error("tilde should expand")
	}
}

func TestCodeEnv(t *testing.T) {
	list := sampleProfiles(t)
	env := codeEnv(list[0], []string{"A=1", "CLAUDE_CONFIG_DIR=/old"})
	if strings.Join(env, " ") != "A=1 CLAUDE_CONFIG_DIR="+home()+"/.claude-augura" {
		t.Errorf("got %v", env)
	}
	if env := codeEnv(list[1], []string{"CLAUDE_CONFIG_DIR=/old"}); len(env) != 0 {
		t.Errorf("default should drop it, got %v", env)
	}
}

func TestEnvCommandQuotes(t *testing.T) {
	f := filepath.Join(t.TempDir(), "p.json")
	_ = os.WriteFile(f, []byte(`[{"id":"a","name":"Q","dir":"/x/Claude-Q","codeDir":"/x/it's"}]`), 0o600)
	t.Setenv("MULTICLAUDE_PROFILES_JSON", f)
	var out bytes.Buffer
	if err := run([]string{"env", "q"}, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != `export CLAUDE_CONFIG_DIR='/x/it'\''s'`+"\n" {
		t.Errorf("got %q", out.String())
	}
}

func TestSummarize(t *testing.T) {
	list := sampleProfiles(t)
	s := usageState{Days: map[string]map[string]map[string]Totals{
		"2026-11-01": {"terminal": {"m": {Output: 1000}}},
		"2026-11-10": {
			"0BBF135A-518D-43DE-BC9D-3D9B8E268028": {"a": {Output: 5, Messages: 1}, "b": {Output: 7, Input: 2}},
			"terminal":                             {"m": {Output: 3}},
			"99999999-0000-0000-0000-000000000000": {"m": {Output: 1}},
		},
	}}
	rows := summarize(s, "2026-11-06", list)
	if len(rows) != 3 || rows[0].Name != "Augura" || rows[0].Totals.Output != 12 || rows[0].Totals.Input != 2 ||
		rows[1].Name != "Terminal" || rows[1].Totals.Output != 3 || rows[2].Name != "Removed account" {
		t.Fatalf("got %+v", rows)
	}
	day := time.Date(2026, 11, 12, 10, 0, 0, 0, time.Local)
	if sinceDay(day, 7) != "2026-11-06" || sinceDay(day, 1) != "2026-11-12" || sinceDay(day, 0) != "2026-11-12" {
		t.Error("sinceDay wrong")
	}
}

func TestShort(t *testing.T) {
	for n, want := range map[int]string{999: "999", 1234: "1.2K", 5_600_000: "5.6M", 2_100_000_000: "2.1B"} {
		if short(n) != want {
			t.Errorf("short(%d) = %s", n, short(n))
		}
	}
}

func TestAssertionHeld(t *testing.T) {
	on := "   pid 812(MultiClaude): [0x0001] 00:02:10 PreventUserIdleDisplaySleep named: \"MultiClaude keep-awake\""
	if !assertionHeld(on) || assertionHeld("   pid 9(Music): [0x1] 00:00:01 PreventUserIdleSystemSleep") {
		t.Error("assertion detection wrong")
	}
}

func TestUnknownCommand(t *testing.T) {
	if err := run([]string{"nope"}, &bytes.Buffer{}); err == nil {
		t.Error("should fail")
	}
}
