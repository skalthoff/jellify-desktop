#!/usr/bin/env python3
"""
Bulk-create GitHub issues from the research agent output markdown files.

Each file in /tmp/jellify-research/*.md contains issue sections in the shape:

    ### Issue N: <Title>
    **Labels:** `a`, `b`, `c`
    **Effort:** M
    **Depends on:** ...
    **Milestone:** M3 — macOS polish   (optional; inferred from area otherwise)

    <body>

Run:
    python3 Scripts/create-issues.py [--dry-run] [--file path]

Requires `gh` on PATH, authenticated.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, field

RESEARCH_DIR = pathlib.Path("/tmp/jellify-research")
ISSUE_HEADER_RE = re.compile(r"^###\s+Issue\s+\d+[:.]?\s*(?P<title>.+?)\s*$", re.MULTILINE)
META_RE = re.compile(r"^\*\*(?P<key>[^:*]+):\*\*\s*(?P<value>.+?)\s*$", re.MULTILINE)
TICK_RE = re.compile(r"`([^`]+)`")

# Area → default milestone (overridable with **Milestone:** in the body).
DEFAULT_MILESTONE: dict[str, str] = {
    "area:macos": "M3 — macOS polish",
    "area:audio": "M3 — macOS polish",
    "area:ux": "M3 — macOS polish",
    "area:design": "M3 — macOS polish",
    "area:a11y": "M3 — macOS polish",
    "area:i18n": "Backlog",
    "area:dist": "M4 — macOS distribution",
    "area:ci": "M4 — macOS distribution",
    "area:windows": "M5 — Windows port",
    "area:linux": "M6 — Linux port",
    "area:perf": "Backlog",
    "area:reliability": "Backlog",
    "area:observability": "Backlog",
    "area:core": "Backlog",
    "area:api": "Backlog",
    "area:docs": "Backlog",
}


@dataclass
class Issue:
    title: str
    labels: list[str] = field(default_factory=list)
    body: str = ""
    milestone: str | None = None

    @property
    def cli_args(self) -> list[str]:
        args = ["gh", "issue", "create", "--title", self.title, "--body", self.body]
        for lbl in self.labels:
            args.extend(["--label", lbl])
        if self.milestone:
            args.extend(["--milestone", self.milestone])
        return args


def parse_file(path: pathlib.Path) -> list[Issue]:
    text = path.read_text(encoding="utf-8")
    # Split on "### Issue ..." keeping the header. The first chunk is preamble.
    chunks = re.split(r"(?=^###\s+Issue\s+\d+)", text, flags=re.MULTILINE)
    issues: list[Issue] = []
    for chunk in chunks:
        chunk = chunk.strip()
        if not chunk.startswith("### Issue"):
            continue
        header_match = ISSUE_HEADER_RE.match(chunk)
        if not header_match:
            continue
        title = header_match.group("title").strip().strip("`").strip('"').strip("'")
        # Some agents emit "Issue 1: Title" and others "Issue 1. Title" — both ok.
        title = re.sub(r"^Issue\s+\d+[:.]?\s*", "", title).strip()

        labels: list[str] = []
        milestone: str | None = None

        body_lines: list[str] = []
        in_body = False
        for line in chunk.splitlines()[1:]:
            if not in_body and line.startswith("**"):
                meta = META_RE.match(line)
                if meta:
                    key = meta.group("key").strip().lower()
                    value = meta.group("value").strip()
                    if key == "labels":
                        for tick in TICK_RE.findall(value):
                            labels.append(tick.strip())
                        # Also accept non-tick, comma-separated labels
                        if not labels:
                            labels = [p.strip() for p in value.split(",") if p.strip()]
                    elif key == "effort":
                        val = value.strip("`").split()[0]
                        labels.append(f"effort:{val}")
                    elif key == "priority":
                        labels.append(value.strip("`"))
                    elif key == "milestone":
                        milestone = value
                    elif key == "depends on":
                        if value and value != "-":
                            body_lines.append(f"**Depends on:** {value}")
                    continue
            if not in_body and line.strip() == "":
                in_body = True
                continue
            body_lines.append(line)

        # Default milestone from area label if not overridden.
        if milestone is None:
            for lbl in labels:
                if lbl in DEFAULT_MILESTONE:
                    milestone = DEFAULT_MILESTONE[lbl]
                    break
        if milestone is None:
            milestone = "Backlog"

        # Add source-file marker to body for traceability.
        body = "\n".join(body_lines).strip()
        body += f"\n\n<sub>Source: `{path.name}`</sub>"

        # Deduplicate labels, preserve order.
        seen = set()
        uniq_labels = []
        for lbl in labels:
            if lbl not in seen:
                seen.add(lbl)
                uniq_labels.append(lbl)

        issues.append(Issue(title=title, labels=uniq_labels, body=body, milestone=milestone))
    return issues


def fetch_existing_titles() -> set[str]:
    result = subprocess.run(
        ["gh", "issue", "list", "--state", "all", "--limit", "1000",
         "--json", "title", "--jq", ".[].title"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        print(f"warning: failed to fetch existing issues: {result.stderr}", file=sys.stderr)
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--file", type=pathlib.Path, help="Process only this file")
    ap.add_argument("--dir", type=pathlib.Path, default=RESEARCH_DIR)
    args = ap.parse_args()

    files: list[pathlib.Path]
    if args.file:
        files = [args.file]
    else:
        files = sorted(args.dir.glob("*.md"))
    if not files:
        print(f"no markdown files in {args.dir}", file=sys.stderr)
        sys.exit(1)

    all_issues: list[Issue] = []
    for f in files:
        parsed = parse_file(f)
        print(f"{f.name}: {len(parsed)} issues")
        all_issues.extend(parsed)

    existing = fetch_existing_titles() if not args.dry_run else set()

    created = 0
    skipped = 0
    for issue in all_issues:
        if issue.title in existing:
            skipped += 1
            print(f"SKIP (exists): {issue.title}")
            continue
        if args.dry_run:
            print(f"[dry] {issue.title}  labels={issue.labels}  ms={issue.milestone}")
            continue
        result = subprocess.run(issue.cli_args, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"FAIL: {issue.title}\n  {result.stderr.strip()}", file=sys.stderr)
        else:
            url = result.stdout.strip().splitlines()[-1]
            print(f"  created: {url}  — {issue.title}")
            created += 1

    print(f"\nsummary: created={created}  skipped={skipped}  total_parsed={len(all_issues)}")


if __name__ == "__main__":
    main()
