#!/usr/bin/env python3
"""sango_waggle_relay — on-chain anchors become top-tier field signals.

Connection Map v2 §7.1: finalization on Sui triggers a deposit at the top of
the evidence ladder. The chain is the instrument; this relay is the watch.

Feed it FieldAnchored / BoundedAnchored events as JSON lines on stdin —
from `sui client events`, a webhook exporter, or any indexer:

    sui_event_stream | python3 relay/sango_waggle_relay.py

Each event becomes a Waggle deposit with evidence_tier "on-chain-anchored"
(the only path that mints that tier — nothing self-reports its way to the
top). Milli fixed-point round-trips back to the field's decimals exactly.

Stdlib only; fails soft per line.
"""

import json
import os
import sys
import urllib.error
import urllib.request

WAGGLE = os.environ.get("WAGGLE_URL", "http://127.0.0.1:7777").rstrip("/")
AGENT = "sango-relay"


def deposit(body: dict) -> bool:
    req = urllib.request.Request(
        f"{WAGGLE}/v1/signals", data=json.dumps(body).encode(),
        method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5):
            return True
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        return False


def relay_event(ev: dict) -> bool:
    """One anchored event → one top-tier deposit."""
    fields = ev.get("parsedJson") or ev  # raw event or already-parsed fields
    resource = fields.get("resource")
    if not resource:
        return False
    receipt = str(fields.get("receipt_id", ""))
    anchored_by = str(fields.get("anchored_by", ""))
    tx = str(ev.get("id", {}).get("txDigest", "")) if isinstance(ev.get("id"), dict) else ""

    if "stability_milli" in fields:  # BoundedAnchored
        return deposit({
            "agent": AGENT, "resource": resource, "kind": "bounded",
            "intensity": int(fields["stability_milli"]) / 100.0,  # milli → 0..10
            "evidence_tier": "on-chain-anchored",
            "note": "robustness verdict anchored on Sui",
            "meta": {"receipt": receipt, "tx": tx, "anchored_by": anchored_by,
                     "escape": str(fields.get("escape", "")),
                     "maxiter": str(fields.get("maxiter", ""))},
        })
    # FieldAnchored (gold or other kinds)
    return deposit({
        "agent": AGENT, "resource": resource,
        "kind": str(fields.get("kind", "gold")),
        "intensity": int(fields.get("intensity_milli", 1000)) / 1000.0,
        "decay": "power",  # anchored findings fade to background, never to nothing
        "evidence_tier": "on-chain-anchored",
        "note": "finalized on Sui",
        "meta": {"receipt": receipt, "tx": tx, "anchored_by": anchored_by},
    })


def main():
    ok = fail = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if relay_event(ev):
            ok += 1
        else:
            fail += 1
    print(f"[sango-relay] deposited {ok}, failed {fail}", file=sys.stderr)


if __name__ == "__main__":
    main()
