// Package harness provides isolated process-orchestration primitives for
// black-box testing of the zmx binary.
package harness

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// isolatedEnv returns os.Environ() with any zmx-related variables stripped.
// append() alone doesn't override: getenv() returns the first match, and
// inherited entries appear before appended ones. A developer's ambient
// ZMX_DIR or ZMX_SESSION_PREFIX would silently leak into the test harness.
func isolatedEnv() []string {
	env := os.Environ()[:0]
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "ZMX_DIR=") ||
			strings.HasPrefix(kv, "ZMX_SESSION_PREFIX=") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// Harness owns an isolated ZMX_DIR and tracks every spawned process so
// cleanup is deterministic — no `pkill -f` shotgun.
type Harness struct {
	Bin       string // path to zmx binary under test
	SocketDir string

	env       []string
	procs     []*exec.Cmd
	shortLink string // symlink used as ZMX_DIR when SocketDir > sun_path limit
}

// New creates a Harness rooted in t.TempDir() and registers Close via
// t.Cleanup. Use this from ordinary *testing.T tests.
func New(tb testing.TB, zmxBin string) *Harness {
	tb.Helper()
	h, err := NewIn(tb.TempDir(), zmxBin)
	if err != nil {
		tb.Fatalf("harness: %v", err)
	}
	tb.Cleanup(h.Close)
	return h
}

// maxSocketDirLen leaves headroom for session names within the sun_path
// limit (104 on macOS, 108 on Linux). Long test names + t.TempDir()'s
// deep prefix can blow through this; we shortcut via /tmp when needed.
const maxSocketDirLen = 85

// NewIn creates a Harness rooted in the given directory. Caller is
// responsible for calling Close. Use this when you don't have a
// full testing.TB (e.g. inside a rapid.Check iteration).
//
// zmx treats ZMX_DIR as the socket directory itself (not a parent) and
// derives log_dir as ZMX_DIR/logs.
func NewIn(root, zmxBin string) (*Harness, error) {
	socketDir := filepath.Join(root, "s")
	logDir := filepath.Join(socketDir, "logs")
	for _, d := range []string{socketDir, logDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}

	// Unix socket sun_path is ~104 chars; when socketDir is too long,
	// ZMX_DIR points at a short symlink so bind() succeeds.
	// The real dirs still live under the provided root (cleaned up with it).
	zmxDir := socketDir
	if len(socketDir) > maxSocketDirLen {
		short, err := os.MkdirTemp("", "zmxh")
		if err != nil {
			return nil, fmt.Errorf("mkdtemp for short path: %w", err)
		}
		_ = os.Remove(short)
		if err := os.Symlink(socketDir, short); err != nil {
			return nil, fmt.Errorf("symlink short path: %w", err)
		}
		zmxDir = short
	}

	return &Harness{
		Bin:       zmxBin,
		SocketDir: socketDir,
		shortLink: zmxDir,
		env:       append(isolatedEnv(), "ZMX_DIR="+zmxDir),
	}, nil
}

// Env returns the isolated environment for child processes.
func (h *Harness) Env() []string { return h.env }

// Zmx runs a zmx subcommand to completion and returns its combined output
// and exit code. For one-shot commands (kill, history, list, wait).
//
// Daemon-spawning commands (attach, first `run`) may fork a daemon that
// inherits our stdout/stderr pipes. cmd.Wait() blocks until those pipes
// EOF, which never happens while the daemon lives. We sidestep by using
// os.Pipe() pairs we can close ourselves on timeout, forcing the Wait
// goroutine to unblock.
func (h *Harness) Zmx(timeout time.Duration, args ...string) (string, int) {
	cmd := exec.Command(h.Bin, args...)
	cmd.Env = h.env

	// Own the pipe so we can close the write end on timeout and let Wait return.
	rOut, wOut, _ := os.Pipe()
	cmd.Stdout = wOut
	cmd.Stderr = wOut

	if err := cmd.Start(); err != nil {
		_ = rOut.Close()
		_ = wOut.Close()
		return fmt.Sprintf("start failed: %v", err), -2
	}
	h.track(cmd)
	// Parent doesn't write; drop our copy so EOF is possible once daemon dies.
	_ = wOut.Close()

	outCh := make(chan []byte, 1)
	go func() {
		b, _ := io.ReadAll(rOut)
		outCh <- b
	}()

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	select {
	case <-done:
		_ = rOut.Close()
		return string(<-outCh), cmd.ProcessState.ExitCode()
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done // reap — Kill makes Wait return promptly
		// Close our read end → any inherited-pipe holders get EPIPE next write,
		// the reader goroutine returns.
		_ = rOut.Close()
		return string(<-outCh), -1
	}
}

// track records a process for cleanup.
func (h *Harness) track(cmd *exec.Cmd) {
	h.procs = append(h.procs, cmd)
}

// Close reaps every tracked process, then best-effort kills any daemons
// still holding sockets. Idempotent.
func (h *Harness) Close() {
	for _, p := range h.procs {
		if p.Process != nil && p.ProcessState == nil {
			_ = p.Process.Kill()
			_ = p.Wait()
		}
	}
	h.procs = nil

	// Daemons setsid() away from tracked processes; sweep by socket.
	// This is the authoritative teardown — `zmx kill` tells the daemon
	// to shut down cleanly (SIGTERM to shell, unlink socket).
	for _, name := range h.ListSockets() {
		h.Zmx(2*time.Second, "kill", name)
	}

	if h.shortLink != "" && h.shortLink != h.SocketDir {
		_ = os.Remove(h.shortLink)
	}
}

// ListSockets returns session names (socket filenames) currently present.
func (h *Harness) ListSockets() []string {
	entries, _ := os.ReadDir(h.SocketDir)
	var out []string
	for _, e := range entries {
		// DirEntry.Type() doesn't expose ModeSocket on all FS; stat for mode.
		if fi, err := os.Stat(filepath.Join(h.SocketDir, e.Name())); err == nil &&
			fi.Mode()&os.ModeSocket != 0 {
			out = append(out, e.Name())
		}
	}
	return out
}

// SocketPath returns the expected socket path for a session name.
func (h *Harness) SocketPath(sessionName string) string {
	return filepath.Join(h.SocketDir, sessionName)
}

// WaitForSocket polls until the session's Unix socket exists.
func (h *Harness) WaitForSocket(sessionName string, timeout time.Duration) error {
	path := h.SocketPath(sessionName)
	return WaitFor(timeout, func() bool {
		fi, err := os.Stat(path)
		return err == nil && fi.Mode()&os.ModeSocket != 0
	}, "socket %s", path)
}

// WaitFor polls pred until true or timeout. Desc is a format string for the
// error message.
func WaitFor(timeout time.Duration, pred func() bool, desc string, a ...any) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if pred() {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for "+desc, a...)
}
