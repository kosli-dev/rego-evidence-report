# kosli.evidence v3
#
# A policy is a list of subject sets:
#   {
#     "name": "merged_pr",          # row linkage + set verdict key (default: type)
#     "type": "pull_request",       # subject type label
#     "path": [...],                # collection location in input (array or single object)
#     "id": [...],                  # identity path within a subject
#     "quantifier": "every"|"some", # every subject passes / some subject passes ALL clauses
#     "where": {name: clause},      # filter: only subjects passing these become subjects
#     "min_count": 1,               # guard against vacuous pass (counts filtered subjects)
#     "clauses": {name: clause}
#   }
#
# Leaf clause ops: range, excludes, includes, equals, present,
# non_empty_string, compare, compare_time.
# Collection ops: {"op": "all"|"any", "path": [...], "clause": <leaf clause>}
# (one nesting level: Rego forbids recursion).
# Custom ops: contribute op_passed(clause, subj) bodies to this package from
# another file; give the clause "expression" and "echo" for report rendering.
package kosli.evidence

import rego.v1

# ---------- subject resolution ----------

raw_subjects(doc, set) := coll if {
	coll := object.get(doc, object.get(set, "path", []), null)
	is_array(coll)
}

raw_subjects(doc, set) := [coll] if {
	coll := object.get(doc, object.get(set, "path", []), null)
	is_object(coll)
}

raw_subjects(doc, set) := [] if {
	not is_array(object.get(doc, object.get(set, "path", []), null))
	not is_object(object.get(doc, object.get(set, "path", []), null))
}

matching_subjects(doc, set) := [subj |
	some subj in raw_subjects(doc, set)
	subject_matches(subj, set)
]

subject_matches(subj, set) if {
	every _, clause in object.get(set, "where", {}) {
		op_passed(clause, subj)
	}
}

set_name(set) := object.get(set, "name", object.get(set, "type", "subject"))

quantifier(set) := object.get(set, "quantifier", "every")

subject_ref(subj, set) := {
	"type": object.get(set, "type", "subject"),
	"id": object.get(subj, object.get(set, "id", []), null),
}

# ---------- value helpers ----------

value_at(subj, path) := object.get(subj, path, null)

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
	value_at(subj, clause.path) == clause.value
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
	cmp(clause.cmp, value_at(subj, clause.left), value_at(subj, clause.right))
}

leaf_passed(clause, subj) if {
	clause.op == "compare_time"
	l := time.parse_rfc3339_ns(value_at(subj, clause.left))
	r := time.parse_rfc3339_ns(value_at(subj, clause.right))
	cmp(clause.cmp, l, r)
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
	every elem in coll {
		leaf_passed(clause.clause, elem)
	}
}

op_passed(clause, subj) if {
	clause.op == "any"
	some elem in value_at(subj, clause.path)
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

# Explicit echo list wins (needed by custom ops).
clause_inputs(subj, clause) := [{"name": path_name(p), "value": value_at(subj, p)} | some p in clause.echo] if {
	clause.echo
}

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

# ---------- rows ----------

subject_passed(set, subj) if {
	every _, clause in set.clauses {
		op_passed(clause, subj)
	}
}

subject_rows(doc, set) := [row |
	some subj in matching_subjects(doc, set)
	some name, clause in set.clauses
	row := {
		"set": set_name(set),
		"subject": subject_ref(subj, set),
		"predicate": name,
		"description": object.get(clause, "description", ""),
		"expression": expression_of(clause),
		"inputs": clause_inputs(subj, clause),
		"passed": op_passed(clause, subj),
	}
]

meta_rows(doc, set) := [{
	"set": set_name(set),
	"subject": {"type": object.get(set, "type", "subject"), "id": null},
	"predicate": "min_count",
	"description": sprintf("at least %d matching %s subject(s) required", [set.min_count, object.get(set, "type", "subject")]),
	"expression": sprintf("count(%s) >= %d", [path_name(object.get(set, "path", [])), set.min_count]),
	"inputs": [{"name": sprintf("count(%s)", [path_name(object.get(set, "path", []))]), "value": count(matching_subjects(doc, set))}],
	"passed": count(matching_subjects(doc, set)) >= set.min_count,
}] if {
	set.min_count
}

meta_rows(_, set) := [] if not set.min_count

# ---------- set verdicts ----------

default set_satisfied(_, _) := false

set_satisfied(doc, set) if {
	quantifier(set) == "every"
	every row in meta_rows(doc, set) { row.passed }
	every subj in matching_subjects(doc, set) {
		subject_passed(set, subj)
	}
}

set_satisfied(doc, set) if {
	quantifier(set) == "some"
	every row in meta_rows(doc, set) { row.passed }
	some subj in matching_subjects(doc, set)
	subject_passed(set, subj)
}

# ---------- report ----------

results(doc, sets) := array.concat(
	[row | some set in sets; some row in meta_rows(doc, set)],
	[row | some set in sets; some row in subject_rows(doc, set)],
)

report(doc, sets) := {
	"compliant": count([s | some s in sets; not set_satisfied(doc, s)]) == 0,
	"sets": [{
		"name": set_name(set),
		"quantifier": quantifier(set),
		"satisfied": set_satisfied(doc, set),
		"subjects": {"total": count(raw_subjects(doc, set)), "matching": count(matching_subjects(doc, set))},
	} |
		some set in sets
	],
	"results": results(doc, sets),
}
