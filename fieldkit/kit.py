#!/usr/bin/env python3
"""Field kit for trying kosli.evidence against real input documents.

Two subcommands:

    kit.py shape <input.json>              describe an input document's structure
    kit.py run <policy.rego> <input.json>  evaluate a policy and tabulate the rows

`shape` never prints a value, only paths, types and how often each field is
actually present. Its output is therefore safe to carry out of a restricted
environment; `run` output contains real values and is not.

Python 3 standard library only. `run` needs `opa` on PATH.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIBRARY = os.path.join(os.path.dirname(HERE), "src", "library.rego")


# ---------------------------------------------------------------- shape


def typename(node):
    if node is None:
        return "null"
    if isinstance(node, bool):
        return "bool"
    if isinstance(node, (int, float)):
        return "number"
    if isinstance(node, str):
        return "string"
    if isinstance(node, list):
        return "array"
    if isinstance(node, dict):
        return "object"
    return "?"


def walk(node, path, stats):
    """Accumulate {path: {types, seen}}. Array elements share one path, so a
    3-element array contributes seen=3 to `foo[]` and to each of its keys."""
    rec = stats.setdefault(path, {"types": set(), "seen": 0})
    rec["seen"] += 1
    rec["types"].add(typename(node))
    if isinstance(node, dict):
        for key, value in node.items():
            walk(value, path + (key,), stats)
    elif isinstance(node, list):
        for item in node:
            walk(item, path + ("[]",), stats)


def render_path(path):
    if not path:
        return "(root)"
    out = ""
    for seg in path:
        if seg == "[]":
            out += "[]"
        else:
            out += ("." if out else "") + seg
    return out


def rego_path(path):
    """The dotted path as a Rego path array: array indices drop out, because a
    check's `path` addresses one subject, not one element."""
    return "[%s]" % ", ".join('"%s"' % seg for seg in path if seg != "[]")


def cmd_shape(args):
    with open(args.input) as handle:
        doc = json.load(handle)

    stats = {}
    walk(doc, (), stats)

    # A field's denominator is its parent's occurrence count: for `commits[].verified`
    # that is the number of commits, which is what makes "2/3" mean "one commit has
    # no verified field" — the fail-closed cases, spotted before running anything.
    rows = []
    for path in sorted(stats):
        if args.depth and len(path) > args.depth:
            continue
        rec = stats[path]
        parent = stats.get(path[:-1])
        presence = ""
        if path and path[-1] == "[]":
            # For elements the ratio would conflate "how many elements" with "how
            # many arrays"; the element total is the number `all`/`any` turn on.
            presence = "n=%d" % rec["seen"]
        elif parent and parent["seen"] > 1:
            presence = "%d/%d" % (rec["seen"], parent["seen"])
        label = render_path(path) if args.paths or args.rego else (
            "  " * len(path) + (path[-1] if path else "(root)"))
        rows.append((label, "|".join(sorted(rec["types"])), presence, path))

    # Truncate wide sibling groups so a map keyed by data (one entry per artifact,
    # per environment) doesn't bury the rest of the document.
    totals = {}
    for row in rows:
        parent = row[3][:-1]
        totals[parent] = totals.get(parent, 0) + 1

    keep, counts, dropped = [], {}, set()
    for row in rows:
        path = row[3]
        # A truncated key takes its whole subtree with it, or the children show up
        # indented under a parent that was never printed.
        if any(path[:n] in dropped for n in range(1, len(path))):
            continue
        parent = path[:-1]
        counts[parent] = counts.get(parent, 0) + 1
        if counts[parent] <= args.max_children:
            keep.append(row)
            continue
        dropped.add(path)
        if counts[parent] == args.max_children + 1:
            keep.append(("  " * len(path) + "… %d more, use --max-children" % (
                totals[parent] - args.max_children), "", "", parent))

    width = max(len(r[0]) for r in keep)
    for text, types, presence, path in keep:
        line = "%-*s  %-14s %s" % (width, text, types, presence)
        if args.rego and path and path[-1] != "[]":
            line = "%-*s  %s" % (width + 22, line.rstrip(), rego_path(path))
        print(line.rstrip())

    print("\n%d distinct paths, no values printed. "
          "The n/N column counts how many siblings actually carry the field — "
          "anything short of N is a fail-closed candidate." % len(stats))
    return 0


# ---------------------------------------------------------------- run


def package_of(policy_path):
    with open(policy_path) as handle:
        for line in handle:
            match = re.match(r"\s*package\s+([\w.]+)", line)
            if match:
                return match.group(1)
    raise SystemExit("no `package` declaration found in %s" % policy_path)


def opa_eval(query, files, input_path):
    cmd = ["opa", "eval", "--format=json", "-i", input_path]
    for path in files:
        cmd += ["-d", path]
    cmd.append(query)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        raise SystemExit(
            "opa not found on PATH.\n"
            "It is a single static binary: https://openpolicyagent.org/docs/latest/#running-opa\n"
            "If downloads are blocked, check for an internal artifact mirror."
        )
    if proc.returncode != 0:
        raise SystemExit("opa eval failed:\n%s" % (proc.stderr or proc.stdout).strip())
    parsed = json.loads(proc.stdout)
    results = parsed.get("result") or []
    if not results:
        return None
    return results[0]["expressions"][0]["value"]


def brief(value, limit=60):
    text = json.dumps(value)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def brief_id(ident, limit=30):
    """Subject ids are usually URLs or fingerprints, which differ at the tail —
    so keep the tail and drop the head."""
    if ident is None:
        return "(requirement-level)"
    text = ident if isinstance(ident, str) else json.dumps(ident)
    return text if len(text) <= limit else "…" + text[-(limit - 1):]


def cmd_run(args):
    package = package_of(args.policy)
    files = [args.library, args.policy] + list(args.ops or []) + list(args.data or [])
    for path in files:
        if not os.path.exists(path):
            raise SystemExit("no such file: %s" % path)

    report = opa_eval("data.%s.report" % package, files, args.input)
    if report is None:
        raise SystemExit(
            "data.%s.report is undefined — the policy did not evaluate.\n"
            "Try: opa check --strict %s" % (package, " ".join(files))
        )

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    results = report.get("results", [])
    failing = [row for row in results if row.get("passed") is False]
    print("compliant: %s" % json.dumps(report.get("compliant")))
    print("%d rows, %d failing\n" % (len(results), len(failing)))

    for name in sorted(report.get("requirements", {})):
        req = report["requirements"][name]
        subjects = req.get("subjects", {})
        print("  %-24s satisfied=%-5s require=%-5s subjects=%s/%s matching" % (
            name,
            json.dumps(req.get("satisfied")),
            req.get("require"),
            subjects.get("matching"),
            subjects.get("total"),
        ))

    if failing:
        print("\nfailing rows:")
        for row in failing:
            inputs = ", ".join(
                "%s=%s" % (i.get("name"), brief(i.get("value")))
                for i in row.get("inputs", [])
            )
            print("  %-16s %-16s %-30s %s" % (
                row.get("requirement"),
                row.get("check"),
                brief_id(row.get("subject", {}).get("id")),
                inputs,
            ))

    violations = opa_eval(
        "data.kosli.evidence.violations(data.%s.report)" % package, files, args.input
    )
    if violations:
        print("\n%d violations (failing rows that are breaches):" % len(violations))
        for entry in violations:
            print("  %s / %s — %s" % (
                entry.get("requirement"), entry.get("check"),
                entry.get("description") or entry.get("expression") or "",
            ))
    return 0


def main():
    parser = argparse.ArgumentParser(prog="kit.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    shape = sub.add_parser("shape", help="describe an input document's structure")
    shape.add_argument("input")
    shape.add_argument("--paths", action="store_true",
                       help="flat dotted paths instead of a tree")
    shape.add_argument("--rego", action="store_true",
                       help="flat paths, each with its Rego path array to paste")
    shape.add_argument("--depth", type=int, default=0, help="limit nesting depth")
    shape.add_argument("--max-children", type=int, default=25,
                       help="truncate sibling groups wider than this (default 25)")
    shape.set_defaults(func=cmd_shape)

    run = sub.add_parser("run", help="evaluate a policy against an input document")
    run.add_argument("policy")
    run.add_argument("input")
    run.add_argument("--ops", nargs="*", help="extra .rego files (custom operators)")
    run.add_argument("--data", nargs="*",
                     help="JSON data files, e.g. {\"params\": {...}} for a "
                          "policy configured through data.params")
    run.add_argument("--library", default=DEFAULT_LIBRARY)
    run.add_argument("--json", action="store_true", help="print the raw report JSON")
    run.set_defaults(func=cmd_run)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
