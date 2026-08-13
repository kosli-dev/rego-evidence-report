# kosli.evidence v5
#
# A policy declares an object mapping requirement names to requirements, and
# passes it to report():
#   {
#     "merged_pr": {
#       "subject_type": "pull_request",  # subject type label (default: "subject")
#       "from": [...],                   # collection location in input (array or single object)
#       "id": [...],                     # identity path within a subject
#       "require": "every"|"some",       # every subject passes / some subject passes ALL checks
#       "applies_to": {name: check},     # scope filter: only matching subjects are evaluated
#       "min_subjects": 1,               # matching subjects required (default 1; 0 opts into a vacuous pass)
#       "checks": {name: check}
#     }
#   }
#
# The requirement name is the object key, so names are unique by construction and
# a row's (requirement, check) pair always resolves to exactly one definition.
#
# Leaf check ops: range, excludes, includes, equals, present,
# non_empty_string, compare, compare_time.
# Collection ops: {"op": "all"|"any", "path": [...], "check": <leaf check>}
# (one nesting level: Rego forbids recursion). Both require a non-empty array:
# zero recorded elements is absence of evidence, not evidence of compliance.
# Custom ops: contribute op_passed(check, subj) bodies to this package from
# another file; give the check "expression" and "inputs" for report rendering.
#
# Note that "from" locates a collection in the input document, while a check's
# "path" locates a field within one subject. Two different roots, two different
# keywords.
#
# Report shape: report.requirements[<name>].checks is the definition table — one
# entry per check name, holding the raw check spec plus its rendered
# "expression". report.results[] rows carry only
# {requirement, subject, check, inputs, passed} — look up
# report.requirements[<requirement>].checks[<check>] for the description and
# expression instead of repeating them on every row.
#
# The report is a superset: it records every check that ran, passing or failing,
# in scope or out, because evidence that exonerates matters as much as evidence
# that convicts. evidence.violations(report) narrows it to the actionable
# subset — the failing rows that are breaches, joined to their descriptions. The
# selection is generic and lives here; formatting a message is the policy's job.
#
# Checks the library synthesises are "$"-prefixed, so they can never collide
# with a policy's own check names:
#   $well_formed  — the requirement asserts something satisfiable at all (one
#                   row per requirement; static, computed from the declaration)
#   $min_subjects — enough matching subjects (one row per requirement)
#   $applies      — subject is in scope under "applies_to" (one row per raw
#                   subject, only for requirements that declare a filter)
#
# Between them these keep the invariant that an unsatisfied requirement always
# produces at least one failing row to explain itself, so a denial is never
# silent.
#
# Fail-closed throughout: a missing, null or wrong-typed input makes a check
# fail rather than vanish, and a requirement that asserts nothing (no checks) or
# has nothing to assert against (no matching subjects) is not satisfied.
package kosli.evidence

import rego.v1

# ---------- requirement accessors ----------

checks_of(req) := object.get(req, "checks", {})

applies_to_of(req) := object.get(req, "applies_to", {})

from_of(req) := object.get(req, "from", [])

subject_type_of(req) := object.get(req, "subject_type", "subject")

# Guards the vacuous pass an empty collection would otherwise get. Explicit
# "min_subjects": 0 opts back into it.
min_subjects_of(req) := object.get(req, "min_subjects", 1)

require_of(req) := object.get(req, "require", "every")

# ---------- subject resolution ----------

raw_subjects(doc, req) := coll if {
	coll := object.get(doc, from_of(req), null)
	is_array(coll)
}

raw_subjects(doc, req) := [coll] if {
	coll := object.get(doc, from_of(req), null)
	is_object(coll)
}

raw_subjects(doc, req) := [] if {
	not is_array(object.get(doc, from_of(req), null))
	not is_object(object.get(doc, from_of(req), null))
}

matching_subjects(doc, req) := [subj |
	some subj in raw_subjects(doc, req)
	subject_matches(subj, req)
]

# Total, not partial: $applies rows carry this as a value, and an undefined
# verdict would drop the row for exactly the out-of-scope subjects the rows
# exist to record.
default subject_matches(_, _) := false

subject_matches(subj, req) if {
	every _, check in applies_to_of(req) {
		op_passed(check, subj)
	}
}

subject_ref(subj, req) := {
	"type": subject_type_of(req),
	"id": object.get(subj, object.get(req, "id", []), null),
}

# ---------- value helpers ----------

value_at(subj, path) := object.get(subj, path, null)

# Sentinel telling "field absent" apart from "field present and null", so a
# check comparing against null cannot be satisfied by a missing field.
absent := {"kosli.evidence/absent": true}

field(subj, path) := v if {
	v := object.get(subj, path, absent)
	v != absent
}

path_name(path) := concat(".", [sprintf("%v", [p]) | some p in path])

# ---------- leaf operators (element-level, non-recursive) ----------

default leaf_passed(_, _) := false

leaf_passed(check, subj) if {
	check.op == "range"
	v := value_at(subj, check.path)
	is_number(v)
	v >= check.min
	v <= check.max
}

leaf_passed(check, subj) if {
	check.op == "excludes"
	v := value_at(subj, check.path)
	is_array(v)
	not check.value in v
}

leaf_passed(check, subj) if {
	check.op == "includes"
	v := value_at(subj, check.path)
	is_array(v)
	check.value in v
}

leaf_passed(check, subj) if {
	check.op == "equals"
	field(subj, check.path) == check.value
}

leaf_passed(check, subj) if {
	check.op == "present"
	value_at(subj, check.path) != null
}

leaf_passed(check, subj) if {
	check.op == "non_empty_string"
	v := value_at(subj, check.path)
	is_string(v)
	v != ""
}

leaf_passed(check, subj) if {
	check.op == "matches_any"
	v := value_at(subj, check.path)
	is_string(v)
	some pattern in check.patterns
	is_string(pattern)
	regex.match(pattern, v)
}

# Every pattern is type-checked inside the `every`, so a non-string pattern fails
# the check rather than being skipped: `not regex.match(...)` on an erroring call
# is *true*, which would otherwise let a malformed exemption list wave everything
# through. A pattern that is a string but not valid regex remains the one input
# this cannot screen out, the same gap `rfc3339_shaped` documents.
#
# An empty pattern list makes this pass — nothing was excluded — while
# `matches_any` fails on one, which is the safe direction for each.
leaf_passed(check, subj) if {
	check.op == "not_matches_any"
	v := value_at(subj, check.path)
	is_string(v)
	every pattern in check.patterns {
		is_string(pattern)
		not regex.match(pattern, v)
	}
}

leaf_passed(check, subj) if {
	check.op == "compare"
	l := value_at(subj, check.left)
	r := value_at(subj, check.right)
	comparable(l, r)
	cmp(check.cmp, l, r)
}

leaf_passed(check, subj) if {
	check.op == "compare_time"
	l := value_at(subj, check.left)
	r := value_at(subj, check.right)
	rfc3339_shaped(l)
	rfc3339_shaped(r)
	cmp(check.cmp, time.parse_rfc3339_ns(l), time.parse_rfc3339_ns(r))
}

# Epoch numbers are as common as RFC3339 strings in practice — Kosli's own trails
# timestamp everything numerically — and rejecting them made a format mismatch
# indistinguishable from a stale timestamp. Only like compares with like: a number
# against a string satisfies neither body, so it stays fail-closed rather than
# coercing. Both sides must share a unit, which no value can reveal; seconds
# against milliseconds compares cleanly and means nothing.
leaf_passed(check, subj) if {
	check.op == "compare_time"
	l := value_at(subj, check.left)
	r := value_at(subj, check.right)
	is_number(l)
	is_number(r)
	cmp(check.cmp, l, r)
}

# Rego's comparison operators are total across types — null sorts below every
# number and string — so an unguarded "lt" against a missing field would pass.
# Both sides must be present and of the same type to be compared at all.
comparable(l, r) if {
	l != null
	type_name(l) == type_name(r)
}

# Validated before parsing, because time.parse_rfc3339_ns raises a builtin
# error on malformed input: undefined (hence a failing row) with default
# settings, but fatal to the whole evaluation under --strict-builtin-errors.
# Calendar-impossible dates that are still well-shaped (e.g. 2024-02-31) remain
# the one input this cannot screen out.
rfc3339_shaped(v) if {
	is_string(v)
	regex.match(`^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`, v)
}

default cmp(_, _, _) := false

cmp("eq", l, r) if l == r

cmp("ne", l, r) if l != r

cmp("gt", l, r) if l > r

cmp("gte", l, r) if l >= r

cmp("lt", l, r) if l < r

cmp("lte", l, r) if l <= r

# ---------- subject-level operators ----------

quantified(check) if check.op in {"all", "any"}

default op_passed(_, _) := false

op_passed(check, subj) if {
	not quantified(check)
	leaf_passed(check, subj)
}

op_passed(check, subj) if {
	check.op == "all"
	coll := value_at(subj, check.path)
	is_array(coll)
	count(coll) > 0
	every elem in coll {
		leaf_passed(check.check, elem)
	}
}

op_passed(check, subj) if {
	check.op == "any"
	coll := value_at(subj, check.path)
	is_array(coll)
	some elem in coll
	leaf_passed(check.check, elem)
}

# ---------- human-readable expressions ----------

default leaf_describe(_) := ""

leaf_describe(check) := sprintf("%s >= %v and %s <= %v", [n, check.min, n, check.max]) if {
	check.op == "range"
	n := path_name(check.path)
}

leaf_describe(check) := sprintf("not contains(%s, %v)", [path_name(check.path), check.value]) if check.op == "excludes"

leaf_describe(check) := sprintf("contains(%s, %v)", [path_name(check.path), check.value]) if check.op == "includes"

leaf_describe(check) := sprintf("%s == %v", [path_name(check.path), check.value]) if check.op == "equals"

leaf_describe(check) := sprintf("%s is present", [path_name(check.path)]) if check.op == "present"

leaf_describe(check) := sprintf("%s is a non-empty string", [path_name(check.path)]) if check.op == "non_empty_string"

leaf_describe(check) := sprintf("%s matches one of [%s]", [path_name(check.path), pattern_list(check)]) if check.op == "matches_any"

leaf_describe(check) := sprintf("%s matches none of [%s]", [path_name(check.path), pattern_list(check)]) if check.op == "not_matches_any"

# Sorted, so a pattern set written in any order renders identically — the report
# has to stay byte-identical to be worth hashing.
pattern_list(check) := concat(", ", sort([sprintf("%v", [p]) | some p in check.patterns]))

leaf_describe(check) := sprintf("%s %s %s", [path_name(check.left), check.cmp, path_name(check.right)]) if check.op in {"compare", "compare_time"}

default expression_of(_) := ""

expression_of(check) := check.expression

expression_of(check) := leaf_describe(check) if {
	not check.expression
	not quantified(check)
}

expression_of(check) := sprintf("every %s: %s", [path_name(check.path), leaf_describe(check.check)]) if {
	not check.expression
	check.op == "all"
}

expression_of(check) := sprintf("some %s: %s", [path_name(check.path), leaf_describe(check.check)]) if {
	not check.expression
	check.op == "any"
}

# ---------- inputs echoed per check ----------

two_sided(check) if check.op in {"compare", "compare_time"}

default check_inputs(_, _) := []

# An explicit "inputs" list wins (needed by custom ops). An entry is either a
# path, or {"path": [...], "each": [...]} to project a field across a collection
# the way the "all"/"any" ops project theirs.
check_inputs(subj, check) := [echoed(subj, spec) | some spec in check.inputs] if {
	check.inputs
}

echoed(subj, spec) := {"name": path_name(spec), "value": value_at(subj, spec)} if is_array(spec)

echoed(subj, spec) := {
	"name": sprintf("%s[].%s", [path_name(object.get(spec, "path", [])), path_name(object.get(spec, "each", []))]),
	"value": [value_at(elem, object.get(spec, "each", [])) | some elem in value_at(subj, object.get(spec, "path", []))],
} if is_object(spec)

check_inputs(subj, check) := [
	{"name": path_name(check.left), "value": value_at(subj, check.left)},
	{"name": path_name(check.right), "value": value_at(subj, check.right)},
] if {
	not check.inputs
	two_sided(check)
}

check_inputs(subj, check) := [{"name": nm, "value": vals}] if {
	not check.inputs
	quantified(check)
	vals := [value_at(elem, object.get(check.check, "path", [])) | some elem in value_at(subj, check.path)]
	nm := sprintf("%s[].%s", [path_name(check.path), path_name(object.get(check.check, "path", []))])
}

check_inputs(subj, check) := [{"name": path_name(check.path), "value": value_at(subj, check.path)}] if {
	not check.inputs
	not two_sided(check)
	not quantified(check)
	check.path
}

# ---------- check definitions (looked up once per requirement, not per row) ----------

# The raw check spec plus its rendered human-readable expression, keyed by check
# name so rows can reference {requirement, check} instead of repeating this on
# every row.
check_def(check) := object.union(check, {"expression": expression_of(check)})

matching_count_name(req) := sprintf("count(matching(%s))", [path_name(from_of(req))])

min_subjects_def(req) := {"$min_subjects": {
	"description": sprintf("at least %d matching %s subject(s) required", [min_subjects_of(req), subject_type_of(req)]),
	"expression": sprintf("%s >= %d", [matching_count_name(req), min_subjects_of(req)]),
}}

# A requirement declaring no checks, or an unrecognised "require", is
# unsatisfiable — the two verdict bodies below both test exactly these. Without
# a row saying so, such a requirement is denied while producing nothing that
# failed, which reads as "denied, no reason given". The condition is static: it
# depends on the declaration, never on the input document.
well_formed_def(_) := {"$well_formed": {
	"description": "the requirement declares at least one check and a recognised \"require\" value; lacking either, it asserts nothing that could ever be satisfied",
	"expression": "count(checks) >= 1 and require in {every, some}",
}}

default well_formed(_) := false

well_formed(req) if {
	count(checks_of(req)) > 0
	require_of(req) in {"every", "some"}
}

applies_def(req) := {"$applies": {
	"description": sprintf("subject is in scope as a %s under this requirement's applies_to filter; out-of-scope subjects are recorded but not evaluated", [subject_type_of(req)]),
	"expression": concat(" and ", [expression_of(applies_to_of(req)[name]) | some name in applies_to_names(req)]),
}} if count(applies_to_of(req)) > 0

applies_def(req) := {} if count(applies_to_of(req)) == 0

# Sorted so that rendered expressions and echoed inputs are deterministic.
applies_to_names(req) := sort(object.keys(applies_to_of(req)))

requirement_check_defs(req) := object.union(
	object.union(
		{name: check_def(check) | some name, check in checks_of(req)},
		min_subjects_def(req),
	),
	object.union(applies_def(req), well_formed_def(req)),
)

# ---------- rows ----------

subject_passed(req, subj) if {
	every _, check in checks_of(req) {
		op_passed(check, subj)
	}
}

subject_rows(doc, policy, req_name) := [row |
	some subj in matching_subjects(doc, policy[req_name])
	some check_name, check in checks_of(policy[req_name])
	row := {
		"requirement": req_name,
		"subject": subject_ref(subj, policy[req_name]),
		"check": check_name,
		"inputs": check_inputs(subj, check),
		"passed": op_passed(check, subj),
	}
]

# Takes no doc: the declaration is either well formed or it isn't, whatever the
# input happens to contain.
well_formed_row(policy, req_name) := {
	"requirement": req_name,
	"subject": {"type": subject_type_of(policy[req_name]), "id": null},
	"check": "$well_formed",
	"inputs": [
		{"name": "count(checks)", "value": count(checks_of(policy[req_name]))},
		{"name": "require", "value": require_of(policy[req_name])},
	],
	"passed": well_formed(policy[req_name]),
}

min_subjects_row(doc, policy, req_name) := {
	"requirement": req_name,
	"subject": {"type": subject_type_of(policy[req_name]), "id": null},
	"check": "$min_subjects",
	"inputs": [{"name": matching_count_name(policy[req_name]), "value": count(matching_subjects(doc, policy[req_name]))}],
	"passed": count(matching_subjects(doc, policy[req_name])) >= min_subjects_of(policy[req_name]),
}

# One row per raw subject, so a subject dropped by "applies_to" is still named in
# the evidence instead of surviving only as a total/matching discrepancy.
applies_rows(doc, policy, req_name) := [{
	"requirement": req_name,
	"subject": subject_ref(subj, policy[req_name]),
	"check": "$applies",
	"inputs": applies_inputs(subj, policy[req_name]),
	"passed": subject_matches(subj, policy[req_name]),
} |
	some subj in raw_subjects(doc, policy[req_name])
] if {
	count(applies_to_of(policy[req_name])) > 0
}

applies_rows(_, policy, req_name) := [] if count(applies_to_of(policy[req_name])) == 0

applies_inputs(subj, req) := [inp |
	some name in applies_to_names(req)
	some inp in check_inputs(subj, applies_to_of(req)[name])
]

# ---------- requirement verdicts ----------

default requirement_satisfied(_, _) := false

requirement_satisfied(doc, req) if {
	count(checks_of(req)) > 0
	require_of(req) == "every"
	count(matching_subjects(doc, req)) >= min_subjects_of(req)
	every subj in matching_subjects(doc, req) {
		subject_passed(req, subj)
	}
}

requirement_satisfied(doc, req) if {
	count(checks_of(req)) > 0
	require_of(req) == "some"
	count(matching_subjects(doc, req)) >= min_subjects_of(req)
	some subj in matching_subjects(doc, req)
	subject_passed(req, subj)
}

# "some" over nothing, where min_subjects: 0 explicitly opted into a vacuous
# pass. Without this, min_subjects: 0 would mean one thing under "every" (an
# empty collection is fine) and the opposite under "some" (an empty collection
# can never be satisfied, since no subject is there to pass) — and the "some"
# reading left the requirement denied with no failing row to explain it. The
# vacuous pass stays opt-in: the default min_subjects of 1 still denies.
requirement_satisfied(doc, req) if {
	count(checks_of(req)) > 0
	require_of(req) == "some"
	min_subjects_of(req) == 0
	count(matching_subjects(doc, req)) == 0
}

# ---------- report ----------

default all_satisfied(_, _) := false

# A policy declaring no requirements asserts nothing, so it cannot be compliant.
all_satisfied(doc, policy) if {
	count(policy) > 0
	count([name |
		some name, req in policy
		not requirement_satisfied(doc, req)
	]) == 0
}

# Ordered from the most general question to the most specific: is this
# requirement meaningful at all, were there enough subjects, was this subject in
# scope, did its checks pass.
results(doc, policy) := array.concat(
	array.concat(
		[well_formed_row(policy, name) | some name, _ in policy],
		[min_subjects_row(doc, policy, name) | some name, _ in policy],
	),
	array.concat(
		[row | some name, _ in policy; some row in applies_rows(doc, policy, name)],
		[row | some name, _ in policy; some row in subject_rows(doc, policy, name)],
	),
)

report(doc, policy) := {
	"compliant": all_satisfied(doc, policy),
	"requirements": {name: {
		"require": require_of(req),
		"satisfied": requirement_satisfied(doc, req),
		"subjects": {"total": count(raw_subjects(doc, req)), "matching": count(matching_subjects(doc, req))},
		"checks": requirement_check_defs(req),
	} |
		some name, req in policy
	},
	"results": results(doc, policy),
}

# ---------- violations ----------

# The actionable subset of a report: the failing rows that represent a breach,
# joined to their check definitions so a caller can render a message without a
# second lookup.
#
# A pure function of the report — no access to the input document or the policy
# — which is what makes this selection generic rather than something every
# consumer re-derives. Each of the three filters drops rows that are still
# evidence:
#   - passing rows;
#   - rows of a requirement that was satisfied anyway, since under
#     "require": "some" another subject met every check and these rows are
#     exculpatory rather than breaches;
#   - $applies rows, because out of scope is not in breach.
# $min_subjects rows are deliberately kept: "no subject at all" is a breach.
#
# Rendering is the caller's: entries are structured, never formatted strings.
# An array rather than a set, so order follows report.results (deterministic)
# and two distinct failures that happen to render alike are not collapsed.
#
# A $well_formed entry means the policy is broken rather than the thing being
# judged. Both kinds share this one list, $well_formed first — deliberate, since
# a malformed policy should be caught by its own tests. A "category" field is the
# additive escape hatch if that ever proves confusing.
violations(report) := [{
	"requirement": row.requirement,
	"subject": row.subject,
	"check": row.check,
	"description": definition_field(report, row, "description"),
	"expression": definition_field(report, row, "expression"),
	"inputs": row.inputs,
} |
	some row in report.results
	is_violation(report, row)
]

default is_violation(_, _) := false

is_violation(report, row) if {
	row.passed == false
	row.check != "$applies"
	not report.requirements[row.requirement].satisfied
}

# Looked up through the row's requirement, never by check name alone: two
# requirements may reuse a name for unrelated checks.
definition_field(report, row, key) := object.get(
	report.requirements,
	[row.requirement, "checks", row.check, key],
	"",
)
