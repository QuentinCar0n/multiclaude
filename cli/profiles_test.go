package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func sp(s string) *string { return &s }

func TestGroupSlug(t *testing.T) {
	// Same table as --selftest-groups in main.swift (review I3).
	cases := map[string]string{"Straße": "stra-e", "Łódź": "lodz", "Ørsted": "orsted", "Ğüzel": "guzel", "Ș": "s", "ﬁx": "x",
		"Pe\u0301rsonal": "personal", "Mon Groupe/é": "mon-groupe-e", "  ": "group", "Entreprise": "entreprise"}
	for in, want := range cases {
		if got := groupSlug(in); got != want {
			t.Errorf("groupSlug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGroupFolder(t *testing.T) {
	if got := groupFolder("Work"); got != home()+"/.claude-work" {
		t.Errorf("Work: %q", got)
	}
	if got := groupFolder("Personal"); got != "" {
		t.Errorf("Personal should be ~/.claude (empty), got %q", got)
	}
}

func TestCodeConfigDirGroup(t *testing.T) {
	cases := []struct {
		name string
		p    Profile
		want string
	}{
		{"group wins over pin (review C1)", Profile{Dir: sp("/x/Claude-A"), CodeDir: sp(home() + "/.claude-work"), Group: sp("Entreprise")}, home() + "/.claude-entreprise"},
		{"pin without group", Profile{Dir: sp("/x/Claude-A"), CodeDir: sp("/pinned")}, "/pinned"},
		{"grouped", Profile{Dir: sp("/x/Claude-A"), Group: sp("Work")}, home() + "/.claude-work"},
		{"ungrouped keeps own", Profile{Dir: sp("/x/Claude-Augura")}, home() + "/.claude-augura"},
		{"grouped default", Profile{Group: sp("Work")}, home() + "/.claude-work"},
		{"default in Personal", Profile{Group: sp("Personal")}, ""},
	}
	for _, c := range cases {
		if got := c.p.CodeConfigDir(); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestGroupRoundTrip(t *testing.T) {
	var p Profile
	if err := json.Unmarshal([]byte(`{"id":"1","name":"A","group":"Work","future":true}`), &p); err != nil {
		t.Fatal(err)
	}
	if p.Group == nil || *p.Group != "Work" {
		t.Fatalf("group not read: %v", p.Group)
	}
	b, _ := json.Marshal(p)
	var back map[string]any
	json.Unmarshal(b, &back)
	if back["group"] != "Work" || back["future"] != true {
		t.Errorf("round trip lost fields: %s", b)
	}
}

func TestListShowsGroupOnlyWhenUsed(t *testing.T) {
	var plain, grouped strings.Builder
	rows := []listRow{{Number: 1, Name: "Claude", Color: "orange", Folder: "/f"}}
	if err := writeList(rows, &plain, false); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(plain.String(), "GROUP") {
		t.Errorf("no group set, but GROUP column shown:\n%s", plain.String())
	}
	rows = append(rows, listRow{Number: 2, Name: "Augura", Color: "green", Folder: "/g", Group: "Entreprise"})
	if err := writeList(rows, &grouped, false); err != nil {
		t.Fatal(err)
	}
	out := grouped.String()
	if !strings.Contains(out, "GROUP") || !strings.Contains(out, "Entreprise") || !strings.Contains(out, "-") {
		t.Errorf("GROUP column missing:\n%s", out)
	}
}

func TestOpenDirectArgsGroup(t *testing.T) {
	got := strings.Join(openDirectArgs(Profile{Dir: sp("/d"), Group: sp("Work")}, false), " ")
	want := "-n -b com.anthropic.claudefordesktop --env CLAUDE_CONFIG_DIR=" + home() + "/.claude-work --args --user-data-dir=/d"
	if got != want {
		t.Errorf("grouped:\n got %s\nwant %s", got, want)
	}
	if got := strings.Join(openDirectArgs(Profile{Dir: sp("/d")}, false), " "); got != "-n -b com.anthropic.claudefordesktop --args --user-data-dir=/d" {
		t.Errorf("ungrouped changed: %s", got)
	}
}

func TestUsageSourcesGroupOnce(t *testing.T) {
	list := []Profile{{ID: "a", Dir: sp("/x/Claude-GA"), Group: sp("Work")}, {ID: "b", Dir: sp("/x/Claude-GB"), Group: sp("Work")}, {ID: "c", Group: sp("Work")}}
	n := 0
	for _, s := range usageSources(list) {
		if s.root == home()+"/.claude-work/projects" {
			n++
		}
	}
	if n != 1 {
		t.Errorf("group folder scanned %d times, want 1", n)
	}
}
