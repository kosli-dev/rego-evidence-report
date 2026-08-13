# Scratch policy for trying kosli.evidence against a real input document.
#
#   python3 fieldkit/kit.py shape trail.json          # find the paths
#   python3 fieldkit/kit.py run fieldkit/policy_template.rego trail.json
#
# `from` locates a collection in the INPUT DOCUMENT; a check's `path` locates a
# field within ONE SUBJECT. Every path is an array of string segments — exactly
# what `kit.py shape --rego` prints in its right-hand column.
#
# The whole operator vocabulary is listed at the bottom, so this file is the only
# reference you need on a machine that can't reach the README.
package scratch

import data.kosli.evidence
import rego.v1

requirements := {"thing": {
	"subject_type": "thing", # label that appears in every row's subject.type
	"from": ["REPLACE", "ME"], # where the subjects live in the input
	"id": ["id"], # how to identify one subject; unresolvable -> subject.id is null
	"require": "every", # "every" subject passes all checks | "some" ONE subject passes ALL
	"min_subjects": 1, # in-scope subjects required; 0 opts into a vacuous pass
	# Scope filter. Subjects failing any of these are out of scope, not in breach:
	# they get a $applies row and no check rows.
	"applies_to": {"in_scope": {
		"op": "equals",
		"path": ["state"],
		"value": "REPLACE_ME",
	}},
	"checks": {"something_true": {
		"description": "Plain-language statement of what must hold",
		"op": "present",
		"path": ["REPLACE_ME"],
	}},
}}

report := evidence.report(input, requirements)

# ---------------------------------------------------------------------------
# Operator vocabulary. Copy one of these into `checks` and edit.
#
# Leaf ops — one subject (or, inside all/any, one element):
#
#   {"op": "equals",           "path": [...], "value": X}
#   {"op": "present",          "path": [...]}
#   {"op": "non_empty_string", "path": [...]}
#   {"op": "range",            "path": [...], "min": 0, "max": 10}
#   {"op": "includes",         "path": [...], "value": X}   # array contains X
#   {"op": "excludes",         "path": [...], "value": X}
#   {"op": "compare",          "left": [...], "right": [...], "cmp": "gte"}
#   {"op": "compare_time",     "left": [...], "right": [...], "cmp": "lt"}
#
# cmp is eq | ne | gt | gte | lt | lte. compare takes TWO PATHS of the same
# subject, not a constant — to bound a field against a literal, use range.
#
# Collection ops — apply a nested check across a nested array (one level only;
# Rego forbids recursion). Both fail on a missing, non-array or EMPTY array:
#
#   {"op": "all", "path": ["commits"], "check": {"op": "equals", "path": ["verified"], "value": true}}
#   {"op": "any", "path": ["approvers"], "check": {"op": "equals", "path": ["state"], "value": "APPROVED"}}
#
# Custom op — when the vocabulary can't express it. Add an
# op_passed(check, subject) rule in a separate file declaring
# `package kosli.evidence` (see examples/code_review_ops.rego), pass it with
# --ops, and declare on the check the two things the library can't derive:
#
#   {"op": "my_op",
#    "expression": "human-readable form, since the library can't render yours",
#    "inputs": [["author"], {"path": ["commits"], "each": ["timestamp"]}]}
#
# `inputs` is every field the op reads, so the row still carries enough to
# recompute its verdict. A custom op is ordinary Rego: keeping it fail-closed is
# on you. Rego's comparisons are total across types — null < 5 is TRUE — so guard
# types explicitly.
# ---------------------------------------------------------------------------
