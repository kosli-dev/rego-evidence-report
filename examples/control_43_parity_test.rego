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

# A commit that also carries a git author string, which is what the web-flow
# patterns are matched against.
commit_a(sha, user, gitauthor) := {"sha1": sha, "author_username": user, "author": gitauthor, "timestamp": 1000000}

# A root-commit trail: the initial-commit attestation and no pull request, which
# is the shape the substitute exists for. Both policies now implement it — the
# port declares it as a substitute, production as its own trail_compliant rule.
initial_commit_trail(sha, compliant) := {
	"name": sha,
	"git_commit_info": {"author": "alice <a@x>", "sha1": sha, "timestamp": 1000100},
	"compliance_status": {"attestations_statuses": {"initial": {
		"attestation_type": "custom:initial-commit-by-verified-committer",
		"is_compliant": compliant,
	}}},
}

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
	# --- added by the 2026-09-07 refresh -----------------------------------
	#
	# Everything above was in the corpus that first shipped, and it caught exactly
	# one of the five verdict-level differences between the port and that branch.
	# The other four were invisible to it, which is the more useful finding: eight
	# cases all had a readable trail author, a resolvable approver and no bot. A
	# corpus is only as good as the shapes it thinks to vary.

	# The trail exemption is gone upstream, so a bot commit needs a review like
	# anyone else — and passes once it has one. Production's own new tests are
	# test_svc_prefix_pattern_not_exempt and _passes_with_pr.
	"svc_account_no_pr": [make_trail("s2", "svc_deploy <svc@x>", [])],
	"svc_account_with_pr": [make_trail("s3", "svc_deploy <svc@x>", [make_pr("s3", "alice", [commit("c1", "alice")], [appr("bob", 2000000)])])],
	"bot_account_no_pr": [make_trail("s4", "dependabot[bot] <db@x>", [])],
	# The anchoring fix. A human whose name embeds "[bot]" was exempted by the old
	# unanchored patterns — a fail-open on both sides until this refresh.
	"human_named_bot_no_pr": [make_trail("h9", "ali[bot]ce <dev@x>", [])],
	"human_email_svc_no_pr": [make_trail("h8", "Dev Eloper <svc_ops@x>", [])],
	# A genuine web-flow commit, matching the anchored pattern, still tolerated.
	"web_flow_commit_tolerated": [make_trail("w1", "alice <a@x>", [make_pr("w1", "alice", [commit_a("c1", null, "web-flow[bot] <wf@x>")], [appr("bob", 2000000)])])],
	# The anchoring fix where the patterns are still *used*. The two trail-level
	# cases above no longer discriminate on it — with the exemption gone they deny
	# whatever the patterns say — so this is the case that would go green again if
	# anyone unanchored them.
	#
	# It takes some arranging, because the approvers fallback masks the difference
	# on any simpler input. One resolved approver and one unresolved: not every
	# approver resolves, so the fallback cannot rescue the unresolvable author,
	# but bob is still eligible so the approval itself can pass. Anchored, the
	# commit is not web-flow and identity resolution fails. Unanchored, `[bot]`
	# mid-name matches, the commit is waved through, and the trail is compliant —
	# which is exactly the fail-open, isolated.
	"bot_substring_commit_not_web_flow": [make_trail("b1", "alice <a@x>", [make_pr(
		"b1", "alice",
		[commit_a("c1", null, "ali[bot]ce <dev@x>")],
		[appr("bob", 2000000), appr("", 2000000)],
	)])],
	# "ghost" is a login that names nobody. As the sole approver it no longer
	# satisfies four-eyes; as an author it still needs approving, which is
	# production's asymmetry and is deliberate.
	"ghost_sole_approver": [make_trail("g1", "alice <a@x>", [make_pr("g1", "alice", [commit("c1", "alice")], [appr("ghost", 2000000)])])],
	"ghost_author_resolved_approver": [make_trail("g2", "alice <a@x>", [make_pr("g2", "alice", [commit("c1", "ghost")], [appr("bob", 2000000)])])],
	# The one loosening: an unresolvable commit author, tolerated because every
	# approver resolves.
	"null_author_resolved_approvers": [make_trail("n1", "alice <a@x>", [make_pr("n1", "alice", [commit("c1", null)], [appr("bob", 2000000)])])],
	"null_author_unresolved_approver": [make_trail("n2", "alice <a@x>", [make_pr("n2", "alice", [commit("c1", null)], [appr("", 2000000)])])],
	# The trail's git author is read for nothing upstream now. These two are what
	# exposed author_recorded as a verdict-level divergence against both versions.
	"null_trail_author_good_pr": [{
		"name": "t1", "git_commit_info": {"author": null, "sha1": "t1"},
		"compliance_status": {"attestations_statuses": {"pr-review": {
			"attestation_type": "pull_request",
			"pull_requests": [make_pr("t1", "alice", [commit("c1", "alice")], [appr("bob", 2000000)])],
		}}},
	}],
	"no_git_commit_info_good_pr": [{
		"name": "t2",
		"compliance_status": {"attestations_statuses": {"pr-review": {
			"attestation_type": "pull_request",
			"pull_requests": [make_pr("t2", "alice", [commit("c1", "alice")], [appr("bob", 2000000)])],
		}}},
	}],
	# The substitute, which production now implements too — this is the first
	# parity coverage it has had on either side.
	"initial_commit_compliant": [initial_commit_trail("r1", true)],
	"initial_commit_non_compliant": [initial_commit_trail("r2", false)],
}

# Cases where the two policies are KNOWN and INTENDED to reach different verdicts.
# Add "case_id" here with a comment before relaxing any parity failure.
#
# Empty, and now that means something. It used to carry the claim that "the port's
# extra strictness is cause-level, not verdict-level", which was false when it was
# written: `author_recorded` asserted a field production reads for nothing, so a
# trail with an unreadable author and a good pull request was denied here and
# allowed upstream, against the 2026-08-24 capture as much as the branch. The
# eight-case corpus could not see it. The check is gone rather than declared,
# because the fail-open it guarded went with the scope filter it guarded.
#
# The port does keep two deliberate differences, in control_43_ops.rego — both
# fail *closed* on input the original cannot actually verify (an untimestamped
# commit, a string timestamp). Neither is reachable as a verdict difference on
# well-formed input, which is why they need no entry here. That is a narrower and
# more honest claim than the one this comment used to make.
declared_divergence := set()

fe_allow(trails) := x if x := data.four_eyes_vendored.allow with input as {"trails": trails}

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
	count(corpus) >= 23
}
