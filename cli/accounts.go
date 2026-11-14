package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Account editing, the same rules as the app's Engine (add, rename, remove, delete, duplicate, color,
// move, MCP copy, sign-in), so the CLI can stand in for it entirely.

func findOrErr(list []Profile, q string) (Profile, int, error) {
	p, err := find(list, q)
	if err != nil {
		return p, -1, err
	}
	for i := range list {
		if list[i].ID == p.ID {
			return p, i, nil
		}
	}
	return p, -1, fmt.Errorf("no account called %q", q)
}

func nameTaken(list []Profile, name, except string) bool {
	for _, p := range list {
		if p.ID != except && strings.EqualFold(p.Name, name) {
			return true
		}
	}
	return false
}

// newProfile matches Engine.newProfile: a Claude-<slug> folder, name and folder not used by another.
func newProfile(list []Profile, raw string) (Profile, error) {
	name := strings.TrimSpace(raw)
	s := slug(name)
	if s == "" {
		return Profile{}, errors.New("the name needs a letter or digit")
	}
	if nameTaken(list, name, "") {
		return Profile{}, fmt.Errorf("an account is already called %s", name)
	}
	dir := filepath.Join(supportDir(), "Claude-"+s)
	for _, p := range list {
		if p.Dir != nil && canonical(*p.Dir) == canonical(dir) {
			return Profile{}, fmt.Errorf("%s already uses the folder %s", p.Name, tildePath(dir))
		}
	}
	return Profile{ID: newUUID(), Name: name, Dir: strPtr(dir), Color: intPtr(nextColor(list))}, nil
}

func cmdAdd(args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: multiclaude add <name>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, err := newProfile(list, strings.Join(args, " "))
	if err != nil {
		return err
	}
	if _, err := os.Stat(*p.Dir); err == nil {
		// A folder taken off the list earlier comes back with its account and chats.
		var keep []string
		for _, d := range ignoredFolders() {
			if d != canonical(*p.Dir) {
				keep = append(keep, d)
			}
		}
		_ = setIgnoredFolders(keep)
		fmt.Fprintf(out, "%s's folder was already there, so it opens with the account and chats it had.\n", p.Name)
	}
	if err := saveProfiles(append(list, p)); err != nil {
		return err
	}
	fmt.Fprintf(out, "Added %s. Sign in with: multiclaude login %s\n", p.Name, shellArg(p.Name))
	return nil
}

func shellArg(s string) string {
	if strings.ContainsAny(s, " '\"$`\\*?[]{}()&;|<>!#~") {
		return shellQuote(s)
	}
	return s
}

func cmdRename(args []string, out io.Writer) error {
	if len(args) < 2 {
		return errors.New("usage: multiclaude rename <account> <new name>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, i, err := findOrErr(list, args[0])
	if err != nil {
		return err
	}
	name := strings.TrimSpace(strings.Join(args[1:], " "))
	if name == "" {
		return errors.New("the new name is empty")
	}
	if nameTaken(list, name, p.ID) {
		return fmt.Errorf("another account is already called %s", name)
	}
	list[i].Name = name
	// Without the app, the folder follows the name here, as alignFolders does in the app.
	if !multiClaudeRunning() && testStore() == "" {
		alignFolder(&list[i], runningClaudes(list)[p.ID] != 0)
	}
	if err := saveProfiles(list); err != nil {
		return err
	}
	fmt.Fprintf(out, "Renamed %s to %s\n", p.Name, name)
	return nil
}

// alignFolder matches Engine.alignFolders for one account: a closed account's folder moves to
// Claude-<name> and a link stays at the old path, because Claude writes absolute paths into its data.
func alignFolder(p *Profile, running bool) {
	if p.Dir == nil || running || folderInUse(*p.Dir) {
		return
	}
	dir := *p.Dir
	target := folderTarget(p.Name, dir, supportDir())
	if target == "" {
		return
	}
	oldCode := p.CodeConfigDir()
	if err := os.Rename(dir, target); err != nil {
		return
	}
	if err := os.Symlink(target, dir); err != nil {
		if os.Rename(target, dir) == nil {
			return
		}
	}
	if p.CodeDir == nil && oldCode != "" {
		if _, err := os.Stat(oldCode); err == nil {
			p.CodeDir = strPtr(oldCode) // its Keychain sign-in is tied to this path
		}
	}
	p.Dir = strPtr(target)
}

// folderTarget matches Folders.target: where the folder should live, or "" when it already does,
// is outside Application Support, or the name is taken.
func folderTarget(name, current, support string) string {
	s := slug(name)
	if s == "" {
		return ""
	}
	target := filepath.Join(support, "Claude-"+s)
	if filepath.Base(current) == "Claude-"+s || filepath.Clean(filepath.Dir(current)) != filepath.Clean(support) {
		return ""
	}
	if _, err := os.Stat(current); err != nil {
		return ""
	}
	if _, err := os.Lstat(target); err == nil {
		return ""
	}
	return target
}

// folderInUse matches Folders.inUse: Electron's SingletonLock names <host>-<pid> while a Claude uses it.
func folderInUse(dir string) bool {
	lock, err := os.Readlink(filepath.Join(dir, "SingletonLock"))
	if err != nil {
		return false
	}
	i := strings.LastIndex(lock, "-")
	pid, err := strconv.Atoi(lock[i+1:])
	if err != nil || pid <= 0 {
		return true
	}
	err = syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

func cmdRemove(args []string, out io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: multiclaude remove <account>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, i, err := findOrErr(list, args[0])
	if err != nil {
		return err
	}
	if p.IsDefault() {
		return errors.New("the default Claude account stays on the list")
	}
	ign := append(ignoredFolders(), canonical(*p.Dir))
	seen := map[string]bool{}
	var uniq []string
	for _, d := range ign {
		d = strings.ToLower(d)
		if !seen[d] {
			seen[d] = true
			uniq = append(uniq, d)
		}
	}
	if err := setIgnoredFolders(uniq); err != nil {
		return err
	}
	if err := saveProfiles(append(list[:i:i], list[i+1:]...)); err != nil {
		return err
	}
	fmt.Fprintf(out, "Took %s off the list. Its folder stays at %s\n", p.Name, tildePath(*p.Dir))
	return nil
}

// quitAndWait quits the account if it's open and reports whether it's closed.
func quitAndWait(p Profile, list []Profile, timeout time.Duration) bool {
	pid := runningClaudes(list)[p.ID]
	if pid == 0 {
		return true
	}
	if !(multiClaudeRunning() && openURL(link("quit", url.Values{"profile": {p.ID}})) == nil) {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	if waitFor(p, list, false, timeout) == 0 {
		time.Sleep(500 * time.Millisecond)
		return true
	}
	return false
}

func confirm(prompt string) bool {
	fmt.Fprint(os.Stderr, prompt+" [y/N] ")
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	a := strings.ToLower(strings.TrimSpace(line))
	return a == "y" || a == "yes"
}

func trash(path string) error {
	out, err := exec.Command("/usr/bin/trash", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return nil
}

func cmdDelete(args []string, out io.Writer) error {
	yes := false
	var rest []string
	for _, a := range args {
		if a == "--yes" || a == "-y" {
			yes = true
		} else {
			rest = append(rest, a)
		}
	}
	if len(rest) != 1 {
		return errors.New("usage: multiclaude delete <account> [--yes]")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, i, err := findOrErr(list, rest[0])
	if err != nil {
		return err
	}
	if p.IsDefault() {
		return errors.New("the default Claude account can't be deleted")
	}
	h := home()
	real, err := filepath.EvalSymlinks(*p.Dir)
	if err != nil {
		real = *p.Dir
	}
	for _, u := range []string{h, "/", supportDir(), filepath.Join(supportDir(), "Claude"), h + "/Library", h + "/Library/Application Support"} {
		if canonical(u) == canonical(real) {
			return fmt.Errorf("%s's folder is %s. Nothing was changed", p.Name, real)
		}
	}
	if !yes && !confirm(fmt.Sprintf("Move %s's folder %s and its sign-in to the Trash?", p.Name, tildePath(real))) {
		return errors.New("nothing was changed")
	}
	if !quitAndWait(p, list, 10*time.Second) || folderInUse(*p.Dir) {
		return fmt.Errorf("%s didn't quit. Nothing was changed", p.Name)
	}
	// Links left by renames that point at the folder.
	var links []string
	entries, _ := os.ReadDir(supportDir())
	for _, e := range entries {
		path := filepath.Join(supportDir(), e.Name())
		if to, err := os.Readlink(path); err == nil && strings.HasPrefix(e.Name(), "Claude-") && canonical(to) == canonical(real) {
			links = append(links, path)
		}
	}
	if _, err := os.Stat(real); err == nil {
		if err := trash(real); err != nil {
			return fmt.Errorf("couldn't move %s's folder to the Trash (%v). Nothing was changed", p.Name, err)
		}
	}
	for _, l := range append(links, *p.Dir) {
		if _, err := os.Readlink(l); err == nil {
			_ = trash(l)
		}
	}
	note := fmt.Sprintf("Moved %s to the Trash.", p.Name)
	if code := p.CodeConfigDir(); code != "" && canonical(code) != canonical(h+"/.claude") {
		if _, err := os.Stat(code); err == nil {
			shared := false
			for _, o := range list {
				if o.ID != p.ID && o.CodeConfigDir() != "" && canonical(o.CodeConfigDir()) == canonical(code) {
					shared = true
				}
			}
			switch {
			case shared:
				note += " Its Claude Code folder stays, because another account uses it."
			case trash(code) != nil:
				note = fmt.Sprintf("Moved %s to the Trash, but not its Claude Code folder %s.", p.Name, code)
			}
		}
	}
	if err := saveProfiles(append(list[:i:i], list[i+1:]...)); err != nil {
		return err
	}
	fmt.Fprintln(out, note)
	return nil
}

func cmdDuplicate(args []string, out io.Writer) error {
	if len(args) < 2 {
		return errors.New("usage: multiclaude duplicate <account> <new name>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	src, _, err := findOrErr(list, args[0])
	if err != nil {
		return err
	}
	p, err := newProfile(list, strings.Join(args[1:], " "))
	if err != nil {
		return err
	}
	if _, err := os.Lstat(*p.Dir); err == nil {
		return fmt.Errorf("the folder %s already exists: pick another name", tildePath(*p.Dir))
	}
	wasOpen := runningClaudes(list)[src.ID] != 0
	// Copying a folder its Claude is still writing would give the copy torn databases.
	if !quitAndWait(src, list, 15*time.Second) || folderInUse(src.Folder()) {
		return fmt.Errorf("%s didn't quit. Nothing was changed", src.Name)
	}
	fmt.Fprintf(out, "Duplicating %s…\n", src.Name)
	err = cloneFolder(src.Folder(), *p.Dir)
	if wasOpen {
		_ = openProfile(src, list)
	}
	if err != nil {
		return fmt.Errorf("couldn't duplicate %s (%v). Nothing was changed", src.Name, err)
	}
	if err := saveProfiles(append(list, p)); err != nil {
		return err
	}
	fmt.Fprintf(out, "Duplicated %s as %s. Both are signed in to the same account until you sign one out.\n", src.Name, p.Name)
	return nil
}

// cloneFolder matches Duplicate.clone: an APFS clone under a hidden name, renamed at the end, without
// Electron's single-instance lock files.
func cloneFolder(source, dst string) error {
	src, err := filepath.EvalSymlinks(source)
	if err != nil {
		return err
	}
	partial := filepath.Join(filepath.Dir(dst), ".partial-"+newUUID())
	if out, err := exec.Command("/bin/cp", "-cR", src, partial).CombinedOutput(); err != nil {
		_ = os.RemoveAll(partial)
		return fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	for _, l := range []string{"SingletonLock", "SingletonSocket", "SingletonCookie"} {
		_ = os.Remove(filepath.Join(partial, l))
	}
	if err := os.Rename(partial, dst); err != nil {
		_ = os.RemoveAll(partial)
		return err
	}
	return nil
}

func cmdColor(args []string, out io.Writer) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: multiclaude color <account> <%s>", strings.Join(paletteNames, "|"))
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, i, err := findOrErr(list, args[0])
	if err != nil {
		return err
	}
	c := -1
	for j, n := range paletteNames {
		if strings.EqualFold(n, args[1]) {
			c = j
		}
	}
	if n, err := strconv.Atoi(args[1]); err == nil && n >= 1 && n <= len(paletteNames) {
		c = n - 1
	}
	if c < 0 {
		return fmt.Errorf("colors are %s", strings.Join(paletteNames, ", "))
	}
	list[i].Color = intPtr(c)
	if err := saveProfiles(list); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s is %s\n", p.Name, paletteNames[c])
	return nil
}

func cmdMove(args []string, out io.Writer) error {
	if len(args) != 2 {
		return errors.New("usage: multiclaude move <account> <up|down|position>")
	}
	list, err := loadForEdit()
	if err != nil {
		return err
	}
	p, i, err := findOrErr(list, args[0])
	if err != nil {
		return err
	}
	j := i
	switch args[1] {
	case "up":
		j = i - 1
	case "down":
		j = i + 1
	default:
		n, err := strconv.Atoi(args[1])
		if err != nil {
			return errors.New("move takes up, down or a position")
		}
		j = n - 1
	}
	if j < 0 || j >= len(list) {
		return fmt.Errorf("position must be 1 to %d", len(list))
	}
	moved := list[i]
	list = append(list[:i], list[i+1:]...)
	list = append(list[:j], append([]Profile{moved}, list[j:]...)...)
	if err := saveProfiles(list); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s is number %d\n", p.Name, j+1)
	return nil
}

// MARK: MCP servers

func mcpConfig(p Profile) string { return filepath.Join(p.Folder(), "claude_desktop_config.json") }

// readMCP matches MCP.read: a missing or empty file is {}, anything but a JSON object is an error.
func readMCP(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && len(strings.TrimSpace(string(b))) == 0) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil || m == nil {
		return nil, fmt.Errorf("%s isn't valid JSON", path)
	}
	return m, nil
}

// copyMCP matches MCP.copy: adds the source's servers (same name replaced), keeps a dated backup.
func copyMCP(src, dst Profile, now time.Time) (int, error) {
	s, err := readMCP(mcpConfig(src))
	if err != nil {
		return 0, err
	}
	servers, _ := s["mcpServers"].(map[string]any)
	if len(servers) == 0 {
		return 0, nil
	}
	path := mcpConfig(dst)
	t, err := readMCP(path)
	if err != nil {
		return 0, err
	}
	cur, _ := t["mcpServers"].(map[string]any)
	if cur == nil {
		cur = map[string]any{}
	}
	for k, v := range servers {
		cur[k] = v
	}
	t["mcpServers"] = cur
	if old, err := os.ReadFile(path); err == nil {
		backup := path + ".bak-" + now.Format("20060102-150405")
		for n := 2; ; n++ {
			if _, err := os.Stat(backup); err != nil {
				break
			}
			backup = path + ".bak-" + now.Format("20060102-150405") + "-" + strconv.Itoa(n)
		}
		if err := os.WriteFile(backup, old, 0o600); err != nil {
			return 0, err
		}
	} else if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}
	b, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return 0, err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return 0, err
	}
	return len(servers), os.Rename(tmp, path)
}

func cmdMCP(args []string, out io.Writer) error {
	if len(args) == 1 || (len(args) == 2 && args[0] == "list") {
		q := args[len(args)-1]
		list, err := loadProfiles()
		if err != nil {
			return err
		}
		p, err := find(list, q)
		if err != nil {
			return err
		}
		m, err := readMCP(mcpConfig(p))
		if err != nil {
			return err
		}
		servers, _ := m["mcpServers"].(map[string]any)
		if len(servers) == 0 {
			fmt.Fprintf(out, "%s has no MCP servers\n", p.Name)
			return nil
		}
		keys := make([]string, 0, len(servers))
		for name := range servers {
			keys = append(keys, name)
		}
		sort.Strings(keys)
		for _, name := range keys {
			fmt.Fprintln(out, name)
		}
		return nil
	}
	if len(args) != 3 || args[0] != "copy" {
		return errors.New("usage: multiclaude mcp <account> | multiclaude mcp copy <from> <to>")
	}
	list, err := loadProfiles()
	if err != nil {
		return err
	}
	src, err := find(list, args[1])
	if err != nil {
		return err
	}
	dst, err := find(list, args[2])
	if err != nil {
		return err
	}
	n, err := copyMCP(src, dst, time.Now())
	if err != nil {
		return fmt.Errorf("couldn't copy MCP servers: %w", err)
	}
	if n == 0 {
		fmt.Fprintf(out, "%s has no MCP servers to copy\n", src.Name)
		return nil
	}
	fmt.Fprintf(out, "Copied %d MCP server(s) from %s to %s.", n, src.Name, dst.Name)
	if runningClaudes(list)[dst.ID] != 0 {
		fmt.Fprintf(out, " Reopen %s to load them.", dst.Name)
	}
	fmt.Fprintln(out)
	return nil
}
