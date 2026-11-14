package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testStamp = "2026-11-10T12:00:00.250Z"

func testDay(t *testing.T) string {
	t.Helper()
	d, err := time.Parse(time.RFC3339Nano, testStamp)
	if err != nil {
		t.Fatal(err)
	}
	return d.Local().Format("2006-01-02")
}

// usageLine is one transcript line as Claude Code writes it, with its newline.
func usageLine(id, req, model string, in, out int) string {
	return fmt.Sprintf(`{"type":"assistant","requestId":%q,"timestamp":%q,"message":{"id":%q,"model":%q,"usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}`+"\n",
		req, testStamp, id, model, in, out)
}

// sandbox points HOME, usage.json and the app's settings at a temp folder and returns the home.
func sandbox(t *testing.T, archive bool) string {
	t.Helper()
	h := t.TempDir()
	t.Setenv("HOME", h)
	t.Setenv("MULTICLAUDE_USAGE_JSON", filepath.Join(h, "MC", "usage.json"))
	old := settingOn
	settingOn = func(key string) bool { return key == "trackUsage" || (key == "archiveCode" && archive) }
	t.Cleanup(func() { settingOn = old })
	return h
}

func writeFile(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendFile(t *testing.T, path, data string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(data); err != nil {
		t.Fatal(err)
	}
}

func readState(t *testing.T) *scanState {
	t.Helper()
	data, err := os.ReadFile(usagePath())
	if err != nil {
		t.Fatal(err)
	}
	st, ok := decodeScanState(data)
	if !ok {
		t.Fatalf("usage.json does not decode strictly: %s", data)
	}
	return st
}

// outputOf adds up one owner's output tokens over every day and model.
func outputOf(st *scanState, owner string) (out, messages int) {
	for _, owners := range st.Days {
		for _, t := range owners[owner] {
			out += t.Output
			messages += t.Messages
		}
	}
	return out, messages
}

func TestFNV(t *testing.T) {
	for _, c := range []struct {
		in   string
		want uint64
	}{{"", 0xcbf29ce484222325}, {"a", 0xaf63dc4c8601ec8c}, {"foobar", 0x85944171f73967e8}} {
		if got := fnv1a(c.in); got != c.want {
			t.Errorf("fnv1a(%q) = %#x, want %#x", c.in, got, c.want)
		}
	}
}

func TestParseUsage(t *testing.T) {
	day := testDay(t)
	today := time.Now().Local().Format("2006-01-02")
	cases := []struct {
		name  string
		line  string
		ok    bool
		day   string
		model string
		want  Totals
	}{
		{"full line", strings.TrimSuffix(usageLine("m1", "r1", "claude-opus", 10, 20), "\n"), true, day, "claude-opus", Totals{10, 20, 3, 4, 1}},
		{"synthetic skipped", `{"message":{"model":"<synthetic>","usage":{"output_tokens":5}}}`, false, "", "", Totals{}},
		{"no usage", `{"timestamp":"2026-11-10T12:00:00Z","message":{"model":"m","content":"\"usage\""}}`, false, "", "", Totals{}},
		{"no model", `{"message":{"usage":{"output_tokens":5}}}`, false, "", "", Totals{}},
		{"not an object", `["usage"]`, false, "", "", Totals{}},
		{"trailing garbage", `{"message":{"model":"m","usage":{}}} x`, false, "", "", Totals{}},
		{"numbers as Swift casts them", `{"timestamp":"2026-11-10T12:00:00+02:00","message":{"model":"m","usage":{"input_tokens":12.0,"output_tokens":true,"cache_creation_input_tokens":1.5,"cache_read_input_tokens":"7"}}}`,
			true, time.Date(2026, 11, 10, 10, 0, 0, 0, time.UTC).Local().Format("2006-01-02"), "m", Totals{12, 1, 0, 0, 1}},
		{"bad timestamp is today", `{"timestamp":"2026-11-10 12:00:00Z","message":{"model":"m","usage":{"output_tokens":2}}}`, true, today, "m", Totals{0, 2, 0, 0, 1}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d, m, got, ok := parseUsageLine([]byte(c.line))
			if ok != c.ok {
				t.Fatalf("ok = %v, want %v", ok, c.ok)
			}
			if ok && (d != c.day || m != c.model || got != c.want) {
				t.Errorf("got %s %s %+v, want %s %s %+v", d, m, got, c.day, c.model, c.want)
			}
		})
	}
}

func TestScanDedupe(t *testing.T) {
	h := sandbox(t, false)
	proj := filepath.Join(h, ".claude/projects/-tmp-p")
	// The same reply copied into two transcripts counts once; a line without ids counts every time.
	writeFile(t, filepath.Join(proj, "a.jsonl"), usageLine("m1", "r1", "opus", 1, 100)+`{"message":{"model":"opus","usage":{"output_tokens":7}}}`+"\n")
	writeFile(t, filepath.Join(proj, "b.jsonl"), usageLine("m1", "r1", "opus", 1, 100)+`{"message":{"model":"opus","usage":{"output_tokens":7}}}`+"\n")
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	st := readState(t)
	if out, n := outputOf(st, terminalOwner); out != 114 || n != 3 {
		t.Errorf("terminal output %d over %d messages, want 114 over 3", out, n)
	}
	seen, err := os.ReadFile(filepath.Join(h, "MC", "usage-seen.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if len(seen) != 8 || binary.LittleEndian.Uint64(seen) != fnv1a("m1|r1") {
		t.Errorf("seen file = %x, want one little endian fnv1a(\"m1|r1\")", seen)
	}
}

func TestScanResume(t *testing.T) {
	h := sandbox(t, false)
	f := filepath.Join(h, ".claude/projects/-tmp-p/s.jsonl")
	first := usageLine("m1", "r1", "opus", 1, 10)
	half := usageLine("m2", "r2", "opus", 1, 20)
	// The second line is still being written: no newline yet, so it waits for the next scan.
	writeFile(t, f, first+half[:30])
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	st := readState(t)
	if mark := st.Files[f]; mark.Offset != uint64(len(first)) || mark.Owner != terminalOwner {
		t.Fatalf("mark = %+v, want offset %d owned by terminal", mark, len(first))
	}
	if out, _ := outputOf(st, terminalOwner); out != 10 {
		t.Fatalf("first scan output %d, want 10", out)
	}

	appendFile(t, f, half[30:]+usageLine("m3", "r3", "opus", 1, 30))
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	st = readState(t)
	if out, n := outputOf(st, terminalOwner); out != 60 || n != 3 {
		t.Errorf("after resume output %d over %d messages, want 60 over 3", out, n)
	}
	info, _ := os.Stat(f)
	if st.Files[f].Offset != uint64(info.Size()) {
		t.Errorf("offset %d, want file size %d", st.Files[f].Offset, info.Size())
	}

	// With every line read, a scan with nothing new leaves the files alone.
	before, _ := os.Stat(usagePath())
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.Stat(usagePath()); !after.ModTime().Equal(before.ModTime()) {
		t.Error("an idle scan rewrote usage.json")
	}

	// A transcript rewritten shorter is read again from the top; its ids were already counted.
	writeFile(t, f, first)
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	st = readState(t)
	if out, _ := outputOf(st, terminalOwner); out != 60 || st.Files[f].Offset != uint64(len(first)) {
		t.Errorf("after rewrite output %d offset %d, want 60 and %d", out, st.Files[f].Offset, len(first))
	}
}

func TestScanOwners(t *testing.T) {
	h := sandbox(t, true)
	work := filepath.Join(h, "Library/Application Support/Claude-Work")
	p := Profile{ID: "11111111-2222-3333-4444-555555555555", Name: "Work", Dir: &work}
	writeFile(t, filepath.Join(work, "claude-code-sessions/acct/org/local_1.json"), `{"cliSessionId":"s1","title":"One"}`)
	writeFile(t, filepath.Join(work, "claude-code-sessions/acct/org/other.json"), `{"cliSessionId":"s2"}`)

	proj := filepath.Join(h, ".claude/projects/-tmp-p")
	writeFile(t, filepath.Join(proj, "s1.jsonl"), usageLine("a", "1", "opus", 0, 1))
	writeFile(t, filepath.Join(proj, "s1/subagents/agent-x.jsonl"), usageLine("b", "2", "opus", 0, 2))
	writeFile(t, filepath.Join(proj, "s2.jsonl"), usageLine("c", "3", "opus", 0, 4))
	writeFile(t, filepath.Join(h, ".claude-work/projects/-tmp-q/z.jsonl"), usageLine("d", "4", "opus", 0, 8))
	writeFile(t, filepath.Join(work, "local-agent-mode-sessions/x/y.jsonl"), usageLine("e", "5", "opus", 0, 16))

	if err := scanUsage([]Profile{p}); err != nil {
		t.Fatal(err)
	}
	st := readState(t)
	if out, _ := outputOf(st, p.ID); out != 1+2+8+16 {
		t.Errorf("profile output %d, want 27", out)
	}
	if out, _ := outputOf(st, terminalOwner); out != 4 {
		t.Errorf("terminal output %d, want 4", out)
	}
	mc := filepath.Join(h, "MC")
	for _, rel := range []string{
		"Archive/" + p.ID + "/code/-tmp-p/s1.jsonl",
		"Archive/" + p.ID + "/code/-tmp-p/s1/subagents/agent-x.jsonl",
		"Archive/terminal/code/-tmp-p/s2.jsonl",
		"Archive/" + p.ID + "/code-.claude-work/-tmp-q/z.jsonl",
		"Archive/" + p.ID + "/cowork/x/y.jsonl",
	} {
		if _, err := os.Stat(filepath.Join(mc, rel)); err != nil {
			t.Errorf("missing archive copy %s", rel)
		}
	}
	if info, err := os.Stat(filepath.Join(mc, "Archive")); err != nil || info.Mode().Perm() != 0o700 {
		t.Errorf("Archive folder mode %v, want 0700", info.Mode().Perm())
	}

	// The account lists s2 later: what Terminal was credited moves over, and so does the archive copy.
	writeFile(t, filepath.Join(work, "claude-code-sessions/acct/org/local_2.json"), `{"cliSessionId":"s2"}`)
	if err := scanUsage([]Profile{p}); err != nil {
		t.Fatal(err)
	}
	st = readState(t)
	if out, _ := outputOf(st, p.ID); out != 31 {
		t.Errorf("profile output after claim %d, want 31", out)
	}
	for day, owners := range st.Days {
		if _, ok := owners[terminalOwner]; ok {
			t.Errorf("empty terminal entry left on %s", day)
		}
	}
	if st.Files[filepath.Join(proj, "s2.jsonl")].Owner != p.ID {
		t.Error("s2 mark still owned by terminal")
	}
	if _, err := os.Stat(filepath.Join(mc, "Archive/terminal/code/-tmp-p/s2.jsonl")); err == nil {
		t.Error("terminal archive copy not removed")
	}
	if _, err := os.Stat(filepath.Join(mc, "Archive/"+p.ID+"/code/-tmp-p/s2.jsonl")); err != nil {
		t.Error("claimed session not archived under its account")
	}
}

func TestScanSettings(t *testing.T) {
	h := sandbox(t, false)
	writeFile(t, filepath.Join(h, ".claude/projects/-tmp-p/s.jsonl"), usageLine("m", "r", "opus", 0, 1))
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(h, "MC", "Archive")); err == nil {
		t.Error("archived with archiveCode off")
	}
	settingOn = func(string) bool { return false }
	os.Remove(usagePath())
	if err := scanUsage(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(usagePath()); err == nil {
		t.Error("scanned with trackUsage off")
	}
}

func TestScanRoundTrip(t *testing.T) {
	h := sandbox(t, false)
	f := filepath.Join(h, ".claude/projects/-tmp-p/s.jsonl")
	writeFile(t, f, usageLine("m1", "r1", "opus", 5, 50)+usageLine("m2", "r2", "sonnet", 6, 60))
	if err := scanUsage([]Profile{}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(usagePath())
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("usage.json mode %v, want 0600", info.Mode().Perm())
	}
	raw, _ := os.ReadFile(usagePath())
	if !bytes.HasPrefix(raw, []byte(`{"version":1,`)) || !bytes.Contains(raw, []byte(`\/.claude\/projects\/`)) || bytes.HasSuffix(raw, []byte("\n")) {
		t.Errorf("usage.json not shaped like the app's: %s", raw)
	}

	s, err := loadUsage()
	if err != nil {
		t.Fatal(err)
	}
	sum := summarize(s, testDay(t), nil)
	if len(sum) != 1 || sum[0].Owner != terminalOwner || sum[0].Name != "Terminal" ||
		sum[0].Totals != (Totals{11, 110, 6, 8, 2}) || sum[0].Models["sonnet"].Output != 60 {
		t.Errorf("summarize = %+v", sum)
	}

	// What the scan wrote decodes back to the same state, and encoding it again gives the same bytes.
	st := readState(t)
	again, err := encodeScanState(st)
	if err != nil || !bytes.Equal(again, raw) {
		t.Errorf("re-encoded state differs:\n%s\n%s", again, raw)
	}

	// A state Swift could not decode (a missing key) is dropped, like the app does.
	if _, ok := decodeScanState([]byte(`{"files":{},"days":{}}`)); ok {
		t.Error("state without version accepted")
	}
	if _, ok := decodeScanState([]byte(`{"version":1,"files":{"x":{"offset":1}},"days":{}}`)); ok {
		t.Error("mark without owner accepted")
	}
}
