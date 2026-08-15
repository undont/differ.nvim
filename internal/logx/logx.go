// Package logx provides the sidecar's structured logger. it writes to stderr
// ONLY; stdout is reserved for the protocol stream. tokens must never be
// passed to it.
package logx

import (
	"log/slog"
	"os"
	"strings"
)

// LevelEnv names the environment variable that sets the log level. the client
// spawns the sidecar with its own environment, so `DIFFER_LOG_LEVEL=debug nvim`
// reaches it, as does setting vim.env before the first request starts a process.
const LevelEnv = "DIFFER_LOG_LEVEL"

// ParseLevel maps a LevelEnv value to a slog level, case-insensitively. an empty
// value is the default rather than an error; ok is false only for a value that was
// set to something unrecognised, so the caller can say so instead of going quiet.
func ParseLevel(s string) (level slog.Level, ok bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "":
		return slog.LevelInfo, true
	case "debug":
		return slog.LevelDebug, true
	case "info":
		return slog.LevelInfo, true
	case "warn", "warning":
		return slog.LevelWarn, true
	case "error":
		return slog.LevelError, true
	}
	return slog.LevelInfo, false
}

// New returns a slog logger writing text to stderr at the given level.
func New(level slog.Level) *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
}
