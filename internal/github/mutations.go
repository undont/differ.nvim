package github

// GraphQL mutation documents (and the lookups their methods need). kept apart from
// the read queries in queries.go.

// startReviewLookupQuery fetches the PR node id plus the viewer's existing pending
// review (if any) in one round trip, so start_review can be idempotent.
const startReviewLookupQuery = `
query StartReviewLookup($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      reviews(first: 1, states: [PENDING]) {
        nodes { id }
      }
    }
  }
}`

// addReviewMutation creates a pending review (no event) on the PR.
const addReviewMutation = `
mutation AddReview($prId: ID!) {
  addPullRequestReview(input: {pullRequestId: $prId}) {
    pullRequestReview { id }
  }
}`

// publishCommentMutation posts a single published comment by creating its own review
// and submitting it (event: COMMENT) in one mutation. unlike addPullRequestReviewThread
// (which drafts into a pending review and would attach to the viewer's existing draft),
// this never touches any pending review. the thread shape anchors exactly like the draft
// path, so deleted-file / cross-side anchors behave the same.
const publishCommentMutation = `
mutation PublishComment($prId: ID!, $threads: [DraftPullRequestReviewThread!]) {
  addPullRequestReview(input: {pullRequestId: $prId, event: COMMENT, threads: $threads}) {
    pullRequestReview {
      comments(first: 1) { nodes { fullDatabaseId } }
    }
  }
}`

// submitReviewMutation finalizes a pending review with an event (APPROVE /
// REQUEST_CHANGES / COMMENT) and optional body.
const submitReviewMutation = `
mutation SubmitReview($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $reviewId, event: $event, body: $body}) {
    pullRequestReview { fullDatabaseId }
  }
}`

// deleteReviewMutation discards a pending review and its unsubmitted comments.
const deleteReviewMutation = `
mutation DeleteReview($reviewId: ID!) {
  deletePullRequestReview(input: {pullRequestReviewId: $reviewId}) {
    pullRequestReview { id }
  }
}`

// prNodeIDQuery resolves a PR's GraphQL node id (the anchor for review state changes).
const prNodeIDQuery = `
query PRNodeID($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) { id }
  }
}`

// addThreadMutation opens a new thread inside a pending review ($reviewId, a draft).
// immediate (published) comments go through publishCommentMutation directly.
// line/side anchor the end of the range, startLine/startSide the start of a multi-line
// range (null for single-line; cross-side ranges are valid).
const addThreadMutation = `
mutation AddThread($reviewId: ID!, $path: String!, $body: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $reviewId, path: $path, body: $body, line: $line, side: $side, startLine: $startLine, startSide: $startSide}) {
    thread {
      id
      comments(first: 1) { nodes { fullDatabaseId } }
    }
  }
}`

// deleteCommentMutation removes a single review comment (draft or published) by its
// node id. deleting a thread's root comment cascades to the thread; deleting a reply
// drops just the reply.
const deleteCommentMutation = `
mutation DeleteComment($id: ID!) {
  deletePullRequestReviewComment(input: {id: $id}) {
    pullRequestReview { id }
  }
}`

// addThreadReplyMutation replies into an existing thread; $reviewId joins the reply
// to that pending draft, omitting it posts the reply immediately.
const addThreadReplyMutation = `
mutation AddThreadReply($threadId: ID!, $reviewId: ID, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, pullRequestReviewId: $reviewId, body: $body}) {
    comment { fullDatabaseId }
  }
}`

// resolveThreadMutation / unresolveThreadMutation toggle a thread's resolved state.
// the mutation field is aliased to result so both decode into one shape.
const resolveThreadMutation = `
mutation Resolve($threadId: ID!) {
  result: resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}`

const unresolveThreadMutation = `
mutation Unresolve($threadId: ID!) {
  result: unresolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}`

// markFileViewedMutation / unmarkFileViewedMutation toggle a file's per-viewer
// viewed flag. the resulting state is deterministic (VIEWED / UNVIEWED), so the
// payload is not read back.
const markFileViewedMutation = `
mutation MarkViewed($prId: ID!, $path: String!) {
  markFileAsViewed(input: {pullRequestId: $prId, path: $path}) { clientMutationId }
}`

const unmarkFileViewedMutation = `
mutation UnmarkViewed($prId: ID!, $path: String!) {
  unmarkFileAsViewed(input: {pullRequestId: $prId, path: $path}) { clientMutationId }
}`

// mergeLookupQuery fetches the facts merge_pr pre-checks before firing a merge: the
// PR node id, whether it is already merged, its mergeability, and the head ref id
// (for an optional branch delete).
const mergeLookupQuery = `
query MergeLookup($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      merged
      mergeable
      mergeStateStatus
      headRef { id }
    }
  }
}`

// mergePRMutation merges the PR with the chosen method and optional commit message.
const mergePRMutation = `
mutation Merge($prId: ID!, $method: PullRequestMergeMethod!, $headline: String, $body: String) {
  mergePullRequest(input: {pullRequestId: $prId, mergeMethod: $method, commitHeadline: $headline, commitBody: $body}) {
    pullRequest {
      merged
      mergeCommit { oid }
    }
  }
}`

// deleteRefMutation deletes a git ref (the head branch after a merge, best-effort).
const deleteRefMutation = `
mutation DeleteRef($refId: ID!) {
  deleteRef(input: {refId: $refId}) { clientMutationId }
}`

// the set_pr_state lifecycle mutations. each is keyed by the PR node id and aliases
// its mutation field to result so they share one response shape; the resulting
// state/isDraft is read back and normalised.
const (
	readyForReviewMutation = `
mutation Ready($prId: ID!) {
  result: markPullRequestReadyForReview(input: {pullRequestId: $prId}) { pullRequest { state isDraft } }
}`
	convertToDraftMutation = `
mutation Draft($prId: ID!) {
  result: convertPullRequestToDraft(input: {pullRequestId: $prId}) { pullRequest { state isDraft } }
}`
	closePRMutation = `
mutation Close($prId: ID!) {
  result: closePullRequest(input: {pullRequestId: $prId}) { pullRequest { state isDraft } }
}`
	reopenPRMutation = `
mutation Reopen($prId: ID!) {
  result: reopenPullRequest(input: {pullRequestId: $prId}) { pullRequest { state isDraft } }
}`
)
