# Control 43 (four-eyes / source code review), expressed as a kosli.evidence
# policy. A port of `four-eyes.rego` from sdlc-workflows, written against the same
# input and checked against the same behaviours — see control_43_test.rego.
#
# Two identifiers, two schemes, one control:
#
#   SDLC-CTRL-0007   Kosli's published control catalogue — the *requirement*.
#                    https://sdlc.kosli.com/controls/release/code_review/
#   RCTLDEF0000043   a customer's own control register — an *implementation* of
#                    that requirement, which is what this file ports.
#
# So this and examples/code_review.rego are the same control at two levels of
# fidelity. This one matches the published subject — a code change, with *every*
# change requiring review — while code_review.rego covers the artefact-linkage
# requirement that this one cannot, since a commit trail carries no artifact.
#
# Deployed for real this would declare `package policy`, which is what
# `kosli evaluate` queries. It uses its own package here only because
# code_review.rego already occupies `package policy` in this directory.
#
# The subject is a **commit**: `kosli evaluate trails` passes `input.trails[]`, one
# trail per commit, and `trail.name` is the commit sha. Every commit must pass, so
# `require` is the default "every".
package control43

import data.kosli.evidence
import rego.v1

# These changed purpose in production's 2026-09-07 branch, and the rename records
# it. They used to do two jobs: exempt a whole trail whose git author was a
# service account, and tolerate a pull-request commit whose author cannot be
# resolved to a GitHub account. The trail exemption is gone — every commit now
# needs a reviewed pull request, bot or not — so only the second job is left, and
# `service_account_patterns` would name an exemption that no longer exists.
#
# They are also ANCHORED now, which closed a real fail-open. Unanchored,
# `.*\[bot\]` matches a human called `ali[bot]ce` and a bare `noreply@github.com`
# matches any author string merely containing it, so a person could be waved
# through as a bot. Production pins that with three tests; this port carried the
# same hole until this refresh.
#
# Production spells the third one as a separate rule rather than a list entry, and
# leaves its `.` unescaped. Both are kept as they are: one list of alternatives is
# the same predicate as two rules that or together, and escaping the dot would
# make the port very slightly stricter than the policy it mirrors.
web_flow_patterns := patterns if {
	patterns := data.params.web_flow_patterns
	is_array(patterns)
} else := [
	`^svc_[a-zA-Z0-9_-]+ <[^>]+>$`,
	`^.*?\[bot\] <[^>]+>$`,
	`^GitHub <noreply@github.com>$`,
]

# The PR attestation is identified by its *type*, not by its name — the collector's
# attestation name is configurable, so keying on it would break the moment someone
# sets KOSLI_ATTESTATION_NAME. A selector expresses that directly, and resolves the
# same whether attestations arrive as an array or as a map.
pr_attestation := ["compliance_status", "attestations_statuses", {"where": {"attestation_type": "pull_request"}}]

pull_requests := array.concat(pr_attestation, ["pull_requests"])

# The initial commit of a repository has no pull request to be reviewed in: there
# is no parent to open one against, so the evidence four-eyes asks for cannot
# exist. Production answers that with alternative evidence — a
# compliant `initial-commit-by-verified-committer` attestation — and this
# declares it as a substitute, so a check discharged that way says so in its row
# instead of the commit dropping out of scope with no evidence at all.
#
# Selected on `attestation_type` alone, and the type string carries the type's
# name. Kosli's own type grammar is why: built-in types are bare
# (`generic | junit | snyk | pull_request | jira | sonar`) while a custom type is
# referenced as `custom:<name>` — the server constrains it to `^custom:.*$`, and a
# type name may not itself contain a colon. So `custom` alone is not a type any
# attestation ever carries, and the reference is already unique.
#
# This started life as `{"attestation_type": "custom", "attestation_name": …}`,
# which matches nothing on the wire and made the whole substitute inert. It was
# wrong because it was guessed from a fixture written on this side rather than
# read from Kosli, which is the one way a fail-closed library still gets a policy
# wrong: a selector that cannot match denies, so the check simply never fired.
initial_commit_attestation := ["compliance_status", "attestations_statuses", {"where": {
	"attestation_type": "custom:initial-commit-by-verified-committer",
}}]

# Presence of the attestation is the discriminator, not the commit's position in
# history: the collector attests this only for a root commit, so a policy that
# tried to recognise "is the initial commit" from the trail would be re-deriving
# a judgement the evidence already carries.
verified_initial_commit := {
	"description": "A compliant initial-commit-by-verified-committer attestation stands in for the pull request an initial commit cannot have",
	"op": "equals",
	"path": array.concat(initial_commit_attestation, ["is_compliant"]),
	"value": true,
}

requirements := {
	# Production's `allow` requires input.trails to be a non-empty array before
	# anything else. That guard is a requirement of its own here, so that "no
	# commits at all" is denied for its own stated reason rather than as a side
	# effect of another requirement finding nothing.
	"commits_present": {
		"subject_type": "commit",
		"from": ["trails"],
		"id": ["name"],
		"min_subjects": 1,
		"checks": {
			"commit_identified": {
				"description": "The trail names the commit it covers",
				"op": "non_empty_string",
				"path": ["name"],
			},
			# `author_recorded` used to sit here, asserting
			# git_commit_info.author. It is gone, and the reason is worth keeping:
			# it existed to plug a fail-open in the *port's own* scope filter,
			# where a commit with an unreadable author matched no exemption
			# pattern, failed not_matches_any, and so dropped out of scope
			# entirely. That filter is what production has now deleted, so there
			# is no permissive filter left for it to guard.
			#
			# It also turned out to be a verdict-level divergence rather than the
			# cause-level extra strictness it was documented as: production reads
			# the trail's git author for nothing at all now, so a trail with an
			# unreadable author and a properly approved pull request is compliant
			# upstream and was denied here. Measured against both the 2026-08-24
			# capture and the branch — it was never in parity, and the eight-case
			# corpus could not see it because every case had a readable author.
		},
	},
	"commit_reviewed": {
		"subject_type": "commit",
		"from": ["trails"],
		"id": ["name"],
		# There is no `applies_to` here any more, and its absence is the largest
		# single change in production's 2026-09-07 branch. A service-account trail
		# used to be out of scope for four-eyes altogether: `is_service_account`
		# short-circuited `trail_compliant`, so a bot commit needed no pull
		# request. That rule is deleted upstream, its comment now says outright
		# that the patterns "do not exempt a trail from the PR-review
		# requirement", and six tests pin bots as in-scope — including
		# `test_svc_prefix_pattern_passes_with_pr`, which is the same bot commit
		# passing once it has a review.
		#
		# So every commit is a subject of this requirement, and no commit produces
		# a bare $applies row any more.
		#
		# Zero stays, for a narrower reason than before. With no filter, an empty
		# `trails` is the only way this yields no subjects, and commits_present
		# already denies that for its own stated reason. Raising it to 1 would
		# report the same emptiness twice.
		"min_subjects": 0,
		"checks": {
			"pr_attestation_present": {
				"description": "Pull request review data was collected for this commit",
				"op": "present",
				"path": pr_attestation,
				"substitute": verified_initial_commit,
			},
			"pull_request_found": {
				"description": "The commit is associated with at least one pull request",
				"op": "any",
				"path": pull_requests,
				# An empty path addresses the element itself, so this asserts the
				# array holds something without asserting anything about it.
				"check": {"op": "present", "path": []},
				"inputs": [{"path": pull_requests, "each": ["url"]}],
				"substitute": verified_initial_commit,
			},
			# This went back to being a custom op, and it is a genuine loss of
			# altitude — the declarative version made the exemption's
			# discriminator visible in the rendered expression. Production's new
			# rule earns it on the ops file's own stated criterion: it compares two
			# nested collections of the *same* pull request to each other. Either
			# every commit of that pull request has a resolvable author, or every
			# approver of that same pull request does.
			#
			# `any_of` cannot say it. Its option groups hold leaf checks, and both
			# sides of this disjunction are quantified over a collection. The
			# alternative was teaching the library to nest a quantifier inside an
			# `any_of` group, which is a real feature and may still be the right
			# one — it was not worth taking on inside a drift fix, and Rego's ban
			# on recursion means it cannot be done by simply widening the existing
			# rule.
			#
			# Declaring it per pull request also fixes something the `all` form got
			# wrong. Flattening across `pull_requests` × `commits` demanded that
			# every commit of *every* pull request resolve, where production asks
			# only that *some* pull request satisfy identities and approval
			# together. Single-PR trails hid it, which is every trail anyone has
			# captured so far.
			"identities_resolved": {
				"description": "Some pull request has every branch commit linked to a GitHub account or explained as a web-flow commit, or else has every one of its approvers resolved",
				"op": "identities_resolved",
				"expression": "some pull_request: (every commit: author_username resolves or author is web-flow) or (every approver: username resolves)",
				"path": pull_requests,
				"patterns": web_flow_patterns,
				"inputs": [
					{"path": pull_requests, "each": ["commits"]},
					{"path": pull_requests, "each": ["approvers"]},
				],
				"substitute": verified_initial_commit,
			},
			"independently_approved": {
				"description": "Some pull request has an approval from someone other than each of its authors, after its latest commit",
				"op": "independently_approved",
				"expression": "some pull_request: every author: some approver != author where state == APPROVED and timestamp > max(commits[].timestamp)",
				"path": pull_requests,
				"patterns": web_flow_patterns,
				"inputs": [
					["name"],
					{"path": pull_requests, "each": ["approvers"]},
					{"path": pull_requests, "each": ["commits"]},
				],
				"substitute": verified_initial_commit,
			},
		},
	},
}

report := evidence.report(input, requirements)

allow := report.compliant

# ---------------------------------------------------------------------------
# Violations
#
# The consuming schema wants one string per failing commit, and the report holds
# one row per (commit, check) — so the rows are collapsed by an explicit
# precedence. The production policy achieves the same shape by writing its
# violation rules so their guards are mutually exclusive; declaring the order
# instead makes it legible, and means the full evidence survives underneath in
# `report` rather than being narrowed away.
# ---------------------------------------------------------------------------

# Every check of both requirements, because a check missing from this table gets
# no message: `allow` would be false with nothing in `violations` to say why,
# which is the one failure mode this policy must not have. commits_present ranks
# first — if the trail doesn't say which commit it covers, nothing downstream is
# worth reporting.
check_priority := {
	"commit_identified": 1,
	"pr_attestation_present": 2,
	"pull_request_found": 3,
	"identities_resolved": 4,
	"independently_approved": 5,
}

commit_violations(id) := [v |
	some v in evidence.violations(report)
	v.subject.id == id
	check_priority[v.check]
]

# The most fundamental thing that went wrong for this commit. Reporting "no
# independent approval" when the truth is "no PR was ever attested" would send
# someone looking in the wrong place.
#
# The whole entry rather than the check name, because the message depends on the
# row's `cause` as well as which check failed.
primary(id) := v if {
	vs := commit_violations(id)
	count(vs) > 0
	ranks := {check_priority[x.check] | some x in vs}
	some v in vs
	check_priority[v.check] == min(ranks)
}

failing_commits := {v.subject.id |
	some v in evidence.violations(report)
	v.subject.id != null
}

violations contains message(id) if some id in failing_commits

# A requirement-level failure (subject.id is null) is the input guard: there was
# nothing to evaluate.
violations contains "Policy error: input.trails is missing, not an array, or empty — cannot evaluate" if {
	some v in evidence.violations(report)
	v.subject.id == null
}

# Two messages, not one, for the same failing check. A selector resolves to
# nothing both when no attestation matches and when several do, and until rows
# carried a `cause` the report could not tell those apart — the message had to say
# "missing or ambiguous" and let the reader guess. They are different problems
# with different fixes: one is a collector that never ran, the other is two
# attestations of the same type on one trail, which the collector's configurable
# name makes reachable.
message(id) := sprintf("Trail %v: does not name the commit it covers", [id]) if {
	primary(id).check == "commit_identified"
}

message(id) := sprintf("Trail %v: two or more pull_request attestations match — cannot tell which one to judge", [id]) if {
	primary(id).check == "pr_attestation_present"
	primary(id).cause == "ambiguous"
}

message(id) := sprintf("Trail %v: pull_request attestation is missing", [id]) if {
	primary(id).check == "pr_attestation_present"
	primary(id).cause != "ambiguous"
}

message(id) := sprintf("Commit %v: no associated PR found", [short(id)]) if {
	primary(id).check == "pull_request_found"
}

message(id) := sprintf(
	"Commit %v: a pull request commit has no linked GitHub account — identity unverifiable",
	[short(id)],
) if {
	primary(id).check == "identities_resolved"
}

message(id) := sprintf("Commit %v: no independent approval after latest code commit", [short(id)]) if {
	primary(id).check == "independently_approved"
}

# Commit shas are abbreviated in messages, as the production policy does — but
# only when there is something to abbreviate.
short(id) := substring(id, 0, 7) if {
	is_string(id)
	count(id) >= 7
}

short(id) := id if {
	is_string(id)
	count(id) < 7
}

short(id) := sprintf("%v", [id]) if not is_string(id)

output := {
	"allow": allow,
	"violations": violations,
	"report": report,
}
