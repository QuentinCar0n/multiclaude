package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
)

// The app's defaults domain. Profiles live there under "profiles", as JSON data written by the app.
const domain = "me.somalabs.multiclaude"

// Profile mirrors the Swift Profile struct in main.swift. Only the fields the CLI needs.
type Profile struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Dir     *string `json:"dir"` // nil = the default Claude profile, launched without --user-data-dir
	Color   *int    `json:"color,omitempty"`
	CodeDir *string `json:"codeDir,omitempty"`
	AppName *string `json:"appName,omitempty"`
}

func (p Profile) IsDefault() bool { return p.Dir == nil }

// Folder is the account's Claude data folder.
func (p Profile) Folder() string {
	if p.Dir != nil {
		return *p.Dir
	}
	return filepath.Join(home(), "Library/Application Support/Claude")
}

// CodeConfigDir matches Profile.codeConfigDir in main.swift: the default profile keeps ~/.claude
// (returned as ""), the others get their pinned codeDir or ~/.claude-<folder suffix>.
func (p Profile) CodeConfigDir() string {
	if p.Dir == nil {
		return ""
	}
	if p.CodeDir != nil {
		return *p.CodeDir
	}
	suffix := strings.ToLower(strings.ReplaceAll(filepath.Base(*p.Dir), "Claude-", ""))
	return home() + "/.claude-" + suffix
}

// key is the name with only letters and digits, lowercased, like the app's alias key.
func (p Profile) key() string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, p.Name)
}

func home() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return os.Getenv("HOME")
	}
	return h
}

// decodeProfiles reads the app's JSON list. Like the Swift decoder it is lenient about names:
// a missing one falls back to the folder name.
func decodeProfiles(data []byte) ([]Profile, error) {
	var list []Profile
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("can't read MultiClaude's account list: %w", err)
	}
	for i := range list {
		if list[i].Name == "" {
			if list[i].Dir != nil {
				list[i].Name = strings.ReplaceAll(filepath.Base(*list[i].Dir), "Claude-", "")
			} else {
				list[i].Name = "Claude"
			}
		}
		list[i].ID = strings.ToUpper(list[i].ID)
	}
	return list, nil
}

var errNoProfiles = errors.New("no accounts yet: open MultiClaude once so it can find your Claude accounts")

// loadProfiles asks cfprefsd (through `defaults export`), so it sees what the running app last saved,
// not a stale plist on disk. MULTICLAUDE_PROFILES_JSON points at a JSON file instead, for tests.
func loadProfiles() ([]Profile, error) {
	if f := os.Getenv("MULTICLAUDE_PROFILES_JSON"); f != "" {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		return decodeProfiles(data)
	}
	plist, err := exec.Command("/usr/bin/defaults", "export", domain, "-").Output()
	if err != nil {
		return nil, errNoProfiles
	}
	cmd := exec.Command("/usr/bin/plutil", "-extract", "profiles", "raw", "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(plist)
	out, err := cmd.Output()
	if err != nil {
		return nil, errNoProfiles
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		return nil, fmt.Errorf("can't read MultiClaude's account list: %w", err)
	}
	list, err := decodeProfiles(data)
	if err == nil && len(list) == 0 {
		return nil, errNoProfiles
	}
	return list, err
}

// find picks one profile from what the user typed: its number in `multiclaude list`, its name
// (any case, spaces and punctuation ignored), the start of a name, or the start of its id.
func find(list []Profile, q string) (Profile, error) {
	q = strings.TrimSpace(q)
	if n, err := strconv.Atoi(q); err == nil {
		if n >= 1 && n <= len(list) {
			return list[n-1], nil
		}
		return Profile{}, fmt.Errorf("no account number %d (there are %d)", n, len(list))
	}
	lower := strings.ToLower(q)
	key := Profile{Name: q}.key()
	for _, p := range list {
		if strings.ToLower(p.Name) == lower {
			return p, nil
		}
	}
	var hits []Profile
	if key != "" {
		for _, p := range list {
			if p.key() == key {
				hits = append(hits, p)
			}
		}
		if len(hits) == 0 {
			for _, p := range list {
				if strings.HasPrefix(p.key(), key) {
					hits = append(hits, p)
				}
			}
		}
	}
	if len(hits) == 0 && len(q) >= 4 {
		for _, p := range list {
			if strings.HasPrefix(p.ID, strings.ToUpper(q)) {
				hits = append(hits, p)
			}
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return Profile{}, fmt.Errorf("no account called %q (see `multiclaude list`)", q)
	default:
		names := make([]string, len(hits))
		for i, p := range hits {
			names[i] = p.Name
		}
		return Profile{}, fmt.Errorf("%q could be %s", q, strings.Join(names, ", "))
	}
}

// canonical matches Folders.canonical in main.swift: a folder's identity for comparisons only,
// with ~ expanded, symlinks resolved and case folded (Mac volumes ignore case).
func canonical(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		path = home() + path[1:]
	}
	path = filepath.Clean(path)
	if r, err := filepath.EvalSymlinks(path); err == nil {
		path = r
	}
	return strings.ToLower(path)
}

// tildePath shortens a path under the home folder for display.
func tildePath(p string) string {
	h := home()
	if h != "" && (p == h || strings.HasPrefix(p, h+"/")) {
		return "~" + p[len(h):]
	}
	return p
}
