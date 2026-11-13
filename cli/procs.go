package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strings"

	"golang.org/x/sys/unix"
)

// Proc is one running program: its pid, executable path and arguments (argv[0] included).
type Proc struct {
	PID  int
	Exe  string
	Args []string
}

// parseProcArgs reads a KERN_PROCARGS2 buffer: argc as int32, the executable path, NUL padding,
// then argc NUL-terminated arguments (the environment follows and is ignored).
func parseProcArgs(buf []byte) (exe string, args []string, err error) {
	if len(buf) < 4 {
		return "", nil, errors.New("short procargs")
	}
	argc := int(binary.LittleEndian.Uint32(buf[:4]))
	rest := buf[4:]
	i := bytes.IndexByte(rest, 0)
	if i < 0 {
		return "", nil, errors.New("no executable path")
	}
	exe = string(rest[:i])
	rest = rest[i:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	for len(args) < argc && len(rest) > 0 {
		j := bytes.IndexByte(rest, 0)
		if j < 0 {
			args = append(args, string(rest))
			break
		}
		args = append(args, string(rest[:j]))
		rest = rest[j+1:]
	}
	return exe, args, nil
}

func procArgs(pid int) (string, []string, error) {
	buf, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil, err
	}
	return parseProcArgs(buf)
}

// processes lists running programs whose short name (p_comm, 16 bytes at most) is one of names.
// Arguments of other users' processes are unreadable and skipped.
func processes(names ...string) []Proc {
	all, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil
	}
	var out []Proc
	for _, k := range all {
		comm := unix.ByteSliceToString(k.Proc.P_comm[:])
		match := false
		for _, n := range names {
			if comm == n {
				match = true
			}
		}
		if !match {
			continue
		}
		pid := int(k.Proc.P_pid)
		exe, args, err := procArgs(pid)
		if err != nil {
			continue
		}
		out = append(out, Proc{PID: pid, Exe: exe, Args: args})
	}
	return out
}

const runtimesMarker = "/Library/Application Support/MultiClaude/Runtimes.noindex/"

// userDataDir is the --user-data-dir a Claude process was started with, or "".
func userDataDir(args []string) string {
	for _, a := range args {
		if strings.HasPrefix(a, "--user-data-dir=") {
			return strings.TrimPrefix(a, "--user-data-dir=")
		}
	}
	return ""
}

// runtimeOwner is the profile id of the MultiClaude copy of Claude an executable runs from, or "".
func runtimeOwner(exe string) string {
	i := strings.Index(exe, runtimesMarker)
	if i < 0 {
		return ""
	}
	id, _, _ := strings.Cut(exe[i+len(runtimesMarker):], "/")
	return strings.ToUpper(id)
}

// matchRunning maps profile id to the pid of its Claude main process, the way Engine.refresh does:
// by --user-data-dir, and a process without one belongs to the default profile unless it runs from
// another profile's copy (Claude's updater relaunching that copy; the app closes it).
func matchRunning(list []Profile, procs []Proc) map[string]int {
	byDir := map[string]string{}
	defaultID := ""
	for _, p := range list {
		if p.Dir != nil {
			byDir[canonical(*p.Dir)] = p.ID
		} else {
			defaultID = p.ID
		}
	}
	isDefault := func(id string) bool { return id == "" || id == defaultID }
	running := map[string]int{}
	for _, pr := range procs {
		if !strings.HasSuffix(pr.Exe, ".app/Contents/MacOS/Claude") {
			continue
		}
		helper := false
		for _, a := range pr.Args {
			if strings.HasPrefix(a, "--type=") {
				helper = true
			}
		}
		if helper {
			continue
		}
		if dir := userDataDir(pr.Args); dir != "" {
			if id, ok := byDir[canonical(dir)]; ok {
				running[id] = pr.PID
			}
			continue
		}
		if defaultID != "" && isDefault(runtimeOwner(pr.Exe)) {
			running[defaultID] = pr.PID
		}
	}
	return running
}

func runningClaudes(list []Profile) map[string]int {
	return matchRunning(list, processes("Claude"))
}

func multiClaudeRunning() bool {
	for _, p := range processes("MultiClaude") {
		if strings.HasSuffix(p.Exe, "MultiClaude.app/Contents/MacOS/MultiClaude") {
			return true
		}
	}
	return false
}
