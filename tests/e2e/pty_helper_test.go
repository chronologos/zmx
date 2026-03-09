package e2e

import (
	"io"
	"os/exec"

	"github.com/creack/pty"
)

// ptyStart wraps creack/pty.Start and immediately drains the master in
// the background so the spawned process's PTY output doesn't back up.
// Returns the master end for the caller to close.
func ptyStart(cmd *exec.Cmd) (io.ReadWriteCloser, error) {
	master, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	go io.Copy(io.Discard, master)
	return master, nil
}
