package github

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/undont/differ.nvim/internal/protocol"
)

// commentOp routes the post_comment graphql ops. AddThreadReply must be checked
// before AddThread (the former contains the latter as a substring).
func commentOp(t *testing.T, body []byte) string {
	t.Helper()
	s := string(body)
	for _, op := range []string{"StartReviewLookup", "PRNodeID", "PublishComment", "AddThreadReply", "AddThread"} {
		if strings.Contains(s, op) {
			return op
		}
	}
	t.Fatalf("unrecognised graphql op: %s", s)
	return ""
}

func TestPostCommentDraftThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		if op := commentOp(t, body); op != "AddThread" {
			t.Fatalf("a draft post must not look up the PR node, got op %s", op)
		}
		if !strings.Contains(string(body), `"reviewId":"PRR_1"`) {
			t.Errorf("review id not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRT_9","comments":{"nodes":[{"fullDatabaseId":"7001"}]}}}}}`, nil), nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 10, Body: "nit", ReviewID: "PRR_1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if pc.ID != 7001 || pc.ThreadID != "PRT_9" {
		t.Errorf("bad result: %+v", pc)
	}
}

// with no pending review, an immediate post publishes its own COMMENT review: it looks
// up the PR + pending review, finds none, then runs PublishComment.
func TestPostCommentImmediatePublishesWhenNoPendingReview(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		op := commentOp(t, body)
		ops = append(ops, op)
		switch op {
		case "StartReviewLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[]}}}}}`, nil), nil
		case "PublishComment":
			s := string(body)
			for _, want := range []string{`"prId":"PR_NODE"`, `"path":"a.go"`, `"line":5`, `"side":"RIGHT"`, `"body":"hi"`} {
				if !strings.Contains(s, want) {
					t.Errorf("publish payload missing %s: %s", want, s)
				}
			}
			return resp(200, `{"data":{"addPullRequestReview":{"pullRequestReview":{"comments":{"nodes":[{"fullDatabaseId":"42"}]}}}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 5, Body: "hi",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 2 || ops[0] != "StartReviewLookup" || ops[1] != "PublishComment" {
		t.Errorf("want lookup then publish, got %v", ops)
	}
	if pc.ID != 42 || pc.ReviewID != "" {
		t.Errorf("a published comment carries no review id: %+v", pc)
	}
}

// when a pending review already exists, an immediate post joins it as a draft (github
// allows one pending review per PR) and echoes the review id so the frontend adopts it.
func TestPostCommentImmediateJoinsExistingPendingReview(t *testing.T) {
	var ops []string
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		op := commentOp(t, body)
		ops = append(ops, op)
		switch op {
		case "StartReviewLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[{"id":"PRR_X"}]}}}}}`, nil), nil
		case "AddThread":
			if !strings.Contains(string(body), `"reviewId":"PRR_X"`) {
				t.Errorf("comment must join the pending review: %s", body)
			}
			return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRT_2","comments":{"nodes":[{"fullDatabaseId":"7"}]}}}}}`, nil), nil
		}
		t.Fatalf("unexpected op %s", op)
		return nil, nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 5, Body: "hi",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 2 || ops[0] != "StartReviewLookup" || ops[1] != "AddThread" {
		t.Errorf("want lookup then draft, got %v", ops)
	}
	if pc.ID != 7 || pc.ThreadID != "PRT_2" || pc.ReviewID != "PRR_X" {
		t.Errorf("draft result must echo the review id: %+v", pc)
	}
}

// a range comment threads startLine and defaults startSide to side when unset.
func TestPostCommentRangeDefaultsStartSide(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, `"startLine":4`) || !strings.Contains(body, `"startSide":"RIGHT"`) {
			t.Errorf("range start fields not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThread":{"thread":{"id":"T","comments":{"nodes":[{"fullDatabaseId":"1"}]}}}}}`, nil), nil
	})
	_, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 8, StartLine: 4, Body: "range", ReviewID: "PRR_1",
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestDeleteComment(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, "DeleteComment") || !strings.Contains(body, `"id":"PRRC_8"`) {
			t.Errorf("delete mutation not sent with the node id: %s", body)
		}
		return resp(200, `{"data":{"deletePullRequestReviewComment":{"pullRequestReview":{"id":"PRR_1"}}}}`, nil), nil
	})
	if err := c.DeleteComment(context.Background(), "PRRC_8"); err != nil {
		t.Fatal(err)
	}
}

func TestPostCommentReply(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := readBody(t, r)
		if op := commentOp(t, body); op != "AddThreadReply" {
			t.Fatalf("a reply must use the reply mutation, got op %s", op)
		}
		if !strings.Contains(string(body), `"threadId":"PRT_5"`) {
			t.Errorf("thread id not threaded: %s", body)
		}
		return resp(200, `{"data":{"addPullRequestReviewThreadReply":{"comment":{"fullDatabaseId":"9099"}}}}`, nil), nil
	})
	pc, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Body: "thanks", InReplyTo: "PRT_5",
	})
	if err != nil {
		t.Fatal(err)
	}
	if pc.ID != 9099 || pc.ThreadID != "PRT_5" {
		t.Errorf("reply result: %+v", pc)
	}
}

// the envelope below is what GitHub actually returned for an anchor outside the diff
// (captured against a live PR): a 200 carrying a top-level type of UNPROCESSABLE. it is
// the user's line to fix, so it must not read as an internal fault.
func TestPublishCommentOutOfDiffIsBadRequest(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch op := commentOp(t, readBody(t, r)); op {
		case "StartReviewLookup":
			return resp(200, `{"data":{"repository":{"pullRequest":{"id":"PR_NODE","reviews":{"nodes":[]}}}}}`, nil), nil
		case "PublishComment":
			return resp(200, `{"data":{"addPullRequestReview":null},"errors":[{"type":"UNPROCESSABLE","path":["addPullRequestReview"],"locations":[{"line":1,"column":82}],"message":"Line could not be resolved"}]}`, nil), nil
		default:
			t.Fatalf("unexpected op %s", op)
			return nil, nil
		}
	})
	_, err := c.PostComment(context.Background(), "o", "r", 3, PostCommentInput{
		Path: "a.go", Side: "RIGHT", Line: 999999, Body: "nit",
	})
	if got := codeOf(t, err); got != protocol.CodeBadRequest {
		t.Fatalf("out-of-diff anchor → %q, want %q", got, protocol.CodeBadRequest)
	}
	if perrOf(t, err).Message != "Line could not be resolved" {
		t.Errorf("github's own message must survive: %v", err)
	}
}
