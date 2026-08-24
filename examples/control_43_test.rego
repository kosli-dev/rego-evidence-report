# Parity tests for the control 43 port.
#
# Each test mirrors one case from four-eyes_test.rego in sdlc-workflows, keeping
# the original names so the two suites can be read side by side. The fixtures are
# rebuilt here rather than copied: that policy and its tests belong to
# sdlc-workflows, and the shapes are what matter.
#
# The final section is the point of the exercise. Three cases the original suite
# does not cover, where the original policy passes input it cannot verify and this
# port refuses it.
package control43_test

import rego.v1

# ---------- fixtures ----------

# One trail is one commit, and trail.name is the commit sha. `author_str` is git's
# "Name <email>", which is what the service-account patterns match against.
make_trail(sha, author_str, prs) := {
	"name": sha,
	"git_commit_info": {"author": author_str, "sha1": sha, "timestamp": 1000100},
	"compliance_status": {"attestations_statuses": {"pr-review": {
		"attestation_type": "pull_request",
		"pull_requests": prs,
	}}},
}

make_input(trails) := {"trails": trails}

# merge_sha equals trail.name when the trail's commit is the PR's merge commit.
make_pr(merge_sha, pr_author, commits, approvers) := {
	"url": "https://github.com/owner/repo/pull/42",
	"merge_commit": merge_sha,
	"author": pr_author,
	"commits": commits,
	"approvers": approvers,
	"state": "MERGED",
}

pr_commit(sha, username) := {"sha1": sha, "author_username": username, "timestamp": 1000000}

pr_commit_null_user(sha) := {"sha1": sha, "author_username": null, "timestamp": 1000000}

pr_commit_no_user(sha) := {"sha1": sha, "timestamp": 1000000}

# A GitHub web-flow or Copilot co-authored commit: no linked account, and a git
# author that the service-account patterns recognise.
pr_commit_web_flow(sha) := {"sha1": sha, "author": "GitHub <noreply@github.com>", "timestamp": 1000000}

approval(username, ts) := {"username": username, "timestamp": ts, "state": "APPROVED"}

out(doc) := result if {
	result := data.control43.output with input as doc
}

violations_for(trails) := out(make_input(trails)).violations

# ---------- missing attestation ----------

test_missing_attestation_fails if {
	v := violations_for([{
		"name": "abc1234",
		"git_commit_info": {"author": "alice <alice@example.com>", "sha1": "abc1234"},
		"compliance_status": {"attestations_statuses": {}},
	}])
	some msg in v
	contains(msg, "pull_request attestation is missing")
}

# ---------- service account exemption ----------

test_service_account_svc_prefix_passes if {
	count(violations_for([make_trail("abc1234", "svc_deployer <svc@example.com>", [])])) == 0
}

test_service_account_dependabot_passes if {
	author := "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>"
	count(violations_for([make_trail("abc1234", author, [])])) == 0
}

test_service_account_github_actions_passes if {
	author := "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
	count(violations_for([make_trail("abc1234", author, [])])) == 0
}

test_service_account_ci_signed_commit_bot_passes if {
	author := "ci-signed-commit-bot[bot] <247774526+ci-signed-commit-bot[bot]@users.noreply.github.com>"
	count(violations_for([make_trail("abc1234", author, [])])) == 0
}

test_regular_user_not_exempt if {
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [])])
	some msg in v
	contains(msg, "no associated PR")
}

# ---------- merge commit detection ----------

test_merge_commit_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha_alice", "alice")], [approval("bob", 1000001)])
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])) == 0
}

test_merge_commit_no_pr_fails if {
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [])])
	some msg in v
	contains(msg, "no associated PR")
}

# merge_commit != trail.name, so pr.author is counted among the authors needing
# independent approval.
test_non_merge_commit_pr_author_counted if {
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("bob", 1000001)])
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])) == 0
}

test_non_merge_commit_self_approval_fails if {
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("alice", 1000001)])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------- no associated PR ----------

test_no_pr_fails if {
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [])])
	some msg in v
	contains(msg, "no associated PR")
}

# Merge detection is by data, not by commit message, so a commit named like a
# merge is still a plain commit with no PR.
test_fake_merge_message_no_pr_fails if {
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [])])
	some msg in v
	contains(msg, "no associated PR")
}

# ---------- PR approval ----------

test_independent_approval_after_commit_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])) == 0
}

test_self_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("alice", 1000001)])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

test_approval_before_latest_commit_fails if {
	late := {"sha1": "sha_late", "author_username": "alice", "timestamp": 1000010}
	pr := make_pr(
		"abc1234", "alice",
		[pr_commit("sha_early", "alice"), late],
		[approval("bob", 1000005)],
	)
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

test_no_approvals_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------- multi-author PRs ----------

# The rule is per author, not per pull request: two authors reviewing each other
# each have an approver who is not themselves.
test_multi_author_cross_approval_passes if {
	pr := make_pr(
		"abc1234", "sami",
		[pr_commit("sha_sami", "sami"), pr_commit("sha_faye", "faye")],
		[approval("faye", 1000001), approval("sami", 1000002)],
	)
	count(violations_for([make_trail("abc1234", "sami <sami@example.com>", [pr])])) == 0
}

test_multi_author_only_one_committer_approves_fails if {
	pr := make_pr(
		"abc1234", "sami",
		[pr_commit("sha_sami", "sami"), pr_commit("sha_faye", "faye")],
		[approval("faye", 1000001)],
	)
	v := violations_for([make_trail("abc1234", "sami <sami@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------- unresolvable identity ----------

test_null_username_pr_commit_unverifiable if {
	pr := make_pr("abc1234", "alice", [pr_commit_null_user("sha1")], [approval("bob", 1000001)])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "identity unverifiable")
}

# An exempt commit is out of scope, so no check runs against it and no identity
# complaint is raised.
test_null_username_service_account_trail_exempt if {
	pr := make_pr("abc1234", "alice", [pr_commit_null_user("sha1")], [approval("bob", 1000001)])
	v := violations_for([make_trail("abc1234", "svc_deployer <svc@example.com>", [pr])])
	every msg in v {
		not contains(msg, "identity unverifiable")
	}
}

test_all_null_usernames_no_vacuous_pass if {
	pr := make_pr(
		"abc1234", "alice",
		[pr_commit_null_user("sha1"), pr_commit_null_user("sha2")],
		[approval("bob", 1000001)],
	)
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "identity unverifiable")
}

test_absent_username_pr_commit_unverifiable if {
	pr := make_pr("abc1234", "alice", [pr_commit_no_user("sha1")], [approval("bob", 1000001)])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "identity unverifiable")
}

test_web_flow_pr_commit_exempt if {
	pr := make_pr(
		"abc1234", "alice",
		[pr_commit("sha_alice", "alice"), pr_commit_web_flow("sha_copilot")],
		[approval("bob", 1000001)],
	)
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])) == 0
}

# All branch commits unresolvable: the PR author stands in as the code author.
test_merge_commit_web_flow_only_falls_back_to_pr_author_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit_web_flow("sha_webflow")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations_for([trail])) == 0
	out(make_input([trail])).allow
}

# ---------- several associated PRs ----------

# Resolved identities and an approval must hold for the SAME pull request, and one
# qualifying pull request is enough.
test_second_pr_approval_satisfies_check if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	pr_ok := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_ok])])) == 0
}

test_no_pr_with_approval_fails if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_none])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------- several commits, only failures reported ----------

test_only_failing_commits_reported if {
	passing := make_trail("aaa1111", "svc_bot <svc@example.com>", [])
	failing := make_trail("bbb2222", "alice <alice@example.com>", [])
	v := violations_for([passing, failing])
	count(v) == 1
	some msg in v
	contains(msg, "bbb2222")
}

test_direct_commit_and_pr_in_range_one_violation if {
	direct := make_trail("dc20001", "alice <alice@example.com>", [])
	pr := make_pr(
		"mr62001", "alice",
		[pr_commit("sha_c3", "alice"), pr_commit("sha_c4", "alice")],
		[approval("bob", 1000001)],
	)
	merged := make_trail("mr62001", "alice <alice@example.com>", [pr])
	v := violations_for([direct, merged])
	count(v) == 1
	some msg in v
	contains(msg, "dc20001")
}

test_two_prs_both_approved_passes if {
	pr_a := make_pr("mr63001", "sami", [pr_commit("sha_c2", "sami")], [approval("faye", 1000001)])
	pr_b := make_pr("mr64001", "faye", [pr_commit("sha_c3", "faye")], [approval("sami", 1000001)])
	trail_a := make_trail("mr63001", "sami <sami@example.com>", [pr_a])
	trail_b := make_trail("mr64001", "faye <faye@example.com>", [pr_b])
	count(violations_for([trail_a, trail_b])) == 0
}

test_two_prs_one_self_approved_fails if {
	pr_a := make_pr("mr65001", "sami", [pr_commit("sha_c2", "sami")], [approval("faye", 1000001)])
	pr_b := make_pr("mr66001", "faye", [pr_commit("sha_c3", "faye")], [approval("faye", 1000001)])
	trail_a := make_trail("mr65001", "sami <sami@example.com>", [pr_a])
	trail_b := make_trail("mr66001", "faye <faye@example.com>", [pr_b])
	v := violations_for([trail_a, trail_b])
	count(v) == 1
	some msg in v
	contains(msg, "mr66001")
}

# ---------- approval state ----------

test_dismissed_approval_fails if {
	dismissed := {"username": "bob", "timestamp": 1000001, "state": "DISMISSED"}
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [dismissed])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

test_changes_requested_approval_fails if {
	requested := {"username": "bob", "timestamp": 1000001, "state": "CHANGES_REQUESTED"}
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [requested])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

test_dismissed_plus_approved_passes if {
	dismissed := {"username": "bob", "timestamp": 1000001, "state": "DISMISSED"}
	pr := make_pr(
		"abc1234", "alice",
		[pr_commit("sha1", "alice")],
		[dismissed, approval("carol", 1000002)],
	)
	count(violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])) == 0
}

# ---------- approver identity ----------

test_null_username_approver_fails if {
	anon := {"username": null, "timestamp": 1000001, "state": "APPROVED"}
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [anon])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

test_absent_username_approver_fails if {
	anon := {"timestamp": 1000001, "state": "APPROVED"}
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [anon])
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------- input guard ----------

test_missing_trails_key_fails_closed if {
	v := out({}).violations
	some msg in v
	contains(msg, "input.trails is missing")
	not out({}).allow
}

test_wrong_trails_type_fails_closed if {
	doc := {"trails": "not-an-array"}
	v := out(doc).violations
	some msg in v
	contains(msg, "input.trails is missing")
	not out(doc).allow
}

# ---------------------------------------------------------------------------
# Beyond parity: three cases four-eyes.rego passes and this port refuses.
#
# Each was reproduced against that policy before being written here, so these are
# recorded differences in behaviour, not hypotheticals.
# ---------------------------------------------------------------------------

# An approval timestamped with a string clears any numeric cutoff, because Rego
# orders numbers below strings: "1000005" > 1000010 holds. The original counts
# this approval; here the comparison has to be between numbers.
test_stricter_string_approver_timestamp_is_rejected if {
	pr := make_pr(
		"abc1234", "alice",
		[{"sha1": "s1", "author_username": "alice", "timestamp": 1000010}],
		[{"username": "bob", "state": "APPROVED", "timestamp": "1000005"}],
	)
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# A commit with no timestamp is skipped by the original's max() comprehension, so
# it cannot raise the cutoff and an earlier approval still counts. A cutoff that
# cannot be computed is not a cutoff.
test_stricter_untimestamped_commit_is_rejected if {
	pr := make_pr(
		"abc1234", "alice",
		[
			{"sha1": "s1", "author_username": "alice", "timestamp": 1000000},
			{"sha1": "s2", "author_username": "alice"},
		],
		[approval("bob", 1000001)],
	)
	v := violations_for([make_trail("abc1234", "alice <alice@example.com>", [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# Two attestations of type pull_request make the original's pr_attest function
# return two values, which OPA rejects as eval_conflict_error — the whole
# evaluation dies. A selector requiring exactly one match fails closed instead,
# and says which commit and which check.
test_stricter_ambiguous_attestation_fails_closed if {
	pr := make_pr("abc1234", "alice", [pr_commit("s1", "alice")], [approval("bob", 1000001)])
	trail := {
		"name": "abc1234",
		"git_commit_info": {"author": "alice <alice@example.com>", "sha1": "abc1234"},
		"compliance_status": {"attestations_statuses": {
			"pr-a": {"attestation_type": "pull_request", "pull_requests": [pr]},
			"pr-b": {"attestation_type": "pull_request", "pull_requests": []},
		}},
	}
	v := violations_for([trail])
	count(v) == 1
	some msg in v
	contains(msg, "pull_request attestation is missing")
	not out(make_input([trail])).allow
}

# The evidence the original cannot produce: a row per commit per check, carrying
# the values it read, for passing commits as well as failing ones.
test_report_carries_a_row_per_commit_and_check if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	report := out(make_input([make_trail("abc1234", "alice <alice@example.com>", [pr])])).report
	report.compliant
	rows := {r.check |
		some r in report.results
		r.subject.id == "abc1234"
		r.passed == true
	}
	rows == {
		"commit_identified", "$applies",
		"pr_attestation_present", "pull_request_found",
		"identities_resolved", "independently_approved",
	}
}
