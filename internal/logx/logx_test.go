package logx

import (
	"log/slog"
	"testing"
)

func TestParseLevel(t *testing.T) {
	cases := []struct {
		in    string
		want  slog.Level
		known bool
	}{
		{"", slog.LevelInfo, true}, // unset is the default, not a mistake
		{"debug", slog.LevelDebug, true},
		{"DEBUG", slog.LevelDebug, true},
		{"  Info  ", slog.LevelInfo, true},
		{"warn", slog.LevelWarn, true},
		{"warning", slog.LevelWarn, true},
		{"error", slog.LevelError, true},
		{"verbose", slog.LevelInfo, false}, // unrecognised: default, but say so
		{"3", slog.LevelInfo, false},
	}
	for _, tc := range cases {
		got, known := ParseLevel(tc.in)
		if got != tc.want || known != tc.known {
			t.Errorf("ParseLevel(%q) = %v, %v; want %v, %v", tc.in, got, known, tc.want, tc.known)
		}
	}
}
