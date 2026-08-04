# Custom operator for the code-review policy, contributed to the
# kosli.evidence package. This is the escape hatch: logic too specific
# for the operator vocabulary, still flowing through the same report
# machinery. Fail-closed: empty commits => max() undefined => false.
package kosli.evidence

import rego.v1

op_passed(clause, pr) if {
	clause.op == "peer_approved"
	last_commit_ts := max({c.timestamp | some c in pr.commits})
	some approver in pr.approvers
	approver.state == "APPROVED"
	approver.username != pr.author
	approver.timestamp > last_commit_ts
}
