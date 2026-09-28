# INVARIANT_TODO.md
# Machine-readable work queue for completing sovereign tokenomics invariants.
#
# Format per item:
#   id:          invariant number from tokenomics_invariant_check.py
#   status:      STUB | PARTIAL | BLOCKED | OPEN
#   blocker:     what prevents a real implementation (STUB items only)
#   repo:        which repo to edit
#   file:        canonical file for the fix
#   symbol:      the symbol / function / struct that needs real logic
#   work:        one-line description of what needs to be done
#   depends_on:  other invariants that must be done first (comma-separated, or none)
#
# Status key:
#   STUB    — skeleton present (invariant gate passes), real logic missing
#   PARTIAL — partially implemented but known gap
#   BLOCKED — cannot implement without a hard external dependency
#   OPEN    — no code exists yet; gate still failing

---
items:

- id: I-17
  status: STUB
  blocker: witness network signing scheme not specified
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: verify_zangbeto_receipt
  work: "implement Ed25519 signature verification against witness network pubkey; replace stub returning false"
  depends_on: "I-25 (real witness network)"

- id: I-18
  status: BLOCKED
  blocker: "Zàngbétò POST /anchor endpoint not implemented (tracked: E-53 in Omo-Koda2)"
  repo: Omo-Koda2
  file: omokoda-core/src/bridge/arp.rs
  symbol: zangbeto_anchor
  work: "set zangbeto_anchor: Some(real_anchor) on the compute path once Zàngbétò exposes the endpoint"
  depends_on: "I-17 (anchor signature verification)"

- id: I-24
  status: STUB
  blocker: GIX-addressable score attestation format not yet wired
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: verify_score_signature
  work: "verify that score dict is a GIX-indexed receipt signed by a non-claimant verifier pubkey"
  depends_on: "none"

- id: I-25
  status: STUB
  blocker: external witness node network does not yet exist
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: request_witness_votes
  work: "replace empty-return stub with real HTTP calls to 12 independent witness endpoints; votes are Ed25519 signed"
  depends_on: "WITNESS_NETWORK_SPEC.md (to be written)"

- id: I-28
  status: STUB
  blocker: SGX DCAP / TDX vendor library not integrated
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: verify_attestation_signature
  work: "wire SGX DCAP or TDX quote verification against vendor root CA; remove stub returning false"
  depends_on: "none"

- id: I-2
  status: STUB
  blocker: principal registry not wired (no human vs. agent flag source)
  repo: OSOVM
  file: src/token_guards.jl
  symbol: ase_to_synapse
  work: "apply scarcity curve from TOC_CONSTANTS [synapse].saturation_count; current implementation is linear-only"
  depends_on: "none"

- id: I-3
  status: STUB
  blocker: principal registry not wired
  repo: OSOVM
  file: src/token_guards.jl
  symbol: ase_transfer_guard
  work: "replace fail-open stub with real check: return !is_agent(recipient)"
  depends_on: "I-4 (is_agent implementation)"

- id: I-4
  status: STUB
  blocker: principal registry not wired
  repo: OSOVM
  file: src/token_guards.jl
  symbol: is_agent
  work: "query principal registry to distinguish human accounts from agent addresses; replace stub returning false"
  depends_on: "Vantage principal registry API"

- id: I-8
  status: STUB
  blocker: principal identity resolver not wired
  repo: OSOVM
  file: src/token_guards.jl
  symbol: check_self_deal
  work: "resolve buyer/gpu_host/birther to canonical principal ids; deny when all three match"
  depends_on: "I-4 (principal registry)"

- id: I-14
  status: STUB
  blocker: job settlement handler not wired to genealogy payout
  repo: Vantage
  file: backend/agents.py
  symbol: compute_birther_royalty
  work: "call compute_birther_royalty from job-settlement path; persist royalty_payout; apply decay schedule"
  depends_on: "job settlement handler wiring"

- id: I-32
  status: STUB
  blocker: epoch tally ledger not wired
  repo: OSOVM
  file: src/token_guards.jl
  symbol: "enforce_epoch_cap, enforce_repeat_limit"
  work: "wire enforce_epoch_cap and enforce_repeat_limit into the COMPUTE_PROOF / TOC_MINT gate at EndBlock"
  depends_on: "none"

- id: I-36
  status: PARTIAL
  blocker: non-claimant referent assignment flow not implemented
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: referent_id
  work: "add flow where a non-claimant sets referent_id before create_receipt is called; stub creates receipts with empty referent_id"
  depends_on: "I-25 (witness network provides referent binding)"

- id: I-37
  status: PARTIAL
  blocker: same as I-36 — referent_id is still empty in practice
  repo: OSOVM
  file: src/zangbeto_receipts.jl
  symbol: seal_data
  work: "ensure referent_id is populated by a non-claimant before seal is computed; currently zang-ref seal binds empty string"
  depends_on: "I-36"

# ────────────────────────────────────────────────────────────────────────────
# PERMANENTLY BLOCKED — require external infrastructure decisions
# ────────────────────────────────────────────────────────────────────────────

- id: I-18
  status: BLOCKED
  blocker: "external Zàngbétò anchor POST endpoint (E-53)"
  repo: Omo-Koda2
  file: omokoda-core/src/bridge/arp.rs
  symbol: zangbeto_anchor
  work: "tracked as E-53; implement when Zàngbétò exposes POST /anchor"
  depends_on: "Zàngbétò service v2"

# ────────────────────────────────────────────────────────────────────────────
# CHECKER GAPS (real invariants, checker still imprecise)
# ────────────────────────────────────────────────────────────────────────────

- id: I-15
  status: OPEN
  blocker: AIO/Technosis escrow module not present locally (ECO_ALLOW_ABSENT candidate)
  repo: Technosis/AIO
  file: aio/sources/escrow.py (expected)
  symbol: escrow
  work: "implement job-funding escrow so failed jobs refund and birther cut is contingent"
  depends_on: "none"

- id: I-6
  status: PARTIAL
  blocker: toc_drift_check.py does not include ase_minting.jl and abci_endblock.jl
  repo: sovereign-eco-blueprint
  file: specs/toc_drift_check.py
  symbol: "ase_minting.jl, abci_endblock.jl targets"
  work: "add OSOVM/src/ase_minting.jl and abci_endblock.jl to the drift check file list"
  depends_on: "none"

# ────────────────────────────────────────────────────────────────────────────
# DEPENDENCY ORDER for sequential implementation
# ────────────────────────────────────────────────────────────────────────────
#
# Phase 1 — Principal registry (unlocks I-3/4/8):
#   Implement Vantage principal registry; wire is_agent() in token_guards.jl
#
# Phase 2 — Epoch ledger (unlocks I-32):
#   Wire epoch_tally + repeat_count into TOC_MINT / EndBlock
#
# Phase 3 — Witness network (unlocks I-17/25/29):
#   Deploy 12 independent witness nodes; replace request_witness_votes stub
#
# Phase 4 — Score attestation (unlocks I-24/36/37):
#   GIX-addressable score receipts signed by verifier; non-claimant sets referent_id
#
# Phase 5 — TEE integration (unlocks I-28):
#   Wire SGX DCAP / TDX quote signature verification
#
# Phase 6 — Endpoint + settlement (unlocks I-14/18):
#   Zàngbétò POST /anchor + birther royalty settlement payout
