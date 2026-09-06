package github

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/undont/differ.nvim/internal/protocol"
)

// ── get_file_versions ─────────────────────────────────────────────────────────

const prRefsREST = `{"base":{"sha":"basesha"},"head":{"sha":"headsha"}}`

func TestGetFileVersions(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			return resp(200, prRefsREST, nil), nil
		case strings.Contains(r.URL.Path, "/contents/dir/a.go"):
			ref := r.URL.Query().Get("ref")
			if r.Header.Get("Accept") != "application/vnd.github.raw+json" {
				t.Errorf("want raw media type, got %q", r.Header.Get("Accept"))
			}
			return resp(200, "content@"+ref, nil), nil
		}
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	fv, err := c.GetFileVersions(context.Background(), "o", "r", 3, "dir/a.go", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if fv.Base.Content != "content@basesha" || fv.Head.Content != "content@headsha" {
		t.Errorf("blobs not fetched per ref: %+v", fv)
	}
	if fv.Base.Missing || fv.Head.Missing || fv.Truncated {
		t.Errorf("flags should be clear for a present file: %+v", fv)
	}
}

// HeadSHA resolves the live head (not the base) for the TOCTOU guard.
func TestHeadSHA(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/pulls/3") {
			return resp(200, prRefsREST, nil), nil
		}
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	head, err := c.HeadSHA(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if head != "headsha" {
		t.Errorf("want head sha, got %q", head)
	}
}

// pinned base/head shas (from get_pr) skip the prRefs round-trip: the /pulls/3
// endpoint is never hit, and the blobs are fetched at the passed shas.
func TestGetFileVersionsPinnedRefsSkipPrRefs(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			t.Fatalf("prRefs should be skipped when base/head are pinned")
		case strings.Contains(r.URL.Path, "/contents/a.go"):
			return resp(200, "content@"+r.URL.Query().Get("ref"), nil), nil
		}
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	fv, err := c.GetFileVersions(context.Background(), "o", "r", 3, "a.go", "", "pinbase", "pinhead")
	if err != nil {
		t.Fatal(err)
	}
	if fv.Base.Content != "content@pinbase" || fv.Head.Content != "content@pinhead" {
		t.Errorf("blobs not fetched at the pinned shas: %+v", fv)
	}
}

func TestGetFileVersionsAddedFileMissingBase(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			return resp(200, prRefsREST, nil), nil
		case strings.Contains(r.URL.Path, "/contents/"):
			if r.URL.Query().Get("ref") == "basesha" {
				return resp(404, `{"message":"Not Found"}`, nil), nil
			}
			return resp(200, "new file", nil), nil
		}
		t.Fatalf("unexpected request %s", r.URL.Path)
		return nil, nil
	})
	fv, err := c.GetFileVersions(context.Background(), "o", "r", 3, "new.go", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !fv.Base.Missing || fv.Base.Content != "" {
		t.Errorf("added file should have a missing base: %+v", fv.Base)
	}
	if fv.Head.Missing || fv.Head.Content != "new file" {
		t.Errorf("head should be present: %+v", fv.Head)
	}
}

// a rename's two sides live at different paths: the base blob is fetched at basePath
// (the REST file list's previous_path), the head blob at path. asking for either path
// at the other side's ref is the bug this guards.
func TestGetFileVersionsRenameFetchesBothPaths(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		ref := r.URL.Query().Get("ref")
		switch {
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			return resp(200, prRefsREST, nil), nil
		case strings.Contains(r.URL.Path, "/contents/old/a.go"):
			if ref != "basesha" {
				t.Errorf("old path should only be asked for at the base, got ref %q", ref)
			}
			return resp(200, "old content", nil), nil
		case strings.Contains(r.URL.Path, "/contents/new/b.go"):
			if ref != "headsha" {
				t.Errorf("new path should only be asked for at the head, got ref %q", ref)
			}
			return resp(200, "new content", nil), nil
		}
		t.Fatalf("unexpected request %s", r.URL.Path)
		return nil, nil
	})
	fv, err := c.GetFileVersions(context.Background(), "o", "r", 3, "new/b.go", "old/a.go", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if fv.Base.Missing || fv.Base.Content != "old content" {
		t.Errorf("base should come from the previous path, not be missing: %+v", fv.Base)
	}
	if fv.Head.Missing || fv.Head.Content != "new content" {
		t.Errorf("head should come from the new path: %+v", fv.Head)
	}
}

func TestGetFileVersionsPropagatesError(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/pulls/3") {
			return resp(200, prRefsREST, nil), nil
		}
		return resp(401, `{"message":"Bad credentials"}`, nil), nil
	})
	_, err := c.GetFileVersions(context.Background(), "o", "r", 3, "a.go", "", "", "")
	if codeOf(t, err) != protocol.CodeAuth {
		t.Fatalf("want auth, got %v", err)
	}
}

// ── get_threads ───────────────────────────────────────────────────────────────

const threadsGraphQL = `{"data":{"repository":{"pullRequest":{"reviewThreads":{
  "nodes":[
    {"id":"THREAD_A","isResolved":false,"path":"a.go","line":12,"startLine":null,"diffSide":"RIGHT","startDiffSide":null,
     "comments":{"nodes":[
       {"fullDatabaseId":"1001","author":{"login":"alice"},"body":"first","createdAt":"2026-01-01","state":"SUBMITTED","diffHunk":"@@ -10,3 +10,4 @@\n ctx\n+added"},
       {"fullDatabaseId":"1002","author":{"login":"bob"},"body":"reply","createdAt":"2026-01-02","state":"SUBMITTED","diffHunk":"@@ -30,1 +30,2 @@\n+reply"}
     ]}},
    {"id":"THREAD_B","isResolved":true,"path":"b.go","line":40,"startLine":38,"diffSide":"RIGHT","startDiffSide":"RIGHT",
     "comments":{"nodes":[
       {"fullDatabaseId":"2001","author":{"login":"carol"},"body":"draft note","createdAt":"2026-01-03","state":"PENDING"}
     ]}}
  ],
  "pageInfo":{"hasNextPage":false,"endCursor":""}
}}}}}`

func TestGetThreads(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, threadsGraphQL, nil), nil
	})
	threads, err := c.GetThreads(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(threads) != 2 {
		t.Fatalf("want 2 threads, got %d", len(threads))
	}

	a := threads[0]
	if a.ThreadID != "THREAD_A" || a.ID != 1001 {
		t.Errorf("thread A ids wrong: thread_id=%q id=%d", a.ThreadID, a.ID)
	}
	if a.Side != "RIGHT" || a.Line != 12 || a.StartLine != 0 || a.StartSide != "" {
		t.Errorf("thread A anchor wrong: %+v", a)
	}
	if a.Resolved || a.IsPending {
		t.Errorf("thread A should be unresolved + submitted: %+v", a)
	}
	if len(a.Comments) != 2 || a.Comments[1].ID != 1002 || a.Comments[1].Author != "bob" {
		t.Errorf("thread A comments wrong: %+v", a.Comments)
	}
	if a.Comments[0].DiffHunk != "@@ -10,3 +10,4 @@\n ctx\n+added" || a.Comments[1].DiffHunk != "@@ -30,1 +30,2 @@\n+reply" {
		t.Errorf("thread A comment diff hunks wrong: %+v", a.Comments)
	}

	b := threads[1]
	if !b.Resolved || !b.IsPending {
		t.Errorf("thread B should be resolved + pending draft: %+v", b)
	}
	if b.StartLine != 38 || b.StartSide != "RIGHT" {
		t.Errorf("range thread B start anchor wrong: %+v", b)
	}
}

func TestGetThreadsPagination(t *testing.T) {
	page1 := `{"data":{"repository":{"pullRequest":{"reviewThreads":{
      "nodes":[{"id":"T1","isResolved":false,"path":"a","line":1,"diffSide":"RIGHT",
        "comments":{"nodes":[{"fullDatabaseId":"1","author":{"login":"a"},"body":"x","createdAt":"d","state":"SUBMITTED"}]}}],
      "pageInfo":{"hasNextPage":true,"endCursor":"CUR"}}}}}}`
	page2 := `{"data":{"repository":{"pullRequest":{"reviewThreads":{
      "nodes":[{"id":"T2","isResolved":false,"path":"b","line":2,"diffSide":"LEFT",
        "comments":{"nodes":[{"fullDatabaseId":"2","author":{"login":"b"},"body":"y","createdAt":"d","state":"SUBMITTED"}]}}],
      "pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`
	calls := 0
	c := newClient(func(*http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return resp(200, page1, nil), nil
		}
		return resp(200, page2, nil), nil
	})
	threads, err := c.GetThreads(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || len(threads) != 2 || threads[1].ThreadID != "T2" {
		t.Fatalf("pagination wrong: calls=%d threads=%+v", calls, threads)
	}
}

// ── get_pending_review ────────────────────────────────────────────────────────

func TestGetPendingReview(t *testing.T) {
	body := `{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
      {"id":"REVIEW_1","comments":{"nodes":[
        {"fullDatabaseId":"5001","path":"a.go","line":10,"startLine":null,"body":"draft"}
      ]}}
    ]}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, body, nil), nil
	})
	pr, err := c.GetPendingReview(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if pr.ReviewID == nil || *pr.ReviewID != "REVIEW_1" {
		t.Fatalf("review id wrong: %+v", pr.ReviewID)
	}
	if len(pr.Comments) != 1 || pr.Comments[0].ID != 5001 || pr.Comments[0].Body != "draft" {
		t.Errorf("draft comment wrong: %+v", pr.Comments)
	}
	// PullRequestReviewComment has no diffSide; asking for one made the whole query
	// invalid, so the fixture must not carry a field GitHub cannot return
	if pr.Comments[0].Line != 10 || pr.Comments[0].Side != "" {
		t.Errorf("draft anchor wrong: %+v", pr.Comments[0])
	}
}

func TestGetPendingReviewNoDraft(t *testing.T) {
	body := `{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[]}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, body, nil), nil
	})
	pr, err := c.GetPendingReview(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if pr.ReviewID != nil || len(pr.Comments) != 0 {
		t.Fatalf("want nil review id and no comments, got %+v", pr)
	}
}

// ── get_checks ────────────────────────────────────────────────────────────────

const checksGraphQL = `{"data":{"repository":{"pullRequest":{"commits":{"nodes":[
  {"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
    {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci/build","startedAt":"2026-01-01T00:00:00Z"},
    {"__typename":"StatusContext","context":"legacy/lint","state":"FAILURE","targetUrl":"https://ci/lint","createdAt":"2026-01-01T00:01:00Z"}
  ]}}}}
]}}}}}`

func TestGetChecks(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, checksGraphQL, nil), nil
	})
	ck, err := c.GetChecks(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if ck.Rollup != "FAILURE" {
		t.Errorf("rollup = %q, want FAILURE", ck.Rollup)
	}
	if len(ck.Checks) != 2 {
		t.Fatalf("want 2 checks, got %d", len(ck.Checks))
	}
	run := ck.Checks[0]
	if run.Name != "build" || run.Status != "COMPLETED" || run.Conclusion != "SUCCESS" || run.URL != "https://ci/build" {
		t.Errorf("check run flattened wrong: %+v", run)
	}
	// a legacy StatusContext exposes a single state as conclusion + derived status.
	status := ck.Checks[1]
	if status.Name != "legacy/lint" || status.Conclusion != "FAILURE" || status.Status != "COMPLETED" || status.URL != "https://ci/lint" {
		t.Errorf("status context flattened wrong: %+v", status)
	}
}

func TestGetChecksNoRollup(t *testing.T) {
	body := `{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, body, nil), nil
	})
	ck, err := c.GetChecks(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if ck.Rollup != "" || len(ck.Checks) != 0 {
		t.Fatalf("want empty rollup + no checks, got %+v", ck)
	}
}

func TestPendingStatusContextInProgress(t *testing.T) {
	body := `{"data":{"repository":{"pullRequest":{"commits":{"nodes":[
      {"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[
        {"__typename":"StatusContext","context":"deploy","state":"PENDING","targetUrl":"u","createdAt":"d"}
      ]}}}}
    ]}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, body, nil), nil
	})
	ck, err := c.GetChecks(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if ck.Checks[0].Status != "PENDING" {
		t.Errorf("a pending status context should stay in-progress: %+v", ck.Checks[0])
	}
}
