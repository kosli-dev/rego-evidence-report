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

# A one-subject, one-clause report: the smallest thing that drives a clause end
# to end (subject resolution -> operator -> row -> definition table).
solo(subj, clause) := evidence.report(
	{"items": [subj]},
	[{
		"name": "s",
		"type": "thing",
		"path": ["items"],
		"id": ["id"],
		"clauses": {"c": clause},
	}],
)

# The verdict of the clause's own row (as opposed to the set's synthetic
# $min_count row). Reads the row rather than calling op_passed directly, so a
# clause that produces NO row fails the test (report totality) instead of
# quietly looking like a pass.
verdict(subj, clause) := row.passed if {
	some row in solo(subj, clause).results
	row.predicate == "c"
}

inputs_of(subj, clause) := row.inputs if {
	some row in solo(subj, clause).results
	row.predicate == "c"
}

rendered(subj, clause) := solo(subj, clause).sets[0].clauses.c.expression

rows_for(report, set_name, predicate) := [r |
	some r in report.results
	r.set == set_name
	r.predicate == predicate
]

# ---------- subject resolution ----------

id_set(path) := {
	"name": "s",
	"type": "thing",
	"path": path,
	"id": ["id"],
	"clauses": {"c": {"op": "present", "path": ["id"]}},
}

subject_counts(doc, path) := evidence.report(doc, [id_set(path)]).sets[0].subjects

test_array_path_yields_one_subject_per_element if {
	subject_counts({"items": [{"id": "a"}, {"id": "b"}]}, ["items"]) == {"total": 2, "matching": 2}
}

test_single_object_path_is_wrapped_as_one_subject if {
	subject_counts({"item": {"id": "a"}}, ["item"]) == {"total": 1, "matching": 1}
}

test_missing_path_yields_no_subjects if {
	subject_counts({"other": [{"id": "a"}]}, ["items"]) == {"total": 0, "matching": 0}
}

test_scalar_path_yields_no_subjects if {
	subject_counts({"items": "not-a-collection"}, ["items"]) == {"total": 0, "matching": 0}
}

test_empty_path_treats_the_whole_document_as_one_subject if {
	subject_counts({"id": "root"}, []) == {"total": 1, "matching": 1}
}

test_nested_path_resolves_through_objects if {
	subject_counts({"a": {"b": {"items": [{"id": "x"}]}}}, ["a", "b", "items"]) == {"total": 1, "matching": 1}
}

test_missing_id_path_yields_a_null_subject_id if {
	rep := evidence.report({"items": [{"no_id_here": 1}]}, [id_set(["items"])])
	some row in rep.results
	row.subject == {"type": "thing", "id": null}
}

test_subject_id_is_read_from_the_declared_path if {
	rep := evidence.report({"items": [{"id": "abc"}]}, [id_set(["items"])])
	some row in rep.results
	row.subject == {"type": "thing", "id": "abc"}
}

# ---------- where filters ----------

where_set(where) := {
	"name": "s",
	"type": "thing",
	"path": ["items"],
	"id": ["id"],
	"where": where,
	"clauses": {"c": {"op": "present", "path": ["id"]}},
}

merged_only := {"merged": {"op": "equals", "path": ["state"], "value": "MERGED"}}

two_states := {"items": [
	{"id": "a", "state": "MERGED"},
	{"id": "b", "state": "CLOSED"},
]}

test_where_narrows_matching_but_leaves_total_intact if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	rep.sets[0].subjects == {"total": 2, "matching": 1}
}

test_where_clauses_are_conjunctive if {
	both := object.union(merged_only, {"on_main": {"op": "equals", "path": ["base_ref"], "value": "main"}})
	doc := {"items": [
		{"id": "a", "state": "MERGED", "base_ref": "main"},
		{"id": "b", "state": "MERGED", "base_ref": "topic"},
	]}
	rep := evidence.report(doc, [where_set(both)])
	rep.sets[0].subjects == {"total": 2, "matching": 1}
}

test_where_excludes_subjects_whose_filtered_field_is_missing if {
	rep := evidence.report({"items": [{"id": "a"}]}, [where_set(merged_only)])
	rep.sets[0].subjects == {"total": 1, "matching": 0}
}

test_where_with_no_clauses_matches_everything if {
	rep := evidence.report(two_states, [where_set({})])
	rep.sets[0].subjects == {"total": 2, "matching": 2}
}

test_where_evaluates_the_filter_for_every_raw_subject if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	verdicts := {r.subject.id: r.passed |
		some r in rep.results
		r.predicate == "$matches_filter"
	}
	verdicts == {"a": true, "b": false}
}

test_filter_row_echoes_the_field_the_filter_read if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	some r in rep.results
	r.predicate == "$matches_filter"
	r.subject.id == "b"
	r.inputs == [{"name": "state", "value": "CLOSED"}]
}

test_filter_definition_renders_the_filter_expression if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	rep.sets[0].clauses["$matches_filter"].expression == "state == MERGED"
}

test_filter_definition_conjoins_multiple_filter_clauses if {
	both := object.union(merged_only, {"on_main": {"op": "equals", "path": ["base_ref"], "value": "main"}})
	rep := evidence.report(two_states, [where_set(both)])

	# Ordered by filter-clause name — "merged", then "on_main".
	rep.sets[0].clauses["$matches_filter"].expression == "state == MERGED and base_ref == main"
}

test_no_filter_means_no_filter_rows_or_definition if {
	rep := evidence.report(two_states, [id_set(["items"])])
	count([r | some r in rep.results; r.predicate == "$matches_filter"]) == 0
	not "$matches_filter" in object.keys(rep.sets[0].clauses)
}

# Excluded subjects are recorded, not evaluated: no clause rows for them.
test_where_excluded_subject_gets_no_clause_rows if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	ids := {r.subject.id | some r in rep.results; r.predicate == "c"}
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
	"clause": {"op": "equals", "path": ["verified"], "value": true},
}

any_approved := {
	"op": "any",
	"path": ["approvers"],
	"clause": {"op": "equals", "path": ["state"], "value": "APPROVED"},
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

test_all_without_a_leaf_clause_fails if {
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

test_any_without_a_leaf_clause_fails if {
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
	clause := {"op": "equals", "path": ["a", "b"], "value": 1}
	inputs_of({"a": {"b": 1}}, clause) == [{"name": "a.b", "value": 1}]
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

test_inputs_explicit_echo_wins if {
	clause := {"op": "present", "path": ["id"], "echo": [["author"], ["approvers"]]}
	inputs_of({"id": "x", "author": "alice", "approvers": []}, clause) == [
		{"name": "author", "value": "alice"},
		{"name": "approvers", "value": []},
	]
}

test_inputs_empty_when_a_clause_declares_neither_path_nor_echo if {
	inputs_of({"id": "x"}, {"op": "bespoke"}) == []
}

# An echo entry can also project a field across a collection, so a custom op
# reading commits[].timestamp can echo exactly that.
test_inputs_echo_can_project_across_a_collection if {
	clause := {"op": "bespoke", "echo": [{"path": ["commits"], "each": ["timestamp"]}]}
	inputs_of({"commits": [{"timestamp": 1}, {"timestamp": 2}]}, clause) == [{
		"name": "commits[].timestamp",
		"value": [1, 2],
	}]
}

test_inputs_echo_projection_over_a_missing_collection if {
	clause := {"op": "bespoke", "echo": [{"path": ["commits"], "each": ["timestamp"]}]}
	inputs_of({}, clause) == [{"name": "commits[].timestamp", "value": []}]
}

test_inputs_echo_mixes_paths_and_projections if {
	clause := {"op": "bespoke", "echo": [["author"], {"path": ["commits"], "each": ["sha1"]}]}
	inputs_of({"author": "alice", "commits": [{"sha1": "aaaa"}]}, clause) == [
		{"name": "author", "value": "alice"},
		{"name": "commits[].sha1", "value": ["aaaa"]},
	]
}

# ---------- clause definition table ----------

test_definition_carries_the_raw_spec_and_description if {
	clause := object.union(is_merged, {"description": "Merged"})
	def := solo({"state": "MERGED"}, clause).sets[0].clauses.c
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
	clause := {"op": "equals", "path": ["a", "b"], "value": 1}
	rendered({}, clause) == "a.b == 1"
}

test_declared_expression_wins_over_the_rendered_one if {
	clause := object.union(is_merged, {"expression": "state is MERGED"})
	rendered({}, clause) == "state is MERGED"
}

# A custom op the library cannot render gets an empty expression; the policy is
# expected to declare one (see examples/code_review.rego).
test_unrenderable_op_yields_an_empty_expression if rendered({}, {"op": "bespoke"}) == ""

# ---------- rows ----------

two_clause_set := {
	"name": "s",
	"type": "thing",
	"path": ["items"],
	"id": ["id"],
	"clauses": {
		"a": {"op": "present", "path": ["id"]},
		"b": {"op": "equals", "path": ["state"], "value": "MERGED"},
	},
}

test_one_row_per_subject_and_clause if {
	doc := {"items": [{"id": "a"}, {"id": "b"}]}
	rep := evidence.report(doc, [two_clause_set])
	count([r | some r in rep.results; not startswith(r.predicate, "$")]) == 4

	# ...plus the set's own $min_count row.
	count(rep.results) == 5
}

test_row_carries_exactly_the_documented_keys if {
	every row in solo({"state": "MERGED"}, is_merged).results {
		object.keys(row) == {"set", "subject", "predicate", "inputs", "passed"}
	}
}

test_rows_are_produced_even_for_an_empty_subject if {
	rep := evidence.report({"items": [{}]}, [two_clause_set])
	clause_rows := [r | some r in rep.results; not startswith(r.predicate, "$")]
	count(clause_rows) == 2
	every row in clause_rows {
		row.passed == false
	}
}

test_unknown_op_produces_a_failing_row_not_a_gap if {
	verdict({"id": "x"}, {"op": "no_such_op", "path": ["id"]}) == false
}

test_set_name_defaults_to_the_type if {
	rep := evidence.report({"items": [{"id": "a"}]}, [{
		"type": "thing",
		"path": ["items"],
		"clauses": {"c": has_fingerprint},
	}])
	rep.sets[0].name == "thing"
	rep.results[0].set == "thing"
}

test_set_name_defaults_to_subject_without_a_type if {
	rep := evidence.report({"items": [{"id": "a"}]}, [{
		"path": ["items"],
		"clauses": {"c": has_fingerprint},
	}])
	rep.sets[0].name == "subject"
	rep.results[0].subject.type == "subject"
}

test_rows_from_different_sets_are_labelled_separately if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	sets := [
		{"name": "first", "type": "t", "path": ["a"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
		{"name": "second", "type": "t", "path": ["b"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
	]
	rep := evidence.report(doc, sets)
	count(rows_for(rep, "first", "c")) == 1
	count(rows_for(rep, "second", "c")) == 1
}

# ---------- min_count ----------

min_count_set(n) := {
	"name": "s",
	"type": "thing",
	"path": ["items"],
	"id": ["id"],
	"min_count": n,
	"clauses": {"c": {"op": "present", "path": ["id"]}},
}

test_min_count_satisfied if {
	rep := evidence.report({"items": [{"id": "a"}]}, [min_count_set(1)])
	rows_for(rep, "s", "$min_count")[0].passed == true
	rep.sets[0].satisfied == true
}

test_min_count_violated_fails_the_set if {
	rep := evidence.report({"items": []}, [min_count_set(1)])
	rows_for(rep, "s", "$min_count")[0].passed == false
	rep.sets[0].satisfied == false
	rep.compliant == false
}

test_min_count_row_has_a_null_subject_id if {
	rep := evidence.report({"items": []}, [min_count_set(1)])
	rows_for(rep, "s", "$min_count")[0].subject == {"type": "thing", "id": null}
}

test_min_count_definition_is_in_the_clause_table if {
	rep := evidence.report({"items": []}, [min_count_set(2)])
	def := rep.sets[0].clauses["$min_count"]
	def.description == "at least 2 matching thing subject(s) required"
	def.expression == "count(matching(items)) >= 2"
}

# Opt-in would mean a typo'd path silently satisfies a set (issue 3), so every
# set gets the guard whether it asks for one or not.
test_min_count_defaults_to_one if {
	rep := evidence.report({"items": [{"id": "a"}]}, [id_set(["items"])])
	rows_for(rep, "s", "$min_count")[0].passed == true
	rep.sets[0].clauses["$min_count"].expression == "count(matching(items)) >= 1"
}

# ...and an explicit zero opts back into the vacuous pass, for a policy that
# really does mean "if there are any, they must all pass".
test_min_count_zero_permits_an_empty_collection if {
	rep := evidence.report({"items": []}, [min_count_set(0)])
	rows_for(rep, "s", "$min_count")[0].passed == true
	rep.sets[0].satisfied == true
}

test_min_count_counts_subjects_after_the_where_filter if {
	set_with_both := object.union(min_count_set(2), {"where": merged_only})
	rep := evidence.report(two_states, [set_with_both])
	rows_for(rep, "s", "$min_count")[0].passed == false
}

test_min_count_guards_a_missing_collection if {
	rep := evidence.report({}, [min_count_set(1)])
	rows_for(rep, "s", "$min_count")[0].passed == false
	rep.compliant == false
}

# ---------- quantifiers ----------

quantified_set(q) := {
	"name": "s",
	"type": "thing",
	"path": ["items"],
	"id": ["id"],
	"quantifier": q,
	"clauses": {
		"signed": {"op": "equals", "path": ["signed"], "value": true},
		"reviewed": {"op": "equals", "path": ["reviewed"], "value": true},
	},
}

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
	evidence.report(doc, [quantified_set("every")]).sets[0].satisfied == true
}

test_every_unsatisfied_when_one_subject_fails if {
	evidence.report(split_across_subjects, [quantified_set("every")]).sets[0].satisfied == false
}

test_some_satisfied_when_one_subject_passes_every_clause if {
	evidence.report(both_ok, [quantified_set("some")]).sets[0].satisfied == true
}

# The reason `some` exists: requirements may not be split across subjects.
test_some_unsatisfied_when_requirements_are_split_across_subjects if {
	evidence.report(split_across_subjects, [quantified_set("some")]).sets[0].satisfied == false
}

test_some_unsatisfied_without_subjects if {
	evidence.report({"items": []}, [quantified_set("some")]).sets[0].satisfied == false
}

test_some_still_records_rows_for_the_failing_subjects if {
	rep := evidence.report(
		{"items": [
			{"id": "a", "signed": true, "reviewed": true},
			{"id": "b", "signed": false, "reviewed": true},
		]},
		[quantified_set("some")],
	)
	rep.sets[0].satisfied == true
	count([r | some r in rep.results; r.passed == false]) == 1
}

test_quantifier_defaults_to_every if {
	rep := evidence.report(split_across_subjects, [quantified_set("every")])
	defaulted := evidence.report(split_across_subjects, [{
		"name": "s",
		"type": "thing",
		"path": ["items"],
		"id": ["id"],
		"clauses": quantified_set("every").clauses,
	}])
	defaulted.sets[0].quantifier == "every"
	defaulted.sets[0].satisfied == rep.sets[0].satisfied
}

test_unknown_quantifier_is_unsatisfied if {
	evidence.report(both_ok, [quantified_set("most")]).sets[0].satisfied == false
}

# ---------- report-level verdict ----------

test_compliant_when_every_set_is_satisfied if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	sets := [
		{"name": "first", "type": "t", "path": ["a"], "id": ["id"], "min_count": 1, "clauses": {"c": {"op": "present", "path": ["id"]}}},
		{"name": "second", "type": "t", "path": ["b"], "id": ["id"], "min_count": 1, "clauses": {"c": {"op": "present", "path": ["id"]}}},
	]
	evidence.report(doc, sets).compliant == true
}

test_not_compliant_when_any_set_is_unsatisfied if {
	doc := {"a": [{"id": "1"}], "b": [{"no_id": true}]}
	sets := [
		{"name": "first", "type": "t", "path": ["a"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
		{"name": "second", "type": "t", "path": ["b"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
	]
	evidence.report(doc, sets).compliant == false
}

test_report_has_one_entry_per_declared_set if {
	doc := {"a": [{"id": "1"}], "b": [{"id": "2"}]}
	sets := [
		{"name": "first", "type": "t", "path": ["a"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
		{"name": "second", "type": "t", "path": ["b"], "id": ["id"], "clauses": {"c": {"op": "present", "path": ["id"]}}},
	]
	rep := evidence.report(doc, sets)
	[s.name | some s in rep.sets] == ["first", "second"]
}

test_set_entry_carries_exactly_the_documented_keys if {
	rep := solo({"state": "MERGED"}, is_merged)
	object.keys(rep.sets[0]) == {"name", "quantifier", "satisfied", "subjects", "clauses"}
}

test_report_carries_exactly_the_documented_keys if {
	object.keys(solo({}, is_merged)) == {"compliant", "sets", "results"}
}

# Two evaluations of the same policy against the same input must be byte-equal,
# since the report is meant to be hashed and attested.
test_report_is_deterministic if {
	doc := {"items": [{"id": "b", "state": "MERGED"}, {"id": "a", "state": "CLOSED"}]}
	rep := evidence.report(doc, [two_clause_set])
	json.marshal(rep) == json.marshal(evidence.report(doc, [two_clause_set]))
}

# Every row must resolve to exactly one clause definition, which is the
# contract that lets a consumer read a row without the .rego source.
test_every_row_resolves_to_one_clause_definition if {
	rep := evidence.report(two_states, [object.union(min_count_set(1), {"where": merged_only})])
	every row in rep.results {
		count([def |
			some s in rep.sets
			s.name == row.set
			some name, def in s.clauses
			name == row.predicate
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

# Issue 3: a set whose collection resolves to nothing — a typo in `path`, a
# renamed field — satisfies an "every" quantifier vacuously, so the report
# reads compliant. min_count guards this but is opt-in.
test_every_over_no_subjects_is_not_satisfied if {
	evidence.report({"items": []}, [quantified_set("every")]).sets[0].satisfied == false
}

test_a_typo_in_the_subject_path_is_not_compliant if {
	evidence.report({"items": [{"id": "a"}]}, [id_set(["itmes"])]).compliant == false
}

test_a_report_with_no_sets_is_not_compliant if {
	evidence.report({"items": []}, []).compliant == false
}

# Issue 4: the row labels itself count(<raw path>) but reports the count of
# subjects surviving `where` — here 1 of 2 — so the evidence row makes a false
# statement about the input it echoes.
test_min_count_row_labels_the_count_it_actually_reports if {
	set_with_both := object.union(min_count_set(1), {"where": merged_only})
	rep := evidence.report(two_states, [set_with_both])
	row := rows_for(rep, "s", "$min_count")[0]
	row.inputs[0].value == 1
	row.inputs[0].name != "count(items)"
}

# Issue 5: a subject dropped by `where` leaves no trace beyond the
# total/matching delta — you cannot tell which subject was excluded, or why.
test_where_excluded_subject_is_recorded_as_evidence if {
	rep := evidence.report(two_states, [where_set(merged_only)])
	some row in rep.results
	row.subject.id == "b"
}

# Issue 6: nothing enforces unique set names, so a row's (set, predicate) can
# resolve to two conflicting definitions.
test_rows_resolve_to_one_definition_even_with_duplicate_set_names if {
	doc := {"a": [{"id": "A", "v": 1}], "b": [{"id": "B", "v": 9}]}
	sets := [
		{"name": "thing", "type": "thing", "path": ["a"], "id": ["id"], "clauses": {"chk": {"op": "equals", "path": ["v"], "value": 1}}},
		{"name": "thing", "type": "thing", "path": ["b"], "id": ["id"], "clauses": {"chk": {"op": "equals", "path": ["v"], "value": 2}}},
	]
	rep := evidence.report(doc, sets)
	every row in rep.results {
		count([def |
			some s in rep.sets
			s.name == row.set
			some name, def in s.clauses
			name == row.predicate
		]) == 1
	}
}

test_duplicate_set_names_are_suffixed_with_their_position if {
	doc := {"a": [{"id": "A", "v": 1}], "b": [{"id": "B", "v": 9}]}
	dup := {"name": "thing", "type": "thing", "path": ["a"], "id": ["id"], "clauses": {"chk": {"op": "equals", "path": ["v"], "value": 1}}}
	rep := evidence.report(doc, [dup, object.union(dup, {"path": ["b"]})])

	[s.name | some s in rep.sets] == ["thing", "thing#1"]
	{r.set | some r in rep.results} == {"thing", "thing#1"}
}

# Issue 7: synthetic predicates are "$"-prefixed, so a policy is free to name a
# clause min_count without its definition being overlaid by the library's or its
# rows colliding with them.
test_a_user_clause_named_min_count_is_not_clobbered if {
	set_with_collision := {
		"name": "s",
		"type": "thing",
		"path": ["items"],
		"id": ["id"],
		"min_count": 1,
		"clauses": {"min_count": {"description": "user clause", "op": "equals", "path": ["id"], "value": "zzz"}},
	}
	rep := evidence.report({"items": [{"id": "a"}]}, [set_with_collision])

	rep.sets[0].clauses.min_count == {
		"description": "user clause",
		"op": "equals",
		"path": ["id"],
		"value": "zzz",
		"expression": "id == zzz",
	}
	rep.sets[0].clauses["$min_count"].description == "at least 1 matching thing subject(s) required"

	count(rows_for(rep, "s", "min_count")) == 1
	rows_for(rep, "s", "min_count")[0].passed == false
	count(rows_for(rep, "s", "$min_count")) == 1
	rows_for(rep, "s", "$min_count")[0].passed == true
}

# Issue 10: set.clauses is read directly rather than via object.get, so a set
# with no clauses yields an unsatisfied verdict and zero rows explaining it.
test_a_set_without_clauses_explains_itself if {
	rep := evidence.report({"items": [{"id": "a"}]}, [{
		"name": "s",
		"type": "thing",
		"path": ["items"],
		"id": ["id"],
	}])
	rep.sets[0].satisfied == false
	count(rep.results) > 0
}

# Issue 11: a clause declaring "value": null cannot distinguish an absent field
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
