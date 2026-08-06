# Tests for the example consumer policy: SDLC-CTRL-0007 expressed as a
# kosli.evidence policy, plus its custom `peer_approved` op.
#
#   opa test src examples --ignore '*.json'
#
# Fixtures are built here rather than read from examples/*.json, because those
# two files both define data.trail and cannot be loaded together. They stay as
# `opa eval` fixtures for the README walkthrough; trail(compliant_pr) and
# split_prs below mirror them.
#
# Same todo_test_ convention as src/library_test.rego for a known-open issue:
# `opa test` skips it, closing it renames it to test_. Nothing is skipped now.
package policy_test

import rego.v1

# ---------- fixtures ----------

fingerprint := "3f1a9c2e8b7d6f4a5c0e1d2b3a4f5e6d7c8b9a0f1e2d3c4b5a6f7e8d9c0b1a2f"

# A merged PR that satisfies every check: signed commits, on main, approved by
# someone other than the author, after the last commit.
compliant_pr := {
	"url": "https://github.com/kosli-dev/app/pull/42",
	"state": "MERGED",
	"base_ref": "main",
	"author": "alice",
	"commits": [
		{"sha1": "aaaa111122223333", "verified": true, "timestamp": 1753600000},
		{"sha1": "bbbb444455556666", "verified": true, "timestamp": 1753603600},
	],
	"approvers": [{"username": "bob", "state": "APPROVED", "timestamp": 1753607200}],
}

pr(overrides) := object.union(compliant_pr, overrides)

# The trail_split.json scenario: one PR has an unsigned commit, the other is
# self-approved, so no single PR satisfies everything.
split_prs := [
	pr({"commits": [
		{"sha1": "aaaa111122223333", "verified": true, "timestamp": 1753600000},
		{"sha1": "bbbb444455556666", "verified": false, "signature_state": "UNSIGNED", "timestamp": 1753603600},
	]}),
	pr({
		"url": "https://github.com/kosli-dev/app/pull/43",
		"author": "carol",
		"commits": [{"sha1": "cccc777788889999", "verified": true, "timestamp": 1753610000}],
		"approvers": [{"username": "carol", "state": "APPROVED", "timestamp": 1753613600}],
	}),
	pr({
		"url": "https://github.com/kosli-dev/app/pull/44",
		"state": "CLOSED",
		"author": "dave",
		"commits": [],
		"approvers": [],
	}),
]

attestation(overrides) := object.union(
	{"status": "COMPLETE", "pull_requests": [compliant_pr]},
	overrides,
)

artifact(overrides) := object.union(
	{"artifact_fingerprint": fingerprint, "attestations_statuses": {"pull-request": attestation({})}},
	overrides,
)

doc_with(artifacts) := {"trail": {"compliance_status": {"artifacts_statuses": artifacts}}}

# The default-shaped trail carrying the given pull requests.
trail(prs) := doc_with({"artifact": artifact({"attestations_statuses": {"pull-request": attestation({"pull_requests": prs})}})})

out(doc) := result if {
	result := data.policy.output with input as doc
}

row(doc, check_name) := r if {
	some r in out(doc).report.results
	r.check == check_name
}

rows(doc, check_name) := [r |
	some r in out(doc).report.results
	r.check == check_name
]

requirement_verdict(doc, name) := out(doc).report.requirements[name].satisfied

# ---------- the two README scenarios ----------

test_compliant_trail_allows if {
	result := out(trail([compliant_pr]))
	result.allow == true
	count(result.violations) == 0
}

test_split_requirements_deny if {
	result := out(trail(split_prs))
	result.allow == false
	count(result.violations) == 2
}

test_split_requirements_name_both_failing_checks if {
	result := out(trail(split_prs))
	failed := {sprintf("%v/%v", [r.subject.id, r.check]) |
		some r in result.report.results
		r.passed == false
		not startswith(r.check, "$")
	}
	failed == {
		"https://github.com/kosli-dev/app/pull/42/commits_signed",
		"https://github.com/kosli-dev/app/pull/43/peer_approved",
	}
}

test_violation_message_format if {
	result := out(trail(split_prs))
	msg := sprintf("pull_request '%s': commits_signed — %s", [
		"https://github.com/kosli-dev/app/pull/42",
		"Every commit in the pull request is signed with a verified signature (fail-closed on missing 'verified')",
	])
	msg in result.violations
}

# The point of "require": "some" — a satisfied requirement's failing rows are
# evidence, not violations, because another PR met every check on its own.
test_failing_rows_in_a_satisfied_requirement_are_not_violations if {
	result := out(trail(array.concat([compliant_pr], [pr({
		"url": "https://github.com/kosli-dev/app/pull/99",
		"commits": [{"sha1": "dddd", "verified": false, "timestamp": 1753600000}],
	})])))
	result.allow == true
	count(result.violations) == 0
	count([r | some r in result.report.results; r.passed == false]) == 1
}

test_output_embeds_the_report if {
	result := out(trail([compliant_pr]))
	result.report.compliant == result.allow
}

# ---------- artifact requirement ----------

test_missing_artifact_denies if {
	result := out(doc_with({"some-other-artifact": artifact({})}))
	result.allow == false
	requirement_verdict(doc_with({"some-other-artifact": artifact({})}), "artifact") == false
}

test_empty_fingerprint_denies if {
	doc := doc_with({"artifact": artifact({"artifact_fingerprint": ""})})
	out(doc).allow == false
	row(doc, "fingerprint_recorded").passed == false
}

test_missing_fingerprint_denies if {
	doc := doc_with({"artifact": {"attestations_statuses": {"pull-request": attestation({})}}})
	out(doc).allow == false
	row(doc, "fingerprint_recorded").passed == false
}

test_incomplete_attestation_denies if {
	doc := doc_with({"artifact": artifact({"attestations_statuses": {"pull-request": attestation({"status": "INCOMPLETE"})}})})
	out(doc).allow == false
	row(doc, "pr_attestation_complete").passed == false
}

test_missing_attestation_denies if {
	doc := doc_with({"artifact": {"artifact_fingerprint": fingerprint, "attestations_statuses": {}}})
	out(doc).allow == false
	row(doc, "pr_attestation_complete").passed == false
}

test_empty_trail_denies if {
	out({}).allow == false
}

test_empty_trail_still_reports_a_min_subjects_row if {
	count(rows({}, "$min_subjects")) == 2
	every r in rows({}, "$min_subjects") {
		r.passed == false
	}
}

# ---------- merged_pr requirement ----------

test_unmerged_pr_is_not_a_subject if {
	doc := trail([pr({"state": "OPEN"})])
	out(doc).allow == false
	count(rows(doc, "protected_branch")) == 0
	out(doc).report.requirements.merged_pr.subjects == {"total": 1, "matching": 0}
}

# The CLOSED PR is out of scope: recorded as a subject that did not match the
# filter, evaluated against none of the checks, and not a violation.
test_closed_pr_is_recorded_but_not_evaluated if {
	doc := trail(split_prs)
	closed := "https://github.com/kosli-dev/app/pull/44"

	checks := {r.check |
		some r in out(doc).report.results
		r.subject.id == closed
	}
	checks == {"$applies"}

	some r in out(doc).report.results
	r.subject.id == closed
	r.passed == false
	r.inputs == [{"name": "state", "value": "CLOSED"}]

	every v in out(doc).violations {
		not contains(v, closed)
	}
}

test_wrong_base_ref_denies if {
	doc := trail([pr({"base_ref": "develop"})])
	out(doc).allow == false
	row(doc, "protected_branch").passed == false
}

test_missing_base_ref_denies if {
	doc := trail([pr({"base_ref": null})])
	out(doc).allow == false
	row(doc, "protected_branch").passed == false
}

test_unsigned_commit_denies if {
	doc := trail([pr({"commits": [{"sha1": "aaaa", "verified": false, "timestamp": 1753600000}]})])
	out(doc).allow == false
	row(doc, "commits_signed").passed == false
}

test_commit_without_verified_field_denies if {
	doc := trail([pr({"commits": [{"sha1": "aaaa", "timestamp": 1753600000}]})])
	out(doc).allow == false
	row(doc, "commits_signed").passed == false
}

test_commits_signed_echoes_every_verified_flag if {
	doc := trail([pr({"commits": [
		{"sha1": "aaaa", "verified": true, "timestamp": 1},
		{"sha1": "bbbb", "verified": false, "timestamp": 2},
	]})])
	row(doc, "commits_signed").inputs == [{"name": "commits[].verified", "value": [true, false]}]
}

# ---------- the peer_approved custom op ----------

test_peer_approval_after_the_last_commit_passes if {
	row(trail([compliant_pr]), "peer_approved").passed == true
}

test_self_approval_denies if {
	doc := trail([pr({"approvers": [{"username": "alice", "state": "APPROVED", "timestamp": 1753607200}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_approval_before_the_last_commit_denies if {
	doc := trail([pr({"approvers": [{"username": "bob", "state": "APPROVED", "timestamp": 1753600001}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_approval_at_the_same_instant_as_the_last_commit_denies if {
	doc := trail([pr({"approvers": [{"username": "bob", "state": "APPROVED", "timestamp": 1753603600}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_non_approving_review_denies if {
	doc := trail([pr({"approvers": [{"username": "bob", "state": "COMMENTED", "timestamp": 1753607200}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_no_approvers_denies if {
	doc := trail([pr({"approvers": []})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_approver_without_timestamp_denies if {
	doc := trail([pr({"approvers": [{"username": "bob", "state": "APPROVED"}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

# Rego's ">" is total across types, so a string timestamp would outrank every
# numeric commit timestamp if the op did not insist on numbers.
test_approver_with_a_string_timestamp_denies if {
	doc := trail([pr({"approvers": [{"username": "bob", "state": "APPROVED", "timestamp": "2026-01-01T00:00:00Z"}]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_commit_with_a_string_timestamp_denies if {
	doc := trail([pr({"commits": [
		{"sha1": "aaaa", "verified": true, "timestamp": 1753600000},
		{"sha1": "bbbb", "verified": true, "timestamp": "2026-01-01T00:00:00Z"},
	]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

# A second, valid approver rescues an invalid one — "some approver".
test_one_valid_approver_among_several_passes if {
	doc := trail([pr({"approvers": [
		{"username": "alice", "state": "APPROVED", "timestamp": 1753607200},
		{"username": "bob", "state": "APPROVED", "timestamp": 1753607200},
	]})])
	out(doc).allow == true
}

# The op's fail-closed claim: no commits => max() undefined => false.
test_pr_without_commits_denies if {
	doc := trail([pr({"commits": []})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

test_peer_approved_uses_its_declared_expression if {
	out(trail([compliant_pr])).report.requirements.merged_pr.checks.peer_approved.expression == "some approver: state == APPROVED and username != author and timestamp > max(commits[].timestamp)"
}

# ---------- data.params configurability ----------

test_artifact_name_param if {
	doc := doc_with({"my-service": artifact({})})
	result := data.policy.output with input as doc with data.params as {"artifact_name": "my-service"}
	result.allow == true
}

test_pr_attestation_name_param if {
	doc := doc_with({"artifact": {
		"artifact_fingerprint": fingerprint,
		"attestations_statuses": {"code-review": attestation({})},
	}})
	result := data.policy.output with input as doc with data.params as {"pr_attestation_name": "code-review"}
	result.allow == true
}

test_protected_branch_param if {
	doc := trail([pr({"base_ref": "release"})])
	result := data.policy.output with input as doc with data.params as {"protected_branch": "release"}
	result.allow == true
}

test_protected_branch_param_is_enforced_not_just_accepted if {
	doc := trail([compliant_pr])
	result := data.policy.output with input as doc with data.params as {"protected_branch": "release"}
	result.allow == false
}

test_non_string_param_falls_back_to_the_default if {
	doc := trail([compliant_pr])
	result := data.policy.output with input as doc with data.params as {"protected_branch": 42}
	result.allow == true
}

test_defaults_apply_without_params if {
	result := data.policy.output with input as trail([compliant_pr]) with data.params as {}
	result.allow == true
}

# ---------- regressions ----------

# Issue 2: max({c.timestamp | some c in pr.commits}) silently drops commits
# that have no timestamp, so the approval-ordering check compares against the
# wrong commit — approve, then push an unstamped commit, and this still passes.
test_commit_without_a_timestamp_denies if {
	doc := trail([pr({"commits": [
		{"sha1": "aaaa", "verified": true, "timestamp": 1753600000},
		{"sha1": "bbbb", "verified": true},
	]})])
	out(doc).allow == false
	row(doc, "peer_approved").passed == false
}

# Issue 8: the row echoes author and approvers but not commits[].timestamp,
# which the op also reads — so the verdict cannot be recomputed from the
# evidence the row carries.
test_peer_approved_echoes_the_commit_timestamps_it_reads if {
	names := {i.name | some i in row(trail([compliant_pr]), "peer_approved").inputs}
	"commits[].timestamp" in names
}
