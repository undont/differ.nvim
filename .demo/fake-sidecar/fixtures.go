package main

import (
	"context"
	"strconv"
	"sync"
	"time"

	"github.com/undont/differ.nvim/internal/github"
)

// the canned PR the demo records against: acme/widgets#42, "feat: add dracula theme".
// the diff continues the palette/theme story the local-diff fixture tells, so the whole
// demo reads as one codebase. shas are fixed so the TOCTOU head guard always passes.
const (
	baseSHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9011223344"
	headSHA = "44332211109f8e7d6c5b4a3a29180716f6e5d4c3"
	prURL   = "https://github.com/acme/widgets/pull/42"
	author  = "monalisa" // the PR author
	viewer  = "you"      // the reviewer driving the demo
	other   = "octocat"  // the third user with a pre-existing comment
)

// the two changed files, base and head. theme.lua flips monokai -> dracula, widens
// context, and defaults the theme in setup() (a second, separate hunk to land a fresh
// review comment on); palette.lua gains the accent colour the theme references.
var fileVersions = map[string][2]string{
	"lua/theme.lua": {
		// base
		"local M = {}\n\nM.theme = \"monokai\"\nM.context = 10\n\nfunction M.setup()\n  return M.theme\nend\n\nreturn M\n",
		// head
		"local M = {}\n\nM.theme = \"dracula\"\nM.context = 20\nM.accent = \"#bd93f9\"\n\nfunction M.setup()\n  M.theme = M.theme or \"dracula\"\n  return M.theme\nend\n\nreturn M\n",
	},
	"lua/palette.lua": {
		// base
		"local M = {}\n\nM.colours = {\n  red = \"#ff5555\",\n  green = \"#50fa7b\",\n}\n\nreturn M\n",
		// head
		"local M = {}\n\nM.colours = {\n  red = \"#ff5555\",\n  green = \"#50fa7b\",\n  purple = \"#bd93f9\",\n}\n\nreturn M\n",
	},
}

// fixture is the in-memory github stand-in. it satisfies handlers.API and keeps the
// review state (threads, the pending review, viewed flags) live for the whole process,
// so a comment posted in the demo shows up in the next get_threads and a resolve sticks.
type fixture struct {
	mu       sync.Mutex
	threads  []github.Thread
	reviewID string            // the active pending-review node id; "" = none
	viewed   map[string]string // path -> VIEWED/UNVIEWED
	seq      int               // monotonic id source
	now      time.Time         // process-start clock: timestamps are stamped relative to it
}

func newFixture() *fixture {
	f := &fixture{viewed: map[string]string{}, now: time.Now()}
	// octocat's pre-existing, already-submitted inline comment on the accent line.
	f.threads = []github.Thread{{
		ID:        7001,
		ThreadID:  "PRRT_seed1",
		Path:      "lua/theme.lua",
		Side:      "RIGHT",
		Line:      5,
		Resolved:  false,
		IsPending: false,
		Comments: []github.ThreadComment{{
			ID:        8001,
			NodeID:    "PRRC_seed1",
			Author:    other,
			Body:      "could we pull this accent from the palette instead of hard-coding it here?",
			CreatedAt: f.ago(3 * time.Hour),
		}},
	}}
	return f
}

func (f *fixture) nextID() int {
	f.seq++
	return f.seq
}

// ago formats a timestamp d before process start, so the frontend's relative dates read
// as "N hours/days ago" however long after this was written the demo is recorded.
func (f *fixture) ago(d time.Duration) string {
	return f.now.Add(-d).UTC().Format(time.RFC3339)
}

func (f *fixture) ListPRs(_ context.Context, _, _, _ string) ([]github.PR, error) {
	return []github.PR{
		{Number: 42, Title: "feat: add dracula theme", Author: author, HeadRef: "feat/dracula-theme", UpdatedAt: f.ago(3 * time.Hour), Draft: false},
		{Number: 41, Title: "fix: palette fallback for missing keys", Author: other, HeadRef: "fix/palette-fallback", UpdatedAt: f.ago(26 * time.Hour), Draft: false},
	}, nil
}

func (f *fixture) GetPR(_ context.Context, _, _ string, _ int) (*github.PRDetail, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return &github.PRDetail{
		Title:     "feat: add dracula theme",
		Body:      "Switches the default theme to dracula and widens diff context.\n\n- new accent colour, pulled into the palette\n- context 10 -> 20",
		Author:    author,
		BaseSHA:   baseSHA,
		HeadSHA:   headSHA,
		HeadRef:   "feat/dracula-theme",
		URL:       prURL,
		State:     "OPEN",
		Draft:     false,
		Mergeable: "MERGEABLE",
		Files: []github.PRFile{
			{Path: "lua/theme.lua", Status: "modified", Additions: 4, Deletions: 2, ViewedState: f.viewedState("lua/theme.lua")},
			{Path: "lua/palette.lua", Status: "modified", Additions: 1, Deletions: 0, ViewedState: f.viewedState("lua/palette.lua")},
		},
	}, nil
}

// viewedState reads the live viewed flag; callers hold f.mu.
func (f *fixture) viewedState(path string) string {
	if s := f.viewed[path]; s != "" {
		return s
	}
	return "UNVIEWED"
}

func (f *fixture) GetFileVersions(_ context.Context, _, _ string, _ int, path, _, _ string) (*github.FileVersions, error) {
	v, ok := fileVersions[path]
	if !ok {
		return &github.FileVersions{Base: github.FileBlob{Missing: true}, Head: github.FileBlob{Missing: true}}, nil
	}
	return &github.FileVersions{
		Base: github.FileBlob{Content: v[0]},
		Head: github.FileBlob{Content: v[1]},
	}, nil
}

func (f *fixture) HeadSHA(_ context.Context, _, _ string, _ int) (string, error) {
	return headSHA, nil
}

func (f *fixture) GetThreads(_ context.Context, _, _ string, _ int) ([]github.Thread, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]github.Thread, len(f.threads))
	copy(out, f.threads)
	// nothing here is capped, so the last comment is the newest; the real client selects
	// it separately because its list isn't
	for i, t := range out {
		if n := len(t.Comments); n > 0 {
			last := t.Comments[n-1]
			out[i].NewestComment = &github.NewestComment{NodeID: last.NodeID, Body: last.Body}
		}
	}
	return out, nil
}

func (f *fixture) GetTimeline(_ context.Context, _, _ string, _ int) (*github.Timeline, error) {
	return &github.Timeline{
		Comments: []github.TimelineComment{
			{Author: other, Body: "thanks for tackling this, dracula's been on the wishlist for a while.", CreatedAt: f.ago(5 * time.Hour)},
		},
		Reviews: []github.ReviewSummary{
			{Author: other, State: "COMMENTED", Body: "looks close. one inline question on the accent.", CreatedAt: f.ago(3 * time.Hour)},
		},
	}, nil
}

func (f *fixture) GetPendingReview(_ context.Context, _, _ string, _ int) (*github.PendingReview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.reviewID == "" {
		return &github.PendingReview{}, nil
	}
	id := f.reviewID
	pending := &github.PendingReview{ReviewID: &id}
	for _, t := range f.threads {
		if t.IsPending && len(t.Comments) > 0 {
			pending.Comments = append(pending.Comments, github.PendingComment{
				ID: t.Comments[0].ID, Path: t.Path, Side: t.Side, Line: t.Line, Body: t.Comments[0].Body,
			})
		}
	}
	return pending, nil
}

func (f *fixture) GetChecks(_ context.Context, _, _ string, _ int) (*github.Checks, error) {
	return &github.Checks{
		Rollup: "SUCCESS",
		Checks: []github.Check{
			{Name: "lua / lint", Status: "COMPLETED", Conclusion: "SUCCESS", URL: prURL + "/checks", StartedAt: f.ago(3 * time.Hour)},
			{Name: "lua / test", Status: "COMPLETED", Conclusion: "SUCCESS", URL: prURL + "/checks", StartedAt: f.ago(3 * time.Hour)},
			{Name: "build", Status: "COMPLETED", Conclusion: "SUCCESS", URL: prURL + "/checks", StartedAt: f.ago(3 * time.Hour)},
		},
	}, nil
}

func (f *fixture) StartReview(_ context.Context, _, _ string, _ int) (*github.StartReview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.reviewID == "" {
		f.reviewID = "PRR_" + strconv.Itoa(f.nextID())
	}
	return &github.StartReview{ReviewID: f.reviewID}, nil
}

func (f *fixture) SubmitReview(_ context.Context, _, _, _ string) (*github.SubmitReview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	// publish any draft threads and clear the pending review
	for i := range f.threads {
		f.threads[i].IsPending = false
	}
	f.reviewID = ""
	return &github.SubmitReview{ID: int64(f.nextID())}, nil
}

func (f *fixture) DiscardReview(_ context.Context, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	kept := f.threads[:0]
	for _, t := range f.threads {
		if !t.IsPending {
			kept = append(kept, t)
		}
	}
	f.threads = kept
	f.reviewID = ""
	return nil
}

func (f *fixture) PostComment(_ context.Context, _, _ string, _ int, in github.PostCommentInput) (*github.PostComment, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	commentID := int64(8000 + f.nextID())
	nodeID := "PRRC_" + strconv.Itoa(int(commentID))
	comment := github.ThreadComment{ID: commentID, NodeID: nodeID, Author: viewer, Body: in.Body, CreatedAt: f.ago(0)}

	// a reply joins the named thread; otherwise a new thread opens (a draft when a
	// review is in progress, an immediate thread when it isn't)
	if in.InReplyTo != "" {
		for i := range f.threads {
			if f.threads[i].ThreadID == in.InReplyTo {
				f.threads[i].Comments = append(f.threads[i].Comments, comment)
				return &github.PostComment{ID: commentID, ThreadID: in.InReplyTo, ReviewID: f.reviewID}, nil
			}
		}
	}

	threadID := "PRRT_" + strconv.Itoa(f.nextID())
	f.threads = append(f.threads, github.Thread{
		ID:        commentID,
		ThreadID:  threadID,
		Path:      in.Path,
		Side:      in.Side,
		Line:      in.Line,
		StartSide: in.StartSide,
		StartLine: in.StartLine,
		Resolved:  false,
		IsPending: f.reviewID != "",
		Comments:  []github.ThreadComment{comment},
	})
	return &github.PostComment{ID: commentID, ThreadID: threadID, ReviewID: f.reviewID}, nil
}

func (f *fixture) DeleteComment(_ context.Context, commentID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for ti := range f.threads {
		cs := f.threads[ti].Comments
		for ci := range cs {
			if cs[ci].NodeID == commentID {
				if ci == 0 {
					// deleting the root comment drops the whole thread
					f.threads = append(f.threads[:ti], f.threads[ti+1:]...)
				} else {
					f.threads[ti].Comments = append(cs[:ci], cs[ci+1:]...)
				}
				return nil
			}
		}
	}
	return nil
}

func (f *fixture) ResolveThread(_ context.Context, threadID string, resolved bool) (*github.ResolveThread, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.threads {
		if f.threads[i].ThreadID == threadID {
			f.threads[i].Resolved = resolved
			break
		}
	}
	return &github.ResolveThread{Resolved: resolved}, nil
}

func (f *fixture) SetFileViewed(_ context.Context, _, _ string, _ int, path string, viewed bool) (*github.SetFileViewed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	state := "UNVIEWED"
	if viewed {
		state = "VIEWED"
	}
	f.viewed[path] = state
	return &github.SetFileViewed{ViewedState: state}, nil
}

func (f *fixture) MergePR(_ context.Context, _, _ string, _ int, _ string, _ bool, _, _ string) (*github.Merge, error) {
	return &github.Merge{Merged: true, SHA: headSHA}, nil
}

func (f *fixture) SetPRState(_ context.Context, _, _ string, _ int, state string) (*github.SetPRState, error) {
	return &github.SetPRState{State: state}, nil
}
