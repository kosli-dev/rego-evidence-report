#!/usr/bin/env python3
"""Merge kosli.evidence and a policy into the single file `kosli evaluate` accepts.

`kosli evaluate --policy` takes ONE file, and the CLI parses it as a single module
whose package must be exactly `policy` (internal/evaluate/rego.go). So the library
cannot be imported on that path — it has to be textually merged, and merging
collides head-on with the CLI's own contract:

    rego_type_error: conflicting rules data.policy.report found
    rego_type_error: conflicting rules data.policy.violations found

`violations` is the structural one: the CLI reserves that rule name and the library
has a function of the same name. Same package, same name, different arity.

This renames the library's public API out of the way, then PROVES the merge was
behaviour-preserving by evaluating both forms against the same input and diffing
the reports. A rename that changed anything fails loudly instead of shipping.

    python3 fieldkit/bundle.py --policy examples/control_43.rego \
        --ops examples/control_43_ops.rego --verify-with input.json -o policy.rego

Nothing here is needed for the `opa eval` path, where the library imports normally
and the whole report is available. See INTEGRATION.md, "The seam has two doors".
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

# The library rules that collide with the names `kosli evaluate` reserves.
RESERVED = ("report", "violations")
PREFIX = "ev_"


def strip_headers(source, drop_import_evidence):
    source = re.sub(r"^package .*$", "", source, count=1, flags=re.M)
    source = re.sub(r"^import rego\.v1$", "", source, flags=re.M)
    if drop_import_evidence:
        source = re.sub(r"^import data\.kosli\.evidence$", "", source, flags=re.M)
    return source


def rename_library_api(source):
    """Rename the library's own rules. Comments move with them, which is correct:
    the prose should describe the rule as it is now named."""
    for name in RESERVED:
        source = re.sub(rf"\b{name}\b", PREFIX + name, source)
    # Two string literals name report FIELDS, not the rule, and must not move.
    return source.replace('"ev_report"', '"report"')


def rename_call_sites(source):
    for name in RESERVED:
        source = source.replace(f"evidence.{name}(", f"{PREFIX}{name}(")
    return source


def build(library, ops, policy):
    parts = [f"# ===== {library} (library API renamed {'/'.join(RESERVED)} -> {PREFIX}*) =====",
             rename_library_api(strip_headers(pathlib.Path(library).read_text(), False))]
    for path in list(ops) + [policy]:
        parts.append(f"# ===== {path} =====")
        parts.append(rename_call_sites(strip_headers(pathlib.Path(path).read_text(), True)))
    return "package policy\n\nimport rego.v1\n\n" + "\n".join(parts) + "\n"


def opa_eval(files, input_path, query):
    cmd = ["opa", "eval", "-f", "json", "-i", input_path]
    for f in files:
        cmd += ["-d", f]
    cmd.append(query)
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"opa eval failed for {query}:\n{out.stderr or out.stdout}")
    return json.loads(out.stdout)["result"][0]["expressions"][0]["value"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", default="src/library.rego")
    ap.add_argument("--policy", required=True, help="the policy file (its package is discarded)")
    ap.add_argument("--ops", nargs="*", default=[], help="custom-op files contributed into kosli.evidence")
    ap.add_argument("--package", default=None, help="the policy's package name, for --verify-with")
    ap.add_argument("--verify-with", metavar="INPUT.JSON",
                    help="prove the merge preserved behaviour by diffing both forms against this input")
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    bundle = build(args.library, args.ops, args.policy)
    pathlib.Path(args.out).write_text(bundle)

    check = subprocess.run(["opa", "check", "--strict", args.out], capture_output=True, text=True)
    if check.returncode != 0:
        sys.exit(f"bundle does not compile:\n{check.stderr or check.stdout}")
    print(f"wrote {args.out} ({len(bundle.splitlines())} lines), opa check --strict clean")

    if not args.verify_with:
        print("no --verify-with given: the merge is UNVERIFIED, only well-formed")
        return

    pkg = args.package or re.search(r"^package (\S+)", pathlib.Path(args.policy).read_text(), re.M).group(1)
    originals = [args.library] + args.ops + [args.policy]
    for field, merged_query in (("report", "data.policy.report"), ("allow", "data.policy.allow")):
        before = opa_eval(originals, args.verify_with, f"data.{pkg}.{field}")
        after = opa_eval([args.out], args.verify_with, merged_query)
        if before != after:
            sys.exit(f"MERGE CHANGED BEHAVIOUR on `{field}` — refusing to vouch for this bundle")
        print(f"  verified: {field} identical before and after the merge")

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(opa_eval([args.out], args.verify_with, "data.policy.report"), fh)
    print(f"  report from the bundle: {fh.name}")


if __name__ == "__main__":
    main()
