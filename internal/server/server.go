// Package server is the stdio engine: a single stdin reader fans requests
// out to per-request goroutines, all funnelling responses through one serialized
// stdout writer. concurrency-safe by construction; stdout stays protocol-pure.
package server

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/undont/differ.nvim/internal/handlers"
	"github.com/undont/differ.nvim/internal/protocol"
)

// maxLine bounds a single request frame (large get_file_versions blobs land on
// the response side, not here).
const maxLine = 16 * 1024 * 1024

// Server owns the dispatch loop and its handler registry.
type Server struct {
	reg      handlers.Registry
	log      *slog.Logger
	helloOK  atomic.Bool
	outbound chan protocol.Outbound
}

// New builds a server over a method registry.
func New(reg handlers.Registry, log *slog.Logger) *Server {
	return &Server{reg: reg, log: log}
}

// Run reads requests from in until EOF and writes responses to out. it blocks
// until the input is drained and every in-flight handler has completed.
func (s *Server) Run(ctx context.Context, in io.Reader, out io.Writer) error {
	s.outbound = make(chan protocol.Outbound, 64)

	// sole owner of stdout: one goroutine, so writes are serialized without a mutex.
	var writerDone sync.WaitGroup
	writerDone.Go(func() {
		enc := json.NewEncoder(out)
		for msg := range s.outbound {
			if err := enc.Encode(msg); err != nil {
				s.log.Error("encode response", "err", err)
			}
		}
	})

	var inflight sync.WaitGroup
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 64*1024), maxLine)

	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		var req protocol.Request
		if err := json.Unmarshal(line, &req); err != nil {
			s.emit(badRequest(0, "invalid JSON"))
			continue
		}
		s.dispatch(ctx, req, &inflight)
	}
	scanErr := scanner.Err()

	inflight.Wait()
	close(s.outbound)
	writerDone.Wait()
	return scanErr
}

// emit queues an outbound frame for the writer goroutine.
func (s *Server) emit(msg protocol.Outbound) { s.outbound <- msg }

func badRequest(id int, msg string) protocol.Response {
	return protocol.Response{ID: id, Error: &protocol.RPCError{Code: protocol.CodeBadRequest, Message: msg}}
}
