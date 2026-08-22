package github

import (
	"errors"
	"os"
	"os/exec"
	"strings"

	"github.com/undont/differ.nvim/internal/protocol"
)

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
func ResolveToken() (string, error) {
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

	out, err := exec.Command(gh, "auth", "token").Output()
	if err != nil {
		return "", protocol.NewError(protocol.CodeAuth,
			"gh is installed but not authenticated; run `gh auth login`")
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", protocol.NewError(protocol.CodeAuth, "gh returned an empty token; run `gh auth login`")
	}
	return token, nil
}
