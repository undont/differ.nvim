package github

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/undont/differ.nvim/internal/protocol"
)

// ghTimeout bounds `gh auth token`. it normally answers at once, but it can reach the
// OS keyring, and a locked one leaves it waiting on a prompt no one can answer. this
// runs before the server reads stdin, so the wait is the handshake's wait: it has to
// stay well inside the client's ping window or a stuck keyring reads as a dead binary.
const ghTimeout = 5 * time.Second

// ghWaitDelay bounds the wait after the deadline kills gh. killing it does not kill
// whatever it spawned, and a child holding the inherited stdout pipe keeps Output
// blocking however long it likes; past this the pipes are closed out from under it.
const ghWaitDelay = time.Second

// TokenStatus reports whether this client has a usable token: "ok", or the closed-set
// code the resolution failed with ("gh_missing"/"auth") and the message explaining what
// to do about it. resolution happens once at startup and its failure is otherwise only
// visible when a PR method is called, which is far too late to be a diagnostic. the
// token itself is never returned, only whether there is one.
func (c *Client) TokenStatus() (status, message string) {
	if c.tokenErr == nil {
		return "ok", ""
	}
	if perr, ok := errors.AsType[*protocol.Error](c.tokenErr); ok {
		return perr.Code, perr.Message
	}
	return protocol.CodeInternal, c.tokenErr.Error()
}

// ResolveToken finds a GitHub token without go-gh: GH_TOKEN, then
// GITHUB_TOKEN, then `gh auth token`. a missing gh binary with no env token is
// gh_missing; gh present but yielding no token is auth. the token is never logged.
func ResolveToken(ctx context.Context) (string, error) {
	for _, env := range []string{"GH_TOKEN", "GITHUB_TOKEN"} {
		if v := strings.TrimSpace(os.Getenv(env)); v != "" {
			return v, nil
		}
	}

	gh, err := exec.LookPath("gh")
	if err != nil {
		return "", protocol.NewError(protocol.CodeGHMissing,
			"no token in GH_TOKEN/GITHUB_TOKEN and the gh CLI is not installed")
	}

	ctx, cancel := context.WithTimeout(ctx, ghTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, "auth", "token")
	cmd.WaitDelay = ghWaitDelay
	out, err := cmd.Output()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", protocol.NewError(protocol.CodeAuth,
				"`gh auth token` did not answer in time; is your keyring unlocked?")
		}
		return "", protocol.NewError(protocol.CodeAuth,
			"gh is installed but not authenticated; run `gh auth login`")
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", protocol.NewError(protocol.CodeAuth, "gh returned an empty token; run `gh auth login`")
	}
	return token, nil
}
