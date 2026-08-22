package github

import (
	"context"
	"strconv"

	"github.com/undont/differ.nvim/internal/protocol"
)

// ListPRs returns open PRs filtered by open/mine/review_requested. mine and
// review_requested filter the open list against the authenticated viewer, so
// head_ref is populated on every path (the search API would omit it).
func (c *Client) ListPRs(ctx context.Context, owner, repo, filter string) ([]PR, error) {
	if filter == "" {
		filter = "open"
	}
	if filter != "open" && filter != "mine" && filter != "review_requested" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "unknown filter: "+filter)
	}

	q := query(map[string]string{"state": "open", "per_page": "100", "sort": "updated", "direction": "desc"})
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/pulls?" + q
	pulls, err := getPaged[pullDTO](ctx, c, rawURL)
	if err != nil {
		return nil, err
	}

	var viewer string
	if filter != "open" {
		viewer, err = c.viewerLogin(ctx)
		if err != nil {
			return nil, err
		}
	}

	out := make([]PR, 0, len(pulls))
	for _, p := range pulls {
		switch filter {
		case "mine":
			if p.User.Login != viewer {
				continue
			}
		case "review_requested":
			if !hasReviewer(p.Reviewers, viewer) {
				continue
			}
		}
		out = append(out, PR{
			Number:    p.Number,
			Title:     p.Title,
			Author:    p.User.Login,
			HeadRef:   p.Head.Ref,
			UpdatedAt: p.UpdatedAt,
			Draft:     p.Draft,
		})
	}
	return out, nil
}

// GetPR returns full PR detail. metadata and per-file viewed state come from
// GraphQL; the authoritative file list (with rename previous_path) comes from
// REST. the two are merged by path, viewed state defaulting to UNVIEWED.
func (c *Client) GetPR(ctx context.Context, owner, repo string, number int) (*PRDetail, error) {
	viewed := map[string]string{}
	var meta prDetailGQL
	cursor := ""
	for range gqlMaxPages {
		var page prDetailGQL
		vars := map[string]any{"owner": owner, "repo": repo, "number": number}
		if cursor != "" {
			vars["cursor"] = cursor
		}
		if err := c.graphql(ctx, getPRQuery, vars, &page); err != nil {
			return nil, err
		}
		if cursor == "" {
			meta = page
		}
		files := page.Repository.PullRequest.Files
		for _, n := range files.Nodes {
			viewed[n.Path] = n.ViewerViewedState
		}
		next, more := nextCursor(cursor, files.PageInfo)
		if !more {
			break
		}
		cursor = next
	}

	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/pulls/" + strconv.Itoa(number) + "/files?per_page=100"
	restFiles, err := getPaged[fileDTO](ctx, c, rawURL)
	if err != nil {
		return nil, err
	}

	pr := meta.Repository.PullRequest
	detail := &PRDetail{
		Title:     pr.Title,
		Body:      pr.Body,
		Author:    pr.Author.Login,
		BaseSHA:   pr.BaseRefOid,
		HeadSHA:   pr.HeadRefOid,
		HeadRef:   pr.HeadRefName,
		URL:       pr.URL,
		State:     pr.State,
		Draft:     pr.IsDraft,
		Mergeable: pr.Mergeable,
		Files:     make([]PRFile, 0, len(restFiles)),
	}
	for _, f := range restFiles {
		vs := viewed[f.Filename]
		if vs == "" {
			vs = "UNVIEWED"
		}
		detail.Files = append(detail.Files, PRFile{
			Path:         f.Filename,
			Status:       f.Status,
			Additions:    f.Additions,
			Deletions:    f.Deletions,
			PreviousPath: f.PreviousFilename,
			ViewedState:  vs,
		})
	}
	return detail, nil
}

// viewerLogin returns the authenticated login, memoised per process.
func (c *Client) viewerLogin(ctx context.Context) (string, error) {
	c.mu.Lock()
	cached := c.viewer
	c.mu.Unlock()
	if cached != "" {
		return cached, nil
	}

	var u userDTO
	if err := c.getJSON(ctx, c.restURL+"/user", &u); err != nil {
		return "", err
	}
	if u.Login == "" {
		return "", protocol.NewError(protocol.CodeAuth, "could not resolve the authenticated user")
	}
	c.mu.Lock()
	c.viewer = u.Login
	c.mu.Unlock()
	return u.Login, nil
}

func hasReviewer(reviewers []loginDTO, login string) bool {
	for _, r := range reviewers {
		if r.Login == login {
			return true
		}
	}
	return false
}
