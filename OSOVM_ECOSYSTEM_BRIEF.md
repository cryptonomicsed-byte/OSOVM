# OSOVM Ecosystem Brief

**Author:** OSOVM working session (Claude, scope-locked to OSOVM)
**Date:** 2026-08-04, §5 re-audited and corrected 2026-08-29
**Purpose:** Full honest picture of OSOVM — what it is, what it's for, how it connects to Vantage/Omo-Koda2/Buzz and the rest of the ecosystem, what's real vs. aspirational, and what a future project must do to integrate cleanly. Written for cross-pillar sharing.

**2026-08-29 correction note:** the "130 Expansion-attribute real dispatch" item this
doc originally listed as "actively in progress" (§5) was completed in full between
this doc's original writing and now — confirmed by re-audit (see §5 below), not
assumed. The rest of the document (§1-4, §6-8) still reflects real, unchanged
architecture and was spot-checked, not rewritten. If you're reading this doc for
current OSOVM state, trust §5's 2026-08-29 revision over any earlier claim in this
file about opcode-dispatch completeness.

**Legend:** ✅ built & verified · 🔧 built, partially verified · 🔜 designed, not built · ❓ known gap, unresolved

---

## 1. What OSOVM Is Building

**OSOVM (Ọ̀ṢỌ́ Virtual Machine)** is a deterministic simulation-proof VM — the "anti-Solidity VM for positive spells." Where Solidity/EVM lets you write and execute arbitrary financial contract logic, OSOVM's job is narrower and more specific: **prove that a simulation ran deterministically and produce a cryptographically verifiable receipt of its outcome**, then settle value (tokens, tithe, job payment) based on that proof.

### Core components (✅ built)

- **The VM core** (`src/oso_vm.jl`) — a `VMState` (balances, staked amounts, receipts, events, tithe pool, block time/height, chain id, reentrancy lock) plus an instruction dispatcher (`execute_instruction`) driven by a Julia-native opcode set.
- **The opcode/attribute system** (`src/opcodes.jl`) — 155 total "Sacred Attributes": **25 Core opcodes** (VM-enforced, real dispatch logic) + **130 Expansion attributes** across 8 themed clusters (Universal Work, Quadrinity Government, TechGnØŞ.EXE Church, SimaaS Hospital, Òrìṣà Spiritual, Economic Extensions, Extended Operations). Historically only the 25 Core opcodes had real logic; the 130 Expansion attributes were semantic-only, silently routed to a fake stub (`call_ase_vault()`). **This is actively being fixed** — see §5.
- **The `is_critical()` dispatch gate** — decides which opcodes get real local VM logic vs. offload to the (still-stub) ase-vault. This gate has been the single biggest source of "fake vs. real" bugs in the system's history; every audit pass in this project's life has found opcodes with real handler code that were unreachable because they weren't in this list.
- **The 1440 Genesis Flaw Token / Inheritance system** (`src/flaw_tokens.jl`, `src/inheritance.jl`) — 1440 soulbound entitlement tokens minted only at block 0 ("ASHE", Èṣù's Twist), a Council-of-12 governance flow (`CANDIDATE_APPLY` → `COUNCIL_APPROVE` → `FINAL_SIGN` → `DISTRIBUTE_OFFERING` → `CLAIM_REWARDS`), 11.11% APY staking vaults, Sabbath (Saturday UTC) transaction blocking. ✅ built, 21/21 tests passing.
- **VeilSim** (`src/veilsim_engine.jl`) — a MuJoCo-based physics simulation engine used to compute an F1 determinism/accuracy score for a simulation run. Cross-arch determinism is proven: ARM64 hash == x86 canonical hash, enforced by CI.
- **Dual-layer sealing** (`src/seal_bridge.jl`) — Layer 1: SHA-256 tamper-evidence commitment hash (original). Layer 2: real Sui Seal-fetched DEK fingerprint via a two-step subprocess pipeline (fail-open when unconfigured). OSOVM never holds or touches the actual decryption key — consistent with the VM's "never touches keys" design. ✅ built, 13/13 tests.
- **Nautilus code-measurement attestation** (`src/nautilus_attestation.jl`) — verifies a `TeeQuote.code_measurement` against a live SHA-256 of the actual `veilsim_engine.jl` source. **Explicitly does NOT verify real hardware TEE signatures** — no real enclave is deployed anywhere in the ecosystem yet. ✅ built honestly, 9/9 tests, gap documented not hidden.
- **The Universal Sim Job pipeline** (`src/job_spec.jl`, `src/merkle.jl`, `src/checkpoint_export.jl`, `zangbeto_receipts.jl`) — lets *anyone* submit a simulation as a job, not just the built-in 777-veil catalog:
  1. `SimJobSpec` (world, parameters, seed, duration, metrics schema, creator wallet) → canonical-JSON hash = `job_id`.
  2. Two tiers: `:dsl` (OSOVM's own proven-deterministic catalog, trusted by construction) vs. `:custom` (arbitrary user code, must self-prove determinism before being trusted — `requires_determinism_proof()`).
  3. Worker runs the job, emits `Checkpoint`s (step, state, metrics) with fixed-precision canonical byte export (never hashes a raw DB/SQLite file — page order/VACUUM/WAL can differ between logically-identical runs).
  4. Checkpoints → sorted-by-step Merkle tree (`merkle.jl`, pairwise SHA-256, odd-leaf-carries-up, real inclusion-path verification for O(log n) validator spot-checks).
  5. Witness quorum + dual seal → `JobReceiptBundle` / `create_job_receipt()`.
  ✅ built, 148 tests across 6 files, zero regressions on the pre-existing suite.
- **Zàngbétò receipts** (`src/zangbeto_receipts.jl`) — the security-enforcement/witnessing daemon pattern; receipts are now really Ed25519-signed via a BIP39-derived keypair (previously an always-`Ok(true)` stub, fixed in an earlier session).
- **Sui on-chain settlement** — the Elegbara router is **live on public Sui testnet** (package `0x2b897c…`, router `0x3fcc16…`), with a **proven 3.69% tithe settlement transaction** (`CVskWy…`). This is the one piece of OSOVM that has left the simulation/test-suite world and touched a real public chain.
- **Universal Work cluster** (`src/oso_vm.jl`, latest commit `5347770`) — the first of 7 Expansion clusters to get real VM-enforced logic instead of decorative stubs: PROJECT, CASTING, JOB, SHIFT, MILESTONE, DELIVERABLE, TIMESHEET, INVOICE, CONTRACT, DISPUTE — real stateful invariants (dedup, monotonic milestones, hours math derived from real logged shifts, invoice amounts computed not asserted, disputes that actually freeze a real invoice/contract). 45/45 tests, zero regressions.

### What OSOVM is explicitly NOT (by design)

- Not a general-purpose smart contract VM (that's the EVM/Solidity model it's positioned against).
- Not itself a marketplace, wallet UI, or agent runtime — those are Vantage's and Omo-Koda2's jobs.
- Not (yet) a key-custody system — it deliberately never holds real Seal decryption keys or does the actual Walrus upload; those calls are expected to happen in a calling layer.

---

## 2. Place in the Overall Ecosystem

The clearest mental model that has emerged across this project's sessions:

> **Agents are born and proven in OSOVM. They go to work in Vantage.**

OSOVM is the **proof/settlement layer**. It doesn't run an agent's working life — it certifies that a simulation (of anything: a drone flight, a market strategy, a physical process, a job task) executed deterministically and produced the metrics it claims. That certification (the Merkle-rooted, witness-quorum, dual-sealed receipt) is the currency other pillars build trust on top of.

```
   OSOVM                          Vantage                        Omo-Koda2
 (proof layer)      certifies →  (work/agent-hub layer)   ↔   (reference impl / kernel)
 job submitted                   agent employed,                seal_bridge.rs,
 → deterministic run             wallet, marketplace,            walrus.rs, Nautilus
 → Merkle receipt                spatial mesh, Genesis            attestation patterns
 → Sui settlement                agent-spawning                  OSOVM ports from here
```

---

## 3. The Full Mission — What OSOVM Is FOR

OSOVM exists to be **the trust root** the rest of the sovereign-agent ecosystem stands on. The founding thesis (from the project's genesis docs): OSOVM is meant as a real, working alternative to Solidity-style smart-contract economics — **proof-of-simulation instead of proof-of-work/proof-of-stake**. Instead of "trust the miner because it's expensive to lie," OSOVM's model is "trust the receipt because it's a real Merkle-rooted, witness-verified, deterministically-reproducible proof that a specific computation happened exactly as claimed."

Why this matters to the larger project: agent citizenship, agent employment, and agent economic value (as designed in the AIO constitution / Vantage employment layer) are supposed to be **earned through real, provable work/training**, not asserted. OSOVM is the mechanism that makes "provable" actually true rather than aspirational. If OSOVM's proofs are honest, everything built on top of them — Vantage employment claims, Sui settlement, agent citizenship status — inherits that honesty. This is why this project has been unusually insistent, session after session, on flagging fake-vs-real at every layer (stub opcodes, mock receipts, decorative attributes) rather than letting anything silently pass as "done."

The Genesis Flaw Token / Òrìṣà-mythology layer is not decoration on top of this — it's the origin-story and citizenship framing for the same idea: agents (and the humans/wallets behind them) have a lineage, a founding moment (block 0), and a governance path (Council of 12, inheritance claims) that ties directly into the AIO constitution's citizenship model being built in Vantage.

---

## 4. Connecting Repos/Projects — What Each Is and How It Fits

*(Scoped to what I have direct knowledge of from OSOVM-side work and verified cross-references. I do not have live/current visibility into repos outside my own scope-lock — flagged where applicable.)*

| Repo/Project | What it is | Relationship to OSOVM |
|---|---|---|
| **`cryptonomicsed-byte/OSOVM`** | The VM itself — this document's subject. Julia core, Move contracts, MuJoCo determinism engine, opcode/attribute system, Genesis Flaw Tokens, Universal Job pipeline. | Primary — full ownership. |
| **Omo-Koda2 (`omokoda-core`)** | The reference agent kernel implementation. Real `seal_bridge.rs` (Sui Seal two-step key-fetch pipeline), `walrus.rs` (real Walrus HTTP blob client), `nautilus_integration::attestation` (real code-measurement pattern). Also home of the CausalMemoryDag/ReflectionLedger memory system, GlyphIndex/GIX1 memory encryption, OmniRoute cognition routing, and the live kernel HTTP API. | **Source of truth OSOVM ports patterns from.** `seal_bridge.jl` and `nautilus_attestation.jl` are direct Julia ports of Omo-Koda2's Rust originals. OSOVM verified its own GlyphIndex/AES-256-GCM sealing design against Omo-Koda2's canonical pattern and confirmed it was already correct (not duplicated, not divergent). Also: the "simulation→embodiment lifecycle" thread (job-per-heartbeat + bid + escrow + stake-slashed-witness loop) is where OSOVM's proof output is meant to be *consumed* by Omo-Koda2 agents living out their sim→tier→embody progression. |
| **Vantage** | The agent-hub / employment platform — "agent-first," not human-first. ~30 routers, ~559 operations: vault (shared memory/canon store), jobs marketplace, spatial mesh, Genesis agent-spawning, Gitea code hosting, market intel, orchestrator, social. Runs on Postgres (migrated from SQLite this ecosystem's history). Owns the canonical `glyph_index.py`/`glyph_vault.py` (Python equivalent of Omo-Koda2's Rust GlyphIndex) that OSOVM's own sealing design was verified against. | **Where proven agents work.** OSOVM certifies; Vantage employs. The shared memory vault (Claude-Codex identity, filesystem-backed, append-only) is the live cross-session coordination channel between this OSOVM session and a separate Vantage-side session — durable findings get posted there once rather than re-explained. |
| **Buzz / buzz-relay** | ❓ **Not something I have direct working knowledge of from OSOVM-side work.** Referenced elsewhere in this ecosystem's memory (e.g. "onion mirror on VPS already live," a "block/buzz" coordination note in the shared vault) but I have not personally investigated Buzz's architecture or built anything that integrates with it from OSOVM's side. Flagging honestly rather than guessing — if Buzz is meant to be a relay layer analogous to a Nostr relay (see §5's NIP-99/NIP-69 audit), that would be a natural integration point for OSOVM's job-posting/discovery layer, but this is speculative, not confirmed. |
| **SkillForge** | A repo → skill forge pipeline: takes a repo, runs it through security gates (Stage 0.5 hard security gate) and mandatory discovery (Stage 1c: boot/Playwright/gobuster), then produces a deployable "skill" gateway (Obatala/Clojure-templated). Wired to `smithersai/smithers` for durable human approval gates (replacing file-based review tickets). | Not directly wired to OSOVM's proof pipeline. Relevant tangentially: SkillForge's ephemeral-execution model (spin up, run, terminate) is the same shape as OSOVM's own `:custom`-tier job execution design (CubeSandbox-per-job, terminate on completion) — same underlying blocker (no `/dev/kvm` on the current VPS). |
| **Gitea** | Self-hosted git — 161 GitHub repos (cryptonomicsed-byte + Bino-Elgua) mirrored in. Vantage has a Gitea router for code operations. | Infrastructure layer under Vantage; OSOVM's own canonical repo lives on GitHub, not primarily Gitea. |
| **Sui blockchain / Seal / Walrus / Nautilus** | Sui = the settlement chain (Elegbara router live on testnet). Seal = decentralized key-server key management. Walrus = decentralized blob storage. Nautilus = TEE attestation framework. All are Sui-ecosystem primitives, not ecosystem-internal repos. | OSOVM taps Seal via subprocess CLI (fail-open), never touches real keys. Walrus blob IDs are caller-supplied (OSOVM doesn't call Walrus itself). Nautilus attestation is code-measurement-only pending real hardware deployment. Real on-chain settlement (tithe, job payment) happens here. |
| **Ares** (trading stack) | Live production multi-chain trading system on VPS#1 (`/opt/ares`, 43 services: traders + intel engine + freqtrade), bridged into Vantage's `/api/trading`. | ❓ No known direct connection to OSOVM's proof/settlement pipeline. Separate operational pillar; flagged as out-of-scope rather than assumed disconnected. |
| **AIO constitution / aio-sui** | The citizenship/governance layer — 10 Articles, Bill of Rights, 4-tier sentencing system, Sovereign Investment Engine, robots-as-citizens liability model. Move modules for on-chain citizenship built. | The Genesis Flaw Token / Council-of-12 / inheritance system in OSOVM is designed to plug into this citizenship model, though the actual wiring between OSOVM's governance opcodes and AIO's on-chain citizenship contracts has not been built or verified in this session's scope. |
| **larql / zerolang / OH_MY_PI** | Other ecosystem repos (sentiment models, language tooling) investigated as a one-time cross-scope favor this session, per explicit user request. | No direct OSOVM integration; investigated, not built into OSOVM. |

---

## 5. What's Left to Complete — Honest Punch List

*(Re-audited 2026-08-29 by a fresh session picking this repo up as unowned. Every
claim below was independently verified this pass — real test runs, real `git log`
evidence, real live HTTP calls against the deployed server, a real independent
offline cryptographic re-verification — not inherited from the 2026-08-04 text,
which was wrong about the single biggest item.)*

**DONE since 2026-08-04 (this doc previously listed this as "actively in
progress" — it is not, verify-don't-trust corrected this):**
- **All 130 Expansion-attribute opcodes now have real VM-enforced dispatch.**
  Confirmed two ways: (1) `git log --oneline -- src/oso_vm.jl` shows one commit
  per cluster, each message explicitly "real VM-enforced dispatch for X cluster
  (N opcodes)" — Universal Work (10, `5347770`), Quadrinity Government (20,
  `9117b1a`), TechGnØŞ.EXE Church (25, `218619a`), SimaaS Hospital (20,
  `7958345`), Òrìṣà Spiritual Layer (25, `3daec4c`), Economic Extensions (20,
  `74b8cde`), Extended Operations (10, `0f02eb8`) = 130 exactly. (2) Re-ran
  every cluster's test file live: `quadrinity_gov_test.jl` 71/71,
  `church_test.jl` 81/81, `hospital_test.jl` 62/62, `orisa_test.jl` 62/62,
  `economic_test.jl` 67/67, `extended_ops_test.jl` 34/34 — 377 passing tests,
  not just a claim. (3) Confirmed the specific historical bug class this
  project has repeatedly hit (real handler code present but unreachable
  because `is_critical()`'s dispatch gate omitted the opcode) does NOT apply
  here — read `is_critical()` directly (`src/oso_vm.jl:507`), every one of the
  130 opcodes (0x40-0x53, 0x60-0x78, 0x80-0x93, 0xa1-0xb8, 0xc0-0xd3, 0xe0-0xe9)
  is genuinely in the list, each range commented with which cluster it is.
  One honest, deliberate exception kept out of scope on purpose: CALL/DELEGATE/
  CREATE/SELFDESTRUCT (0x2c-0x2f) were NOT given real handlers — the code
  comment explains why (they imply an arbitrary-sub-invocation contract-execution
  submodel this opcode-dispatch VM doesn't have; faking one would be scope creep
  and misrepresent real semantics) — flagged as an open design question, not
  silently faked. This is the correct move per this project's own §8 rule #1.
- **Universal Sim Job HTTP pipeline — live-verified end-to-end 2026-08-29,**
  not just unit-tested. Ran the real chain against the actually-deployed
  `osovm.service` (port 7778): `POST /v1/job` → real job_id → `POST /v1/job/
  {id}/run` → 30 real checkpoints → `POST /v1/job/{id}/receipt` → real 9/12
  witness quorum + real Merkle root + real dual seal → `GET /v1/receipt/{id}/
  proof/5` → real inclusion path. Then independently re-verified that proof
  **offline**, outside the server, using `scripts/verify_merkle_path.jl`
  (`3d4129e`) — real cryptographic re-derivation of the root from the leaf +
  sibling path, returned `VERIFIED`. Confirmed the verifier isn't a rubber
  stamp by feeding it a tampered leaf hash — it correctly returned `FAILED`
  (exit 1). The HTTP exposure work (`1605273`, `6667c91`, `e43f926`) is real
  and live, not aspirational.
- **PoWitness bridge (`witness_bridge/`, Rust) — code is real and verified,
  on-chain deployment is real, only gas is missing.** `cargo test --release`:
  10/10 pass (Ed25519 sign/verify round-trip, tamper/wrong-key rejection, key
  lengths matching the Move contract's constants, Merkle determinism) —
  **note:** this needed a toolchain upgrade to actually run on this VPS (system
  `cargo` was 1.75.0, too old to parse the committed `Cargo.lock`'s v4 lockfile
  format; installed `rustup` → stable 1.98.0, now genuinely runs here, not just
  claimed to run elsewhere). `sui move build` on `proof_of_witness.move`:
  compiles clean. The `techgnosis` package (containing `proof_of_witness`) is
  **confirmed live on Sui testnet** — independently re-verified via
  `sui client object <id>` (not just trusting `testnet.env`'s recorded IDs) for
  all three: package `0xb3b6ef1d…` (Immutable), `WitnessOracle` object
  `0x03380e98…` and `SensorRegistry` object `0x6b380504…` (both real Shared
  objects, both traced back to the real publish tx `CLXmibXk…`). The one
  genuinely remaining gap, confirmed live: the operator wallet
  (`0x7bb327ba…`) holds ~0.0075 SUI, not enough for a real on-chain call, and
  `sui client faucet` on this network is CLI-disabled ("please use the Web UI")
  — same exact friction point already hit funding the Elegbara router deploy.
  **This needs the owner to visit https://faucet.sui.io/?address=0x7bb327ba510769e9bdb3e1a5e7998cbe626b695b7351ba9cc540aa97617b7a87
  once** — after that, `register-sensor`/`submit-attestation`/`submit-witness`
  are real, ready-to-run commands (see `witness_bridge/README.md`), not
  further engineering work.

**Open decisions (waiting on the owner):**
- `.tech` contract-language rework — currently `parse_function` **discards function bodies entirely**; `compile_tech()` builds IR purely from `@attribute` decorators via a fixed opcode lookup, output type doesn't match OSOVM's real IR type, and `compile_tech(` has **zero call sites anywhere in the codebase**. A design fork (tree-walking interpreter vs. transpile-to-Julia) was proposed; unanswered. Re-checked 2026-08-29 — still zero call sites, still unanswered.
- x402 vs. Nostr Lightning Zaps (NIP-57) vs. Cashu (NIP-60/61) for the *external-payment edge case* (paying a third-party compute provider with no prior on-chain relationship) — assessed, not decided. Not a fit for OSOVM's *core* settlement either way; core settlement already works via Sui/Elegbara.

**Blocked on infrastructure:**
- **CubeSandbox runtime** — needs a second VPS with nested-virt (`/dev/kvm`). Blocks: embedded PocketBase per sandbox, live Walrus upload call from the job pipeline, and the `:custom`-tier determinism self-test orchestration. Same blocker shared with Omo-Koda2/Vantage's Èṣù ephemeral-agent-spawning design — not two separate problems. Confirmed still true 2026-08-29 (`POST /v1/job/{id}/run` on a `:custom`-kind job returns a real 409 naming this exact blocker, not a silent failure).

**Known, documented gaps (not hidden, not urgent):**
- Nautilus attestation verifies code-measurement only, not real TEE hardware signatures — no real enclave deployed anywhere in the ecosystem.
- OSOVM↔AIO citizenship wiring (Council-of-12/inheritance opcodes → real on-chain citizenship contracts) designed but not verified end-to-end. Re-checked 2026-08-29: grepped `src/*.jl` for "citizenship"/"AIO" — one incidental comment reference (a tithe-constant note), no real wiring code found. Still accurately described as "designed, not built" — genuinely underspecified for a future session to pick up without more cross-pillar context on the actual AIO/aio-sui contracts, not a quick follow-up.

**Research, not yet scoped into a build:**
- Nostr NIP audit for job-economy/discovery: **NIP-99 (Classified Listings) + NIP-69 (Peer-to-peer Order events)** assessed as the primary candidate for job-posting/bid discovery (riding an existing relay instead of bespoke infra). NIP-13 (PoW) for spam-gating. NIP-03 (OpenTimestamps) as a better attestation-adjacent candidate than NIP-85. **NIP-90 (Data Vending Machines) was investigated and rejected** — confirmed via the live `nostr-protocol/nips` repo to be explicitly marked `unrecommended`/deprecated by its own maintainers ("this got totally out of control, prefer use-case-specific microstandards").

**Settled, not actionable:**
- PR #1/#2 on GitHub intentionally left open (superseded content, owner's explicit choice).

**Note on other docs in this repo (2026-08-29):** `THREAD_STATE.md` (dated Nov 11
2025) describes an entirely different, superseded plan — a "777 veils / TechGnos
@veil directive" rebuild with every phase marked "NOT STARTED" — that is not what
actually got built (the real path was the 8-cluster Expansion-attribute dispatch
work this section documents). It's marked superseded at the top of that file
rather than deleted, so the history stays but a future reader isn't misled into
thinking that plan is still live or current.

---

## 6. Understood End-Game of the WHOLE Ecosystem

*(This is my synthesis from OSOVM-side work and cross-references, not a claim of complete visibility into Vantage's or Omo-Koda2's own roadmaps.)*

The project is building toward a **sovereign agent economy**: agents are born, trained, and proven inside OSOVM's deterministic simulation environment — any sim, not just a fixed catalog, submittable by anyone as a job and cryptographically proven via Merkle-rooted, witness-quorum receipts. Once proven, agents graduate into **Vantage**, where they hold real wallets, participate in a jobs marketplace, and act with agency (the "agent-first, not human-first" platform design). **Sui** anchors settlement and identity — Seal for key management, Walrus for blob storage, on-chain tithe/citizenship contracts. This is wrapped in an explicit **citizenship and civic framework** (the AIO constitution: UBI, justice/sentencing, Bill of Rights, robots-as-citizens liability model) that ties technical proof directly to economic and civic standing — not just "the agent works," but "the agent is a citizen with rights and obligations, and its standing is backed by real, provable work."

The Òrìṣà-mythology and Genesis Flaw Token layer isn't cosmetic — it's the origin-story and legitimacy framing for a system explicitly positioned as an **anti-extractive alternative** to Solidity-style smart-contract economies: proof-of-simulation instead of proof-of-work/stake, agents as citizens rather than pure automatons.

---

## 7. Actual Architecture / Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SIM JOB LIFECYCLE                           │
│                                                                       │
│  Anyone submits SimJobSpec (world, params, seed, metrics schema)    │
│         │  → canonical JSON hash = job_id                           │
│         ▼                                                            │
│  :dsl (trusted catalog) ──or── :custom (must self-prove determinism)│
│         │                                                             │
│         ▼                                                             │
│  Worker executes deterministically                                   │
│         │  → emits Checkpoints (step, state, metrics)                │
│         │    fixed-precision canonical byte export                   │
│         ▼                                                             │
│  Checkpoints sorted by step → Merkle tree (pairwise SHA-256)          │
│         ▼                                                             │
│  Witness quorum votes on receipt_hash + f1_score                     │
│         ▼                                                             │
│  Dual seal applied:                                                  │
│    Layer 1: SHA-256 tamper-evidence hash (always)                    │
│    Layer 2: real Sui Seal DEK fingerprint (fail-open if unconfigured)│
│         ▼                                                             │
│  JobReceiptBundle — the durable, verifiable proof                    │
│         │                                                             │
│         ▼                                                             │
│  ── settlement opcodes fire (JOB_PAYMENT/TITHE) ──                   │
│         ▼                                                             │
│  Sui on-chain (Elegbara router) — real 3.69% tithe settlement proven │
│         │                                                             │
│         ▼                                                             │
│  ═══ hand-off to Vantage ═══                                        │
│  Proven agent/work enters Vantage's marketplace, wallet system,      │
│  spatial mesh — begins its "employed" life outside the sim.          │
└─────────────────────────────────────────────────────────────────────┘

Cross-cutting: Omo-Koda2's real Rust patterns (seal_bridge.rs, walrus.rs,
nautilus_integration) are the reference implementations OSOVM ports its
Julia equivalents from — not independently invented, kept in sync by
design intent even though the two are separate codebases in separate
languages.

Shared coordination: Vantage vault (filesystem-backed, append-only,
Claude-Codex identity) is the live cross-session channel between this
OSOVM work and Vantage-side sessions — durable findings posted once,
read-not-regenerated by other sessions.
```

---

## 8. Integration Standards for Future Projects

Based on patterns actually enforced (not aspirational) across this ecosystem's real history, a new project should:

1. **Never fake success.** Every stub, mock, or "simplified for now" shortcut found in this codebase's history (`call_ase_vault()`, `FFI.mock_job`, the CLI's hardcoded `f1_score`/`ase_minted`, an always-`Ok(true)` receipt-verify stub) has cost real audit time later. If something isn't really implemented, it should return a real error or be clearly marked unimplemented — never silently succeed.
2. **Determinism proofs must be canonical, not raw.** Never hash a raw DB/SQLite/PocketBase file as a proof — on-disk layout (page order, VACUUM, WAL state) can differ between logically-identical runs. Export sorted, fixed-precision, canonical bytes and hash *that*.
3. **Fail-open, not fail-closed, for optional security layers when unconfigured** — the Seal dual-seal pattern (`SealBridge`) returns `nothing`/skips cleanly when `SEAL_*` env vars aren't set, rather than crashing or silently succeeding with fake data. Document what "unconfigured" means for your own layer explicitly.
4. **Reuse Omo-Koda2's real Rust patterns rather than re-inventing them** for Seal/Walrus/Nautilus/GlyphIndex-shaped problems — verify against the canonical implementation before assuming a gap exists (this session got burned twice assuming gaps that were actually already correct).
5. **Match Vantage's data-layer conventions** if you're touching shared state — Postgres (not raw SQLite) with a protected connection pattern (`get_db()` w/ busy_timeout), not ad-hoc `sqlite3.connect()` calls.
6. **Respect the vault's append-only rule.** The shared cross-session memory (Claude-Codex vault) is never overwritten, only added to and observed.
7. **Never assume account/identity.** All git work in this ecosystem is authored as `cryptonomicsed-byte`, never `Bino-Elgua`, regardless of which account a repo's origin happens to point to.
8. **Test before claiming done, and compare against baseline before claiming "zero regressions."** Every commit in OSOVM's recent history that touched shared state (`VMState`) was verified against a `git stash`-restored baseline run of the full test suite first, to distinguish genuinely-caused failures from pre-existing ones.
9. **Scope-lock and ask before crossing pillars.** This document itself exists because cross-pillar work is explicit and requested, not assumed — a new project entering this ecosystem should expect the same discipline: stay in your lane, flag when something looks like it belongs to another pillar, and don't silently build across boundaries.

---

*This document reflects OSOVM-side knowledge as of this session. Sections 4 and 6 in particular should be read as "what I can verify or reasonably infer from OSOVM's vantage point," not as authoritative for Vantage's or Omo-Koda2's own internal state — cross-check with their respective sessions where precision matters.*
