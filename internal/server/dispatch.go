package server

import (
	"context"
	"errors"
	"runtime/debug"
	"sync"
	"time"

	"github.com/undont/differ.nvim/internal/protocol"
)

// outcome names how a request ended, for the debug trace: the error's closed-set
// code, or "ok".
func outcome(resp protocol.Response) string {
	if resp.Error != nil {
		return resp.Error.Code
	}
	return "ok"
}

// dispatch routes one request. hello is handled inline (no goroutine) so the
// hello-first gate has no race; every other method runs in its own goroutine and
// reports back through the serialized writer, so responses may complete out of
// order (the client keys by id).
func (s *Server) dispatch(ctx context.Context, req protocol.Request, inflight *sync.WaitGroup) {
	if req.Method == "hello" {
		resp := s.run(ctx, req)
		if resp.Error == nil {
			s.helloOK.Store(true)
		}
		s.emit(resp)
		return
	}
	if !s.helloOK.Load() {
		s.emit(badRequest(req.ID, "handshake required: send hello first"))
		return
	}
	inflight.Add(1)
	go func() {
		defer inflight.Done()
		s.emit(s.run(ctx, req))
	}()
}

// run invokes a handler, recovering panics into an internal error so one bad
// handler can never crash the process or corrupt the stream.
func (s *Server) run(ctx context.Context, req protocol.Request) (resp protocol.Response) {
	resp.ID = req.ID
	// registered first, so it runs last and sees whatever the recover below settled
	// on. one line per request is the spine of a debug trace: what was asked, how
	// long it took, and what came back
	start := time.Now()
	defer func() {
		s.log.Debug("request", "method", req.Method, "id", req.ID,
			"ms", time.Since(start).Milliseconds(), "code", outcome(resp))
	}()
	defer func() {
		if r := recover(); r != nil {
			s.log.Error("handler panic", "method", req.Method, "panic", r, "stack", string(debug.Stack()))
			resp.Result = nil
			resp.Error = &protocol.RPCError{Code: protocol.CodeInternal, Message: "internal error"}
		}
	}()

	h, ok := s.reg[req.Method]
	if !ok {
		resp.Error = &protocol.RPCError{Code: protocol.CodeBadRequest, Message: "unknown method: " + req.Method}
		return resp
	}

	result, err := h(ctx, req.Params)
	if err != nil {
		resp.Error = toRPCError(err)
		if resp.Error.Code == protocol.CodeInternal {
			s.log.Error("handler error", "method", req.Method, "err", err)
		}
		return resp
	}
	resp.Result = result
	return resp
}

// toRPCError maps a handler error to the wire envelope. a *protocol.Error keeps
// its code; anything else is internal (and the real error is logged, never
// surfaced, so tokens can't leak).
func toRPCError(err error) *protocol.RPCError {
	var pe *protocol.Error
	if errors.As(err, &pe) {
		return &protocol.RPCError{Code: pe.Code, Message: pe.Message, RetryAfter: pe.RetryAfter}
	}
	return &protocol.RPCError{Code: protocol.CodeInternal, Message: "internal error"}
}
