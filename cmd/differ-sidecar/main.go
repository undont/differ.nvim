// differ-sidecar speaks newline-delimited JSON over stdio to the Lua client.
// it owns all GitHub API interaction for the PR-review frontend.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/undont/differ.nvim/internal/github"
	"github.com/undont/differ.nvim/internal/handlers"
	"github.com/undont/differ.nvim/internal/logx"
	"github.com/undont/differ.nvim/internal/server"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	raw := os.Getenv(logx.LevelEnv)
	level, known := logx.ParseLevel(raw)
	log := logx.New(level)
	if !known {
		log.Warn("unrecognised log level, using info", "var", logx.LevelEnv, "value", raw)
	}

	// token resolution failure is non-fatal: the handshake still works and the
	// error is handed to the client so only PR methods surface gh_missing/auth.
	token, tokenErr := github.ResolveToken(ctx)
	if tokenErr != nil {
		log.Warn("github auth not ready", "err", tokenErr)
	}
	gh := github.New(nil, token, tokenErr, log)

	reg := handlers.NewRegistry(handlers.Deps{GH: gh, Log: log})
	srv := server.New(reg, log)

	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "differ-sidecar:", err)
		os.Exit(1)
	}
}
