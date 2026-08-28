package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/undont/differ.nvim/internal/handlers"
	"github.com/undont/differ.nvim/internal/protocol"
)

const helloLine = `{"id":1,"method":"hello","params":{"client":"differ.nvim","protocol":1}}`

// drive runs the server over the given input lines and returns the responses in
// the order they were written.
func drive(t *testing.T, reg handlers.Registry, lines ...string) []protocol.Response {
	t.Helper()
	in := strings.NewReader(strings.Join(lines, "\n") + "\n")
	var out strings.Builder
	srv := New(reg, discardLog())

	done := make(chan error, 1)
	go func() { done <- srv.Run(context.Background(), in, &out) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return (deadlock?)")
	}

	var resps []protocol.Response
	dec := json.NewDecoder(strings.NewReader(out.String()))
	for {
		var r protocol.Response
		if err := dec.Decode(&r); err == io.EOF {
			break
		} else if err != nil {
			t.Fatalf("decode response: %v\noutput: %q", err, out.String())
		}
		resps = append(resps, r)
	}
	return resps
}

func discardLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestHello(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	resps := drive(t, reg, helloLine)
	if len(resps) != 1 {
		t.Fatalf("want 1 response, got %d", len(resps))
	}
	r := resps[0]
	if r.ID != 1 || r.Error != nil {
		t.Fatalf("bad hello response: %+v", r)
	}
	res, _ := r.Result.(map[string]any)
	if res["binary"] != protocol.Binary {
		t.Errorf("binary = %v, want %v", res["binary"], protocol.Binary)
	}
	if int(res["protocol"].(float64)) != protocol.Version {
		t.Errorf("protocol = %v, want %v", res["protocol"], protocol.Version)
	}
}

func TestHelloProtocolMismatch(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	resps := drive(t, reg, `{"id":1,"method":"hello","params":{"client":"x","protocol":99}}`)
	if got := resps[0].Error; got == nil || got.Code != protocol.CodeBadRequest {
		t.Fatalf("want bad_request on mismatch, got %+v", resps[0])
	}
}

func TestHandshakeGate(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	// a non-hello method before hello must be rejected, not dispatched.
	resps := drive(t, reg, `{"id":7,"method":"list_prs","params":{}}`)
	if len(resps) != 1 || resps[0].Error == nil || resps[0].Error.Code != protocol.CodeBadRequest {
		t.Fatalf("want bad_request before handshake, got %+v", resps)
	}
	if resps[0].ID != 7 {
		t.Errorf("id = %d, want 7", resps[0].ID)
	}
}

func TestUnknownMethod(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	resps := drive(t, reg, helloLine, `{"id":2,"method":"nope","params":{}}`)
	last := resps[len(resps)-1]
	if last.Error == nil || last.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("want bad_request for unknown method, got %+v", last)
	}
}

func TestInvalidJSONNeverCrashes(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	resps := drive(t, reg, `{not json`, helloLine)
	if len(resps) != 2 {
		t.Fatalf("want 2 responses, got %d: %+v", len(resps), resps)
	}
	if resps[0].Error == nil || resps[0].Error.Code != protocol.CodeBadRequest {
		t.Errorf("invalid JSON should yield bad_request, got %+v", resps[0])
	}
	if resps[1].Error != nil {
		t.Errorf("hello after bad line should still succeed, got %+v", resps[1])
	}
}

func TestPanicBecomesInternal(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	reg["boom"] = func(context.Context, json.RawMessage) (any, error) { panic("kaboom") }
	resps := drive(t, reg, helloLine, `{"id":3,"method":"boom","params":{}}`)
	last := resps[len(resps)-1]
	if last.ID != 3 || last.Error == nil || last.Error.Code != protocol.CodeInternal {
		t.Fatalf("panic should map to internal, got %+v", last)
	}
}

func TestOversizedLineResyncs(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	// a frame past the cap is answered and discarded to its terminator. drive fails
	// the test if Run returns an error, so this also pins that it no longer does.
	big := `{"id":2,"method":"hello","params":{"junk":"` + strings.Repeat("a", maxLine) + `"}}`
	after := `{"id":3,"method":"hello","params":{"client":"differ.nvim","protocol":1}}`
	resps := drive(t, reg, helloLine, big, after)

	if len(resps) != 3 {
		t.Fatalf("want 3 responses, got %d: %+v", len(resps), resps)
	}
	if resps[0].ID != 1 || resps[0].Error != nil {
		t.Errorf("hello before the oversized frame should succeed, got %+v", resps[0])
	}
	// the id is unrecoverable from an unparsed frame, so the error carries 0
	if resps[1].ID != 0 || resps[1].Error == nil || resps[1].Error.Code != protocol.CodeBadRequest {
		t.Errorf("oversized frame should yield bad_request, got %+v", resps[1])
	}
	// the point of the resync: the frame behind the oversized one is still served
	if resps[2].ID != 3 || resps[2].Error != nil {
		t.Errorf("request after the oversized frame should succeed, got %+v", resps[2])
	}
}

func TestFrameAtCapIsServed(t *testing.T) {
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	// the cap is inclusive, and the frame spans several reader buffers on the way to
	// it: the length has to be checked against the whole frame, not the last chunk
	head := `{"id":4,"method":"hello","params":{"client":"differ.nvim","protocol":1,"junk":"`
	tail := `"}}`
	atCap := head + strings.Repeat("a", maxLine-len(head)-len(tail)) + tail
	if len(atCap) != maxLine {
		t.Fatalf("test frame is %d bytes, want %d", len(atCap), maxLine)
	}

	resps := drive(t, reg, atCap)
	if len(resps) != 1 {
		t.Fatalf("want 1 response, got %d", len(resps))
	}
	if resps[0].ID != 4 || resps[0].Error != nil {
		t.Errorf("a frame at the cap should be served, got %+v", resps[0])
	}
}

func TestOutOfOrderKeyedByID(t *testing.T) {
	var release sync.WaitGroup
	release.Add(1)
	reg := handlers.NewRegistry(handlers.Deps{Log: discardLog()})
	// slow blocks until released; fast returns immediately. with per-request
	// goroutines, fast's response is written before slow's despite slow arriving
	// first, and each response still carries its own id.
	reg["slow"] = func(context.Context, json.RawMessage) (any, error) { release.Wait(); return "slow", nil }
	reg["fast"] = func(context.Context, json.RawMessage) (any, error) { return "fast", nil }
	in := strings.NewReader(strings.Join([]string{
		helloLine,
		`{"id":10,"method":"slow","params":{}}`,
		`{"id":11,"method":"fast","params":{}}`,
	}, "\n") + "\n")
	var out lockedBuffer
	srv := New(reg, discardLog())
	done := make(chan error, 1)
	go func() { done <- srv.Run(context.Background(), in, &out) }()

	// let fast land first, then release slow.
	time.Sleep(50 * time.Millisecond)
	release.Done()
	if err := <-done; err != nil {
		t.Fatal(err)
	}

	var resps []protocol.Response
	dec := json.NewDecoder(strings.NewReader(out.String()))
	for {
		var r protocol.Response
		if err := dec.Decode(&r); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		resps = append(resps, r)
	}
	if len(resps) != 3 {
		t.Fatalf("want 3 responses, got %d", len(resps))
	}
	// fast (id 11) must precede slow (id 10) in the output stream.
	got := []int{resps[1].ID, resps[2].ID}
	if got[0] != 11 || got[1] != 10 {
		t.Fatalf("want fast(11) before slow(10), got order %v", got)
	}
}

// lockedBuffer is a concurrency-safe io.Writer for the out-of-order test, since
// the real writer goroutine is the sole writer but the test reads concurrently.
type lockedBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// captureLog returns a debug-level logger writing into buf.
func captureLog(buf *bytes.Buffer) *slog.Logger {
	return slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

func runWith(t *testing.T, log *slog.Logger, reg handlers.Registry, lines ...string) {
	t.Helper()
	in := strings.NewReader(strings.Join(lines, "\n") + "\n")
	var out strings.Builder
	if err := New(reg, log).Run(context.Background(), in, &out); err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestDebugTracesEveryRequest(t *testing.T) {
	var buf bytes.Buffer
	reg := handlers.NewRegistry(handlers.Deps{Log: captureLog(&buf)})
	reg["boom"] = func(context.Context, json.RawMessage) (any, error) { panic("kaboom") }
	runWith(t, captureLog(&buf), reg, helloLine, `{"id":3,"method":"boom","params":{}}`)

	got := buf.String()
	if !strings.Contains(got, "msg=request method=hello id=1") {
		t.Errorf("hello was not traced:\n%s", got)
	}
	// the trace line is registered before the recover, so it runs after it and
	// reports the code the caller actually received rather than "ok"
	if !strings.Contains(got, "msg=request method=boom id=3") || !strings.Contains(got, "code=internal") {
		t.Errorf("the panicking request was not traced with its outcome:\n%s", got)
	}
}

func TestDefaultLevelTracesNothing(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil)) // no level set: info
	reg := handlers.NewRegistry(handlers.Deps{Log: log})
	runWith(t, log, reg, helloLine)

	if strings.Contains(buf.String(), "msg=request") {
		t.Errorf("info level should not trace requests:\n%s", buf.String())
	}
}
