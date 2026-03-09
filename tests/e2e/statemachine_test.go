package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/neurosnap/zmx/tests/harness"
	"pgregory.net/rapid"
)

// sessionModel is a rapid state-machine: it issues random sequences of
// Run/Wait/Kill against a real zmx daemon while maintaining an in-memory
// model of expected state. After every step, the real system must agree
// with the model.
//
// This surfaces drift between the daemon's internal state and the
// user-observable contract — most usefully, whether a subsequent Run on
// the same session reports that command's exit code, not a stale one.

type sessionModel struct {
	h *harness.Harness
	// name → expected last exit code (nil = never ran anything)
	sessions map[string]*int
	// Live Session handles for cleanup
	live map[string]*harness.Session
}

// A tiny pool of session names forces frequent revisits to the same
// session — that's where state-drift bugs hide.
var names = []string{"sa", "sb"}

// init sets up a fresh isolated harness for one rapid iteration.
// Uses a subdirectory under root so each iteration is hermetic without
// relying on rapid.T having TempDir/Cleanup.
func (m *sessionModel) init(t *rapid.T, root, bin string, iter int) {
	dir := filepath.Join(root, fmt.Sprintf("iter%d", iter))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	h, err := harness.NewIn(dir, bin)
	if err != nil {
		t.Fatalf("harness: %v", err)
	}
	m.h = h
	m.sessions = map[string]*int{}
	m.live = map[string]*harness.Session{}
}

// ensureSession creates the session if it doesn't exist yet.
// Separated from Run so the model can reason about "exists but never ran".
func (m *sessionModel) ensureSession(t *rapid.T, name string) {
	if _, ok := m.live[name]; ok {
		return
	}
	s, err := harness.NewSession(m.h, name)
	if err != nil {
		t.Fatalf("create session %s: %v", name, err)
	}
	m.live[name] = s
	m.sessions[name] = nil // exists, no runs yet
}

// Run: send `true` or `false`; update model's expected exit code.
// zmx shell-quotes args containing `()` so a subshell `(exit N)` becomes a
// literal string. true/false are simple builtins with known exit codes.
func (m *sessionModel) Run(t *rapid.T) {
	name := rapid.SampledFrom(names).Draw(t, "name")
	want := rapid.SampledFrom([]int{0, 1}).Draw(t, "exit")
	cmd := map[int]string{0: "true", 1: "false"}[want]
	m.ensureSession(t, name)

	got, err := m.live[name].Run(cmd, 5*time.Second)
	if err != nil {
		t.Fatalf("Run(%s, %s): %v", name, cmd, err)
	}

	// `wait` must report this command's exit code, not a previous one.
	// rapid shrinks any failure to a minimal reproducer automatically.
	if got != want {
		t.Fatalf("Run(%s, %s) → wait returned %d, want %d (daemon state drift)",
			name, cmd, got, want)
	}

	m.sessions[name] = &want
}

// Kill: remove a session. Subsequent ops on this name must recreate it.
func (m *sessionModel) Kill(t *rapid.T) {
	if len(m.live) == 0 {
		t.Skip("no sessions")
	}
	// Draw only from existing sessions
	existing := make([]string, 0, len(m.live))
	for n := range m.live {
		existing = append(existing, n)
	}
	name := rapid.SampledFrom(existing).Draw(t, "victim")

	m.live[name].Kill()
	delete(m.live, name)
	delete(m.sessions, name)

	// Post-condition: socket must disappear (daemon cleaned up).
	if err := harness.WaitFor(2*time.Second, func() bool {
		return !fileExists(m.h.SocketPath(name))
	}, "socket %s removed after kill", name); err != nil {
		t.Fatalf("%v — daemon didn't clean up", err)
	}
}

// Check: invariant — socket directory agrees with model's set of sessions.
// Using filesystem state instead of `zmx list` to avoid depending on its
// output format.
func (m *sessionModel) Check(t *rapid.T) {
	listed := map[string]bool{}
	for _, name := range m.h.ListSockets() {
		listed[name] = true
	}

	for name := range m.sessions {
		if !listed[name] {
			t.Fatalf("model has session %q but no socket on disk", name)
		}
	}
	for name := range listed {
		if _, ok := m.sessions[name]; !ok {
			t.Fatalf("socket %q present but model has no record (leaked daemon?)", name)
		}
	}
}

func TestSessionStateMachine(t *testing.T) {
	if testing.Short() {
		t.Skip("state machine test is slow; skip in -short")
	}
	bin := zmxBin(t)
	root := t.TempDir()
	iter := 0
	rapid.Check(t, func(rt *rapid.T) {
		iter++
		m := &sessionModel{}
		m.init(rt, root, bin, iter)
		defer m.h.Close()
		rt.Repeat(map[string]func(*rapid.T){
			"Run":  m.Run,
			"Kill": m.Kill,
			"":     m.Check, // invariant — runs after every step
		})
	})
}

