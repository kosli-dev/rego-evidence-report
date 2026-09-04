# VENDORED COPY — DO NOT EDIT THE LOGIC.
#
# Origin: production `four-eyes.rego` from the customer's `sdlc-workflows` repo,
# via the round-2/3 capture that also lives in `fieldkit/scratch/c43/`.
#
# **No upstream revision is recorded** — the capture did not carry one. Until a
# revision or content hash is pinned here, this file proves parity against *a*
# version of the production policy rather than against a known one. Fill it in
# the next time that file crosses.
#
# The ONLY edit from upstream is the `package` line below; the body is
# byte-for-byte. Upstream is `package policy`, and so is
# `examples/code_review.rego` — two modules of that name in one loaded set do
# not shadow each other, they MERGE: `allow` becomes a conflicting complete rule
# and the two `violations` sets silently union, which breaks `code_review`'s own
# tests. (Verified: `eval_conflict_error` plus three unrelated failures.) See
# CONTRIBUTING.md. Hence the rename, and hence nothing else here may change.
#
# Refresh this file in the same PR that changes the production policy, and keep
# the diff to the package line.

package four_eyes_vendored

import rego.v1

# Four-eyes principle enforcement: every commit must have independent review.
# This policy evaluates per-commit attestation data from Kosli.
#
# Positive-assertion model: allow is true only when input.trails is a non-empty
# array AND every trail explicitly satisfies trail_compliant. Any failure to
# evaluate (malformed input, helper bug, missing field) leaves trails outside
# the compliant set and allow stays false. There is no defensive guard rule
# because the structure is fail-closed by construction.
default allow := false

allow if {
	is_array(input.trails)
	count(input.trails) > 0
	every trail in input.trails {
		trail_compliant(trail)
	}
}

# ---------------------------------------------------------------------------
# Compliance — a trail is compliant if any of these positive conditions hold
# ---------------------------------------------------------------------------

# Service-account commits are exempt from PR review.
trail_compliant(trail) if {
	is_service_account(trail)
}

# Human-authored commits are compliant when an associated PR has independent
# approval covering every author after the latest code commit.
trail_compliant(trail) if {
	not is_service_account(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	all_authors_resolved(pr)
	has_independent_approval(trail, pr)
}

# ---------------------------------------------------------------------------
# Attestation data
#
# Used with `kosli evaluate trails` (plural). Each trail in input.trails
# represents one commit. The PR attestation payload is found by type, not by
# name, so any attestation with attestation_type == "pull_request" qualifies.
#
# Attested via: kosli attest pullrequest github --name <name> --commit <sha>
# ---------------------------------------------------------------------------

# Extract PR attestation payload from a trail by type.
pr_attest(trail) := attest if {
	some attest in trail.compliance_status.attestations_statuses
	attest.attestation_type == "pull_request"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# GitHub usernames of all PR branch commit authors whose identity was resolved.
pr_commit_authors(pr) := {c.author_username |
	some c in pr.commits
	is_string(c.author_username)
	c.author_username != ""
}

# Approver usernames that can satisfy four-eyes constraints for a cutoff.
approved_approvers_after_cutoff(pr, cutoff) := {a.username |
	some a in pr.approvers
	a.state == "APPROVED"
	is_string(a.username)
	a.username != ""
	a.timestamp > cutoff
}

# Latest Unix timestamp among PR branch commits.
latest_commit_ts(pr) := max({c.timestamp | some c in pr.commits})

# Every commit on the PR has a resolvable author (or is a known service-account
# style commit like web-flow / Copilot co-auth that we tolerate).
all_authors_resolved(pr) if {
	every c in pr.commits {
		author_resolved_or_exempt(c)
	}
}

author_resolved_or_exempt(c) if {
	is_string(c.author_username)
	c.author_username != ""
}

author_resolved_or_exempt(c) if {
	is_web_flow_commit(c)
}

# A commit is the merge commit when the PR's merge_commit field matches the
# trail name (which is the commit SHA). Covers squash, regular, and rebase merges.
is_merge_commit(trail, pr) if {
	trail.name == pr.merge_commit
}

# Regular commit: PR branch authors + PR author all need independent approval after last code commit.
has_independent_approval(trail, pr) if {
	not is_merge_commit(trail, pr)
	cutoff := latest_commit_ts(pr)
	all_authors := pr_commit_authors(pr) | {pr.author}
	eligible_approvers := approved_approvers_after_cutoff(pr, cutoff)
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(pr.approvers) > 0
	every author in all_authors {
		some approver in eligible_approvers
		approver != author
	}
}

# Merge commit: only PR branch commit authors need independent approval.
# The merge button clicker did not write code and requires no separate review.
has_independent_approval(trail, pr) if {
	is_merge_commit(trail, pr)
	cutoff := latest_commit_ts(pr)
	all_authors := pr_commit_authors(pr)
	eligible_approvers := approved_approvers_after_cutoff(pr, cutoff)
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(pr.approvers) > 0
	every author in all_authors {
		some approver in eligible_approvers
		approver != author
	}
}

# Merge commit fallback: if branch commits are all web-flow/unresolved,
# treat PR author as the code author requiring independent approval.
has_independent_approval(trail, pr) if {
	is_merge_commit(trail, pr)
	cutoff := latest_commit_ts(pr)
	count(pr_commit_authors(pr)) == 0
	is_string(pr.author)
	pr.author != ""
	eligible_approvers := approved_approvers_after_cutoff(pr, cutoff)

	# At least one approver must exist to satisfy four-eyes.
	count(pr.approvers) > 0
	every author in {pr.author} {
		some approver in eligible_approvers
		approver != author
	}
}

# ---------------------------------------------------------------------------
# Service account exemption
#
# Matched against trail.git_commit_info.author, which is "Name <email>" format.
# Patterns work against the full string, e.g.:
#   "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
# ---------------------------------------------------------------------------

service_account_patterns := {
	"svc_.*",
	".*\\[bot\\]",
	"noreply@github.com",
}

# Commit author is a service account (CI, GitHub Actions, dependabot, etc).
is_service_account(trail) if {
	some pattern in service_account_patterns
	regex.match(pattern, trail.git_commit_info.author)
}

# PR commit author is unresolvable (web-flow edits, Copilot co-auth).
is_web_flow_commit(c) if {
	some pattern in service_account_patterns
	regex.match(pattern, object.get(c, "author", ""))
}

# ---------------------------------------------------------------------------
# Violations — human-readable diagnostic output
#
# These are derived for debugging and reporting only. allow does NOT depend
# on this set: a sprintf failure here cannot affect the compliance decision.
# A trail appears in violations if and only if it is not in trail_compliant.
# ---------------------------------------------------------------------------

violations contains "Policy error: input.trails is missing or not an array — cannot evaluate" if {
	not is_array(object.get(input, "trails", null))
}

violations contains "Policy error: input.trails is empty — nothing to evaluate" if {
	is_array(input.trails)
	count(input.trails) == 0
}

# Missing attestation: no PR review data collected for this commit.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	not pr_attest(trail)
	msg := sprintf("Trail %v: pull_request attestation is missing", [trail.name])
}

# Unverifiable identity: commit author has no resolvable GitHub account
# and is not a known service account or web-flow commit.
# Matches both null and empty string author_username (e.g. GitHub "ghost" users).
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	some c in pr.commits
	username := object.get(c, "author_username", null)
	not is_service_account(trail)
	not is_web_flow_commit(c)
	_is_unresolved_username(username)
	msg := sprintf(
		"PR %v: commit %v has no linked GitHub account — identity unverifiable",
		[pr.url, substring(c.sha1, 0, 7)],
	)
}

_is_unresolved_username(u) if { u == null }
_is_unresolved_username(u) if { u == "" }

# Missing PR: non-service-account commit has no associated merged PR.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	not is_service_account(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) == 0
	msg := sprintf("Commit %v: no associated PR found", [substring(trail.name, 0, 7)])
}

# Missing approval: commit has an associated PR but no PR satisfies the
# independent-approval requirement.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	not is_service_account(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) > 0
	not any_pr_fully_approved(trail, attest)
	msg := sprintf(
		"Commit %v: no independent approval after latest code commit",
		[substring(trail.name, 0, 7)],
	)
}

# True if any associated PR has both resolved authors and independent approval.
# Used only for violation messaging to distinguish "missing approval" from
# "unverifiable identity".
any_pr_fully_approved(trail, attest) if {
	some pr in attest.pull_requests
	all_authors_resolved(pr)
	has_independent_approval(trail, pr)
}