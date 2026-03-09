package e2e

// Smoke tests for invocation patterns that touch defensive code paths.
// These assert "doesn't crash" — the underlying failure modes are
// UB/latent/race-dependent and don't reliably reproduce black-box.
// See cli_test.go for tests with deterministic pass/fail behavior.

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/neurosnap/zmx/tests/harness"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// When stdin is not a TTY, tcgetattr fails. The termios setup must check
// the return value rather than feeding undefined stack bytes through
// cfmakeraw + tcsetattr.

func TestAttachNonTTYStdinNoCrash(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	// Harness.Zmx leaves stdin unset → child inherits closed stdin
	// (not a TTY). The daemon forks, then clientLoop sees stdin EOF and
	// exits quickly. We're testing that the termios setup path in between
	// doesn't panic on tcgetattr failure.
	out, _ := h.Zmx(2*time.Second, "attach", "nontty")

	assert.NotContains(t, strings.ToLower(out), "panic",
		"tcgetattr failure on non-TTY stdin should be handled, not UB")
	assert.NotContains(t, out, "reached unreachable",
		"safe-mode undefined-value check should not fire")
}

// The forked child's argv array must handle unbounded CLI argument
// counts. A fixed-size stack buffer would corrupt on >63 args.

func TestAttachManyArgsNoOverflow(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	// 70 args (session name + echo + 67 words). `echo` accepts anything.
	args := []string{"attach", "manyargs", "echo"}
	for i := range 67 {
		args = append(args, fmt.Sprintf("a%d", i))
	}

	cmd := exec.Command(h.Bin, args...)
	cmd.Env = h.Env()
	master, err := ptyStart(cmd)
	require.NoError(t, err)
	defer master.Close()

	// Socket appearing means the daemon survived the fork+exec with a
	// large argv in the child.
	require.NoError(t, h.WaitForSocket("manyargs", 3*time.Second),
		"daemon should come up with 70 argv entries")

	_ = cmd.Process.Kill()
	_ = cmd.Wait()
}

// Writing to a closed client socket delivers SIGPIPE (default:
// terminate) before write() can return EPIPE. The daemon must ignore
// SIGPIPE so an abruptly exiting client doesn't kill it — and every
// other attached session with it.

func TestDaemonSurvivesClientSIGKILL(t *testing.T) {
	h := harness.New(t, zmxBin(t))

	s, err := harness.NewSession(h, "survivor")
	require.NoError(t, err)
	defer s.Kill()

	// Second client, SIGKILLed. The daemon's next write to that socket
	// (e.g. broadcasting PTY output) would deliver SIGPIPE if not ignored.
	client := exec.Command(h.Bin, "attach", "survivor")
	client.Env = h.Env()
	master, err := ptyStart(client)
	require.NoError(t, err)
	defer master.Close()

	// Give the attach time to connect and send Init.
	time.Sleep(300 * time.Millisecond)

	require.NoError(t, syscall.Kill(client.Process.Pid, syscall.SIGKILL))
	_ = client.Wait()

	// Daemon must still be responsive. If SIGPIPE killed it, this
	// times out or reports "session unreachable".
	got, err := s.Run("true", 5*time.Second)
	require.NoError(t, err, "daemon must survive abrupt client death")
	assert.Equal(t, 0, got, "daemon must remain functional")
}
