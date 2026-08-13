#!/usr/bin/env python3
"""Turn a real Kosli trail into a committable fixture.

    python3 fieldkit/sanitize.py real.json > fixture.json
    python3 fieldkit/sanitize.py real.json --audit    # what was replaced, no output doc

Preserves everything that makes a fixture worth having — key names, types,
nesting, array-vs-map choices, which siblings carry which fields, empty strings,
empty arrays, JSON-encoded strings, and cross-references (one commit sha stays one
commit sha everywhere) — and replaces everything that identifies a person, host,
repository, or tenant.

Replacement is **deterministic** (a fixed salt, so reruns produce identical
output) and **fail-closed**: a string is kept only if it is recognisable policy
vocabulary, and anything unrecognised is replaced rather than passed through. That
is the right default for a redaction tool, and it means a schema change upstream
shows up as an obviously-fake value rather than as a silent leak.

Timestamps, booleans and numbers pass through: they carry no identity, and the
epoch-number format is itself a finding the fixture needs to preserve.
"""

import argparse
import hashlib
import json
import re
import sys

SALT = "kosli.evidence fixture"

# Policy vocabulary: meaningful to the library, identifying to no one. Anything
# not listed here is replaced.
KEEP = {
    "", "{}", "app", "generic", "dev", "1.0",
    "COMPLETE", "NON-COMPLIANT", "INCOMPLETE", "COMPLIANT",
    "SOURCE_CODE_REVIEW_COMPLETED", "SDLC_REQUIREMENTS_FOR_RELEASE_COMPLETED",
    "UNIT_TEST_REPORT_COMPLETED", "TEST_CASES_TRACEABILITY_COMPLETED",
    "NO_HARD_CODED_CREDENTIALS_VERIFICATION_COMPLETED",
    "trail_reported", "trail_updated", "trail_attestation_reported",
    "artifact_creation_reported",
    # `changes` entries are field names, not free text.
    "git_commit_info", "origin_url",
}

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UUIDISH = re.compile(r"^[0-9a-f]{4,}(-[0-9a-f]{2,}){2,}$")

replacements = {}


def digest(*parts):
    return hashlib.sha256((SALT + "|" + "|".join(parts)).encode()).hexdigest()


def fake_hex(original, length):
    return digest("hex", original)[:length]


def fake_uuid(original):
    """Keep the original's segment lengths — Kosli's ids are 8-4-4-4-8, not
    canonical UUIDs, and a fixture that quietly 'fixes' that is a fixture that
    stops reproducing the real thing."""
    stream = digest("uuid", original)
    out, at = [], 0
    for segment in original.split("-"):
        out.append(stream[at:at + len(segment)])
        at += len(segment)
    return "-".join(out)


def fake_url(original):
    sha = re.search(r"[0-9a-f]{40}", original)
    if "/commit/" in original:
        return "https://github.com/acme/demo-app-service/commit/%s" % (
            fake_hex(sha.group(0), 40) if sha else fake_hex(original, 40))
    if "/actions/runs/" in original:
        return "https://github.com/acme/demo-app-service/actions/runs/%s" % (
            digest("run", original)[:11].translate(str.maketrans("abcdef", "012345")))
    return "https://example.com/redacted"


def sanitize_string(key, value):
    if value in KEEP:
        return value
    if HEX64.match(value):
        return fake_hex(value, 64)
    if HEX40.match(value):
        return fake_hex(value, 40)
    if UUIDISH.match(value):
        return fake_uuid(value)
    if value.startswith(("http://", "https://")):
        return fake_url(value)
    # A JSON-encoded payload: sanitize inside and re-encode, so the fixture keeps
    # the string-encoding quirk that a consumer has to decode through.
    if value[:1] in "{[":
        try:
            return json.dumps(sanitize(json.loads(value)))
        except ValueError:
            pass
    if "@" in value:
        return "Test User <test.user@example.com>"
    # A flow template: rebuilt rather than kept, since nothing in the library
    # reads it and a real one may name internal systems.
    if key == "content" and "version:" in value:
        return ("\nversion: 1\ntrail:\n  artifacts:\n    - name: app\n"
                "  attestations:\n    - name: SOURCE_CODE_REVIEW_COMPLETED\n"
                "      type: generic\n")
    # An artifact coordinate: registry host / path / tag. Distinct originals must
    # stay distinct, or two artifacts collapse into one subject.
    if "/" in value and ":" in value:
        return "registry.example.com/demo/demo-app-service:1.2.%d" % (
            int(digest("tag", value)[:4], 16) % 100)
    return {
        "message": "commit message",
        "created_by": "ci-bot",
        "name": "demo-flow",
        "description": "demo",
    }.get(key, "redacted-%s" % digest("other", value)[:4])


def sanitize(node, key=None):
    if isinstance(node, dict):
        return {k: sanitize(v, k) for k, v in node.items()}
    if isinstance(node, list):
        return [sanitize(v, key) for v in node]
    if isinstance(node, str):
        clean = sanitize_string(key, node)
        if clean != node:
            replacements.setdefault((key, node), clean)
        return clean
    return node


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--audit", action="store_true",
                        help="report replacements instead of the document")
    parser.add_argument("--wrap", metavar="KEY",
                        help="nest the result under KEY (e.g. --wrap trail)")
    args = parser.parse_args()

    with open(args.input) as handle:
        doc = json.load(handle)

    clean = sanitize(doc)
    if args.wrap:
        clean = {args.wrap: clean}

    if args.audit:
        width = max(len(str(k)) for k, _ in replacements) if replacements else 1
        for (key, before), after in sorted(replacements.items(), key=lambda i: str(i[0])):
            print("%-*s  %s\n%-*s    -> %s" % (width, key, before, width, "", after))
        print("\n%d distinct values replaced." % len(replacements))
        return 0

    json.dump(clean, sys.stdout, indent=2, sort_keys=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
