package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/neurosnap/zmx/tests/harness"
	"github.com/stretchr/testify/assert"
)

// zmxBin locates the binary under test. Override via ZMX_BIN env var.
func zmxBin(t testing.TB) string {
	t.Helper()
	if p := os.Getenv("ZMX_BIN"); p != "" {
		return p
	}
	p, err := filepath.Abs("../../zig-out/bin/zmx")
	if err != nil || !fileExists(p) {
		t.Skipf("ZMX_BIN not set and no binary at %s", p)
	}
	return p
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// Session names become filenames under SocketDir, and stale-cleanup does
// unlinkat(dirfd, name). A name with path components could escape the
// directory on both operations.
//
// Assert on behavior (exit code + filesystem), not error message text —
// Zig's error-return-trace strings depend on CWD and build mode.

func TestPathTraversal(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	evil := filepath.Join(filepath.Dir(h.SocketDir), "evil")
	defer os.Remove(evil)

	_, rc := h.Zmx(2*time.Second, "attach", "../evil")

	assert.NotEqual(t, 0, rc,
		"traversal should be rejected (nonzero exit)")
	assert.NoFileExists(t, evil,
		"socket must not escape SocketDir")
	assert.Empty(t, h.ListSockets(), "no session should have been created")
}

func TestInvalidSessionNames(t *testing.T) {
	h := harness.New(t, zmxBin(t))
	// NUL byte omitted: Go's os/exec rejects it at fork time, before zmx runs.
	for _, name := range []string{"a/b", "..", "."} {
		t.Run(name, func(t *testing.T) {
			_, rc := h.Zmx(1*time.Second, "attach", name)
			assert.NotEqual(t, 0, rc, "invalid name %q should be rejected", name)
			assert.Empty(t, h.ListSockets(), "no session created for %q", name)
		})
	}
}

// `history --vt` with no positional arg must not panic on nil session-name
// unwrap — should error gracefully (SessionNameRequired or equivalent).

func TestHistoryNoSessionArg(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	out, rc := h.Zmx(2*time.Second, "history", "--vt")

	assert.NotContains(t, strings.ToLower(out), "panic",
		"must not crash on missing positional arg")
	// We don't set ZMX_SESSION_PREFIX, so absence of a positional should error.
	if rc == 0 {
		t.Errorf("expected non-zero exit with no session name and no prefix")
	}
}

// `wait` with a nonexistent session name must not exit 0 (that would
// silently pass CI checks when run and wait race, or on a typo). After
// a few polls with no matches, it should fail with a clear message.

func TestWaitNonexistentSession(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	out, rc := h.Zmx(6*time.Second, "wait", "ghost")

	assert.NotEqual(t, 0, rc,
		"vacuous exit 0 would hide CI failures when run+wait race")
	// Accept either explicit error (rc=2) or harness timeout (rc=-1) — not 0.
	if rc == 2 {
		assert.Contains(t, out, "no matching sessions")
	}
}
