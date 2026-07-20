# CubeSandbox Job Pipeline — the ephemeral-worker contract

Locks in the design from this session: users submit a Job Spec ("a smart
contract for a simulation"), an ephemeral CubeSandbox microVM runs it and
terminates, and OSOVM anchors the resulting paper trail. This doc is the
single source of truth for that flow — what's built and tested in OSOVM
right now, and the external contract a CubeSandbox worker must satisfy
(not fake-implemented here, since CubeSandbox itself has never been
cloned/deployed anywhere — task #24, still blocked on provisioning a
second VPS with nested-virt, which is a real infra/spend decision, not
something built inline).

## The full loop

1. User submits a **`SimJobSpec`** (`src/job_spec.jl`): `world`,
   `parameters`, `seed`, `duration_steps`, `metrics_schema`,
   `creator_wallet`. Two tiers:
   - `:dsl` — parameterized against OSOVM's existing deterministic
     catalog (VeilSim). Accepted as mineable by default — the engine's
     determinism is already proven (`782a7b2a...`, cross-machine).
   - `:custom` — arbitrary user code, runs in an isolated CubeSandbox.
     Not mineable until it passes its own determinism self-test (see
     step 6).
2. `job_id = JobSpec.job_id(spec)` — SHA-256 of the spec's canonical
   serialization. Deterministic regardless of Dict/Vector key order
   (tested: `test/job_spec_test.jl`).
3. **[EXTERNAL — CubeSandbox worker, not built in this repo]** Coordinator
   spins up a fresh CubeSandbox microVM for the job (sub-60ms cold
   start). The sandbox:
   - Runs the job deterministically (`:dsl` → OSOVM's own VeilSim
     binary/library; `:custom` → whatever the user submitted, inside the
     isolated, eBPF-egress-controlled VM).
   - May use an embedded PocketBase instance for live telemetry/
     observability during the run — convenience only, never the proof
     source (see the canonicalization warning below).
   - On completion, serializes every checkpoint through
     `CheckpointExport.canonical_checkpoint_bytes` — **not** a raw
     PocketBase/SQLite file hash. On-disk DB layout (page order, VACUUM
     state, WAL artifacts) can differ between two logically-identical
     runs; hashing that would manufacture false "nondeterminism"
     failures, the same bug class already found and fixed in this
     session's real determinism work.
4. **[EXTERNAL]** Sandbox uploads the canonical checkpoint export to
   Walrus (real client pattern already exists — see Omo-Koda2's
   `omokoda-core/src/memory/walrus.rs`: `PUT
   {publisher}/v1/blobs?epochs=N`) → gets back a `walrus_blob_id`.
   OSOVM itself never uploads storage, same architecture as
   `glyphindex.jl`'s `walrus_blob_id` field.
5. **[BUILT + TESTED HERE]** Sandbox (or the coordinator on its behalf)
   calls `ZangbetoReceipts.create_job_receipt(spec, checkpoints,
   final_metrics, walrus_blob_id)`:
   - Validates the spec and that `final_metrics` actually covers
     `metrics_schema` (throws otherwise — a receipt for a spec violation
     is not a receipt).
   - Builds the checkpoint **Merkle tree** (`src/merkle.jl` — generic,
     pairwise SHA-256, no synthetic leaf duplication; supports path
     generation so a validator can verify one sampled checkpoint without
     downloading the whole job).
   - Runs the existing witness-quorum simulation (7/12,
     `collect_witness_votes`/`check_quorum` — now generic, shared with
     the original VeilSim receipt path).
   - Applies the **dual seal**: SHA-256 tamper-evidence commitment
     (Layer 1) + a real Sui Seal DEK fingerprint (Layer 2, via
     `src/seal_bridge.jl`) when `SEAL_*` env vars are configured,
     fail-open (empty string) otherwise.
   - Returns a `JobReceiptBundle`: `job_id`, `checkpoint_merkle_root`,
     `walrus_blob_id`, quorum result, dual seal, timestamp.
6. **[EXTERNAL, for `:custom` jobs only]** Determinism self-test: run the
   job twice in two separate sandboxes, compare `checkpoint_merkle_root`.
   Match required before the receipt is eligible for the mineable
   pipeline. Same principle as OSOVM's own P0 gate (`test/
   determinism_real.jl`), applied per-job instead of once to the engine.
7. **[EXTERNAL, ongoing]** Later, any validator who wants to check a
   specific checkpoint: fetch the export from Walrus, call
   `Merkle.merkle_path`/`verify_merkle_path` against the receipt's root.
   The sandbox that produced it no longer needs to exist — the receipt +
   Walrus blob is the whole durable trail. This is why the ephemeral
   "spin up, run, terminate" model works for the paper trail, not
   against it: nothing tampering-capable is still running once the
   receipt is anchored.
8. Sandbox terminates. Zero idle infra cost between jobs.

## Built and verified in this repo (2026-07-20)

| Module | What | Tests |
|---|---|---|
| `src/job_spec.jl` | `SimJobSpec`, canonical hash/`job_id`, validation, tier gating | `test/job_spec_test.jl` — 10/10 |
| `src/merkle.jl` | Generic Merkle root + path generation + verification | `test/merkle_test.jl` — 97/97 (every leaf count 1-13, tamper detection) |
| `src/checkpoint_export.jl` | Canonical, full-precision, key-order-independent checkpoint serialization | `test/checkpoint_export_test.jl` — 6/6 |
| `src/zangbeto_receipts.jl` (`create_job_receipt`) | Ties the above together into a signed, dual-sealed `JobReceiptBundle` | `test/job_receipt_test.jl` — 13/13 |

Full regression suite rerun after every change in this build: zero
regressions against the known baseline throughout.

## Not built here, and why

- **The CubeSandbox microVM runtime itself.** Never cloned or deployed
  anywhere in this ecosystem (confirmed by search across every local
  repo and the VPS). Building/provisioning it needs a second VPS with
  nested-virt support (task #24) — a real infrastructure decision
  (cost, provider, ongoing spend) that wasn't authorized to just go
  provision autonomously.
- **The embedded-PocketBase-per-sandbox wiring.** Depends on the
  CubeSandbox runtime existing first; the *pattern* is locked (per-job
  local telemetry, canonical export is the only thing hashed into the
  Merkle tree, never the raw DB file) but there's no runtime to wire it
  into yet.
- **The actual Walrus upload call from inside a sandbox.** The real
  client pattern exists (Omo-Koda2's `walrus.rs`) and `create_job_receipt`
  already accepts a `walrus_blob_id` as input exactly the way
  `glyphindex.jl` does — but no sandbox exists yet to call it from.
- **The `:custom`-tier determinism self-test orchestration** (run twice,
  compare roots, gate mineability). The comparison logic itself would be
  trivial (`bundle1.checkpoint_merkle_root == bundle2.checkpoint_merkle_root`)
  once two real sandbox runs exist to compare — nothing to build in
  Julia beyond that equality check, which is not worth stubbing out
  ahead of having real inputs.

## Next real step, when task #24 unblocks

Provision the second VPS, clone `TencentCloud/CubeSandbox`, get one job
running end-to-end through the full loop above using the modules already
built and tested here.
