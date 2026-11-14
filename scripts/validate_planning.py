#!/usr/bin/env python3
"""Validate traceability and truthful status; not a replacement for runtime tests."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {"TODO", "IN_PROGRESS", "BLOCKED", "DONE"}


def validate(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for name in (
        "AGENTS.md", "TASKS.md", "docs/ARCHITECTURE.md",
        "docs/OPEN_DECISIONS.md", "docs/PROJECT_STATUS.md",
        "docs/PARALLEL_WORK.md", "docs/TEST_PLAN.md",
        "docs/reference/Khotwa_SRS_v1.3.docx", "packages/contracts/API.md",
    ):
        if not (root / name).is_file():
            errors.append(f"Missing required file: {name}")
    data = json.loads((root / "docs/requirements_map.json").read_text(encoding="utf-8-sig"))
    requirements = data["requirements"]
    ids = [r["id"] for r in requirements]
    expected = {f"FR-{i:02d}" for i in range(1, 129)}
    if len(ids) != 128 or set(ids) != expected:
        errors.append("Expected each FR-01 through FR-128 exactly once")
    for requirement in requirements:
        if requirement["status"] not in ALLOWED:
            errors.append(f"Invalid status: {requirement['id']}")
        if requirement["status"] == "DONE" and not requirement.get("evidence"):
            errors.append(f"DONE requires executed evidence: {requirement['id']}")
    tasks = (root / "TASKS.md").read_text(encoding="utf-8-sig")
    rows = re.findall(r"^\| ([A-Z]+-\d+) \| (.+)$", tasks, re.M)
    known = {task for task, _ in rows}
    graph: dict[str, list[str]] = {}
    for task, columns in rows:
        cells = [cell.strip() for cell in columns.split("|")]
        deps = re.findall(r"[A-Z]+-\d+", cells[2])
        graph[task] = deps
        if cells[3] not in ALLOWED:
            errors.append(f"Invalid task state: {task}")
        for dep in deps:
            if dep not in known:
                errors.append(f"Unknown dependency {dep} for {task}")
    visited: set[str] = set()
    active: set[str] = set()

    def visit(task: str) -> None:
        if task in active:
            errors.append(f"Dependency cycle at {task}")
            return
        if task in visited:
            return
        active.add(task)
        for dependency in graph.get(task, []):
            visit(dependency)
        active.remove(task)
        visited.add(task)

    for task in graph:
        visit(task)
    return errors


if __name__ == "__main__":
    failures = validate()
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        raise SystemExit(1)
    print("PASS: SRS present; 128 unique FRs; task dependency DAG; valid states and evidence gates")
