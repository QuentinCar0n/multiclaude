package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func sp(s string) *string { return &s }

func TestGroupSlug(t *testing.T) {
	cases := map[string]string{"Entreprise": "entreprise", "Mon Groupe/é": "mon-groupe-e", "  ": "group"}
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
		{"pinned wins", Profile{Dir: sp("/x/Claude-A"), CodeDir: sp("/pinned"), Group: sp("Work")}, "/pinned"},
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
