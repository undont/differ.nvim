// Package handlers implements the protocol methods. each handler decodes its own
// params and returns (result, error); a *protocol.Error carries a closed-set
// code, anything else becomes internal in dispatch.
package handlers

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/undont/differ.nvim/internal/github"
	"github.com/undont/differ.nvim/internal/protocol"
)

// Handler runs one method: decode params, do the work, return a result struct
// (marshalled into Response.Result) or an error.
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

// Registry maps method names to handlers.
type Registry map[string]Handler

// API is the github surface the handlers depend on, declared here (consumer-side)
// so handler logic is mockable independently of the transport. *github.Client
// satisfies it. grown per slice as methods land.
type API interface {
	ListPRs(ctx context.Context, owner, repo, filter string) ([]github.PR, error)
	GetPR(ctx context.Context, owner, repo string, number int) (*github.PRDetail, error)
	GetFileVersions(ctx context.Context, owner, repo string, number int, path, basePath, base, head string) (*github.FileVersions, error)
	HeadSHA(ctx context.Context, owner, repo string, number int) (string, error)
	GetThreads(ctx context.Context, owner, repo string, number int) ([]github.Thread, error)
	GetTimeline(ctx context.Context, owner, repo string, number int) (*github.Timeline, error)
	GetPendingReview(ctx context.Context, owner, repo string, number int) (*github.PendingReview, error)
	GetChecks(ctx context.Context, owner, repo string, number int) (*github.Checks, error)
	StartReview(ctx context.Context, owner, repo string, number int) (*github.StartReview, error)
	SubmitReview(ctx context.Context, reviewID, event, body string) (*github.SubmitReview, error)
	DiscardReview(ctx context.Context, reviewID string) error
	PostComment(ctx context.Context, owner, repo string, number int, in github.PostCommentInput) (*github.PostComment, error)
	DeleteComment(ctx context.Context, commentID string) error
	ResolveThread(ctx context.Context, threadID string, resolved bool) (*github.ResolveThread, error)
	SetFileViewed(ctx context.Context, owner, repo string, number int, path string, viewed bool) (*github.SetFileViewed, error)
	MergePR(ctx context.Context, owner, repo string, number int, method string, deleteBranch bool, subject, body string) (*github.Merge, error)
	SetPRState(ctx context.Context, owner, repo string, number int, state string) (*github.SetPRState, error)
	TokenStatus() (status, message string)
}

// Deps are the handler dependencies, injected once at construction (no globals).
type Deps struct {
	GH  API
	Log *slog.Logger
}

// NewRegistry wires every method to its handler.
func NewRegistry(d Deps) Registry {
	return Registry{
		"hello":              d.hello,
		"list_prs":           d.listPRs,
		"get_pr":             d.getPR,
		"get_file_versions":  d.getFileVersions,
		"get_threads":        d.getThreads,
		"get_timeline":       d.getTimeline,
		"get_pending_review": d.getPendingReview,
		"get_checks":         d.getChecks,
		"start_review":       d.startReview,
		"submit_review":      d.submitReview,
		"discard_review":     d.discardReview,
		"post_comment":       d.postComment,
		"delete_comment":     d.deleteComment,
		"resolve_thread":     d.resolveThread,
		"set_file_viewed":    d.setFileViewed,
		"merge_pr":           d.mergePR,
		"set_pr_state":       d.setPRState,
		"cache_clear":        d.cacheClear,
	}
}

// guardHead enforces the TOCTOU guard: when the client pins expected (the head sha
// it anchored the review against), resolve the PR's current head and reject with conflict
// if it moved, so a comment never lands against a commit the user wasn't looking at. an
// empty expected skips the check (the client didn't pin one); the latency note keeps
// this round-trip off the read hot path, so it costs one REST call per anchored mutation
func (d Deps) guardHead(ctx context.Context, owner, repo string, number int, expected string) error {
	if expected == "" {
		return nil
	}
	head, err := d.GH.HeadSHA(ctx, owner, repo, number)
	if err != nil {
		return err
	}
	if head != expected {
		return protocol.NewError(protocol.CodeConflict, "the PR head moved since the review was anchored; refresh and retry")
	}
	return nil
}

// decode unmarshals params into v, mapping malformed input to bad_request.
func decode(params json.RawMessage, v any) error {
	if len(params) == 0 {
		return nil
	}
	if err := json.Unmarshal(params, v); err != nil {
		return protocol.NewError(protocol.CodeBadRequest, "invalid params: "+err.Error())
	}
	return nil
}
