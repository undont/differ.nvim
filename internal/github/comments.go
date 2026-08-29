package github

import (
	"context"

	"github.com/undont/differ.nvim/internal/protocol"
)

// PostComment creates a review comment. InReplyTo (a thread node id) replies into an
// existing thread; with ReviewID set a new thread joins the pending draft; otherwise
// the comment publishes immediately. anchor shape (side, line ordering) is validated
// by the handler before this runs.
func (c *Client) PostComment(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	var (
		res *PostComment
		err error
	)
	switch {
	case in.InReplyTo != "":
		res, err = c.replyToThread(ctx, in)
	case in.ReviewID != "":
		res, err = c.draftThread(ctx, in)
	default:
		res, err = c.postNewThread(ctx, owner, repo, number, in)
	}
	return res, err
}

func (c *Client) replyToThread(ctx context.Context, in PostCommentInput) (*PostComment, error) {
	vars := map[string]any{"threadId": in.InReplyTo, "body": in.Body}
	if in.ReviewID != "" {
		vars["reviewId"] = in.ReviewID
	}
	var out addReplyGQL
	if err := c.graphql(ctx, addThreadReplyMutation, vars, &out); err != nil {
		return nil, err
	}
	return &PostComment{
		ID:       parseID(out.AddPullRequestReviewThreadReply.Comment.FullDatabaseID),
		ThreadID: in.InReplyTo,
	}, nil
}

// draftThread opens a new thread inside the viewer's pending review (a draft). it
// stays unpublished until submit_review, so the caller must hold a ReviewID.
func (c *Client) draftThread(ctx context.Context, in PostCommentInput) (*PostComment, error) {
	vars := map[string]any{
		"path":     in.Path,
		"body":     in.Body,
		"line":     in.Line,
		"side":     in.Side,
		"reviewId": in.ReviewID,
	}
	if in.StartLine != 0 {
		side := in.StartSide
		if side == "" {
			side = in.Side
		}
		vars["startLine"] = in.StartLine
		vars["startSide"] = side
	}

	var out addThreadGQL
	if err := c.graphql(ctx, addThreadMutation, vars, &out); err != nil {
		return nil, err
	}
	// an anchor outside the diff is not an error here: GitHub answers 200 with no
	// errors array and a null thread, so the draft silently never exists. the publish
	// path rejects the same anchor with UNPROCESSABLE, so report it the same way
	thread := out.AddPullRequestReviewThread.Thread
	if thread.ID == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest,
			"line could not be resolved: the comment must anchor to a line in the diff")
	}
	pc := &PostComment{ThreadID: thread.ID}
	if len(thread.Comments.Nodes) > 0 {
		pc.ID = parseID(thread.Comments.Nodes[0].FullDatabaseID)
	}
	return pc, nil
}

// postNewThread opens a new top-level thread without an explicit review. GitHub allows
// one pending review per PR, so the route depends on whether one already exists: if it
// does, the comment must join it as a draft, otherwise the comment publishes immediately
// as its own COMMENT review. the thread shape matches the draft path, so deleted-file /
// cross-side anchors all behave the same.
func (c *Client) postNewThread(ctx context.Context, owner, repo string, number int, in PostCommentInput) (*PostComment, error) {
	prID, pendingID, err := c.prAndPendingReview(ctx, owner, repo, number)
	if err != nil {
		return nil, err
	}
	if pendingID != "" {
		in.ReviewID = pendingID
		pc, derr := c.draftThread(ctx, in)
		if derr != nil {
			return nil, derr
		}
		pc.ReviewID = pendingID // signal the frontend the comment landed in a draft
		return pc, nil
	}

	thread := map[string]any{"path": in.Path, "line": in.Line, "side": in.Side, "body": in.Body}
	if in.StartLine != 0 {
		side := in.StartSide
		if side == "" {
			side = in.Side
		}
		thread["startLine"] = in.StartLine
		thread["startSide"] = side
	}
	var out publishCommentGQL
	if err := c.graphql(ctx, publishCommentMutation, map[string]any{"prId": prID, "threads": []any{thread}}, &out); err != nil {
		return nil, err
	}
	pc := &PostComment{}
	if nodes := out.AddPullRequestReview.PullRequestReview.Comments.Nodes; len(nodes) > 0 {
		pc.ID = parseID(nodes[0].FullDatabaseID)
	}
	return pc, nil
}

// DeleteComment removes a single review comment by its node id (draft or published).
func (c *Client) DeleteComment(ctx context.Context, commentID string) error {
	if err := c.graphql(ctx, deleteCommentMutation, map[string]any{"id": commentID}, nil); err != nil {
		return err
	}
	return nil
}

// prNodeID resolves a PR's GraphQL node id (the anchor for review state mutations).
func (c *Client) prNodeID(ctx context.Context, owner, repo string, number int) (string, error) {
	var out prNodeIDGQL
	vars := map[string]any{"owner": owner, "repo": repo, "number": number}
	if err := c.graphql(ctx, prNodeIDQuery, vars, &out); err != nil {
		return "", err
	}
	if id := out.Repository.PullRequest.ID; id != "" {
		return id, nil
	}
	return "", protocol.NewError(protocol.CodeNotFound, "pull request not found")
}
