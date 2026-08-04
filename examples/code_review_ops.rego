# Custom operator for the code-review policy, contributed to the
# kosli.evidence package. This is the escape hatch: logic too specific
# for the operator vocabulary, still flowing through the same report
# machinery.
#
# Fail-closed on anything that would let an approval outrank a commit it never
# saw: a commit with a missing or non-numeric timestamp (which a bare max()
# comprehension would silently skip over), or an approval whose own timestamp is
# missing or non-numeric (Rego's ">" is total across types, so a string would
# outrank every number). The count(commits) > 0 line is belt-and-braces — max()
# over no commits is undefined already — but states the intent rather than
# resting on that.
package kosli.evidence

import rego.v1

op_passed(clause, pr) if {
	clause.op == "peer_approved"
	count(pr.commits) > 0
	every c in pr.commits {
		is_number(c.timestamp)
	}
	last_commit_ts := max({c.timestamp | some c in pr.commits})
	some approver in pr.approvers
	approver.state == "APPROVED"
	approver.username != pr.author
	is_number(approver.timestamp)
	approver.timestamp > last_commit_ts
}
