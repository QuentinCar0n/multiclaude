package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Totals mirrors UsageTotals in main.swift.
type Totals struct {
	Input      int `json:"input"`
	Output     int `json:"output"`
	CacheWrite int `json:"cacheWrite"`
	CacheRead  int `json:"cacheRead"`
	Messages   int `json:"messages"`
}

func (t Totals) Total() int { return t.Input + t.Output + t.CacheWrite + t.CacheRead }

func (t *Totals) add(o Totals) {
	t.Input += o.Input
	t.Output += o.Output
	t.CacheWrite += o.CacheWrite
	t.CacheRead += o.CacheRead
	t.Messages += o.Messages
}

// usageState is the part of usage.json the CLI reads: day -> owner -> model -> totals.
// The owner is a profile id, or "terminal" for Claude Code sessions no account claims.
type usageState struct {
	Days map[string]map[string]map[string]Totals `json:"days"`
}

type OwnerUsage struct {
	Owner  string            `json:"owner"`
	Name   string            `json:"name"`
	Totals Totals            `json:"totals"`
	Models map[string]Totals `json:"models"`
}

func usagePath() string {
	if f := os.Getenv("MULTICLAUDE_USAGE_JSON"); f != "" {
		return f
	}
	return filepath.Join(home(), "Library/Application Support/MultiClaude/usage.json")
}

// summarize adds up the days from `since` (YYYY-MM-DD, inclusive) on, per owner, biggest output first.
func summarize(s usageState, since string, list []Profile) []OwnerUsage {
	names := map[string]string{"terminal": "Terminal"}
	for _, p := range list {
		names[p.ID] = p.Name
	}
	by := map[string]*OwnerUsage{}
	for day, owners := range s.Days {
		if day < since {
			continue
		}
		for owner, models := range owners {
			u := by[owner]
			if u == nil {
				name := names[owner]
				if name == "" {
					name = "Removed account"
				}
				u = &OwnerUsage{Owner: owner, Name: name, Models: map[string]Totals{}}
				by[owner] = u
			}
			for model, t := range models {
				u.Totals.add(t)
				m := u.Models[model]
				m.add(t)
				u.Models[model] = m
			}
		}
	}
	out := make([]OwnerUsage, 0, len(by))
	for _, u := range by {
		out = append(out, *u)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Totals.Output != out[j].Totals.Output {
			return out[i].Totals.Output > out[j].Totals.Output
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func loadUsage() (usageState, error) {
	var s usageState
	data, err := os.ReadFile(usagePath())
	if err != nil {
		return s, err
	}
	err = json.Unmarshal(data, &s)
	return s, err
}

// sinceDay is the first day of a window of n days ending today, in local time like the app.
func sinceDay(now time.Time, n int) string {
	if n < 1 {
		n = 1
	}
	return now.AddDate(0, 0, -(n - 1)).Format("2006-01-02")
}
