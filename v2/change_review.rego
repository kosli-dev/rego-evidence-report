# Source-code review policy: every commit in the change must have
# been independently reviewed, after it was committed.
package change_review

import data.kosli.evidence
import rego.v1

policy := [{
	"type": "commit",
	"path": ["commits"],
	"id": ["sha"],
	"min_count": 1,
	"clauses": {
		"independent_reviewer": {
			"description": "Reviewer is not the code committer",
			"op": "compare",
			"cmp": "ne",
			"left": ["review", "reviewer"],
			"right": ["author"],
		},
		"review_after_commit": {
			"description": "Review date is after commit date",
			"op": "compare_time",
			"cmp": "gt",
			"left": ["review", "timestamp"],
			"right": ["timestamp"],
		},
		"reviewed_at_all": {
			"description": "A review exists for the commit",
			"op": "present",
			"path": ["review"],
		},
	},
}]

report := evidence.report(input, policy)

compliant := report.compliant
