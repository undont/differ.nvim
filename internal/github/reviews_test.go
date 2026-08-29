package github

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/undont/differ.nvim/internal/protocol"
)

// gqlOp returns the operation name from a GraphQL request body so a fake transport
// can route the lookup query and the mutation that follows it.
func gqlOp(t *testing.T, body []byte) string {
	t.Helper()
	s := string(body)
	for _, op := range []string{"StartReviewLookup", "AddReview", "SubmitReview", "DeleteReview"} {
		if strings.Contains(s, op) {
			return op
		}
	}
	t.Fatalf("unrecognised graphql op: %s", s)
	return ""
}

func readBody(t *testing.T, r *http.Request) []byte {
	t.Helper()
	b, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatalf("reading request body: %v", err)
	}
	return b
}

// ── start_review ──────────────────────────────────────────────────────────────

func TestStartReviewCreatesWhenNoDraft(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		op := gqlOp(t, readBody(t, r))
		ops = append(ops, op)
		switch op {
		case "StartReviewLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[]}}}}}`, nil), nil
		case "AddReview":
			return resp(200, `{"data":{"addPullRequestReview":{"pullRequestReview":{"id":"PRR_NEW"}}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	sr, err := c.StartReview(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if sr.ReviewID != "PRR_NEW" {
		t.Errorf("review id = %q, want PRR_NEW", sr.ReviewID)
	}
	if len(ops) != 2 || ops[0] != "StartReviewLookup" || ops[1] != "AddReview" {
		t.Errorf("expected lookup then add, got %v", ops)
	}
}

func TestStartReviewIsIdempotent(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		op := gqlOp(t, readBody(t, r))
		ops = append(ops, op)
		// an existing pending review short-circuits before any mutation.
		return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[{"id":"PRR_EXISTING"}]}}}}}`, nil), nil
	})
	sr, err := c.StartReview(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if sr.ReviewID != "PRR_EXISTING" {
		t.Errorf("review id = %q, want the existing draft", sr.ReviewID)
	}
	if len(ops) != 1 {
		t.Errorf("idempotent start must not mutate, ops=%v", ops)
	}
}

// ── submit_review ─────────────────────────────────────────────────────────────

func TestSubmitReview(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, `"event":"APPROVE"`) || !strings.Contains(body, `"reviewId":"PRR_1"`) {
			t.Errorf("submit vars not threaded: %s", body)
		}
		return resp(200, `{"data":{"submitPullRequestReview":{"pullRequestReview":{"fullDatabaseId":"4242"}}}}`, nil), nil
	})
	sr, err := c.SubmitReview(context.Background(), "PRR_1", "APPROVE", "lgtm")
	if err != nil {
		t.Fatal(err)
	}
	if sr.ID != 4242 {
		t.Errorf("submitted id = %d, want 4242", sr.ID)
	}
}

// ── discard_review ────────────────────────────────────────────────────────────

func TestDiscardReview(t *testing.T) {
	called := false
	c := newClient(func(r *http.Request) (*http.Response, error) {
		called = true
		if !strings.Contains(string(readBody(t, r)), `"reviewId":"PRR_1"`) {
			t.Error("discard did not thread the review id")
		}
		return resp(200, `{"data":{"deletePullRequestReview":{"pullRequestReview":{"id":"PRR_1"}}}}`, nil), nil
	})
	if err := c.DiscardReview(context.Background(), "PRR_1"); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Error("discard never hit the transport")
	}
}

func TestDiscardReviewMapsGraphQLError(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, `{"data":null,"errors":[{"type":"NOT_FOUND","message":"no such review"}]}`, nil), nil
	})
	err := c.DiscardReview(context.Background(), "PRR_x")
	if codeOf(t, err) != protocol.CodeNotFound {
		t.Fatalf("want not_found, got %v", err)
	}
}

// a null review payload must not read as a started review: lua would store the empty id,
// promise the user drafts, and publish every later comment straight to the PR.
func TestStartReviewRejectsEmptyID(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(string(readBody(t, r)), "StartReviewLookup") {
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[]}}}}}`, nil), nil
		}
		return resp(200, `{"data":{"addPullRequestReview":{"pullRequestReview":null}}}`, nil), nil
	})
	sr, err := c.StartReview(context.Background(), "o", "r", 3)
	if sr != nil {
		t.Errorf("no review id must not yield a review: %+v", sr)
	}
	if got := codeOf(t, err); got != protocol.CodeInternal {
		t.Fatalf("empty review id → %q, want %q", got, protocol.CodeInternal)
	}
}
