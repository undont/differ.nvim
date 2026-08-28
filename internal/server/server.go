// Package server is the stdio engine: a single stdin reader fans requests
// out to per-request goroutines, all funnelling responses through one serialized
// stdout writer. concurrency-safe by construction; stdout stays protocol-pure.
package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// readBuf is the reader's working buffer; frames larger than this are accumulated
// across reads, up to maxLine.
const readBuf = 64 * 1024

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
	reader := bufio.NewReaderSize(in, readBuf)

	var readErr error
	for {
		line, oversized, err := readFrame(reader)
		if oversized {
			// the id is unrecoverable: the frame was never parsed, and a client
			// encoding its object in any key order can put id past the cap
			s.emit(badRequest(0, fmt.Sprintf("request exceeds the %d byte frame limit", maxLine)))
		}
		if len(line) > 0 {
			var req protocol.Request
			if uerr := json.Unmarshal(line, &req); uerr != nil {
				s.emit(badRequest(0, "invalid JSON"))
			} else {
				s.dispatch(ctx, req, &inflight)
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				readErr = err
			}
			break
		}
	}

	inflight.Wait()
	close(s.outbound)
	writerDone.Wait()
	return readErr
}

// readFrame returns the next newline-terminated frame. a frame past maxLine is
// discarded to its terminator and reported oversized, so the stream resyncs on the
// next request rather than the process dying with one queued behind it.
func readFrame(r *bufio.Reader) (line []byte, oversized bool, err error) {
	for {
		chunk, e := r.ReadSlice('\n')
		full := errors.Is(e, bufio.ErrBufferFull)
		if !full {
			// only the last chunk can carry the terminator, and the cap is on the
			// frame rather than on the frame plus its newline
			chunk = bytes.TrimSuffix(chunk, []byte{'\n'})
		}
		// ReadSlice aliases the reader's buffer, so the frame has to be copied out
		// before the next read overwrites it
		line = append(line, chunk...)
		if len(line) > maxLine {
			if full {
				e = discardFrame(r)
			}
			return nil, true, e
		}
		if !full {
			return line, false, e
		}
	}
}

// discardFrame drops whatever remains of the current frame, leaving the reader on
// the next one.
func discardFrame(r *bufio.Reader) error {
	for {
		if _, err := r.ReadSlice('\n'); !errors.Is(err, bufio.ErrBufferFull) {
			return err
		}
	}
}

// emit queues an outbound frame for the writer goroutine.
func (s *Server) emit(msg protocol.Outbound) { s.outbound <- msg }

func badRequest(id int, msg string) protocol.Response {
	return protocol.Response{ID: id, Error: &protocol.RPCError{Code: protocol.CodeBadRequest, Message: msg}}
}
