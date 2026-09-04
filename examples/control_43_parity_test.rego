# Differential parity: production four-eyes.rego (package policy, vendored) and
# the declarative port must reach the same verdict on a shared corpus, except on
# an explicit, justified divergence list. Verdicts only — cause-level differences
# are the port's job and belong in control_43_test.rego.
package control43_parity_test

import rego.v1

make_trail(sha, author, prs) := {
	"name": sha,
	"git_commit_info": {"author": author, "sha1": sha, "timestamp": 1000100},
	"compliance_status": {"attestations_statuses": {"pr-review": {
		"attestation_type": "pull_request", "pull_requests": prs,
	}}},
}

make_pr(merge, author, commits, approvers) := {
	"url": "https://github.com/o/r/pull/1", "merge_commit": merge,
	"author": author, "commits": commits, "approvers": approvers, "state": "MERGED",
}

commit(sha, user) := {"sha1": sha, "author_username": user, "timestamp": 1000000}

appr(user, ts) := {"username": user, "timestamp": ts, "state": "APPROVED"}

corpus := {
	"service_account": [make_trail("s1", "svc_bot <svc@x>", [])],
	"missing_attestation": [{"name": "h1", "git_commit_info": {"author": "alice <a@x>", "sha1": "h1", "timestamp": 1}, "compliance_status": {"attestations_statuses": {}}}],
	"merge_independent_ok": [make_trail("m1", "alice <a@x>", [make_pr("m1", "alice", [commit("c1", "alice")], [appr("bob", 2000000)])])],
	"self_approval_only": [make_trail("m2", "alice <a@x>", [make_pr("m2", "alice", [commit("c1", "alice")], [appr("alice", 2000000)])])],
	"no_approver": [make_trail("m3", "alice <a@x>", [make_pr("m3", "alice", [commit("c1", "alice")], [])])],
	"two_author_mutual": [make_trail("m4", "alice <a@x>", [make_pr("m4", "alice", [commit("c1", "alice"), commit("c2", "bob")], [appr("alice", 2000000), appr("bob", 2000000)])])],
	"two_author_partial": [make_trail("m5", "alice <a@x>", [make_pr("m5", "alice", [commit("c1", "alice"), commit("c2", "bob")], [appr("bob", 2000000)])])],
	"empty_commits": [make_trail("m6", "carol <c@x>", [make_pr("m6", "carol", [], [appr("dave", 2000000)])])],
}

# Cases where the two policies are KNOWN and INTENDED to reach different verdicts.
# Empty today: the port's extra strictness is cause-level, not verdict-level.
# Add "case_id" here with a comment before relaxing any parity failure.
declared_divergence := set()

fe_allow(trails) := x if { x := data.four_eyes_vendored.allow with input as {"trails": trails} }

port_allow(trails) := c if {
	rep := data.control43.report with input as {"trails": trails}
	c := rep.compliant
}

agrees(id) if {
	not declared_divergence[id]
	fe_allow(corpus[id]) == port_allow(corpus[id])
}

agrees(id) if {
	declared_divergence[id]
	fe_allow(corpus[id]) != port_allow(corpus[id])
}

# The whole point: every corpus case behaves as parity (or declared divergence).
test_verdicts_agree_across_corpus if {
	every id, _ in corpus {
		agrees(id)
	}
}

# Guard against the harness going inert. `every` over an empty collection is
# vacuously true, so an emptied or renamed `corpus` would leave
# test_verdicts_agree_across_corpus passing while asserting nothing — the same
# failure mode as the substitute that matched no attestation and denied every
# initial commit. Raise this number when cases are added.
test_corpus_is_populated if {
	count(corpus) >= 8
}
