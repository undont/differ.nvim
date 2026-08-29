package handlers

import (
	"context"
	"encoding/json"

	"github.com/undont/differ.nvim/internal/github"
	"github.com/undont/differ.nvim/internal/protocol"
)

type postCommentParams struct {
	prParams
	Path      string `json:"path"`
	Side      string `json:"side"`
	Line      int    `json:"line"`
	Body      string `json:"body"`
	StartSide string `json:"start_side"`
	StartLine int    `json:"start_line"`
	InReplyTo string `json:"in_reply_to"`
	ReviewID  string `json:"review_id"`
	// the head sha the review was anchored against; gates the post on the TOCTOU guard
	ExpectedHead string `json:"expected_head"`
}

// postComment creates a review comment: a reply when in_reply_to is set, else a new
// thread (a draft with review_id, immediate without). anchor validation runs here so
// GitHub's opaque rejections never reach the user.
func (d Deps) postComment(ctx context.Context, params json.RawMessage) (any, error) {
	var p postCommentParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	if p.Body == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "body is required")
	}
	if p.InReplyTo == "" {
		if err := validateAnchor(p); err != nil {
			return nil, err
		}
	}
	if err := d.guardHead(ctx, p.Owner, p.Repo, p.Number, p.ExpectedHead); err != nil {
		return nil, err
	}
	return d.GH.PostComment(ctx, p.Owner, p.Repo, p.Number, github.PostCommentInput{
		Path:      p.Path,
		Side:      p.Side,
		Line:      p.Line,
		Body:      p.Body,
		StartSide: p.StartSide,
		StartLine: p.StartLine,
		InReplyTo: p.InReplyTo,
		ReviewID:  p.ReviewID,
	})
}

type deleteCommentParams struct {
	prParams
	CommentID string `json:"comment_id"` // the comment's graphql node id
}

// deleteComment removes a single review comment (draft or published) by node id.
func (d Deps) deleteComment(ctx context.Context, params json.RawMessage) (any, error) {
	var p deleteCommentParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	if p.CommentID == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "comment_id is required")
	}
	if err := d.GH.DeleteComment(ctx, p.CommentID); err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

// validateAnchor checks a new thread's diff anchor before any API call. only what
// GitHub guarantees is enforced: a known side, a positive end line, and a range that
// starts strictly before it ends. cross-side ranges (start LEFT → end RIGHT) are
// valid and not rejected; diff-membership is left to GitHub (its UNPROCESSABLE, and the
// null thread it returns on the draft path, both map to bad_request).
func validateAnchor(p postCommentParams) error {
	if p.Path == "" {
		return protocol.NewError(protocol.CodeBadRequest, "path is required")
	}
	if !validSide(p.Side) {
		return protocol.NewError(protocol.CodeBadRequest, "side must be LEFT or RIGHT")
	}
	if p.Line <= 0 {
		return protocol.NewError(protocol.CodeBadRequest, "line must be positive")
	}
	if p.StartLine != 0 || p.StartSide != "" {
		if p.StartLine <= 0 {
			return protocol.NewError(protocol.CodeBadRequest, "start_line must be positive on a range comment")
		}
		if p.StartLine >= p.Line {
			return protocol.NewError(protocol.CodeBadRequest, "start_line must be less than line")
		}
		if p.StartSide != "" && !validSide(p.StartSide) {
			return protocol.NewError(protocol.CodeBadRequest, "start_side must be LEFT or RIGHT")
		}
	}
	return nil
}

func validSide(side string) bool {
	return side == "LEFT" || side == "RIGHT"
}
