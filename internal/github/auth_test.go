package github

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/undont/differ.nvim/internal/protocol"
)

// fakeGH puts a `gh` on PATH running the given shell body, and clears the env tokens
// so resolution reaches it.
func fakeGH(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatalf("write fake gh: %v", err)
	}
	// prepended, not replaced: the fake still needs a PATH to run its own commands
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GH_TOKEN", "")
	t.Setenv("GITHUB_TOKEN", "")
}

func TestResolveTokenPrefersEnv(t *testing.T) {
	fakeGH(t, "echo from-gh")
	t.Setenv("GH_TOKEN", "from-env")

	got, err := ResolveToken(context.Background())
	if err != nil || got != "from-env" {
		t.Fatalf("got %q/%v, want from-env", got, err)
	}
}

func TestResolveTokenFromGH(t *testing.T) {
	fakeGH(t, "echo from-gh")

	got, err := ResolveToken(context.Background())
	if err != nil || got != "from-gh" {
		t.Fatalf("got %q/%v, want from-gh", got, err)
	}
}

func TestResolveTokenDeadline(t *testing.T) {
	// a gh that never answers, as a locked keyring waiting on a prompt. the caller's
	// own deadline stands in for ghTimeout so the test does not wait it out
	fakeGH(t, "sleep 60")

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := ResolveToken(ctx)

	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("ResolveToken waited %s; the deadline did not stop it", elapsed)
	}
	var perr *protocol.Error
	if !errors.As(err, &perr) || perr.Code != protocol.CodeAuth {
		t.Fatalf("want an auth error, got %v", err)
	}
	if !strings.Contains(perr.Message, "did not answer in time") {
		t.Errorf("the timeout should say so, got %q", perr.Message)
	}
}

func TestResolveTokenEmptyOutput(t *testing.T) {
	fakeGH(t, "echo ''")

	_, err := ResolveToken(context.Background())
	var perr *protocol.Error
	if !errors.As(err, &perr) || perr.Code != protocol.CodeAuth {
		t.Fatalf("want an auth error, got %v", err)
	}
}
