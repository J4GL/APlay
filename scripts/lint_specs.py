#!/usr/bin/env python3
"""Structural lint for specs/ — see AGENTS.md "Specs".

Checks, per the project's spec format:
  1. Every spec file has all 8 frontmatter keys, with the declared types.
  2. Body sections appear, exactly once each, in the fixed order.
  3. Every scenario declares an explicit timeout.
  4. Every spec has at least one happy path and one sad path.
  5. Every scenario heading is Given/When/Then shaped.
  6. Every "UI test requirement" section names a specific element.
  7. index.md links resolve; every spec is listed; ids are unique and match filenames.
  8. Every `dependencies:` id exists.
  9. Every `test_e2e_file:` points under Tests/.
 10. Out-of-scope features are not specified anywhere.

Exit 0 when clean, 1 otherwise. No third-party dependencies.
"""

import re
import sys
from pathlib import Path

SPECS = Path(__file__).resolve().parent.parent / "specs"
INDEX = SPECS / "index.md"

REQUIRED_KEYS = [
    "id", "title", "status", "priority",
    "feature_group", "tags", "test_e2e_file", "dependencies",
]
SECTIONS = [
    "## Purpose",
    "## Rules",
    "## E2E test scenarios",
    "## UI test requirement",
    "## Implementation",
    "## Notes",
]
VALID_STATUS = {"draft", "approved", "implemented", "verified"}
VALID_PRIORITY = {"high", "medium", "low"}

# From specs/index.md "Explicitly out of scope". Matched case-insensitively as
# whole phrases, excluding the index itself and the Notes sections that
# deliberately record the exclusion.
OUT_OF_SCOPE = [
    r"playback speed",
    r"frame-by-frame",
    r"a-b loop",
]

errors: list[str] = []
warnings: list[str] = []


def err(f: Path, msg: str) -> None:
    errors.append(f"{f.relative_to(SPECS.parent)}: {msg}")


def split_frontmatter(text: str, f: Path):
    if not text.startswith("---\n"):
        err(f, "missing YAML frontmatter (file must start with '---')")
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        err(f, "unterminated YAML frontmatter")
        return {}, text
    raw, body = text[4:end], text[end + 5:]
    fm, current = {}, None
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith((" ", "\t", "-")):
            if current:
                fm[current] = (fm.get(current) or "") + " " + line.strip()
            continue
        if ":" not in line:
            err(f, f"unparseable frontmatter line: {line!r}")
            continue
        k, v = line.split(":", 1)
        current = k.strip()
        fm[current] = v.strip()
    return fm, body


def check_frontmatter(f: Path, fm: dict) -> str:
    for key in REQUIRED_KEYS:
        if key not in fm:
            err(f, f"frontmatter missing required key '{key}'")
    spec_id = fm.get("id", "")
    if spec_id and not re.fullmatch(r"[A-Z]+-\d{3}", spec_id):
        err(f, f"id {spec_id!r} is not of the form ABC-001")
    if fm.get("status") not in VALID_STATUS and "status" in fm:
        err(f, f"status {fm['status']!r} not one of {sorted(VALID_STATUS)}")
    if fm.get("priority") not in VALID_PRIORITY and "priority" in fm:
        err(f, f"priority {fm['priority']!r} not one of {sorted(VALID_PRIORITY)}")
    if "tags" in fm and not fm["tags"].startswith("["):
        err(f, "tags must be an inline list, e.g. [a, b]")
    tef = fm.get("test_e2e_file", "")
    if tef and not tef.startswith("Tests/"):
        err(f, f"test_e2e_file {tef!r} must point under Tests/")
    fg = fm.get("feature_group", "")
    if fg and fg != f.parent.name:
        err(f, f"feature_group {fg!r} does not match directory {f.parent.name!r}")
    return spec_id


def check_sections(f: Path, body: str) -> None:
    positions = []
    for section in SECTIONS:
        found = [m.start() for m in re.finditer(rf"^{re.escape(section)}\s*$", body, re.M)]
        if len(found) == 0:
            err(f, f"missing section {section!r}")
            return
        if len(found) > 1:
            err(f, f"section {section!r} appears {len(found)} times, expected once")
            return
        positions.append(found[0])
    if positions != sorted(positions):
        err(f, "sections are out of the required order: " + " -> ".join(SECTIONS))


def check_scenarios(f: Path, body: str, spec_id: str) -> None:
    start = body.find("## E2E test scenarios")
    end = body.find("## UI test requirement")
    block = body[start:end]
    scenarios = re.findall(r"^### (.+)$", block, re.M)
    if not scenarios:
        err(f, "no scenarios found under '## E2E test scenarios'")
        return

    happy = [s for s in scenarios if "(happy path)" in s]
    sad = [s for s in scenarios if "(sad path)" in s]
    if not happy:
        err(f, "no scenario marked '(happy path)'")
    if not sad:
        err(f, "no scenario marked '(sad path)'")
    for s in scenarios:
        if "(happy path)" not in s and "(sad path)" not in s:
            err(f, f"scenario not marked happy or sad: {s!r}")
        if spec_id and not s.startswith(spec_id + "-"):
            err(f, f"scenario id should start with {spec_id}-: {s!r}")

    # One explicit timeout per scenario, and Given/When/Then shape.
    chunks = re.split(r"^### .+$", block, flags=re.M)[1:]
    for name, chunk in zip(scenarios, chunks):
        timeouts = re.findall(r"\*\*Timeout:\*\*\s*(\d+)\s*s", chunk)
        if len(timeouts) != 1:
            err(f, f"scenario {name!r} must declare exactly one '**Timeout:** N s' (found {len(timeouts)})")
        elif int(timeouts[0]) <= 0:
            err(f, f"scenario {name!r} has a non-positive timeout")
        for kw in ("**Given**", "**When**", "**Then**"):
            if kw not in chunk:
                err(f, f"scenario {name!r} missing {kw}")


def check_ui_requirement(f: Path, body: str) -> None:
    start = body.find("## UI test requirement")
    end = body.find("## Implementation")
    block = body[start:end]
    if len(block.strip().splitlines()) < 2:
        err(f, "'UI test requirement' section is empty")
        return
    named = re.findall(r"`play\.[a-zA-Z0-9.<>]+`", block)
    if not named and "no UI" not in block and "No UI surface" not in block:
        err(f, "'UI test requirement' names no specific element (expected a `play.*` identifier) "
               "and does not state that the spec has no UI surface")


def check_out_of_scope(f: Path, body: str) -> None:
    # Notes sections legitimately record why something is excluded.
    notes_at = body.find("## Notes")
    searchable = body[:notes_at] if notes_at != -1 else body
    for pattern in OUT_OF_SCOPE:
        for m in re.finditer(pattern, searchable, re.I):
            line = searchable[:m.start()].count("\n") + 1
            err(f, f"out-of-scope feature {m.group(0)!r} specified at body line ~{line}")


def main() -> int:
    if not INDEX.exists():
        print(f"FATAL: {INDEX} not found", file=sys.stderr)
        return 1

    spec_files = sorted(p for p in SPECS.rglob("*.md") if p != INDEX)
    if not spec_files:
        print("FATAL: no spec files found", file=sys.stderr)
        return 1

    ids: dict[str, Path] = {}
    deps: dict[str, list[str]] = {}
    e2e_files: dict[str, str] = {}

    for f in spec_files:
        text = f.read_text(encoding="utf-8")
        fm, body = split_frontmatter(text, f)
        spec_id = check_frontmatter(f, fm)
        check_sections(f, body)
        if spec_id:
            if spec_id in ids:
                err(f, f"duplicate id {spec_id} (also in {ids[spec_id].name})")
            ids[spec_id] = f
            check_scenarios(f, body, spec_id)
            deps[spec_id] = re.findall(r"([A-Z]+-\d{3})", fm.get("dependencies", ""))
            e2e_files[spec_id] = fm.get("test_e2e_file", "")
        check_ui_requirement(f, body)
        check_out_of_scope(f, body)

    # Dependency ids must exist.
    for spec_id, dep_ids in deps.items():
        for d in dep_ids:
            if d not in ids:
                err(ids[spec_id], f"dependency {d} does not exist")
            if d == spec_id:
                err(ids[spec_id], f"depends on itself")

    # test_e2e_file paths must be unique per spec.
    seen_e2e: dict[str, str] = {}
    for spec_id, path in e2e_files.items():
        if path and path in seen_e2e:
            err(ids[spec_id], f"test_e2e_file {path!r} already used by {seen_e2e[path]}")
        seen_e2e[path] = spec_id

    # index.md: links resolve, and every spec is listed exactly once.
    index_text = INDEX.read_text(encoding="utf-8")
    linked: set[Path] = set()
    for target in re.findall(r"\]\(([^)]+\.md)\)", index_text):
        p = (SPECS / target).resolve()
        if not p.exists():
            errors.append(f"specs/index.md: broken link -> {target}")
        else:
            linked.add(p)
    for f in spec_files:
        if f.resolve() not in linked:
            errors.append(f"specs/index.md: does not link to {f.relative_to(SPECS)}")
    for spec_id in ids:
        if not re.search(rf"\|\s*{spec_id}\s*\|", index_text):
            errors.append(f"specs/index.md: no table row for {spec_id}")

    total_scenarios = 0
    for f in spec_files:
        total_scenarios += len(re.findall(r"^### [A-Z]+-\d{3}-", f.read_text(encoding="utf-8"), re.M))

    print(f"specs: {len(spec_files)} files, {len(ids)} ids, {total_scenarios} scenarios")
    for w in warnings:
        print(f"  warn: {w}")
    if errors:
        print(f"\n{len(errors)} error(s):")
        for e in errors:
            print(f"  {e}")
        return 1
    print("lint: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
