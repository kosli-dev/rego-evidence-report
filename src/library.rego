# kosli.evidence v4
#
# A policy is a list of subject sets:
#   {
#     "name": "merged_pr",          # row linkage + set verdict key (default: type)
#     "type": "pull_request",       # subject type label
#     "path": [...],                # collection location in input (array or single object)
#     "id": [...],                  # identity path within a subject
#     "quantifier": "every"|"some", # every subject passes / some subject passes ALL clauses
#     "where": {name: clause},      # filter: only subjects passing these become subjects
#     "min_count": 1,               # matching subjects required (default 1; 0 opts into a vacuous pass)
#     "clauses": {name: clause}
#   }
#
# Leaf clause ops: range, excludes, includes, equals, present,
# non_empty_string, compare, compare_time.
# Collection ops: {"op": "all"|"any", "path": [...], "clause": <leaf clause>}
# (one nesting level: Rego forbids recursion). Both require a non-empty array:
# zero recorded elements is absence of evidence, not evidence of compliance.
# Custom ops: contribute op_passed(clause, subj) bodies to this package from
# another file; give the clause "expression" and "echo" for report rendering.
#
# Report shape: report.sets[].clauses is the definition table — one entry per
# predicate name, holding the raw clause spec plus its rendered "expression".
# report.results[] rows carry only {set, subject, predicate, inputs, passed} —
# look up report.sets[<set>].clauses[<predicate>] for the description and
# expression instead of repeating them on every row.
#
# Predicates the library synthesises are "$"-prefixed, so they can never
# collide with a policy's own clause names:
#   $min_count      — enough matching subjects (one row per set)
#   $matches_filter — subject satisfied "where" (one row per raw subject,
#                     only for sets that declare a filter)
#
# Fail-closed throughout: a missing, null or wrong-typed input makes a clause
# fail rather than vanish, and a set that asserts nothing (no clauses) or has
# nothing to assert against (no matching subjects) is not satisfied.
package kosli.evidence

import rego.v1

# ---------- set accessors ----------

clauses_of(set) := object.get(set, "clauses", {})

where_of(set) := object.get(set, "where", {})

path_of(set) := object.get(set, "path", [])

type_of(set) := object.get(set, "type", "subject")

# Guards the vacuous pass an empty collection would otherwise get. Explicit
# "min_count": 0 opts back into it.
min_count_of(set) := object.get(set, "min_count", 1)

quantifier(set) := object.get(set, "quantifier", "every")

set_name(set) := object.get(set, "name", type_of(set))

# Rows and set entries are linked by name, so names have to be unique: a
# duplicate is suffixed with its position rather than silently shadowing the
# first set's clause definitions.
set_key(sets, i) := set_name(sets[i]) if {
	count(earlier_with_same_name(sets, i)) == 0
}

set_key(sets, i) := sprintf("%s#%d", [set_name(sets[i]), i]) if {
	count(earlier_with_same_name(sets, i)) > 0
}

earlier_with_same_name(sets, i) := [j |
	some j, s in sets
	j < i
	set_name(s) == set_name(sets[i])
]

# ---------- subject resolution ----------

raw_subjects(doc, set) := coll if {
	coll := object.get(doc, path_of(set), null)
	is_array(coll)
}

raw_subjects(doc, set) := [coll] if {
	coll := object.get(doc, path_of(set), null)
	is_object(coll)
}

raw_subjects(doc, set) := [] if {
	not is_array(object.get(doc, path_of(set), null))
	not is_object(object.get(doc, path_of(set), null))
}

matching_subjects(doc, set) := [subj |
	some subj in raw_subjects(doc, set)
	subject_matches(subj, set)
]

# Total, not partial: $matches_filter rows carry this as a value, and an
# undefined verdict would drop the row for exactly the excluded subjects the
# rows exist to record.
default subject_matches(_, _) := false

subject_matches(subj, set) if {
	every _, clause in where_of(set) {
		op_passed(clause, subj)
	}
}

subject_ref(subj, set) := {
	"type": type_of(set),
	"id": object.get(subj, object.get(set, "id", []), null),
}

# ---------- value helpers ----------

value_at(subj, path) := object.get(subj, path, null)

# Sentinel telling "field absent" apart from "field present and null", so a
# clause comparing against null cannot be satisfied by a missing field.
absent := {"kosli.evidence/absent": true}

field(subj, path) := v if {
	v := object.get(subj, path, absent)
	v != absent
}

path_name(path) := concat(".", [sprintf("%v", [p]) | some p in path])

# ---------- leaf operators (element-level, non-recursive) ----------

default leaf_passed(_, _) := false

leaf_passed(clause, subj) if {
	clause.op == "range"
	v := value_at(subj, clause.path)
	is_number(v)
	v >= clause.min
	v <= clause.max
}

leaf_passed(clause, subj) if {
	clause.op == "excludes"
	v := value_at(subj, clause.path)
	is_array(v)
	not clause.value in v
}

leaf_passed(clause, subj) if {
	clause.op == "includes"
	v := value_at(subj, clause.path)
	is_array(v)
	clause.value in v
}

leaf_passed(clause, subj) if {
	clause.op == "equals"
	field(subj, clause.path) == clause.value
}

leaf_passed(clause, subj) if {
	clause.op == "present"
	value_at(subj, clause.path) != null
}

leaf_passed(clause, subj) if {
	clause.op == "non_empty_string"
	v := value_at(subj, clause.path)
	is_string(v)
	v != ""
}

leaf_passed(clause, subj) if {
	clause.op == "compare"
	l := value_at(subj, clause.left)
	r := value_at(subj, clause.right)
	comparable(l, r)
	cmp(clause.cmp, l, r)
}

leaf_passed(clause, subj) if {
	clause.op == "compare_time"
	l := value_at(subj, clause.left)
	r := value_at(subj, clause.right)
	rfc3339_shaped(l)
	rfc3339_shaped(r)
	cmp(clause.cmp, time.parse_rfc3339_ns(l), time.parse_rfc3339_ns(r))
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

quantified(clause) if clause.op in {"all", "any"}

default op_passed(_, _) := false

op_passed(clause, subj) if {
	not quantified(clause)
	leaf_passed(clause, subj)
}

op_passed(clause, subj) if {
	clause.op == "all"
	coll := value_at(subj, clause.path)
	is_array(coll)
	count(coll) > 0
	every elem in coll {
		leaf_passed(clause.clause, elem)
	}
}

op_passed(clause, subj) if {
	clause.op == "any"
	coll := value_at(subj, clause.path)
	is_array(coll)
	some elem in coll
	leaf_passed(clause.clause, elem)
}

# ---------- human-readable expressions ----------

default leaf_describe(_) := ""

leaf_describe(clause) := sprintf("%s >= %v and %s <= %v", [n, clause.min, n, clause.max]) if {
	clause.op == "range"
	n := path_name(clause.path)
}

leaf_describe(clause) := sprintf("not contains(%s, %v)", [path_name(clause.path), clause.value]) if clause.op == "excludes"

leaf_describe(clause) := sprintf("contains(%s, %v)", [path_name(clause.path), clause.value]) if clause.op == "includes"

leaf_describe(clause) := sprintf("%s == %v", [path_name(clause.path), clause.value]) if clause.op == "equals"

leaf_describe(clause) := sprintf("%s is present", [path_name(clause.path)]) if clause.op == "present"

leaf_describe(clause) := sprintf("%s is a non-empty string", [path_name(clause.path)]) if clause.op == "non_empty_string"

leaf_describe(clause) := sprintf("%s %s %s", [path_name(clause.left), clause.cmp, path_name(clause.right)]) if clause.op in {"compare", "compare_time"}

default expression_of(_) := ""

expression_of(clause) := clause.expression

expression_of(clause) := leaf_describe(clause) if {
	not clause.expression
	not quantified(clause)
}

expression_of(clause) := sprintf("every %s: %s", [path_name(clause.path), leaf_describe(clause.clause)]) if {
	not clause.expression
	clause.op == "all"
}

expression_of(clause) := sprintf("some %s: %s", [path_name(clause.path), leaf_describe(clause.clause)]) if {
	not clause.expression
	clause.op == "any"
}

# ---------- inputs echoed per clause ----------

two_sided(clause) if clause.op in {"compare", "compare_time"}

default clause_inputs(_, _) := []

# Explicit echo list wins (needed by custom ops). An entry is either a path, or
# {"path": [...], "each": [...]} to project a field across a collection the way
# the "all"/"any" ops echo theirs.
clause_inputs(subj, clause) := [echoed(subj, spec) | some spec in clause.echo] if {
	clause.echo
}

echoed(subj, spec) := {"name": path_name(spec), "value": value_at(subj, spec)} if is_array(spec)

echoed(subj, spec) := {
	"name": sprintf("%s[].%s", [path_name(object.get(spec, "path", [])), path_name(object.get(spec, "each", []))]),
	"value": [value_at(elem, object.get(spec, "each", [])) | some elem in value_at(subj, object.get(spec, "path", []))],
} if is_object(spec)

clause_inputs(subj, clause) := [
	{"name": path_name(clause.left), "value": value_at(subj, clause.left)},
	{"name": path_name(clause.right), "value": value_at(subj, clause.right)},
] if {
	not clause.echo
	two_sided(clause)
}

clause_inputs(subj, clause) := [{"name": nm, "value": vals}] if {
	not clause.echo
	quantified(clause)
	vals := [value_at(elem, object.get(clause.clause, "path", [])) | some elem in value_at(subj, clause.path)]
	nm := sprintf("%s[].%s", [path_name(clause.path), path_name(object.get(clause.clause, "path", []))])
}

clause_inputs(subj, clause) := [{"name": path_name(clause.path), "value": value_at(subj, clause.path)}] if {
	not clause.echo
	not two_sided(clause)
	not quantified(clause)
	clause.path
}

# ---------- clause definitions (looked up once per set, not per row) ----------

# The raw clause spec plus its rendered human-readable expression, keyed by
# predicate name so rows can reference {set, predicate} instead of repeating
# this on every row.
clause_def(clause) := object.union(clause, {"expression": expression_of(clause)})

matching_count_name(set) := sprintf("count(matching(%s))", [path_name(path_of(set))])

min_count_def(set) := {"$min_count": {
	"description": sprintf("at least %d matching %s subject(s) required", [min_count_of(set), type_of(set)]),
	"expression": sprintf("%s >= %d", [matching_count_name(set), min_count_of(set)]),
}}

filter_def(set) := {"$matches_filter": {
	"description": sprintf("subject qualifies as a %s under this set's filter; non-matching subjects are recorded but not evaluated", [type_of(set)]),
	"expression": concat(" and ", [expression_of(where_of(set)[name]) | some name in where_names(set)]),
}} if count(where_of(set)) > 0

filter_def(set) := {} if count(where_of(set)) == 0

# Sorted so that rendered expressions and echoed inputs are deterministic.
where_names(set) := sort(object.keys(where_of(set)))

set_clause_defs(set) := object.union(
	object.union(
		{name: clause_def(clause) | some name, clause in clauses_of(set)},
		min_count_def(set),
	),
	filter_def(set),
)

# ---------- rows ----------

subject_passed(set, subj) if {
	every _, clause in clauses_of(set) {
		op_passed(clause, subj)
	}
}

subject_rows(doc, sets, i) := [row |
	some subj in matching_subjects(doc, sets[i])
	some name, clause in clauses_of(sets[i])
	row := {
		"set": set_key(sets, i),
		"subject": subject_ref(subj, sets[i]),
		"predicate": name,
		"inputs": clause_inputs(subj, clause),
		"passed": op_passed(clause, subj),
	}
]

min_count_row(doc, sets, i) := {
	"set": set_key(sets, i),
	"subject": {"type": type_of(sets[i]), "id": null},
	"predicate": "$min_count",
	"inputs": [{"name": matching_count_name(sets[i]), "value": count(matching_subjects(doc, sets[i]))}],
	"passed": count(matching_subjects(doc, sets[i])) >= min_count_of(sets[i]),
}

# One row per raw subject, so a subject dropped by "where" is still named in the
# evidence instead of surviving only as a total/matching discrepancy.
filter_rows(doc, sets, i) := [{
	"set": set_key(sets, i),
	"subject": subject_ref(subj, sets[i]),
	"predicate": "$matches_filter",
	"inputs": filter_inputs(subj, sets[i]),
	"passed": subject_matches(subj, sets[i]),
} |
	some subj in raw_subjects(doc, sets[i])
] if {
	count(where_of(sets[i])) > 0
}

filter_rows(_, sets, i) := [] if count(where_of(sets[i])) == 0

filter_inputs(subj, set) := [inp |
	some name in where_names(set)
	some inp in clause_inputs(subj, where_of(set)[name])
]

# ---------- set verdicts ----------

default set_satisfied(_, _) := false

set_satisfied(doc, set) if {
	count(clauses_of(set)) > 0
	quantifier(set) == "every"
	count(matching_subjects(doc, set)) >= min_count_of(set)
	every subj in matching_subjects(doc, set) {
		subject_passed(set, subj)
	}
}

set_satisfied(doc, set) if {
	count(clauses_of(set)) > 0
	quantifier(set) == "some"
	count(matching_subjects(doc, set)) >= min_count_of(set)
	some subj in matching_subjects(doc, set)
	subject_passed(set, subj)
}

# ---------- report ----------

default all_satisfied(_, _) := false

# A policy declaring no sets asserts nothing, so it cannot be compliant.
all_satisfied(doc, sets) if {
	count(sets) > 0
	count([s | some s in sets; not set_satisfied(doc, s)]) == 0
}

results(doc, sets) := array.concat(
	array.concat(
		[min_count_row(doc, sets, i) | some i, _ in sets],
		[row | some i, _ in sets; some row in filter_rows(doc, sets, i)],
	),
	[row | some i, _ in sets; some row in subject_rows(doc, sets, i)],
)

report(doc, sets) := {
	"compliant": all_satisfied(doc, sets),
	"sets": [{
		"name": set_key(sets, i),
		"quantifier": quantifier(sets[i]),
		"satisfied": set_satisfied(doc, sets[i]),
		"subjects": {"total": count(raw_subjects(doc, sets[i])), "matching": count(matching_subjects(doc, sets[i]))},
		"clauses": set_clause_defs(sets[i]),
	} |
		some i, _ in sets
	],
	"results": results(doc, sets),
}
