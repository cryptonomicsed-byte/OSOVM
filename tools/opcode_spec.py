#!/usr/bin/env python3
"""opcode_spec.py — OPCODE_SPEC.toml is generated from the live VM, and gated.

The TOML is the contract between the language (Techgnosis) and the VM. It is
never hand-edited: it is regenerated from what src/oso_vm.jl actually does when
each byte is executed (tools/opcode_probe.jl), and CI fails if the committed
copy no longer matches, or if the VM and its own declaration table disagree.

    tools/opcode_spec.py generate        # rewrite OPCODE_SPEC.toml
    tools/opcode_spec.py check           # gate; exit code = failure count

Both run the Julia probe unless --probe-json PATH is given.

FAILURES (each counts 1 toward the exit code)
  removed-but-declared   the table names a byte the VM rejects as removed
  dispatched-undeclared  the VM runs a byte the table has no name for
  name-on-two-bytes      one name resolves to more than one byte
  spec-stale             committed OPCODE_SPEC.toml != regenerated
  spec-missing           no committed OPCODE_SPEC.toml

REPORTED, NOT COUNTED
  unimplemented          declared, routed to the fail-closed vault stub.
                         These are real gaps (e.g. the contract lifecycle,
                         plan blocker B1) -- listed, not drift.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "OPCODE_SPEC.toml"
PROBE = ROOT / "tools" / "opcode_probe.jl"

STATUS = {"dispatched": "dispatched", "offloaded": "unimplemented",
          "removed": "removed", "unknown": "unknown"}


def probe(julia: str, probe_json: str | None) -> dict:
    if probe_json:
        return json.loads(Path(probe_json).read_text())
    out = subprocess.run([julia, f"--project={ROOT}", str(PROBE)], cwd=ROOT,
                         capture_output=True, text=True, timeout=1800)
    if out.returncode != 0:
        sys.stderr.write(out.stderr[-4000:])
        raise SystemExit(f"opcode probe failed (exit {out.returncode})")
    return json.loads(out.stdout)


def _q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(p: dict) -> str:
    """Deterministic: same VM -> byte-identical file. No timestamps."""
    rows = [r for r in p["bytes"] if r["names"] or r["class"] == "dispatched"]
    counts: dict[str, int] = {}
    for r in rows:
        counts[STATUS[r["class"]]] = counts.get(STATUS[r["class"]], 0) + 1
    out = [
        "# OPCODE_SPEC.toml — GENERATED. Do not edit by hand.",
        "# Source of truth: src/oso_vm.jl, measured by executing every byte",
        "# (tools/opcode_probe.jl). Regenerate: tools/opcode_spec.py generate",
        "",
        "[meta]",
        f"source = {_q(p['source'])}",
        f"declared_bytes = {sum(1 for r in rows if r['names'])}",
        f"declared_names = {sum(len(r['names']) for r in rows)}",
    ] + [f"{k} = {v}" for k, v in sorted(counts.items())] + [""]
    for r in sorted(rows, key=lambda r: int(r["byte"], 16)):
        out += [
            "[[opcode]]",
            f"byte = {_q(r['byte'])}",
            "names = [" + ", ".join(_q(n) for n in sorted(r["names"])) + "]",
            f"status = {_q(STATUS[r['class']])}",
            f"critical = {'true' if r['critical'] else 'false'}",
            "",
        ]
    return "\n".join(out)


def check(p: dict) -> list[tuple[str, str]]:
    fails: list[tuple[str, str]] = []
    by_name: dict[str, list[str]] = {}
    for r in p["bytes"]:
        for n in r["names"]:
            by_name.setdefault(n, []).append(r["byte"])
        if r["names"] and r["class"] == "removed":
            fails.append(("removed-but-declared", f"{r['byte']} {r['names']}: {r['note']}"))
        if r["class"] == "dispatched" and not r["names"]:
            fails.append(("dispatched-undeclared", f"{r['byte']} runs but has no name in opcodes.jl"))
    for n, bs in sorted(by_name.items()):
        if len(bs) > 1:
            fails.append(("name-on-two-bytes", f"{n} -> {', '.join(bs)}"))
    want = render(p)
    if not SPEC.exists():
        fails.append(("spec-missing", "OPCODE_SPEC.toml not committed; run generate"))
    elif SPEC.read_text() != want:
        fails.append(("spec-stale", "OPCODE_SPEC.toml differs from the live VM; run generate"))
    return fails


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["generate", "check"])
    ap.add_argument("--julia", default="julia")
    ap.add_argument("--probe-json")
    a = ap.parse_args()
    p = probe(a.julia, a.probe_json)

    if a.cmd == "generate":
        SPEC.write_text(render(p))
        print(f"wrote {SPEC.relative_to(ROOT)}")
        return 0

    fails = check(p)
    unimpl = [r for r in p["bytes"] if r["names"] and r["class"] == "offloaded"]
    for kind, msg in fails:
        print(f"FAIL  {kind:22} {msg}")
    for r in unimpl:
        print(f"note  {'unimplemented':22} {r['byte']} {r['names']} (fails closed)")
    print(f"\n{len(fails)} failure(s); {len(unimpl)} declared-but-unimplemented (reported, not counted)")
    return min(len(fails), 125)


if __name__ == "__main__":
    sys.exit(main())
