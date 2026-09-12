# Canonical Pillar Contract — OSOVM
## Protocol: SPP-1 (Sovereign Proof Protocol v1)

This document defines the protocol obligations of **OSOVM** as the
**Law pillar** of the Vantage Sovereign Ecosystem.

---

## Pillar Identity

| Field | Value |
|-------|-------|
| Pillar | Law (Ọ̀ṢỌ́VM) |
| Role | Proof-of-Useful-Simulation, opcode execution, Àṣẹ minting authority |
| Protocol token | SPP-1 |
| Primary port | 7780 (HTTP server, Julia) |
| Env var | `OSOVM_URL` (default `http://localhost:7780`) |

---

## Protocol Obligations

### SPP-1: Sovereign Proof Protocol

OSOVM is the canonical verifier. Its `vm_state_hash` is the final word on
whether a simulation is valid. No receipt claiming simulation proof is
authoritative without an OSOVM `vm_state_hash`.

**Every `/run` response MUST include:**
- `status` — "ok" | "error"
- `run_id` — unique execution identifier
- `opcode` — opcode executed
- `f1_score` — simulation fidelity (0.0–1.0)
- `ase_minted` — Àṣẹ amount authorised for minting (in mist)
- `receipts` — array of receipt references produced
- `vm_state_hash` — `sha256:{hex}` over serialised VM result
- `wall_ms` — wall-clock execution time

**Every `/veilsim/run` response MUST include:**
- `f1_score`, `energy_drift`, `robustness`, `receipt`, `vm_state_hash`

### Stateless Execution Contract

Each HTTP request creates a fresh VM via `OsoVM.create_vm()`. There is NO
persistent VM state between requests. State lives in the receipt chain, not
in the VM process.

### Opcode Registry Contract

`GET /opcodes` MUST return the complete set of CORE + EXPANSION opcodes.
Opcodes may not be removed without a protocol version bump.

---

## Cross-Pillar Interfaces

### ← Sovereign Stack (Society Pillar)
Receives `POST /run`:
```json
{
  "opcode": "VEIL",
  "args": { "twin_id": "sha256:...", "trajectory_count": 500, ... },
  "agent": "did:key:...",
  "work_id": "wk:sim:..."
}
```
Returns result with `vm_state_hash`. Caller stores receipt under `ReceiptKind::Simulation`.

### ← Omo-Koda2 (Agent Pillar)
Same `/run` interface. Omo-Koda2 calls via `osovm_run` MCP tool (tier 3 required).

### → Vantage (Society Backend)
OSOVM does NOT push to Vantage directly. Callers pull `vm_state_hash` and store
it in their local receipt chains. Vantage's `osovm_client.py` polls `/health`
and calls `/run` as needed.

---

## Economics Contract

OSOVM is the **mint authority** for proof-of-simulation Àṣẹ.

- `ase_minted` in the `/run` response is an authorisation, not a transfer.
- The calling pillar (sovereign-node or Vantage) MUST submit a `SettlementReceipt`
  to Sui to finalise the mint.
- Tithe (3.69%) is deducted by the settlement layer, not OSOVM.
- OSOVM does NOT know about daily emission limits — that is the Proof Engine's job.

### WorkID Propagation

OSOVM is a stateless verifier. It receives `work_id` in request bodies and
echoes it back in receipts. It does NOT create or own WorkIDs.

---

## VeilSim Contract

VeilSim scenarios validate the Odù 256-tile spatial economy:
- Input: `veil_ids` (array), `entity_count`, `step_count`
- Output: `f1_score` ≥ 0.7 required for receipt to be valid
- `energy_drift` < 0.05 required for Àṣẹ minting eligibility
- `robustness` ≥ 0.8 required for T4+ tier advancement credit

---

## Health Contract

`GET /health` MUST respond within 5 seconds with `{"status":"ok","version":"osovm/1"}`.
All callers poll this before submitting work. If health fails, work is queued locally.

---

## Protocol Versions Supported

| Protocol | Version | Status |
|----------|---------|--------|
| SPP-1 | 1.0 | Active |
| HTTP/JSON | — | Active |
| OSOVM opcodes | CORE + EXPANSION | Active |

---

## Canonical Type Reference

OSOVM is implemented in Julia. The corresponding Rust types in
`sovereign-types::work_id` define the schema that all pillars use
to interpret OSOVM receipts:
- `ActionReceipt.execution_id` — maps to OSOVM `run_id`
- `ActionReceipt.output_hash` — BLAKE3 of `vm_state_hash`
- `WorkKind::Simulation` — for receipts produced by `/run`
- `WorkKind::Scene` — for receipts produced by `/veilsim/run`

*Version: SPP-1.0 | Last updated: 2026-09-10*
