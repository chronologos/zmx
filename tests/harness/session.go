package harness

import (
	"fmt"
	"io"
	"os/exec"
	"time"

	"github.com/creack/pty"
)

// Session wraps a single zmx session's lifecycle.
//
// Creating a session requires a controlling TTY (the daemon's child shell
// wants one), so Create() allocates a PTY pair. The test holds the master
// end; reading from it drains daemon output that would otherwise back up
// and block the shell.
type Session struct {
	H       *Harness
	Name    string
	master  io.ReadWriteCloser // PTY master — daemon writes here
	spawner *exec.Cmd          // the `zmx run` that created the session (exits quickly)
}

// NewSession creates a session by running `zmx run <name> true` under a PTY
// and waiting for the socket to appear. The noop `true` command forces
// session creation without leaving a long-running foreground attach.
func NewSession(h *Harness, name string) (*Session, error) {
	cmd := exec.Command(h.Bin, "run", name, "true")
	cmd.Env = h.Env()
	// pty.Start internally does setsid() to give the child a controlling
	// terminal; adding Setpgid here causes "operation not permitted" on
	// macOS. The daemon setsid()s itself anyway, and Harness.Close sweeps
	// by zmx kill against socket names, so pgid tracking is unnecessary.

	master, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("pty.Start: %w", err)
	}
	h.track(cmd)

	// Drain the PTY in the background so the shell's echo/output doesn't
	// back up. We don't care about the contents for most tests.
	go io.Copy(io.Discard, master)

	if err := h.WaitForSocket(name, 3*time.Second); err != nil {
		_ = master.Close()
		return nil, err
	}

	// The spawner `zmx run` exits once it gets an Ack from the daemon.
	_ = cmd.Wait()

	// The daemon's initial `true` command hasn't necessarily emitted its
	// task-complete marker yet. Wait for it to settle so the first test
	// Run() doesn't race — the protocol has no per-invocation nonce, so
	// two overlapping runs can be confused. See tests/AGENTS.md.
	_, rc := h.Zmx(5*time.Second, "wait", name)
	if rc != 0 {
		_ = master.Close()
		return nil, fmt.Errorf("bootstrap wait %s: exit %d", name, rc)
	}

	return &Session{H: h, Name: name, master: master, spawner: cmd}, nil
}

// Run sends `cmd` to the session and returns the exit code reported by
// `zmx wait`. Synchronous — does not return until the command completes
// or the wait times out.
func (s *Session) Run(cmd string, timeout time.Duration) (int, error) {
	if _, rc := s.H.Zmx(timeout, "run", s.Name, cmd); rc != 0 {
		return -1, fmt.Errorf("zmx run %q: exit %d", cmd, rc)
	}
	_, rc := s.H.Zmx(timeout, "wait", s.Name)
	if rc < 0 {
		return -1, fmt.Errorf("zmx wait %s: timed out", s.Name)
	}
	return rc, nil
}

// Kill tears down the session. Idempotent.
func (s *Session) Kill() {
	s.H.Zmx(2*time.Second, "kill", s.Name)
	if s.master != nil {
		_ = s.master.Close()
		s.master = nil
	}
}
