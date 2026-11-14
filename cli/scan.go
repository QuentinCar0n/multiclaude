package main

// A port of UsageScan in main.swift. The CLI and the app read and write the same files in the
// MultiClaude folder, so either one can resume from the marks the other left:
//
//   - usage.json: {"version", "files": path -> {"offset", "owner"}, "days": day -> owner -> model -> totals}
//   - usage-seen.bin: the FNV-1a hash of every message id already counted, little endian uint64s
//   - Archive/<owner>/<source>/<path>: a clone of every transcript, when "Keep Claude Code Conversations" is on

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// terminalOwner is the owner of ~/.claude sessions no account folder lists: the CLI's own sign-in.
const terminalOwner = "terminal"

type fileMark struct {
	Offset uint64 `json:"offset"`
	Owner  string `json:"owner"`
}

// scanState is the whole of usage.json, as UsageScan.State encodes it.
type scanState struct {
	Version int                                     `json:"version"`
	Files   map[string]fileMark                     `json:"files"`
	Days    map[string]map[string]map[string]Totals `json:"days"`
}

func newScanState() *scanState {
	return &scanState{Version: 1, Files: map[string]fileMark{}, Days: map[string]map[string]map[string]Totals{}}
}

// usageSource is one folder of JSONL transcripts, and whose files they are.
type usageSource struct {
	root        string
	archiveName string                   // folder under Archive/<owner>/
	owner       func(file string) string // profile id, or terminalOwner
}

// scanner holds one scan's state, like a UsageScan instance.
type scanner struct {
	folder         string
	archiveEnabled bool
	state          *scanState
	seen           map[uint64]bool
	seenOrder      []uint64
}

func (s *scanner) stateFile() string  { return filepath.Join(s.folder, "usage.json") }
func (s *scanner) seenFile() string   { return filepath.Join(s.folder, "usage-seen.bin") }
func (s *scanner) archiveDir() string { return filepath.Join(s.folder, "Archive") }

// settingOn reads one of the app's boolean settings. Tests replace it.
var settingOn = defaultsSetting

// defaultsSetting matches Engine.isOn for settings that are on by default (trackUsage, archiveCode):
// a missing key is on, otherwise the value is read the way UserDefaults.bool reads it.
func defaultsSetting(key string) bool {
	out, err := exec.Command("/usr/bin/defaults", "read", domain, key).Output()
	if err != nil {
		return true
	}
	v := strings.TrimSpace(string(out))
	switch strings.ToLower(v) {
	case "yes", "true":
		return true
	}
	if f, err := strconv.ParseFloat(v, 64); err == nil {
		return f != 0
	}
	return false
}

// scanUsage runs one incremental scan of every transcript source and saves the state, like
// Usage.refresh in the app. It does nothing when token usage tracking is off.
func scanUsage(list []Profile) error {
	if !settingOn("trackUsage") {
		return nil
	}
	s := &scanner{folder: filepath.Dir(usagePath()), archiveEnabled: settingOn("archiveCode")}
	return s.scan(usageSources(list))
}

// fnv1a is FNV-1a 64, stable across runs and identical to UsageScan.fnv.
func fnv1a(s string) uint64 {
	h := uint64(0xcbf29ce484222325)
	for i := 0; i < len(s); i++ {
		h = (h ^ uint64(s[i])) * 0x100000001b3
	}
	return h
}

// load reads usage.json and usage-seen.bin. Like Swift's JSONDecoder, a usage.json that is missing a
// key or holds a value of the wrong type is dropped as a whole, and the scan starts over.
func (s *scanner) load() {
	s.state = newScanState()
	s.seen = map[uint64]bool{}
	if data, err := os.ReadFile(s.stateFile()); err == nil {
		if st, ok := decodeScanState(data); ok {
			s.state = st
		}
	}
	if data, err := os.ReadFile(s.seenFile()); err == nil {
		for i := 0; i+8 <= len(data); i += 8 {
			s.addSeen(binary.LittleEndian.Uint64(data[i:]))
		}
	}
}

func (s *scanner) addSeen(h uint64) bool {
	if s.seen[h] {
		return false
	}
	s.seen[h] = true
	s.seenOrder = append(s.seenOrder, h)
	return true
}

// Strict mirrors of the state: a nil pointer is a missing key or a null, which Swift refuses.
type strictTotals struct {
	Input      *int `json:"input"`
	Output     *int `json:"output"`
	CacheWrite *int `json:"cacheWrite"`
	CacheRead  *int `json:"cacheRead"`
	Messages   *int `json:"messages"`
}

type strictMark struct {
	Offset *uint64 `json:"offset"`
	Owner  *string `json:"owner"`
}

type strictState struct {
	Version *int                                              `json:"version"`
	Files   *map[string]*strictMark                           `json:"files"`
	Days    *map[string]*map[string]*map[string]*strictTotals `json:"days"`
}

func decodeScanState(data []byte) (*scanState, bool) {
	var raw strictState
	if json.Unmarshal(data, &raw) != nil || raw.Version == nil || raw.Files == nil || raw.Days == nil {
		return nil, false
	}
	st := &scanState{Version: *raw.Version, Files: map[string]fileMark{}, Days: map[string]map[string]map[string]Totals{}}
	for path, m := range *raw.Files {
		if m == nil || m.Offset == nil || m.Owner == nil {
			return nil, false
		}
		st.Files[path] = fileMark{Offset: *m.Offset, Owner: *m.Owner}
	}
	for day, owners := range *raw.Days {
		if owners == nil {
			return nil, false
		}
		st.Days[day] = map[string]map[string]Totals{}
		for owner, models := range *owners {
			if models == nil {
				return nil, false
			}
			st.Days[day][owner] = map[string]Totals{}
			for model, t := range *models {
				if t == nil || t.Input == nil || t.Output == nil || t.CacheWrite == nil || t.CacheRead == nil || t.Messages == nil {
					return nil, false
				}
				st.Days[day][owner][model] = Totals{*t.Input, *t.Output, *t.CacheWrite, *t.CacheRead, *t.Messages}
			}
		}
	}
	return st, true
}

// encodeScanState writes JSON the way Swift's JSONEncoder does: compact, no HTML escaping, "/" as "\/",
// no trailing newline. Only the key order differs (Swift's is unordered, this one is sorted).
func encodeScanState(st *scanState) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(st); err != nil {
		return nil, err
	}
	// A "/" can only appear inside a JSON string, so this never touches the structure.
	return bytes.ReplaceAll(bytes.TrimRight(b.Bytes(), "\n"), []byte("/"), []byte(`\/`)), nil
}

// writeAtomic writes to a temporary file in the same folder, then renames it over path.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(data)
	cerr := f.Close()
	if err := errors.Join(werr, cerr, os.Chmod(tmp, mode)); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func (s *scanner) save() error {
	if err := os.MkdirAll(s.folder, 0o755); err != nil {
		return err
	}
	data, err := encodeScanState(s.state)
	if err != nil {
		return err
	}
	if err := writeAtomic(s.stateFile(), data, 0o600); err != nil {
		return err
	}
	ids := make([]byte, 8*len(s.seenOrder))
	for i, h := range s.seenOrder {
		binary.LittleEndian.PutUint64(ids[i*8:], h)
	}
	// Data.write(options: .atomic) leaves the umask's default mode.
	return writeAtomic(s.seenFile(), ids, 0o644)
}

// sessionIndex maps each session id to the profile whose claude-code-sessions/local_*.json lists it.
// A later profile wins when two list the same session, like the Swift loop.
func sessionIndex(list []Profile) (owners, titles map[string]string) {
	owners, titles = map[string]string{}, map[string]string{}
	for _, p := range list {
		root := filepath.Join(p.Folder(), "claude-code-sessions")
		walkFollowRoot(root, func(path string, d fs.DirEntry) {
			name := d.Name()
			if !strings.HasPrefix(name, "local_") || filepath.Ext(name) != ".json" {
				return
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return
			}
			var j map[string]any
			if json.Unmarshal(data, &j) != nil {
				return
			}
			sid, ok := j["cliSessionId"].(string)
			if !ok {
				return
			}
			owners[sid] = p.ID
			if title, ok := j["title"].(string); ok && title != "" {
				titles[sid] = title
			}
		})
	}
	return owners, titles
}

// sessionID is the session a transcript belongs to: <id>.jsonl, or <id>/subagents/agent-*.jsonl.
func sessionID(file string) string {
	parent := filepath.Dir(file)
	if filepath.Base(parent) == "subagents" {
		return filepath.Base(filepath.Dir(parent))
	}
	base := filepath.Base(file)
	return strings.TrimSuffix(base, filepath.Ext(base))
}

func usageSources(list []Profile) []usageSource {
	owners, _ := sessionIndex(list)
	out := []usageSource{{
		root:        filepath.Join(home(), ".claude/projects"),
		archiveName: "code",
		owner: func(f string) string {
			if o, ok := owners[sessionID(f)]; ok {
				return o
			}
			return terminalOwner
		},
	}}
	for _, p := range list {
		id := p.ID
		mine := func(string) string { return id }
		if p.Dir != nil {
			if cfg := p.CodeConfigDir(); cfg != "" {
				out = append(out, usageSource{root: filepath.Join(cfg, "projects"), archiveName: "code-" + filepath.Base(cfg), owner: mine})
			}
		}
		out = append(out, usageSource{root: filepath.Join(p.Folder(), "local-agent-mode-sessions"), archiveName: "cowork", owner: mine})
	}
	return out
}

// walkFollowRoot visits every regular file under root, recursively. Like FileManager's enumerator it
// follows root when root itself is a symbolic link, but not links found inside it.
func walkFollowRoot(root string, visit func(path string, d fs.DirEntry)) {
	if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
		return
	}
	// The trailing separator makes WalkDir follow a symlinked root; Join cleans it out of the paths.
	filepath.WalkDir(root+string(filepath.Separator), func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.Type().IsRegular() {
			visit(filepath.Clean(path), d)
		}
		return nil
	})
}

// scan reads what was added to each transcript since the last scan, then saves when anything changed.
func (s *scanner) scan(sources []usageSource) error {
	s.load()
	changed := false
	for _, src := range sources {
		walkFollowRoot(src.root, func(path string, d fs.DirEntry) {
			if filepath.Ext(path) != ".jsonl" {
				return
			}
			fi, err := os.Stat(path)
			if err != nil {
				return
			}
			size := uint64(fi.Size())
			mark, ok := s.state.Files[path]
			if !ok {
				mark = fileMark{Offset: 0, Owner: src.owner(path)}
			}
			// A Code session is credited to Terminal until an account lists it, and its transcript can be
			// read before that list is. Once an account claims it, what was counted moves over.
			if mark.Owner == terminalOwner {
				if now := src.owner(path); now != terminalOwner {
					s.reassign(path, mark.Offset, mark.Owner, now)
					if s.archiveEnabled {
						os.RemoveAll(s.archivePath(path, src.root, src.archiveName, mark.Owner))
					}
					mark.Owner = now
					s.state.Files[path] = mark
					changed = true
					if s.archiveEnabled && size <= mark.Offset {
						s.archive(path, src.root, src.archiveName, now)
					}
				}
			}
			if size < mark.Offset {
				mark.Offset = 0 // rewritten: counted ids are skipped anyway
			}
			if size <= mark.Offset {
				return
			}
			owner := mark.Owner
			mark.Offset = usageLines(path, mark.Offset, math.MaxUint64, func(line []byte) { s.count(line, owner) })
			s.state.Files[path] = mark
			changed = true
			if s.archiveEnabled {
				s.archive(path, src.root, src.archiveName, mark.Owner)
			}
		})
	}
	if changed {
		return s.save()
	}
	return nil
}

var usageMarker = []byte(`"usage"`)

// usageLines calls body on each complete line holding "usage" between offset and end, and returns the
// offset after the last complete line read. A last line with no newline yet is left for the next scan.
func usageLines(path string, offset, end uint64, body func([]byte)) uint64 {
	f, err := os.Open(path)
	if err != nil {
		return offset
	}
	defer f.Close()
	if _, err := f.Seek(int64(offset), io.SeekStart); err != nil {
		return offset
	}
	r := bufio.NewReaderSize(f, 4<<20)
	pos := offset
	for pos < end {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break // EOF or a read error: only complete lines count
		}
		content := line[:len(line)-1]
		if bytes.Contains(content, usageMarker) {
			body(content)
		}
		pos += uint64(len(line))
	}
	return pos
}

// reassign moves what the first offset bytes of path added under old to newOwner. A reply also counted from
// another file was only added once, so no bucket is taken below zero.
func (s *scanner) reassign(path string, offset uint64, old, newOwner string) {
	if offset == 0 {
		return
	}
	usageLines(path, 0, offset, func(line []byte) {
		day, model, t, ok := parseUsageLine(line)
		if !ok {
			return
		}
		have := s.state.Days[day][old][model]
		moved := clampTotals(have, t)
		if moved == (Totals{}) {
			return
		}
		left := subTotals(have, moved)
		if left == (Totals{}) {
			delete(s.state.Days[day][old], model)
		} else {
			s.state.Days[day][old][model] = left
		}
		if len(s.state.Days[day][old]) == 0 {
			delete(s.state.Days[day], old)
		}
		s.addTotals(day, newOwner, model, moved)
	})
}

func clampTotals(have, t Totals) Totals {
	return Totals{min(have.Input, t.Input), min(have.Output, t.Output), min(have.CacheWrite, t.CacheWrite),
		min(have.CacheRead, t.CacheRead), min(have.Messages, t.Messages)}
}

func subTotals(a, b Totals) Totals {
	return Totals{a.Input - b.Input, a.Output - b.Output, a.CacheWrite - b.CacheWrite, a.CacheRead - b.CacheRead, a.Messages - b.Messages}
}

func (s *scanner) addTotals(day, owner, model string, t Totals) {
	if s.state.Days[day] == nil {
		s.state.Days[day] = map[string]map[string]Totals{}
	}
	if s.state.Days[day][owner] == nil {
		s.state.Days[day][owner] = map[string]Totals{}
	}
	have := s.state.Days[day][owner][model]
	have.add(t)
	s.state.Days[day][owner][model] = have
}

func (s *scanner) count(line []byte, owner string) {
	j, ok := decodeObject(line)
	if !ok {
		return
	}
	m, ok := j["message"].(map[string]any)
	if !ok {
		return
	}
	id, _ := m["id"].(string)
	req, _ := j["requestId"].(string)
	key := id + "|" + req
	day, model, t, ok := parseUsage(j)
	if !ok {
		return
	}
	if key != "|" && !s.addSeen(fnv1a(key)) {
		return
	}
	s.addTotals(day, owner, model, t)
}

// decodeObject parses one JSON line whose top level must be an object, keeping numbers exact.
func decodeObject(line []byte) (map[string]any, bool) {
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return nil, false
	}
	// JSONSerialization refuses anything after the value but whitespace.
	if _, err := dec.Token(); err != io.EOF {
		return nil, false
	}
	j, ok := v.(map[string]any)
	return j, ok
}

func parseUsageLine(line []byte) (day, model string, t Totals, ok bool) {
	j, ok := decodeObject(line)
	if !ok {
		return "", "", Totals{}, false
	}
	return parseUsage(j)
}

// parseUsage matches UsageScan.parse: the reply's day in local time, its model and its token counts.
func parseUsage(j map[string]any) (day, model string, t Totals, ok bool) {
	m, ok := j["message"].(map[string]any)
	if !ok {
		return "", "", Totals{}, false
	}
	u, ok := m["usage"].(map[string]any)
	if !ok {
		return "", "", Totals{}, false
	}
	model, ok = m["model"].(string)
	if !ok || model == "<synthetic>" {
		return "", "", Totals{}, false
	}
	stamp := time.Now()
	if s, isStr := j["timestamp"].(string); isStr {
		if d, err := time.Parse(time.RFC3339Nano, s); err == nil {
			stamp = d
		}
	}
	t = Totals{
		Input:      swiftInt(u["input_tokens"]),
		Output:     swiftInt(u["output_tokens"]),
		CacheWrite: swiftInt(u["cache_creation_input_tokens"]),
		CacheRead:  swiftInt(u["cache_read_input_tokens"]),
		Messages:   1,
	}
	return stamp.Local().Format("2006-01-02"), model, t, true
}

// swiftInt is `value as? Int ?? 0` on a JSONSerialization value: whole numbers that fit (12.0 and 1e3
// included), booleans as 1 or 0, anything else 0.
func swiftInt(v any) int {
	switch x := v.(type) {
	case json.Number:
		if i, err := strconv.ParseInt(string(x), 10, 64); err == nil {
			return int(i)
		}
		f, err := strconv.ParseFloat(string(x), 64)
		if err != nil || f != math.Trunc(f) || f < math.MinInt64 || f >= math.MaxInt64 {
			return 0
		}
		return int(f)
	case bool:
		if x {
			return 1
		}
	}
	return 0
}

// archivePath is Archive/<owner>/<source>/<path relative to the source root>.
func (s *scanner) archivePath(file, root, name, owner string) string {
	rel := strings.Trim(strings.TrimPrefix(filepath.Clean(file), filepath.Clean(root)), "/")
	return filepath.Join(s.archiveDir(), owner, name, rel)
}

// archive clones the transcript into the archive (APFS clone: no space taken while Claude keeps the
// original), falling back to a plain copy like copyfile(COPYFILE_CLONE), then swaps it into place.
func (s *scanner) archive(file, root, name, owner string) {
	dest := s.archivePath(file, root, name, owner)
	// Transcripts hold whole conversations: only this user may open the archive.
	if _, err := os.Stat(s.archiveDir()); errors.Is(err, fs.ErrNotExist) {
		if os.MkdirAll(s.archiveDir(), 0o700) == nil {
			os.Chmod(s.archiveDir(), 0o700)
		}
	}
	dir := filepath.Dir(dest)
	os.MkdirAll(dir, 0o755)
	tmp := filepath.Join(dir, ".partial-"+filepath.Base(dest))
	os.RemoveAll(tmp)
	if unix.Clonefile(file, tmp, unix.CLONE_NOFOLLOW) != nil && copyFile(file, tmp) != nil {
		os.Remove(tmp)
		return
	}
	os.Rename(tmp, dest)
	if _, err := os.Lstat(tmp); err == nil {
		os.Remove(tmp)
	}
}

// copyFile copies data, mode and times, refusing to overwrite (COPYFILE_EXCL).
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, fi.Mode().Perm())
	if err != nil {
		return err
	}
	_, cerr := io.Copy(out, in)
	if err := errors.Join(cerr, out.Close()); err != nil {
		return err
	}
	os.Chmod(dst, fi.Mode().Perm())
	return os.Chtimes(dst, fi.ModTime(), fi.ModTime())
}
