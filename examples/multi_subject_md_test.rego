# The pin for examples/multi_subject_md/policy.md.
#
#   opa test src examples --ignore '*.json'
#
# The other two Markdown examples both judge one kind of thing, so neither of
# them can tell a working transpiler from one that keeps a single subject and
# lets the last declaration win — which is what it did until this file existed.
# examples/code_review.rego judges three kinds of thing, so this is not a
# hypothetical shape.
#
# There is no Rego twin to compare against here, so these assert the shape
# directly: two requirements, two different subjects, and properties resolved
# against the right one.
package multi_subject_md_test

import rego.v1

reqs := data.multi_subject_md.requirements

test_each_requirement_keeps_its_own_subject if {
	reqs.artifact_identified.subject_type == "artifact"
	reqs.artifact_identified.from == ["artifacts"]
	reqs.artifact_identified.id == ["fingerprint"]

	reqs.change_reviewed.subject_type == "pull request"
	reqs.change_reviewed.from == ["pull_requests"]
	reqs.change_reviewed.id == ["url"]
}

# Properties are scoped to the subject that declares them, so a rule resolves
# `base branch` to the pull request's path and could not have reached it from
# the artifact requirement at all.
test_properties_resolve_against_their_own_subject if {
	reqs.artifact_identified.checks.fingerprint_recorded.path == ["fingerprint"]
	reqs.change_reviewed.checks.protected_branch.path == ["base_ref"]
}

# The nested collection check still projects correctly under a named subject:
# `commits` is the collection, `commits[].verified` the element field.
test_a_collection_check_survives_subject_scoping if {
	check := reqs.change_reviewed.checks.commits_signed
	check.op == "all"
	check.path == ["commits"]
	check.check == {"op": "equals", "path": ["verified"], "value": true}
}

# Scope filters and min_subjects belong to the requirement, not the subject.
test_scope_and_minimum_are_per_requirement if {
	reqs.change_reviewed.applies_to.merged.value == "MERGED"
	reqs.change_reviewed.min_subjects == 1
	not reqs.artifact_identified.min_subjects
}
