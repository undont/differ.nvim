package github

// github wire shapes we decode into. these track GitHub's API (REST field names,
// GraphQL enums, the {data,errors} envelope); the contract-facing shapes built
// from them are in results.go.

// pullDTO is a REST /pulls list item (also covers the fields list_prs filters on).
type pullDTO struct {
	Number int      `json:"number"`
	Title  string   `json:"title"`
	User   loginDTO `json:"user"`
	Head   struct {
		Ref string `json:"ref"`
	} `json:"head"`
	UpdatedAt string     `json:"updated_at"`
	Draft     bool       `json:"draft"`
	Reviewers []loginDTO `json:"requested_reviewers"`
}

type loginDTO struct {
	Login string `json:"login"`
}

// userDTO is the REST /user response (the authenticated viewer).
type userDTO struct {
	Login string `json:"login"`
}

// fileDTO is a REST /pulls/{n}/files item; the authoritative file list, carrying
// rename info (PreviousFilename) that the GraphQL files() connection omits.
type fileDTO struct {
	Filename         string `json:"filename"`
	Status           string `json:"status"`
	Additions        int    `json:"additions"`
	Deletions        int    `json:"deletions"`
	PreviousFilename string `json:"previous_filename"`
}

// prDetailGQL is the get_pr GraphQL response: PR metadata plus a page of files
// carrying viewerViewedState (REST has no equivalent field).
type prDetailGQL struct {
	Repository struct {
		PullRequest struct {
			Title       string   `json:"title"`
			Body        string   `json:"body"`
			URL         string   `json:"url"`
			State       string   `json:"state"`
			IsDraft     bool     `json:"isDraft"`
			Mergeable   string   `json:"mergeable"`
			BaseRefOid  string   `json:"baseRefOid"`
			HeadRefOid  string   `json:"headRefOid"`
			HeadRefName string   `json:"headRefName"`
			Author      loginDTO `json:"author"`
			Files       struct {
				Nodes []struct {
					Path              string `json:"path"`
					ViewerViewedState string `json:"viewerViewedState"`
				} `json:"nodes"`
				PageInfo pageInfoGQL `json:"pageInfo"`
			} `json:"files"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

type pageInfoGQL struct {
	HasNextPage bool   `json:"hasNextPage"`
	EndCursor   string `json:"endCursor"`
}

// prRefsDTO is the slice of REST /pulls/{n} get_file_versions resolves the base
// and head commit SHAs from (lighter than the get_pr GraphQL meta).
type prRefsDTO struct {
	Base struct {
		SHA string `json:"sha"`
	} `json:"base"`
	Head struct {
		SHA string `json:"sha"`
	} `json:"head"`
}

// threadsGQL is the get_threads GraphQL response: a page of review threads, each
// with its diff anchor and comments. line/startLine are null on outdated threads.
type threadsGQL struct {
	Repository struct {
		PullRequest struct {
			ReviewThreads struct {
				Nodes []struct {
					ID         string `json:"id"`
					IsResolved bool   `json:"isResolved"`
					IsOutdated bool   `json:"isOutdated"`
					Path       string `json:"path"`
					Line       *int   `json:"line"`
					StartLine  *int   `json:"startLine"`
					// where the thread anchored in the diff it was written against.
					// still present when line/startLine have gone null
					OriginalLine *int   `json:"originalLine"`
					DiffSide     string `json:"diffSide"`
					StartSide    string `json:"startDiffSide"`
					Comments     struct {
						Nodes []commentGQL `json:"nodes"`
					} `json:"comments"`
				} `json:"nodes"`
				PageInfo pageInfoGQL `json:"pageInfo"`
			} `json:"reviewThreads"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// commentGQL is one review-thread comment. fullDatabaseId is a BigInt serialized
// as a string (the numeric comment id, the reply anchor); state is PENDING on an
// unsubmitted draft.
type commentGQL struct {
	ID             string   `json:"id"` // graphql node id, the delete_comment target
	FullDatabaseID string   `json:"fullDatabaseId"`
	Author         loginDTO `json:"author"`
	Body           string   `json:"body"`
	CreatedAt      string   `json:"createdAt"`
	State          string   `json:"state"`
	DiffHunk       string   `json:"diffHunk"` // the diff context the comment anchors to
}

// pendingReviewGQL is the get_pending_review GraphQL response: the viewer's single
// pending review (if any) with its draft comments.
type pendingReviewGQL struct {
	Repository struct {
		PullRequest struct {
			Reviews struct {
				Nodes []struct {
					ID       string `json:"id"`
					Comments struct {
						Nodes []struct {
							FullDatabaseID string `json:"fullDatabaseId"`
							Path           string `json:"path"`
							Line           *int   `json:"line"`
							StartLine      *int   `json:"startLine"`
							Body           string `json:"body"`
						} `json:"nodes"`
					} `json:"comments"`
				} `json:"nodes"`
			} `json:"reviews"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// timelineGQL is the get_timeline response: PR conversation comments (paginated) and
// the review verdicts. reviews carry submittedAt (null on the viewer's PENDING draft).
type timelineGQL struct {
	Repository struct {
		PullRequest struct {
			Comments struct {
				Nodes []struct {
					Author    loginDTO `json:"author"`
					Body      string   `json:"body"`
					CreatedAt string   `json:"createdAt"`
				} `json:"nodes"`
				PageInfo pageInfoGQL `json:"pageInfo"`
			} `json:"comments"`
			Reviews struct {
				Nodes []struct {
					Author      loginDTO `json:"author"`
					State       string   `json:"state"`
					Body        string   `json:"body"`
					SubmittedAt string   `json:"submittedAt"`
				} `json:"nodes"`
			} `json:"reviews"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// checksGQL is the get_checks GraphQL response: the rollup on the PR's head commit.
// statusCheckRollup is null when no checks are configured.
type checksGQL struct {
	Repository struct {
		PullRequest struct {
			Commits struct {
				Nodes []struct {
					Commit struct {
						StatusCheckRollup *struct {
							State    string `json:"state"`
							Contexts struct {
								Nodes []checkContextGQL `json:"nodes"`
							} `json:"contexts"`
						} `json:"statusCheckRollup"`
					} `json:"commit"`
				} `json:"nodes"`
			} `json:"commits"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// checkContextGQL is one rollup context; Typename selects the CheckRun fields from
// the StatusContext fields (the two halves of the union).
type checkContextGQL struct {
	Typename string `json:"__typename"`
	// CheckRun
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"detailsUrl"`
	StartedAt  string `json:"startedAt"`
	// StatusContext
	Context   string `json:"context"`
	State     string `json:"state"`
	TargetURL string `json:"targetUrl"`
	CreatedAt string `json:"createdAt"`
}

// startReviewLookupGQL carries the PR node id and the viewer's existing pending
// review, the two facts start_review needs to stay idempotent.
type startReviewLookupGQL struct {
	Repository struct {
		PullRequest struct {
			ID      string `json:"id"`
			Reviews struct {
				Nodes []struct {
					ID string `json:"id"`
				} `json:"nodes"`
			} `json:"reviews"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// addReviewGQL is the addPullRequestReview response; ID is the new review node id.
type addReviewGQL struct {
	AddPullRequestReview struct {
		PullRequestReview struct {
			ID string `json:"id"`
		} `json:"pullRequestReview"`
	} `json:"addPullRequestReview"`
}

// submitReviewGQL is the submitPullRequestReview response; the submitted review's
// numeric id (BigInt as a string).
type submitReviewGQL struct {
	SubmitPullRequestReview struct {
		PullRequestReview struct {
			FullDatabaseID string `json:"fullDatabaseId"`
		} `json:"pullRequestReview"`
	} `json:"submitPullRequestReview"`
}

// publishCommentGQL is the addPullRequestReview (event: COMMENT) response: the new
// published comment's numeric id, for the post_comment result.
type publishCommentGQL struct {
	AddPullRequestReview struct {
		PullRequestReview struct {
			Comments struct {
				Nodes []struct {
					FullDatabaseID string `json:"fullDatabaseId"`
				} `json:"nodes"`
			} `json:"comments"`
		} `json:"pullRequestReview"`
	} `json:"addPullRequestReview"`
}

// prNodeIDGQL carries a PR's node id (the anchor for review state mutations).
type prNodeIDGQL struct {
	Repository struct {
		PullRequest struct {
			ID string `json:"id"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// addThreadGQL is the addPullRequestReviewThread response: the new thread's node id
// and its single comment's numeric id.
type addThreadGQL struct {
	AddPullRequestReviewThread struct {
		Thread struct {
			ID       string `json:"id"`
			Comments struct {
				Nodes []struct {
					FullDatabaseID string `json:"fullDatabaseId"`
				} `json:"nodes"`
			} `json:"comments"`
		} `json:"thread"`
	} `json:"addPullRequestReviewThread"`
}

// addReplyGQL is the addPullRequestReviewThreadReply response: the reply comment's
// numeric id.
type addReplyGQL struct {
	AddPullRequestReviewThreadReply struct {
		Comment struct {
			FullDatabaseID string `json:"fullDatabaseId"`
		} `json:"comment"`
	} `json:"addPullRequestReviewThreadReply"`
}

// resolveThreadGQL is the (un)resolveReviewThread response; the mutation field is
// aliased to result so resolve and unresolve share one shape.
type resolveThreadGQL struct {
	Result struct {
		Thread struct {
			IsResolved bool `json:"isResolved"`
		} `json:"thread"`
	} `json:"result"`
}

// mergeLookupGQL is the merge_pr pre-flight: node id, merged flag, mergeability, and
// the head ref node id for an optional branch delete.
type mergeLookupGQL struct {
	Repository struct {
		PullRequest struct {
			ID               string `json:"id"`
			Merged           bool   `json:"merged"`
			Mergeable        string `json:"mergeable"`
			MergeStateStatus string `json:"mergeStateStatus"`
			HeadRef          struct {
				ID string `json:"id"`
			} `json:"headRef"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// mergePRGQL is the mergePullRequest response: the merged flag and the merge commit
// sha.
type mergePRGQL struct {
	MergePullRequest struct {
		PullRequest struct {
			Merged      bool `json:"merged"`
			MergeCommit struct {
				Oid string `json:"oid"`
			} `json:"mergeCommit"`
		} `json:"pullRequest"`
	} `json:"mergePullRequest"`
}

// setPRStateGQL is the shared response shape for the lifecycle mutations (the field
// is aliased to result); state/isDraft normalise to the returned condition.
type setPRStateGQL struct {
	Result struct {
		PullRequest struct {
			State   string `json:"state"`
			IsDraft bool   `json:"isDraft"`
		} `json:"pullRequest"`
	} `json:"result"`
}
