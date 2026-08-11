package github

import (
	"context"
	"strconv"
)

// GetThreads returns the PR's review threads with their comments, paginating the
// thread list. inner comment lists are capped at threadCommentsPage and flagged when
// they hit it. per thread, ID is the root comment's numeric id (the reply anchor),
// ThreadID is the GraphQL node id resolve_thread targets, and IsPending marks an
// unsubmitted draft (root comment in PENDING state).
func (c *Client) GetThreads(ctx context.Context, owner, repo string, number int) ([]Thread, error) {
	key := threadKey(owner, repo, number)
	if t, ok := c.cache.thread(key); ok {
		return t, nil
	}
	// captured before the walk: an invalidation landing mid-pagination must win over the
	// snapshot this walk is assembling
	gen := c.cache.threadGeneration()
	out := []Thread{} // non-nil so an empty PR marshals to [] (null would decode to vim.NIL)
	cursor := ""
	for n := 0; n < gqlMaxPages; n++ {
		var page threadsGQL
		vars := map[string]any{"owner": owner, "repo": repo, "number": number}
		if cursor != "" {
			vars["cursor"] = cursor
		}
		if err := c.graphql(ctx, getThreadsQuery, vars, &page); err != nil {
			return nil, err
		}
		threads := page.Repository.PullRequest.ReviewThreads
		for _, n := range threads.Nodes {
			t := Thread{
				ThreadID:          n.ID,
				Path:              n.Path,
				Side:              n.DiffSide,
				Line:              deref(n.Line),
				StartSide:         n.StartSide,
				StartLine:         deref(n.StartLine),
				Outdated:          n.IsOutdated,
				OriginalLine:      deref(n.OriginalLine),
				Resolved:          n.IsResolved,
				Comments:          make([]ThreadComment, 0, len(n.Comments.Nodes)),
				CommentsTruncated: len(n.Comments.Nodes) >= threadCommentsPage,
			}
			if newest := n.NewestComment.Nodes; len(newest) > 0 {
				t.NewestComment = &NewestComment{NodeID: newest[0].ID, Body: newest[0].Body}
			}
			for _, cm := range n.Comments.Nodes {
				t.Comments = append(t.Comments, ThreadComment{
					ID:        parseID(cm.FullDatabaseID),
					NodeID:    cm.ID,
					Author:    cm.Author.Login,
					Body:      cm.Body,
					CreatedAt: cm.CreatedAt,
					DiffHunk:  cm.DiffHunk,
				})
			}
			if len(n.Comments.Nodes) > 0 {
				root := n.Comments.Nodes[0]
				t.ID = parseID(root.FullDatabaseID)
				t.IsPending = root.State == "PENDING"
			}
			out = append(out, t)
		}
		next, more := nextCursor(cursor, threads.PageInfo)
		if !more {
			break
		}
		cursor = next
	}
	c.cache.putThreads(key, out, gen)
	return out, nil
}

// GetPendingReview returns the viewer's unsubmitted draft review (drives review
// resume), or a nil ReviewID when none exists. pending reviews are private to
// their author, so reviews(states: [PENDING]) scopes to the viewer.
func (c *Client) GetPendingReview(ctx context.Context, owner, repo string, number int) (*PendingReview, error) {
	var page pendingReviewGQL
	vars := map[string]any{"owner": owner, "repo": repo, "number": number}
	if err := c.graphql(ctx, getPendingReviewQuery, vars, &page); err != nil {
		return nil, err
	}
	nodes := page.Repository.PullRequest.Reviews.Nodes
	if len(nodes) == 0 {
		return &PendingReview{}, nil
	}
	r := nodes[0]
	id := r.ID
	out := &PendingReview{ReviewID: &id}
	for _, cm := range r.Comments.Nodes {
		// PullRequestReviewComment carries no diff side, so Side/StartSide stay empty
		// here; a draft's side is only available through the thread it belongs to
		out.Comments = append(out.Comments, PendingComment{
			ID:        parseID(cm.FullDatabaseID),
			Path:      cm.Path,
			Line:      deref(cm.Line),
			StartLine: deref(cm.StartLine),
			Body:      cm.Body,
		})
	}
	return out, nil
}

// ResolveThread toggles a review thread's resolved state, returning the state
// GitHub reports after the mutation. threadID is the GraphQL node id from
// get_threads (Thread.ThreadID).
func (c *Client) ResolveThread(ctx context.Context, threadID string, resolved bool) (*ResolveThread, error) {
	mutation := unresolveThreadMutation
	if resolved {
		mutation = resolveThreadMutation
	}
	var out resolveThreadGQL
	if err := c.graphql(ctx, mutation, map[string]any{"threadId": threadID}, &out); err != nil {
		return nil, err
	}
	c.cache.invalidateThreads()
	return &ResolveThread{Resolved: out.Result.Thread.IsResolved}, nil
}

func deref(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

// parseID converts a GraphQL fullDatabaseId (a BigInt serialized as a string) to
// its numeric form; an empty or unparseable value yields 0.
func parseID(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
