package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// The CLI and the app share one account list, in the app's defaults domain. Without the app the CLI
// does what the app would do at launch: build the first list (Seed), add new Claude-* folders
// (discoverFolders) and give each account a color. With the app running, every write is followed by a
// multiclaude://reload link so the app takes the new list instead of saving its old one over it.

func supportDir() string { return filepath.Join(home(), "Library/Application Support") }

// paletteNames matches Palette.colors in main.swift.
var paletteNames = []string{"orange", "blue", "green", "purple", "pink", "teal", "yellow", "graphite"}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := strings.ToUpper(hex.EncodeToString(b[:]))
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

func strPtr(s string) *string { return &s }
func intPtr(n int) *int       { return &n }

// nextColor matches Engine.nextColor: the first unused palette color, else cycle by count.
func nextColor(list []Profile) int {
	used := map[int]bool{}
	for _, p := range list {
		if p.Color != nil {
			used[*p.Color] = true
		}
	}
	for i := range paletteNames {
		if !used[i] {
			return i
		}
	}
	return len(list) % len(paletteNames)
}

// slug matches Folders.slug: letters, digits, - and _ only.
func slug(name string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || r == '-' || r == '_' {
			return r
		}
		return -1
	}, name)
}

// folderCandidates matches Folders.candidates: real Claude-* folders, not links, not Claude-3p.
func folderCandidates(support string) []string {
	entries, _ := os.ReadDir(support)
	var out []string
	for _, e := range entries {
		n := e.Name()
		if !strings.HasPrefix(n, "Claude-") || n == "Claude-3p" || len(n) <= 7 {
			continue
		}
		if fi, err := os.Lstat(filepath.Join(support, n)); err == nil && fi.IsDir() {
			out = append(out, filepath.Join(support, n))
		}
	}
	sort.Strings(out)
	return out
}

var aliasRE = regexp.MustCompile(`(?m)^\s*alias\s+(\w+)=['"]open -n -a "?Claude"? --args --user-data-dir="?([^"']+)"?['"]`)

// seedProfiles matches Seed.profiles: the default account, the Claude aliases in ~/.zshrc, then the
// other Claude-* folders.
func seedProfiles() []Profile {
	list := []Profile{{ID: newUUID(), Name: "Claude"}}
	seen := map[string]bool{}
	h := home()
	rc, _ := os.ReadFile(filepath.Join(h, ".zshrc"))
	for _, m := range aliasRE.FindAllStringSubmatch(string(rc), -1) {
		dir := strings.NewReplacer("${HOME}", h, "$HOME", h).Replace(m[2])
		if strings.HasPrefix(dir, "~/") {
			dir = h + dir[1:]
		}
		if !strings.HasPrefix(dir, "/") || seen[dir] {
			continue
		}
		name := m[1]
		if name != "" {
			name = strings.ToUpper(name[:1]) + strings.ToLower(name[1:])
		}
		list = append(list, Profile{ID: newUUID(), Name: name, Dir: strPtr(dir)})
		seen[dir] = true
	}
	entries, _ := os.ReadDir(supportDir())
	for _, e := range entries {
		n := e.Name()
		if !strings.HasPrefix(n, "Claude-") || n == "Claude-3p" {
			continue
		}
		dir := filepath.Join(supportDir(), n)
		if !seen[dir] {
			list = append(list, Profile{ID: newUUID(), Name: n[7:], Dir: strPtr(dir)})
		}
	}
	return list
}

// discover matches Engine.discoverFolders, and colors accounts that have none. It reports a change.
func discover(list []Profile, ignored []string) ([]Profile, bool) {
	changed := false
	known := map[string]bool{}
	for _, p := range list {
		if p.Dir != nil {
			known[canonical(*p.Dir)] = true
		}
	}
	for _, d := range ignored {
		known[strings.ToLower(d)] = true
	}
	for _, dir := range folderCandidates(supportDir()) {
		if known[canonical(dir)] {
			continue
		}
		list = append(list, Profile{ID: newUUID(), Name: filepath.Base(dir)[7:], Dir: strPtr(dir)})
		changed = true
	}
	for i := range list {
		if list[i].Color == nil {
			list[i].Color = intPtr(nextColor(list))
			changed = true
		}
	}
	return list, changed
}

// MARK: reading and writing the shared defaults

func testStore() string { return os.Getenv("MULTICLAUDE_PROFILES_JSON") }

func defaultsExport() []byte {
	out, err := exec.Command("/usr/bin/defaults", "export", domain, "-").Output()
	if err != nil {
		return nil
	}
	return out
}

// plistValue extracts one key of the exported domain in the given plutil format, or nil.
func plistValue(plist []byte, key, format string) []byte {
	if plist == nil {
		return nil
	}
	cmd := exec.Command("/usr/bin/plutil", "-extract", key, format, "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(plist)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	return out
}

func ignoredFolders() []string {
	var list []string
	if f := testStore(); f != "" {
		b, _ := os.ReadFile(f + ".ignored")
		_ = json.Unmarshal(b, &list)
		return list
	}
	_ = json.Unmarshal(plistValue(defaultsExport(), "ignoredFolders", "json"), &list)
	return list
}

func setIgnoredFolders(list []string) error {
	sort.Strings(list)
	if f := testStore(); f != "" {
		b, _ := json.Marshal(list)
		return os.WriteFile(f+".ignored", b, 0o600)
	}
	args := append([]string{"write", domain, "ignoredFolders", "-array"}, list...)
	return exec.Command("/usr/bin/defaults", args...).Run()
}

// readSettingBool reads one of the app's Bool settings, with its default when never set.
func readSettingBool(key string, def bool) bool {
	if testStore() != "" {
		return def
	}
	out, err := exec.Command("/usr/bin/defaults", "read", domain, key).Output()
	if err != nil {
		return def
	}
	return strings.TrimSpace(string(out)) == "1"
}

func readSettingInt(key string, def int) int {
	if testStore() != "" {
		return def
	}
	out, err := exec.Command("/usr/bin/defaults", "read", domain, key).Output()
	if err != nil {
		return def
	}
	var n int
	if _, err := fmt.Sscan(strings.TrimSpace(string(out)), &n); err != nil {
		return def
	}
	return n
}

// saveProfiles writes the list where the app keeps it, then tells a running app to reload it.
func saveProfiles(list []Profile) error {
	data, err := json.Marshal(list)
	if err != nil {
		return err
	}
	if f := testStore(); f != "" {
		return os.WriteFile(f, data, 0o600)
	}
	if err := exec.Command("/usr/bin/defaults", "write", domain, "profiles", "-data", hex.EncodeToString(data)).Run(); err != nil {
		return fmt.Errorf("couldn't save the account list: %w", err)
	}
	if multiClaudeRunning() {
		_ = openURL("multiclaude://reload")
	}
	return nil
}

// loadForEdit is the list a command changes: the saved one, or a first one built like the app would.
// Without the app running, new folders are adopted and saved right away, as the app does at launch.
func loadForEdit() ([]Profile, error) {
	list, err := loadProfiles()
	if err == errNoProfiles {
		list, err = seedProfiles(), nil
		list, _ = discover(list, ignoredFolders())
		return list, saveProfiles(list)
	}
	if err != nil {
		return nil, err
	}
	if testStore() == "" && multiClaudeRunning() {
		return list, nil
	}
	list, changed := discover(list, ignoredFolders())
	if changed {
		err = saveProfiles(list)
	}
	return list, err
}
