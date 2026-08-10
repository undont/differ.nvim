package github

// getPRQuery fetches PR metadata plus a page of files carrying viewerViewedState.
// the file list itself (with rename info) comes from REST; this supplies the
// per-file viewed state and the metadata REST splits across endpoints.
const getPRQuery = `
query GetPR($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      title
      body
      url
      state
      isDraft
      mergeable
      baseRefOid
      headRefOid
      headRefName
      author { login }
      files(first: 100, after: $cursor) {
        nodes {
          path
          viewerViewedState
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}`

// getThreadsQuery fetches the PR's review threads (paginated) with their comments.
// diffSide/startDiffSide carry the LEFT/RIGHT anchor; the comment state
// distinguishes a submitted thread from an unsubmitted draft (is_pending); diffHunk
// is the diff context each comment anchors to (the root's feeds the overview). inner
// comments are capped at 100 (threads rarely exceed that).
const getThreadsQuery = `
query GetThreads($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          originalLine
          diffSide
          startDiffSide
          comments(first: 100) {
            nodes {
              id
              fullDatabaseId
              author { login }
              body
              createdAt
              state
              diffHunk
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}`

// getPendingReviewQuery fetches the viewer's unsubmitted draft review. pending
// reviews are private to their author, so reviews(states: [PENDING]) scopes to the
// viewer; a user has at most one pending review per PR.
const getPendingReviewQuery = `
query GetPendingReview($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviews(first: 1, states: [PENDING]) {
        nodes {
          id
          comments(first: 100) {
            nodes {
              fullDatabaseId
              path
              line
              startLine
              body
            }
          }
        }
      }
    }
  }
}`

// getTimelineQuery fetches the PR's conversation comments and submitted reviews —
// the two timeline ingredients get_pr/get_threads don't carry. reviews include the
// viewer's PENDING draft, filtered out in GetTimeline (it isn't a timeline entry).
const getTimelineQuery = `
query GetTimeline($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      comments(first: 100, after: $cursor) {
        nodes {
          author { login }
          body
          createdAt
        }
        pageInfo { hasNextPage endCursor }
      }
      reviews(first: 100) {
        nodes {
          author { login }
          state
          body
          submittedAt
        }
      }
    }
  }
}`

// getChecksQuery fetches the status-check rollup for the PR's head commit. contexts
// is a union of CheckRun (modern checks) and StatusContext (legacy commit statuses);
// both are normalised to a common shape in checks.go.
const getChecksQuery = `
query GetChecks($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  __typename
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    detailsUrl
                    startedAt
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                    createdAt
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}`
