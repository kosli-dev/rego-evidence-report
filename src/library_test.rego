# Tests for the kosli.evidence library.
#
#   opa test src --verbose                      # library only
#   opa test src examples --ignore '*.json'     # library + example policy
#
# The --ignore is required: examples/*.json are `opa eval` fixtures, and both
# define data.trail, so loading them together is a merge error.
#
# Convention for a known-open issue: prefix its rule `todo_test_` and `opa test`
# skips it, so the suite stays green while the assertion states the behaviour we
# want; closing the issue is the change that renames it to `test_`. Nothing is
# skipped at the moment.
#
# The final section holds the regression tests for the fail-open and
# evidence-integrity bugs this library shipped with — the cases most worth not
# reintroducing.
package kosli.evidence_test

import data.kosli.evidence
import rego.v1

# ---------- helpers ----------

# A one-subject, one-check report: the smallest thing that drives a check end
# to end (subject resolution -> operator -> row -> definition table).
solo(subj, check) := evidence.report(
	{"items": [subj]},
	{"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
		"checks": {"c": check},
	}},
)

# The verdict of the check's own row (as opposed to the requirement's synthetic
# $min_subjects row). Reads the row rather than calling op_passed directly, so a
# check that produces NO row fails the test (report totality) instead of quietly
# looking like a pass.
verdict(subj, check) := row.passed if {
	some row in solo(subj, check).results
	row.check == "c"
}

inputs_of(subj, check) := row.inputs if {
	some row in solo(subj, check).results
	row.check == "c"
}

rendered(subj, check) := solo(subj, check).requirements.s.checks.c.expression

rows_for(report, req_name, check_name) := [r |
	some r in report.results
	r.requirement == req_name
	r.check == check_name
]

# ---------- subject resolution ----------

id_req(from) := {"s": {
	"subject_type": "thing",
	"from": from,
	"id": ["id"],
	"checks": {"c": {"op": "present", "path": ["id"]}},
}}

subject_counts(doc, from) := evidence.report(doc, id_req(from)).requirements.s.subjects

test_array_from_yields_one_subject_per_element if {
	subject_counts({"items": [{"id": "a"}, {"id": "b"}]}, ["items"]) == {"total": 2, "matching": 2}
}

test_single_object_from_is_wrapped_as_one_subject if {
	subject_counts({"item": {"id": "a"}}, ["item"]) == {"total": 1, "matching": 1}
}

test_missing_from_yields_no_subjects if {
	subject_counts({"other": [{"id": "a"}]}, ["items"]) == {"total": 0, "matching": 0}
}

test_scalar_from_yields_no_subjects if {
	subject_counts({"items": "not-a-collection"}, ["items"]) == {"total": 0, "matching": 0}
}

test_empty_from_treats_the_whole_document_as_one_subject if {
	subject_counts({"id": "root"}, []) == {"total": 1, "matching": 1}
}

test_nested_from_resolves_through_objects if {
	subject_counts({"a": {"b": {"items": [{"id": "x"}]}}}, ["a", "b", "items"]) == {"total": 1, "matching": 1}
}

test_missing_id_path_yields_a_null_subject_id if {
	rep := evidence.report({"items": [{"no_id_here": 1}]}, id_req(["items"]))
	some row in rep.results
	row.subject == {"type": "thing", "id": null}
}

test_subject_id_is_read_from_the_declared_path if {
	rep := evidence.report({"items": [{"id": "abc"}]}, id_req(["items"]))
	some row in rep.results
	row.subject == {"type": "thing", "id": "abc"}
}

# ---------- applies_to filters ----------

scoped_req(applies_to) := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"applies_to": applies_to,
	"checks": {"c": {"op": "present", "path": ["id"]}},
}}

merged_only := {"merged": {"op": "equals", "path": ["state"], "value": "MERGED"}}

two_states := {"items": [
	{"id": "a", "state": "MERGED"},
	{"id": "b", "state": "CLOSED"},
]}

test_applies_to_narrows_matching_but_leaves_total_intact if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	rep.requirements.s.subjects == {"total": 2, "matching": 1}
}

test_applies_to_checks_are_conjunctive if {
	both := object.union(merged_only, {"on_main": {"op": "equals", "path": ["base_ref"], "value": "main"}})
	doc := {"items": [
		{"id": "a", "state": "MERGED", "base_ref": "main"},
		{"id": "b", "state": "MERGED", "base_ref": "topic"},
	]}
	rep := evidence.report(doc, scoped_req(both))
	rep.requirements.s.subjects == {"total": 2, "matching": 1}
}

test_applies_to_excludes_subjects_whose_filtered_field_is_missing if {
	rep := evidence.report({"items": [{"id": "a"}]}, scoped_req(merged_only))
	rep.requirements.s.subjects == {"total": 1, "matching": 0}
}

test_empty_applies_to_matches_everything if {
	rep := evidence.report(two_states, scoped_req({}))
	rep.requirements.s.subjects == {"total": 2, "matching": 2}
}

test_applies_to_is_evaluated_for_every_raw_subject if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	verdicts := {r.subject.id: r.passed |
		some r in rep.results
		r.check == "$applies"
	}
	verdicts == {"a": true, "b": false}
}

test_applies_row_echoes_the_field_the_filter_read if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	some r in rep.results
	r.check == "$applies"
	r.subject.id == "b"
	r.inputs == [{"name": "state", "value": "CLOSED"}]
}

test_applies_definition_renders_the_filter_expression if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	rep.requirements.s.checks["$applies"].expression == "state == MERGED"
}

test_applies_definition_conjoins_multiple_filter_checks if {
	both := object.union(merged_only, {"on_main": {"op": "equals", "path": ["base_ref"], "value": "main"}})
	rep := evidence.report(two_states, scoped_req(both))

	# Ordered by filter-check name — "merged", then "on_main".
	rep.requirements.s.checks["$applies"].expression == "state == MERGED and base_ref == main"
}

test_no_applies_to_means_no_applies_rows_or_definition if {
	rep := evidence.report(two_states, id_req(["items"]))
	count([r | some r in rep.results; r.check == "$applies"]) == 0
	not "$applies" in object.keys(rep.requirements.s.checks)
}

# Out-of-scope subjects are recorded, not evaluated: no check rows for them.
test_out_of_scope_subject_gets_no_check_rows if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	ids := {r.subject.id | some r in rep.results; r.check == "c"}
	ids == {"a"}
}

# ---------- leaf operator: range ----------

in_range := {"op": "range", "path": ["temp_c"], "min": 0, "max": 10}

test_range_inside if verdict({"temp_c": 5}, in_range) == true

test_range_at_lower_bound if verdict({"temp_c": 0}, in_range) == true

test_range_at_upper_bound if verdict({"temp_c": 10}, in_range) == true

test_range_below_bound if verdict({"temp_c": -1}, in_range) == false

test_range_above_bound if verdict({"temp_c": 11}, in_range) == false

test_range_rejects_numeric_string if verdict({"temp_c": "5"}, in_range) == false

test_range_rejects_missing_field if verdict({"other": 5}, in_range) == false

test_range_rejects_null if verdict({"temp_c": null}, in_range) == false

# ---------- leaf operator: excludes ----------

no_wip := {"op": "excludes", "path": ["labels"], "value": "wip"}

test_excludes_when_value_absent if verdict({"labels": ["ready"]}, no_wip) == true

test_excludes_over_empty_array if verdict({"labels": []}, no_wip) == true

test_excludes_when_value_present if verdict({"labels": ["ready", "wip"]}, no_wip) == false

# Absence cannot be proven against a non-collection, so this stays fail-closed.
test_excludes_rejects_non_array if verdict({"labels": "wip"}, no_wip) == false

test_excludes_rejects_missing_field if verdict({}, no_wip) == false

# ---------- leaf operator: includes ----------

has_approved := {"op": "includes", "path": ["labels"], "value": "approved"}

test_includes_when_value_present if verdict({"labels": ["approved"]}, has_approved) == true

test_includes_when_value_absent if verdict({"labels": ["ready"]}, has_approved) == false

test_includes_over_empty_array if verdict({"labels": []}, has_approved) == false

test_includes_rejects_non_array if verdict({"labels": "approved"}, has_approved) == false

test_includes_rejects_missing_field if verdict({}, has_approved) == false

# ---------- leaf operator: equals ----------

is_merged := {"op": "equals", "path": ["state"], "value": "MERGED"}

test_equals_on_match if verdict({"state": "MERGED"}, is_merged) == true

test_equals_on_mismatch if verdict({"state": "CLOSED"}, is_merged) == false

test_equals_rejects_missing_field if verdict({}, is_merged) == false

test_equals_is_type_sensitive if verdict({"n": "1"}, {"op": "equals", "path": ["n"], "value": 1}) == false

test_equals_compares_booleans if verdict({"verified": true}, {"op": "equals", "path": ["verified"], "value": true}) == true

test_equals_compares_nested_objects if {
	verdict({"a": {"b": [1, 2]}}, {"op": "equals", "path": ["a"], "value": {"b": [1, 2]}}) == true
}

# The counterpart to test_equals_null_does_not_pass_on_a_missing_field: a field
# that IS explicitly null still matches, so "was recorded as null" and "was
# never recorded" stay distinguishable.
test_equals_null_matches_an_explicit_null if {
	verdict({"x": null}, {"op": "equals", "path": ["x"], "value": null}) == true
}

# ---------- leaf operator: present ----------

has_fingerprint := {"op": "present", "path": ["fingerprint"]}

test_present_when_set if verdict({"fingerprint": "abc"}, has_fingerprint) == true

test_present_rejects_missing_field if verdict({}, has_fingerprint) == false

test_present_rejects_explicit_null if verdict({"fingerprint": null}, has_fingerprint) == false

# present is a null check only — emptiness is non_empty_string's job.
test_present_accepts_empty_string if verdict({"fingerprint": ""}, has_fingerprint) == true

test_present_accepts_false if verdict({"fingerprint": false}, has_fingerprint) == true

# ---------- leaf operator: non_empty_string ----------

filled := {"op": "non_empty_string", "path": ["fingerprint"]}

test_non_empty_string_when_filled if verdict({"fingerprint": "abc"}, filled) == true

test_non_empty_string_rejects_empty_string if verdict({"fingerprint": ""}, filled) == false

test_non_empty_string_rejects_number if verdict({"fingerprint": 42}, filled) == false

test_non_empty_string_rejects_null if verdict({"fingerprint": null}, filled) == false

test_non_empty_string_rejects_missing_field if verdict({}, filled) == false

# ---------- leaf operator: compare ----------

compare_ab(op) := {"op": "compare", "cmp": op, "left": ["a"], "right": ["b"]}

test_compare_eq_when_equal if verdict({"a": 1, "b": 1}, compare_ab("eq")) == true

test_compare_eq_when_different if verdict({"a": 1, "b": 2}, compare_ab("eq")) == false

test_compare_ne_when_different if verdict({"a": 1, "b": 2}, compare_ab("ne")) == true

test_compare_ne_when_equal if verdict({"a": 1, "b": 1}, compare_ab("ne")) == false

test_compare_gt_when_greater if verdict({"a": 2, "b": 1}, compare_ab("gt")) == true

test_compare_gt_when_equal if verdict({"a": 1, "b": 1}, compare_ab("gt")) == false

test_compare_gte_when_equal if verdict({"a": 1, "b": 1}, compare_ab("gte")) == true

test_compare_lt_when_less if verdict({"a": 1, "b": 2}, compare_ab("lt")) == true

test_compare_lt_when_equal if verdict({"a": 1, "b": 1}, compare_ab("lt")) == false

test_compare_lte_when_equal if verdict({"a": 1, "b": 1}, compare_ab("lte")) == true

test_compare_compares_strings if verdict({"a": "abc", "b": "abd"}, compare_ab("lt")) == true

test_compare_rejects_unknown_cmp if verdict({"a": 1, "b": 1}, compare_ab("congruent")) == false

test_compare_rejects_missing_cmp if {
	verdict({"a": 1, "b": 1}, {"op": "compare", "left": ["a"], "right": ["b"]}) == false
}

# ---------- leaf operator: compare_time ----------

compare_time_span(op) := {"op": "compare_time", "cmp": op, "left": ["start"], "right": ["end"]}

span := {"start": "2024-01-01T00:00:00Z", "end": "2024-06-01T00:00:00Z"}

test_compare_time_lt if verdict(span, compare_time_span("lt")) == true

test_compare_time_gt if verdict(span, compare_time_span("gt")) == false

test_compare_time_normalises_offsets if {
	doc := {"start": "2024-01-01T12:00:00Z", "end": "2024-01-01T13:00:00+01:00"}
	verdict(doc, compare_time_span("eq")) == true
}

test_compare_time_respects_sub_second_precision if {
	doc := {"start": "2024-01-01T00:00:00.000000001Z", "end": "2024-01-01T00:00:00.000000002Z"}
	verdict(doc, compare_time_span("lt")) == true
}

# The next four go through the rfc3339_shaped gate rather than reaching
# time.parse_rfc3339_ns, which is what keeps them failing rows instead of a
# builtin error that would be fatal under --strict-builtin-errors.
test_compare_time_rejects_malformed_timestamp if {
	verdict({"start": "yesterday", "end": "2024-01-01T00:00:00Z"}, compare_time_span("lt")) == false
}

test_compare_time_rejects_an_out_of_range_month if {
	verdict({"start": "2024-13-01T00:00:00Z", "end": "2024-01-01T00:00:00Z"}, compare_time_span("lt")) == false
}

test_compare_time_rejects_a_date_without_a_time if {
	verdict({"start": "2024-01-01", "end": "2024-06-01"}, compare_time_span("lt")) == false
}

# The gate itself, since in default mode a malformed timestamp yields a failing
# row either way and only --strict-builtin-errors can tell the two apart.
test_rfc3339_gate_accepts_valid_timestamps if {
	every ts in [
		"2024-01-01T00:00:00Z",
		"2024-01-01T00:00:00z",
		"2024-06-30T23:59:59.999999999Z",
		"2024-06-30T12:00:00+02:00",
		"2024-06-30T12:00:00-05:30",
	] {
		evidence.rfc3339_shaped(ts)
	}
}

test_rfc3339_gate_rejects_everything_else if {
	every ts in [
		"yesterday",
		"",
		"2024-01-01",
		"2024-13-01T00:00:00Z",
		"2024-00-01T00:00:00Z",
		"2024-01-32T00:00:00Z",
		"2024-01-01T24:00:00Z",
		"2024-01-01T00:60:00Z",
		# A leap second is legal RFC3339 but "second out of range" to Go's
		# parser, so the gate has to reject it too.
		"2024-12-31T23:59:60Z",
		"2024-01-01T00:00:00",
		"2024-01-01T00:00:00+24:00",
		"24-01-01T00:00:00Z",
		1753600000,
		null,
		true,
		["2024-01-01T00:00:00Z"],
	] {
		not evidence.rfc3339_shaped(ts)
	}
}

test_compare_time_rejects_epoch_seconds if {
	verdict({"start": 1753600000, "end": 1753603600}, compare_time_span("lt")) == false
}

# Unlike `compare` (issue 1), compare_time is already fail-closed on a missing
# side — but only because parsing null errors into undefined, which is the same
# fragile path as the two tests above.
test_compare_time_rejects_a_missing_side if {
	verdict({"end": "2024-01-01T00:00:00Z"}, compare_time_span("lt")) == false
}

# ---------- collection operators ----------

all_verified := {
	"op": "all",
	"path": ["commits"],
	"check": {"op": "equals", "path": ["verified"], "value": true},
}

any_approved := {
	"op": "any",
	"path": ["approvers"],
	"check": {"op": "equals", "path": ["state"], "value": "APPROVED"},
}

test_all_when_every_element_passes if {
	verdict({"commits": [{"verified": true}, {"verified": true}]}, all_verified) == true
}

test_all_when_one_element_fails if {
	verdict({"commits": [{"verified": true}, {"verified": false}]}, all_verified) == false
}

test_all_when_an_element_is_missing_the_field if {
	verdict({"commits": [{"verified": true}, {"sha1": "abc"}]}, all_verified) == false
}

test_all_rejects_non_array if verdict({"commits": "none"}, all_verified) == false

test_all_rejects_missing_path if verdict({}, all_verified) == false

test_all_rejects_object_collection if {
	verdict({"commits": {"a": {"verified": true}}}, all_verified) == false
}

test_all_without_a_nested_check_fails if {
	verdict({"commits": [{"verified": true}]}, {"op": "all", "path": ["commits"]}) == false
}

test_any_when_one_element_passes if {
	verdict({"approvers": [{"state": "COMMENTED"}, {"state": "APPROVED"}]}, any_approved) == true
}

test_any_when_no_element_passes if {
	verdict({"approvers": [{"state": "COMMENTED"}]}, any_approved) == false
}

test_any_over_empty_collection if verdict({"approvers": []}, any_approved) == false

test_any_rejects_missing_path if verdict({}, any_approved) == false

test_any_without_a_nested_check_fails if {
	verdict({"approvers": [{"state": "APPROVED"}]}, {"op": "any", "path": ["approvers"]}) == false
}

# ---------- echoed inputs ----------

test_inputs_echo_the_read_path if {
	inputs_of({"state": "MERGED"}, is_merged) == [{"name": "state", "value": "MERGED"}]
}

test_inputs_echo_null_for_a_missing_field if {
	inputs_of({}, is_merged) == [{"name": "state", "value": null}]
}

test_inputs_name_nested_paths_with_dots if {
	check := {"op": "equals", "path": ["a", "b"], "value": 1}
	inputs_of({"a": {"b": 1}}, check) == [{"name": "a.b", "value": 1}]
}

test_inputs_echo_both_sides_of_a_comparison if {
	inputs_of({"a": 1, "b": 2}, compare_ab("lt")) == [
		{"name": "a", "value": 1},
		{"name": "b", "value": 2},
	]
}

test_inputs_project_leaf_values_across_a_collection if {
	inputs_of({"commits": [{"verified": true}, {"verified": false}]}, all_verified) == [{
		"name": "commits[].verified",
		"value": [true, false],
	}]
}

test_explicit_inputs_win if {
	check := {"op": "present", "path": ["id"], "inputs": [["author"], ["approvers"]]}
	inputs_of({"id": "x", "author": "alice", "approvers": []}, check) == [
		{"name": "author", "value": "alice"},
		{"name": "approvers", "value": []},
	]
}

test_inputs_empty_when_a_check_declares_neither_path_nor_inputs if {
	inputs_of({"id": "x"}, {"op": "bespoke"}) == []
}

# An inputs entry can also project a field across a collection, so a custom op
# reading commits[].timestamp can echo exactly that.
test_inputs_can_project_across_a_collection if {
	check := {"op": "bespoke", "inputs": [{"path": ["commits"], "each": ["timestamp"]}]}
	inputs_of({"commits": [{"timestamp": 1}, {"timestamp": 2}]}, check) == [{
		"name": "commits[].timestamp",
		"value": [1, 2],
	}]
}

test_inputs_projection_over_a_missing_collection if {
	check := {"op": "bespoke", "inputs": [{"path": ["commits"], "each": ["timestamp"]}]}
	inputs_of({}, check) == [{"name": "commits[].timestamp", "value": []}]
}

test_inputs_mix_paths_and_projections if {
	check := {"op": "bespoke", "inputs": [["author"], {"path": ["commits"], "each": ["sha1"]}]}
	inputs_of({"author": "alice", "commits": [{"sha1": "aaaa"}]}, check) == [
		{"name": "author", "value": "alice"},
		{"name": "commits[].sha1", "value": ["aaaa"]},
	]
}

# ---------- check definition table ----------

test_definition_carries_the_raw_spec_and_description if {
	check := object.union(is_merged, {"description": "Merged"})
	def := solo({"state": "MERGED"}, check).requirements.s.checks.c
	def.op == "equals"
	def.path == ["state"]
	def.value == "MERGED"
	def.description == "Merged"
}

test_expression_for_range if rendered({"temp_c": 5}, in_range) == "temp_c >= 0 and temp_c <= 10"

test_expression_for_excludes if rendered({"labels": []}, no_wip) == "not contains(labels, wip)"

test_expression_for_includes if rendered({"labels": []}, has_approved) == "contains(labels, approved)"

test_expression_for_equals if rendered({}, is_merged) == "state == MERGED"

test_expression_for_present if rendered({}, has_fingerprint) == "fingerprint is present"

test_expression_for_non_empty_string if rendered({}, filled) == "fingerprint is a non-empty string"

test_expression_for_compare if rendered({}, compare_ab("lt")) == "a lt b"

test_expression_for_compare_time if rendered(span, compare_time_span("lt")) == "start lt end"

test_expression_for_all if rendered({"commits": []}, all_verified) == "every commits: verified == true"

test_expression_for_any if rendered({"approvers": []}, any_approved) == "some approvers: state == APPROVED"

test_expression_for_nested_paths_is_dotted if {
	check := {"op": "equals", "path": ["a", "b"], "value": 1}
	rendered({}, check) == "a.b == 1"
}

test_declared_expression_wins_over_the_rendered_one if {
	check := object.union(is_merged, {"expression": "state is MERGED"})
	rendered({}, check) == "state is MERGED"
}

# A custom op the library cannot render gets an empty expression; the policy is
# expected to declare one (see examples/code_review.rego).
test_unrenderable_op_yields_an_empty_expression if rendered({}, {"op": "bespoke"}) == ""

# ---------- rows ----------

two_check_req := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"checks": {
		"a": {"op": "present", "path": ["id"]},
		"b": {"op": "equals", "path": ["state"], "value": "MERGED"},
	},
}}

test_one_row_per_subject_and_check if {
	doc := {"items": [{"id": "a"}, {"id": "b"}]}
	rep := evidence.report(doc, two_check_req)
	count([r | some r in rep.results; not startswith(r.check, "$")]) == 4

	# ...plus the requirement's own $well_formed and $min_subjects rows.
	count(rep.results) == 6
}

test_row_carries_exactly_the_documented_keys if {
	every row in solo({"state": "MERGED"}, is_merged).results {
		object.keys(row) == {"requirement", "subject", "check", "inputs", "passed"}
	}
}

test_rows_are_produced_even_for_an_empty_subject if {
	rep := evidence.report({"items": [{}]}, two_check_req)
	check_rows := [r | some r in rep.results; not startswith(r.check, "$")]
	count(check_rows) == 2
	every row in check_rows {
		row.passed == false
	}
}

test_unknown_op_produces_a_failing_row_not_a_gap if {
	verdict({"id": "x"}, {"op": "no_such_op", "path": ["id"]}) == false
}

test_subject_type_defaults_to_subject if {
	rep := evidence.report({"items": [{"id": "a"}]}, {"s": {
		"from": ["items"],
		"checks": {"c": has_fingerprint},
	}})
	rep.results[0].subject.type == "subject"
}

test_rows_from_different_requirements_are_labelled_separately if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	policy := {
		"first": {"subject_type": "t", "from": ["a"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
		"second": {"subject_type": "t", "from": ["b"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
	}
	rep := evidence.report(doc, policy)
	count(rows_for(rep, "first", "c")) == 1
	count(rows_for(rep, "second", "c")) == 1
}

# The requirement name is the policy's own object key — it is never rewritten, so
# a row's name always matches the key a consumer looks up.
test_requirement_name_is_the_policy_key if {
	rep := evidence.report({"items": [{"id": "a"}]}, id_req(["items"]))
	object.keys(rep.requirements) == {"s"}
	{r.requirement | some r in rep.results} == {"s"}
}

# ---------- min_subjects ----------

min_subjects_req(n) := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"min_subjects": n,
	"checks": {"c": {"op": "present", "path": ["id"]}},
}}

test_min_subjects_satisfied if {
	rep := evidence.report({"items": [{"id": "a"}]}, min_subjects_req(1))
	rows_for(rep, "s", "$min_subjects")[0].passed == true
	rep.requirements.s.satisfied == true
}

test_min_subjects_violated_fails_the_requirement if {
	rep := evidence.report({"items": []}, min_subjects_req(1))
	rows_for(rep, "s", "$min_subjects")[0].passed == false
	rep.requirements.s.satisfied == false
	rep.compliant == false
}

test_min_subjects_row_has_a_null_subject_id if {
	rep := evidence.report({"items": []}, min_subjects_req(1))
	rows_for(rep, "s", "$min_subjects")[0].subject == {"type": "thing", "id": null}
}

test_min_subjects_definition_is_in_the_check_table if {
	rep := evidence.report({"items": []}, min_subjects_req(2))
	def := rep.requirements.s.checks["$min_subjects"]
	def.description == "at least 2 matching thing subject(s) required"
	def.expression == "count(matching(items)) >= 2"
}

# Opt-in would mean a typo'd "from" silently satisfies a requirement (issue 3),
# so every requirement gets the guard whether it asks for one or not.
test_min_subjects_defaults_to_one if {
	rep := evidence.report({"items": [{"id": "a"}]}, id_req(["items"]))
	rows_for(rep, "s", "$min_subjects")[0].passed == true
	rep.requirements.s.checks["$min_subjects"].expression == "count(matching(items)) >= 1"
}

# ...and an explicit zero opts back into the vacuous pass, for a policy that
# really does mean "if there are any, they must all pass".
test_min_subjects_zero_permits_an_empty_collection if {
	rep := evidence.report({"items": []}, min_subjects_req(0))
	rows_for(rep, "s", "$min_subjects")[0].passed == true
	rep.requirements.s.satisfied == true
}

test_min_subjects_counts_subjects_after_the_applies_to_filter if {
	both := {"s": object.union(min_subjects_req(2).s, {"applies_to": merged_only})}
	rep := evidence.report(two_states, both)
	rows_for(rep, "s", "$min_subjects")[0].passed == false
}

test_min_subjects_guards_a_missing_collection if {
	rep := evidence.report({}, min_subjects_req(1))
	rows_for(rep, "s", "$min_subjects")[0].passed == false
	rep.compliant == false
}

# ---------- $well_formed ----------

test_well_formed_passes_for_an_ordinary_requirement if {
	rep := evidence.report({"items": [{"id": "a"}]}, id_req(["items"]))
	rows_for(rep, "s", "$well_formed")[0].passed == true
}

test_well_formed_fails_when_no_checks_are_declared if {
	rep := evidence.report({"items": [{"id": "a"}]}, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
	}})
	rows_for(rep, "s", "$well_formed")[0].passed == false
	rep.requirements.s.satisfied == false
}

test_well_formed_fails_on_an_unrecognised_require_value if {
	rep := evidence.report(both_ok, require_req("most"))
	rows_for(rep, "s", "$well_formed")[0].passed == false
	rep.requirements.s.satisfied == false
}

test_well_formed_row_is_about_the_requirement_not_a_subject if {
	rep := evidence.report({"items": [{"id": "a"}, {"id": "b"}]}, id_req(["items"]))
	count(rows_for(rep, "s", "$well_formed")) == 1
	rows_for(rep, "s", "$well_formed")[0].subject == {"type": "thing", "id": null}
}

# Static: the same declaration is well formed or not regardless of the document,
# so an empty input must not change the verdict on it.
test_well_formed_does_not_depend_on_the_input if {
	with_items := evidence.report({"items": [{"id": "a"}]}, id_req(["items"]))
	without := evidence.report({}, id_req(["items"]))
	rows_for(with_items, "s", "$well_formed")[0] == rows_for(without, "s", "$well_formed")[0]
}

test_well_formed_echoes_the_declaration_it_read if {
	rep := evidence.report(both_ok, require_req("most"))
	rows_for(rep, "s", "$well_formed")[0].inputs == [
		{"name": "count(checks)", "value": 2},
		{"name": "require", "value": "most"},
	]
}

test_well_formed_definition_is_in_the_check_table if {
	rep := evidence.report({"items": [{"id": "a"}]}, id_req(["items"]))
	rep.requirements.s.checks["$well_formed"].expression == "count(checks) >= 1 and require in {every, some}"
}

# ---------- require ----------

require_req(q) := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"require": q,
	"checks": {
		"signed": {"op": "equals", "path": ["signed"], "value": true},
		"reviewed": {"op": "equals", "path": ["reviewed"], "value": true},
	},
}}

both_ok := {"items": [{"id": "a", "signed": true, "reviewed": true}]}

split_across_subjects := {"items": [
	{"id": "a", "signed": true, "reviewed": false},
	{"id": "b", "signed": false, "reviewed": true},
]}

test_every_satisfied_when_all_subjects_pass if {
	doc := {"items": [
		{"id": "a", "signed": true, "reviewed": true},
		{"id": "b", "signed": true, "reviewed": true},
	]}
	evidence.report(doc, require_req("every")).requirements.s.satisfied == true
}

test_every_unsatisfied_when_one_subject_fails if {
	evidence.report(split_across_subjects, require_req("every")).requirements.s.satisfied == false
}

test_some_satisfied_when_one_subject_passes_every_check if {
	evidence.report(both_ok, require_req("some")).requirements.s.satisfied == true
}

# The reason `some` exists: checks may not be split across subjects.
test_some_unsatisfied_when_checks_are_split_across_subjects if {
	evidence.report(split_across_subjects, require_req("some")).requirements.s.satisfied == false
}

test_some_unsatisfied_without_subjects if {
	evidence.report({"items": []}, require_req("some")).requirements.s.satisfied == false
}

# min_subjects: 0 means the same thing under both require modes — "if there are
# any, the rule applies; if there are none, that's fine". It used to mean the
# opposite under "some", where an empty collection could never be satisfied
# because no subject was there to pass, leaving the requirement denied with no
# failing row to explain it.
some_req_zero := {"s": object.union(require_req("some").s, {"min_subjects": 0})}

test_some_with_min_subjects_zero_is_vacuously_satisfied_when_empty if {
	rep := evidence.report({"items": []}, some_req_zero)
	rep.requirements.s.satisfied == true
	rep.compliant == true
}

# The vacuous pass stays opt-in — the default of 1 still denies an empty
# collection under "some".
test_some_without_min_subjects_zero_still_denies_an_empty_collection if {
	evidence.report({"items": []}, require_req("some")).requirements.s.satisfied == false
}

# ...and it is only about emptiness. Subjects that exist must still produce a
# passer.
test_some_with_min_subjects_zero_still_denies_when_no_subject_passes if {
	rep := evidence.report(split_across_subjects, some_req_zero)
	rep.requirements.s.satisfied == false
	count(evidence.violations(rep)) > 0
}

# Emptiness after the filter counts as emptiness.
test_some_with_min_subjects_zero_is_satisfied_when_the_filter_empties_the_scope if {
	scoped := {"s": object.union(some_req_zero.s, {"applies_to": merged_only})}
	evidence.report({"items": [{"id": "a", "state": "CLOSED"}]}, scoped).requirements.s.satisfied == true
}

test_some_still_records_rows_for_the_failing_subjects if {
	rep := evidence.report(
		{"items": [
			{"id": "a", "signed": true, "reviewed": true},
			{"id": "b", "signed": false, "reviewed": true},
		]},
		require_req("some"),
	)
	rep.requirements.s.satisfied == true
	count([r | some r in rep.results; r.passed == false]) == 1
}

test_require_defaults_to_every if {
	rep := evidence.report(split_across_subjects, require_req("every"))
	defaulted := evidence.report(split_across_subjects, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
		"checks": require_req("every").s.checks,
	}})
	defaulted.requirements.s.require == "every"
	defaulted.requirements.s.satisfied == rep.requirements.s.satisfied
}

test_unknown_require_value_is_unsatisfied if {
	evidence.report(both_ok, require_req("most")).requirements.s.satisfied == false
}

# ---------- report-level verdict ----------

test_compliant_when_every_requirement_is_satisfied if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	policy := {
		"first": {"subject_type": "t", "from": ["a"], "id": ["id"], "min_subjects": 1, "checks": {"c": {"op": "present", "path": ["id"]}}},
		"second": {"subject_type": "t", "from": ["b"], "id": ["id"], "min_subjects": 1, "checks": {"c": {"op": "present", "path": ["id"]}}},
	}
	evidence.report(doc, policy).compliant == true
}

test_not_compliant_when_any_requirement_is_unsatisfied if {
	doc := {"a": [{"id": "1"}], "b": [{"no_id": true}]}
	policy := {
		"first": {"subject_type": "t", "from": ["a"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
		"second": {"subject_type": "t", "from": ["b"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
	}
	evidence.report(doc, policy).compliant == false
}

test_report_has_one_entry_per_declared_requirement if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	policy := {
		"first": {"subject_type": "t", "from": ["a"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
		"second": {"subject_type": "t", "from": ["b"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}},
	}
	object.keys(evidence.report(doc, policy).requirements) == {"first", "second"}
}

test_requirement_entry_carries_exactly_the_documented_keys if {
	rep := solo({"state": "MERGED"}, is_merged)
	object.keys(rep.requirements.s) == {"require", "satisfied", "subjects", "checks"}
}

test_report_carries_exactly_the_documented_keys if {
	object.keys(solo({}, is_merged)) == {"compliant", "requirements", "results"}
}

# Two evaluations of the same policy against the same input must be byte-equal,
# since the report is meant to be hashed and attested.
test_report_is_deterministic if {
	doc := {"items": [{"id": "b", "state": "MERGED"}, {"id": "a", "state": "CLOSED"}]}
	rep := evidence.report(doc, two_check_req)
	json.marshal(rep) == json.marshal(evidence.report(doc, two_check_req))
}

# Row order must not depend on how the policy object was written, or two
# consumers building the same policy in a different key order would hash to
# different reports.
test_row_order_is_independent_of_policy_key_order if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	first := {"subject_type": "t", "from": ["a"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}}
	second := {"subject_type": "t", "from": ["b"], "id": ["id"], "checks": {"c": {"op": "present", "path": ["id"]}}}

	json.marshal(evidence.report(doc, {"first": first, "second": second})) == json.marshal(evidence.report(doc, {"second": second, "first": first}))
}

# The exact sequence the README documents under "Report shape": grouped by kind
# of check from the most general question to the most specific, then requirement
# name, then input order of subjects, then check name. Groups interleave across
# requirements — both $well_formed rows precede either $min_subjects row — which
# is the part prose most easily gets wrong.
test_row_order_groups_by_check_kind_then_requirement if {
	req := {
		"subject_type": "t",
		"from": ["items"],
		"id": ["id"],
		"applies_to": {"live": {"op": "equals", "path": ["live"], "value": true}},
		"checks": {
			"zeta": {"op": "present", "path": ["id"]},
			"alpha": {"op": "present", "path": ["id"]},
		},
	}
	doc := {"items": [{"id": "s2", "live": true}, {"id": "s1", "live": false}]}

	sequence := [sprintf("%s/%s/%v", [r.requirement, r.check, r.subject.id]) |
		some r in evidence.report(doc, {"zzz": req, "aaa": req}).results
	]
	sequence == [
		"aaa/$well_formed/null",
		"zzz/$well_formed/null",
		"aaa/$min_subjects/null",
		"zzz/$min_subjects/null",
		"aaa/$applies/s2",
		"aaa/$applies/s1",
		"zzz/$applies/s2",
		"zzz/$applies/s1",
		"aaa/alpha/s2",
		"aaa/zeta/s2",
		"zzz/alpha/s2",
		"zzz/zeta/s2",
	]
}

# Every row must resolve to exactly one check definition, which is the contract
# that lets a consumer read a row without the .rego source.
test_every_row_resolves_to_one_check_definition if {
	scoped := {"s": object.union(min_subjects_req(1).s, {"applies_to": merged_only})}
	rep := evidence.report(two_states, scoped)
	every row in rep.results {
		count([def |
			some name, req in rep.requirements
			name == row.requirement
			some check_name, def in req.checks
			check_name == row.check
		]) == 1
	}
}

# ---------- violations ----------

violating_req := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"checks": {
		"signed": {"description": "Signed", "op": "equals", "path": ["signed"], "value": true},
		"reviewed": {"description": "Reviewed", "op": "equals", "path": ["reviewed"], "value": true},
	},
}}

test_violations_are_empty_for_a_compliant_report if {
	rep := evidence.report({"items": [{"id": "a", "signed": true, "reviewed": true}]}, violating_req)
	rep.compliant == true
	evidence.violations(rep) == []
}

test_violation_entry_carries_exactly_the_documented_keys if {
	rep := evidence.report({"items": [{"id": "a"}]}, violating_req)
	count(evidence.violations(rep)) == 2
	every v in evidence.violations(rep) {
		object.keys(v) == {"requirement", "subject", "check", "description", "expression", "inputs"}
	}
}

# The join every consumer would otherwise write by hand: description and
# expression come from the definition table, the rest from the row.
test_violations_join_the_definition_onto_the_row if {
	rep := evidence.report({"items": [{"id": "a", "signed": true}]}, violating_req)
	evidence.violations(rep) == [{
		"requirement": "s",
		"subject": {"type": "thing", "id": "a"},
		"check": "reviewed",
		"description": "Reviewed",
		"expression": "reviewed == true",
		"inputs": [{"name": "reviewed", "value": null}],
	}]
}

test_violations_default_a_missing_description_to_an_empty_string if {
	rep := evidence.report({"items": [{"id": "a"}]}, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
		"checks": {"undescribed": {"op": "equals", "path": ["x"], "value": 1}},
	}})
	v := evidence.violations(rep)
	count(v) == 1
	v[0].description == ""
	v[0].expression == "x == 1"
}

test_violations_exclude_passing_rows if {
	rep := evidence.report({"items": [{"id": "a", "signed": true}]}, violating_req)
	[v.check | some v in evidence.violations(rep)] == ["reviewed"]
}

# $min_subjects failures ARE breaches: "no subject at all" is exactly what that
# guard exists to report.
test_violations_include_min_subjects_failures if {
	rep := evidence.report({"items": []}, min_subjects_req(1))
	v := evidence.violations(rep)
	count(v) == 1
	v[0].check == "$min_subjects"
	v[0].subject == {"type": "thing", "id": null}
	v[0].description == "at least 1 matching thing subject(s) required"
}

# $applies failures are not: out of scope is not in breach. The requirement here
# is unsatisfied, so the exclusion is doing the work rather than passing
# vacuously.
test_violations_exclude_applies_rows if {
	doc := {"items": [
		{"id": "a", "state": "MERGED"},
		{"id": "b", "state": "CLOSED"},
	]}
	rep := evidence.report(doc, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
		"applies_to": merged_only,
		"checks": {"signed": {"op": "equals", "path": ["signed"], "value": true}},
	}})
	rep.requirements.s.satisfied == false

	# The out-of-scope subject did produce a failing $applies row...
	count([r | some r in rep.results; r.check == "$applies"; r.passed == false]) == 1

	# ...and only the in-scope subject's own failure is a violation.
	[[v.subject.id, v.check] | some v in evidence.violations(rep)] == [["a", "signed"]]
}

# The subtle one, and the reason this belongs in the library: under
# "require": "some" a satisfied requirement's failing rows are evidence, not
# breaches, because another subject met every check on its own. A consumer that
# re-derived this and forgot the guard would report violations while allow was
# true.
test_violations_exclude_rows_of_a_satisfied_requirement if {
	rep := evidence.report(
		{"items": [
			{"id": "a", "signed": true, "reviewed": true},
			{"id": "b", "signed": false, "reviewed": true},
		]},
		require_req("some"),
	)
	rep.requirements.s.satisfied == true
	count([r | some r in rep.results; r.passed == false]) == 1
	evidence.violations(rep) == []
}

test_violations_span_multiple_requirements if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	policy := {
		"first": {"subject_type": "t", "from": ["a"], "id": ["id"], "checks": {"c": {"op": "equals", "path": ["v"], "value": 1}}},
		"second": {"subject_type": "t", "from": ["b"], "id": ["id"], "checks": {"c": {"op": "equals", "path": ["v"], "value": 1}}},
	}
	{v.requirement | some v in evidence.violations(evidence.report(doc, policy))} == {"first", "second"}
}

# Order follows report.results, which is itself deterministic — a violation list
# that reordered between runs would be useless in a diff.
test_violations_follow_results_order if {
	rep := evidence.report({"items": [{"id": "a"}, {"id": "b"}]}, violating_req)
	from_rows := [[r.requirement, r.check, r.subject.id] |
		some r in rep.results
		r.passed == false
		r.check != "$applies"
	]
	[[v.requirement, v.check, v.subject.id] | some v in evidence.violations(rep)] == from_rows
}

test_a_requirement_without_checks_yields_a_violation if {
	rep := evidence.report({"items": [{"id": "a"}]}, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
	}})
	rep.compliant == false
	[v.check | some v in evidence.violations(rep)] == ["$well_formed"]
}

test_an_unknown_require_value_yields_a_violation if {
	rep := evidence.report(both_ok, require_req("most"))
	rep.compliant == false
	[v.check | some v in evidence.violations(rep)] == ["$well_formed"]
}

# The invariant the above two restore, swept across the declaration and input
# shapes that used to break it. 180 combinations; 69 of them once returned
# "denied, and nothing failed to say why".
scan_requires := ["every", "some", "most"]

scan_mins := [0, 1, 2]

scan_checksets := [{}, {"c": {"op": "present", "path": ["id"]}}]

scan_filters := [{}, {"m": {"op": "equals", "path": ["state"], "value": "MERGED"}}]

scan_docs := [
	{"items": []},
	{"items": [{"id": "a", "state": "MERGED"}]},
	{"items": [{"no_id": 1, "state": "MERGED"}]},
	{"items": [{"id": "a", "state": "MERGED"}, {"no_id": 1, "state": "MERGED"}]},
	{"items": [{"id": "a", "state": "CLOSED"}]},
]

scan_policy(rq, mn, cs, fl) := {"s": {
	"subject_type": "thing",
	"from": ["items"],
	"id": ["id"],
	"require": rq,
	"min_subjects": mn,
	"applies_to": fl,
	"checks": cs,
}}

test_an_unsatisfied_report_always_explains_itself if {
	unexplained := [rep |
		some rq in scan_requires
		some mn in scan_mins
		some cs in scan_checksets
		some fl in scan_filters
		some d in scan_docs
		rep := evidence.report(d, scan_policy(rq, mn, cs, fl))
		rep.compliant == false
		count(evidence.violations(rep)) == 0
	]
	count(unexplained) == 0
}

# Why a failing $well_formed row can never be swallowed by the satisfied-guard
# in violations(): every requirement_satisfied body opens with the same two
# conditions well_formed tests, so malformed implies unsatisfied. That is a
# structural property rather than a coincidence of these inputs, and this pins
# it against someone later relaxing one of those bodies.
test_a_malformed_requirement_is_never_satisfied if {
	malformed := [rep |
		some rq in scan_requires
		some mn in scan_mins
		some cs in scan_checksets
		some fl in scan_filters
		some d in scan_docs
		rep := evidence.report(d, scan_policy(rq, mn, cs, fl))
		rows_for(rep, "s", "$well_formed")[0].passed == false
	]

	# The sweep genuinely covers malformed declarations, so this isn't vacuous.
	count(malformed) > 0

	every rep in malformed {
		rep.requirements.s.satisfied == false
		count([v |
			some v in evidence.violations(rep)
			v.check == "$well_formed"
		]) == 1
	}
}

# ---------- regressions ----------
# One rule per bug this library shipped with, each naming the trap it fell into.

# Issue 1: value_at returns null for a missing field, and Rego's total order
# sorts null below every number and string, so lt/lte/ne pass vacuously —
# missing evidence reads as satisfied.
test_compare_lt_fails_when_the_left_side_is_missing if {
	verdict({"b": 5}, compare_ab("lt")) == false
}

test_compare_lte_fails_when_the_left_side_is_missing if {
	verdict({"b": 5}, compare_ab("lte")) == false
}

test_compare_gt_fails_when_the_right_side_is_missing if {
	verdict({"a": 5}, compare_ab("gt")) == false
}

test_compare_ne_fails_when_a_side_is_missing if {
	verdict({"b": 5}, compare_ab("ne")) == false
}

test_compare_eq_fails_when_both_sides_are_missing if {
	verdict({}, compare_ab("eq")) == false
}

test_compare_fails_across_mismatched_types if {
	verdict({"a": "10", "b": 5}, compare_ab("gt")) == false
}

# Issue 3: a requirement whose collection resolves to nothing — a typo in "from",
# a renamed field — satisfies an "every" requirement vacuously, so the report
# reads compliant. min_subjects guards this but is opt-in.
test_every_over_no_subjects_is_not_satisfied if {
	evidence.report({"items": []}, require_req("every")).requirements.s.satisfied == false
}

test_a_typo_in_the_subject_from_path_is_not_compliant if {
	evidence.report({"items": [{"id": "a"}]}, id_req(["itmes"])).compliant == false
}

test_a_policy_with_no_requirements_is_not_compliant if {
	evidence.report({"items": []}, {}).compliant == false
}

# Issue 4: the row labels itself count(<raw path>) but reports the count of
# subjects surviving the filter — here 1 of 2 — so the evidence row makes a false
# statement about the input it echoes.
test_min_subjects_row_labels_the_count_it_actually_reports if {
	scoped := {"s": object.union(min_subjects_req(1).s, {"applies_to": merged_only})}
	rep := evidence.report(two_states, scoped)
	row := rows_for(rep, "s", "$min_subjects")[0]
	row.inputs[0].value == 1
	row.inputs[0].name != "count(items)"
}

# Issue 5: a subject dropped by the filter leaves no trace beyond the
# total/matching delta — you cannot tell which subject was excluded, or why.
test_out_of_scope_subject_is_recorded_as_evidence if {
	rep := evidence.report(two_states, scoped_req(merged_only))
	some row in rep.results
	row.subject.id == "b"
}

# Issue 6: nothing enforced unique requirement names, so a row's
# (requirement, check) pair could resolve to two conflicting definitions. Naming
# requirements by object key makes duplicates unrepresentable — this asserts the
# property the old `name` field needed suffixing logic to keep.
test_requirement_names_are_unique_by_construction if {
	doc := {"a": [{"id": "A", "v": 1}], "b": [{"id": "B", "v": 9}]}
	policy := {
		"thing": {"subject_type": "thing", "from": ["a"], "id": ["id"], "checks": {"chk": {"op": "equals", "path": ["v"], "value": 1}}},
		"other_thing": {"subject_type": "thing", "from": ["b"], "id": ["id"], "checks": {"chk": {"op": "equals", "path": ["v"], "value": 2}}},
	}
	rep := evidence.report(doc, policy)
	every row in rep.results {
		count([def |
			some name, req in rep.requirements
			name == row.requirement
			some check_name, def in req.checks
			check_name == row.check
		]) == 1
	}
}

# Issue 7: synthetic checks are "$"-prefixed, so a policy is free to name a check
# min_subjects without its definition being overlaid by the library's or its rows
# colliding with them.
test_a_user_check_named_min_subjects_is_not_clobbered if {
	colliding := {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
		"min_subjects": 1,
		"checks": {"min_subjects": {"description": "user check", "op": "equals", "path": ["id"], "value": "zzz"}},
	}}
	rep := evidence.report({"items": [{"id": "a"}]}, colliding)

	rep.requirements.s.checks.min_subjects == {
		"description": "user check",
		"op": "equals",
		"path": ["id"],
		"value": "zzz",
		"expression": "id == zzz",
	}
	rep.requirements.s.checks["$min_subjects"].description == "at least 1 matching thing subject(s) required"

	count(rows_for(rep, "s", "min_subjects")) == 1
	rows_for(rep, "s", "min_subjects")[0].passed == false
	count(rows_for(rep, "s", "$min_subjects")) == 1
	rows_for(rep, "s", "$min_subjects")[0].passed == true
}

# Issue 10: req.checks is read directly rather than via object.get, so a
# requirement with no checks yields an unsatisfied verdict and zero rows
# explaining it.
test_a_requirement_without_checks_explains_itself if {
	rep := evidence.report({"items": [{"id": "a"}]}, {"s": {
		"subject_type": "thing",
		"from": ["items"],
		"id": ["id"],
	}})
	rep.requirements.s.satisfied == false
	count(rep.results) > 0
}

# Issue 11: a check declaring "value": null cannot distinguish an absent field
# from one explicitly set to null.
test_equals_null_does_not_pass_on_a_missing_field if {
	verdict({}, {"op": "equals", "path": ["x"], "value": null}) == false
}

# Issue 12: `all` requires an array but `any` does not, so `any` silently
# iterates the values of an object.
test_any_rejects_an_object_collection if {
	verdict({"approvers": {"a": {"state": "APPROVED"}}}, any_approved) == false
}

# Issue 13: "every commit is signed" over a subject with zero recorded commits
# is vacuous truth, not evidence of compliance.
test_all_over_an_empty_collection_is_not_a_pass if {
	verdict({"commits": []}, all_verified) == false
}
