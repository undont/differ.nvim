package github

import "context"

// GetTimeline returns the PR's conversation comments (paginated) and its submitted
// review verdicts. the viewer's PENDING draft is dropped (submittedAt empty) — it's a
// work-in-progress, not a timeline entry. reviews with no body and no verdict state
// are dropped too (a bare COMMENTED review that only carried inline thread comments is
// noise here; those comments render in the diff overlay).
func (c *Client) GetTimeline(ctx context.Context, owner, repo string, number int) (*Timeline, error) {
	out := &Timeline{Comments: []TimelineComment{}, Reviews: []ReviewSummary{}}
	cursor := ""
	for n := 0; n < gqlMaxPages; n++ {
		var page timelineGQL
		vars := map[string]any{"owner": owner, "repo": repo, "number": number}
		if cursor != "" {
			vars["cursor"] = cursor
		}
		if err := c.graphql(ctx, getTimelineQuery, vars, &page); err != nil {
			return nil, err
		}
		pr := page.Repository.PullRequest
		for _, n := range pr.Comments.Nodes {
			out.Comments = append(out.Comments, TimelineComment{
				Author: n.Author.Login, Body: n.Body, CreatedAt: n.CreatedAt,
			})
		}
		// reviews come back whole on the first page; collect once (cursor=="")
		if cursor == "" {
			for _, n := range pr.Reviews.Nodes {
				if n.SubmittedAt == "" { // PENDING draft — not a timeline entry
					continue
				}
				if n.Body == "" && (n.State == "" || n.State == "COMMENTED") {
					continue // bare COMMENTED review with no summary — its inline comments live in the diff
				}
				out.Reviews = append(out.Reviews, ReviewSummary{
					Author: n.Author.Login, State: n.State, Body: n.Body, CreatedAt: n.SubmittedAt,
				})
			}
		}
		next, more := nextCursor(cursor, pr.Comments.PageInfo)
		if !more {
			break
		}
		cursor = next
	}
	return out, nil
}
