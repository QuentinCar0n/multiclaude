package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/QuentinCar0n/multiclaude/cli/internal/logging"
)

// In CLI mode a log line is a readable console line on the writer given, never JSON, and carries
// no timestamp: a terminal user does not want a log pipeline's format.
func TestCLILogIsAConsoleLineOnOut(t *testing.T) {
	t.Setenv("LOG_LEVEL", "")
	t.Setenv("LOG_FORMAT", "")
	var buf bytes.Buffer
	startLogging(&buf)
	clog := logging.Module("cli")
	clog.Error().Str("command", "open").Msg("command_failed")
	out := strings.TrimSpace(buf.String())
	if out == "" || strings.Contains(out, "\n") {
		t.Fatalf("one line expected: %q", buf.String())
	}
	if strings.HasPrefix(out, "{") || strings.Contains(out, `"level"`) {
		t.Fatalf("console line expected, got JSON: %q", out)
	}
	if !strings.Contains(out, "command_failed") || !strings.Contains(out, "command=") {
		t.Fatalf("event and field expected: %q", out)
	}
	if strings.HasPrefix(out, "20") {
		t.Fatalf("no timestamp expected: %q", out)
	}
}
