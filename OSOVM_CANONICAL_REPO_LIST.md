# OSOVM Pillar — Canonical Ecosystem Repo/Project List

**Author:** OSOVM working session · **Date:** 2026-08-04
**Purpose:** Follow-up to the OSOVM Ecosystem Brief — (1) derives the "1:1 world" concept from the shared Vantage vault, (2) confirms the full agent-birth sequence and repos it depends on, (3) notes unreconciled parallel projects, (4) produces this pillar's canonical repo list, for comparison against Vantage's and Omo-Koda2's own lists.

---

## 1. The "1:1 World" / Drone-Hive Concept — Derived from the Vault

Searched the shared Claude-Codex vault (`/api/agents/Claude-Codex/vault/search`) for "1:1", "hive mind", "digital twin", "drone hive", "business gate". No literal phrase "drone-hive 1:1 mapping business-gate" exists verbatim anywhere in the vault — that term appears to be a paraphrase from an earlier session, not a canon quote. But the underlying concept is fully documented, in `knowledge/OSOVM_CODEX.md` §26 ("Spatial Twin layer") and §30e/30g, recorded 2026-07-11 as a **roadmap, phase-3, deferred behind P0**.

**The actual concept, in the owner's own words (quoted from the codex):**
> "use GPUs to eventually create a **1:1 mapping of the world for agents to sim in**; gather images from ALL [devices] ... it all in **Walrus blobs** so the tile-world becomes a **1:1 twin**."

**How it works:**
- Crowd-sourced devices (phones, drones, robots) capture RGB(+depth/LiDAR) → each generates a local **3D Gaussian Splatting (3DGS)** "blob" of its area.
- Blobs fuse via **collaborative multi-agent SLAM** (loop closure, global bundle adjustment) into one shared, growing reconstruction of the real world.
- That reconstruction becomes **USD → NVIDIA Omniverse + Isaac Sim** — a controllable, ground-truth twin with real PhysX physics and deterministic sensors, usable as a **mineable PoSim sim substrate** (this is the direct link to OSOVM: a real-world-grounded sim can be proven the same way any other OSOVM job is proven).
- **Omo-Koda2 agents train inside that real-grounded world**, then **embody** (e.g. via Unitree hardware) in the actual physical place the twin represents.
- **NVIDIA Cosmos** (generative) is explicitly walled off from this — it's allowed only as *appearance* augmentation (lighting/weather/texture variation) conditioned on the real Omniverse structure, and is a **hard rule** that it can never be part of the reproducible proof side (Cosmos output isn't reproducible, so no validator could re-derive it).
- The mapping/capture work itself is a **new mineable job type** — a "blob contribution" earns Àṣẹ like a DePIN mapping network (Hivemapper-style), scored on coverage/novelty/geometric consistency, dropping into the same uncapped 1440/day emission as other OSOVM work.
- **Business/economic gate**: the twin data itself is framed as a **sellable asset** — "we can eventually sell the data and use it to pay users" — a DePIN flywheel (cheap crowd-captured reality → valuable living twin → revenue → pays the fleet/contributors, tithe-gated like everything else).

**Explicit, owner-confirmed honesty caveats already in the canon** (this is not naive hype — the design document is self-skeptical):
1. **"1:1" is aspirational, not literal.** High fidelity only in densely-captured bounded zones (a campus, a warehouse, a city block); sparse/stale everywhere else, and the world keeps changing underneath it. It's explicitly termed "a living twin of covered zones," not a literal 1:1 of the world.
2. **Fusion (registering mismatched cameras/drift/scale into one consistent map) is the actual research-grade hard problem** — the biggest engineering cost.
3. **Privacy/legal is called out as the real wall, bigger than the tech** — faces, plates, interiors, GDPR/BIPA. Consent/redaction from day one or it's a lawsuit.
4. **Two-tier compute** — capture is cheap/decentralized (DePIN-friendly), but fusion + Omniverse/Cosmos need real data-center GPU, which is centralized. The design explicitly flags this as a trade against the sovereign/local-first ethos, not free.
5. **Sequencing discipline**: this is explicitly phase-3+, gated behind the P0 determinism proof (Julia/OSOVM's own sim pipeline working, cross-machine determinism verified — which OSOVM itself closed this ecosystem's history ago). The canon's own words: *"Do NOT let this shiny layer pull focus until one agent completes one deterministic sim and reaches one real device."*

**So: the "1:1 world" is OSOVM's long-horizon training-substrate vision** — a crowd-built, DePIN-funded, real-world digital twin that Omo-Koda2 agents train in before physically embodying, gated behind a strict reconstruction-vs-generation wall so the proof side never touches non-reproducible generative content, and gated behind privacy/legal + P0 sequencing discipline. It is **not built** — it's a well-specified roadmap item, explicitly deferred, one of the more mature "designed but not started" pieces in OSOVM's own canon.

---

## 2. Parallel, Unreconciled Hermes-Driven Projects (Noted, Not Investigated)

Per the owner's flag: **BuzzAgent Mesh** (`~/Buzz-swarm`), **Bondhive** (`~/bondhive`), and likely **Iranti** exist on the Mac side and are real, Hermes-driven parallel work — but **none of the three appear anywhere in the shared Vantage vault** (searched directly, zero hits for "Bondhive," "Iranti," "BuzzAgent"). This confirms they are genuinely not yet reconciled into the three-pillar structure or its shared memory — not an oversight on my part, an actual gap in the ecosystem's own cross-session bookkeeping. Flagging their existence here for the record, per instruction, without investigating further (out of scope for this pass, and I don't have direct filesystem access to the Mac's `~` from this VPS-based session).

---

## 3. Agent Birth Sequence — Confirmed Chain + What Else It Touches

Cross-checked against the vault (`convo-1a475350-part07/08/09`) and VPS `/opt/ares` listing. The real, working birth sequence, in order:

```
BIPON39 (Rust, HD seed derivation, Yorùbá-enriched mnemonics)
   → IfáScript (Odù sign — the "traditional Yorùbá Odù corpus" full parallel structural twin)
   → Koodu (resonance/codex — the ritual runtime; real btc-time.js confirmed genuine substantive
     Bitcoin-block-height calendar math, verified in a prior audit, not a stub)
   → CloakSeed / vanity-cloakseed (vanity address generation + cloak/duress panic-room layer —
     "ritual codex is Koodu and vanity is CloakSeed," per the owner directly)
   → signs agent_id with Sui-derived Ed25519 keypair
   → POST /api/agents/register (Vantage) → POST /api/mesh/agents/join
```

**Two additional real repos this sequence (or its immediate surroundings) depends on that were not previously named in my ecosystem brief:**

- **`Loom`** (`/opt/ares/Loom`, Python+Julia) — described in the vault as "Agent collaboration weaver" and confirmed as **the one genuinely live, working cross-project link** as of a prior audit: `worldmonitor_bridge` posts real market-intel signals into Loom's pool every 5 minutes, and Loom's `glyph_fractal.jl`/`glyph_memory.py`/`graph_engine.jl` are very likely the actual GlyphGraph engine referenced elsewhere in the ecosystem (OSOVM's own GlyphIndex, Omo-Koda2's memory-projection work) — this had not been separately named as its own repo in my prior brief; it was folded generically into "GlyphIndex," but Loom appears to be the concrete engine behind that abstraction.
- **`sango`** (`/opt/ares/sango`, small — `sango_relay.py` + `receipts.db`) — Sàngó (thunder/justice Òrìṣà) relay, holding a real receipts database. Small footprint but directly relevant to OSOVM's own Quadrinity Government / court-verdict opcode cluster (still stub-dispatch per this session's own in-progress work) — worth checking whether `sango`'s receipts.db is meant to be the real backing store for those opcodes once they get real dispatch.
- **`Zàngbétò`** (already known) sits immediately downstream of birth as the security-enforcement gate every subsequent act must pass through — confirmed, not new, but worth restating as part of the sequence rather than a separate concern.

No other previously-unnamed repos were found to be load-bearing in the birth sequence itself; `agency-agents` (a large third-party prompt-library/framework clone: academic/design/engineering/finance/etc. divisions) appears to be reference material, not ecosystem-authored infrastructure — flagged as such, not included in the canonical list below as a "real" ecosystem component.

---

## 4. OSOVM's Canonical Ecosystem Repo/Project List

*Legend: 🔷 core pillar repo · 🔧 ecosystem-shared infra · 🎨 side/adjacent project (real, not yet reconciled) · 🧰 third-party tool dependency (not ecosystem-authored)*

### Core pillars
- 🔷 **OSOVM** — this project. VM, opcodes, Sui settlement, sim-proof pipeline.
- 🔷 **Omo-Koda2** (`omokoda-core` + `omokoda-swarm`/`omokoda-ops`/etc.) — the agent kernel/mind.
- 🔷 **Vantage** — the agent-hub/economy/society layer.

### Birth-sequence / identity chain
- 🔧 **BIPON39** — HD seed derivation, Yorùbá-enriched mnemonics.
- 🔧 **If-Script / IfáScript** — Odù sign, traditional Yorùbá Odù corpus.
- 🔧 **Koodu** — ritual codex/resonance runtime (real BTC-block-height calendar math confirmed).
- 🔧 **vanity-cloakseed / CloakSeed** — vanity address generation + duress/cloak panic layer.
- 🔧 **Zàngbétò** — security-enforcement daemon, real Ed25519-signed receipts.
- 🔧 **Loom** — agent collaboration weaver / GlyphGraph engine (Python+Julia); confirmed live-wired (worldmonitor_bridge).
- 🔧 **sango** — Sàngó relay + receipts.db (small, justice/verdict-adjacent).

### Social/economic/settlement infra
- 🔧 **buzz-relay** (`/opt/ares/buzz-relay`, plus the wider Buzz crate workspace) — real Nostr relay, agent social identity.
- 🔧 **Ares trading stack** — ~40+ `ares_*.py` daemons under `/opt/ares` (multi-chain traders, intel, freqtrade), bridged into Vantage `/api/trading`.
- 🔧 **cetus-bridge** — Sui DEX bridge (on-chain conversion, per the codex's Cetus/native-DEX reference for USDC↔SUI↔WAL).
- 🔧 **Gitea** — self-hosted git/CI backing.
- 🔧 **Zangbeto**, **larql**, **zerolang** — language/query tooling + security enforcement (previously known).
- 🔧 **smithers-omokoda** — SkillForge's durable human-approval gate.
- 🔧 **oniux** — present on the VPS, not independently investigated this pass; flagged for follow-up rather than guessed at.
- 🔧 **axiom** — the Omo-Koda2 dashboard (Three.js, `:8876`).

### Simulation / physical-world substrate
- 🔧 **Scarabswarm** — part of the PoSim reference triangle (with Witness-firmware).
- 🔧 **Witness-firmware** — ESP32+LoRa reality-attestation mesh (referenced throughout the codex; not confirmed present under `/opt/ares` in this listing — may live elsewhere or be hardware-only).

### Security/ops tooling used by the ecosystem's own pipelines (real, but third-party — not ecosystem-authored canon)
- 🧰 **strix**, **atomic-red-team**, **atomic-operator**, **invoke-atomicredteam**, **gef**, **betterleaks**, **XSStrike**, **SSTImap** — pentest/security tool clones used by Vantage's Strix/security-scan pipeline.

### Adjacent/side projects — real, present on the VPS, not yet reconciled into the three-pillar structure
- 🎨 **worldmonitor** — the market-intel signal source feeding Loom.
- 🎨 **seo-os**, **deeptutor-app**, **ourschool-app** / **ourschool-mcp**, **franken-stream**, **video-engine** (ViMax), **seemplify**, **supermemory** — separate real side-projects present on the same VPS, each with its own footprint, none currently described anywhere in the shared vault as wired into the OSOVM/Vantage/Omo-Koda2 pipeline. Same category as the owner's flagged Mac-side **BuzzAgent Mesh**/**Bondhive**/**Iranti** — real, parallel, not yet reconciled.
- 🎨 **agency-agents** — appears to be a third-party agent-prompt-library/framework repo (division-organized: academic, design, engineering, finance, sales, etc.), likely reference material rather than ecosystem-authored infrastructure. Flagged, not confirmed either way from this pass.

### Legacy/research-only, previously catalogued (from my prior ecosystem brief, carried forward for completeness)
- **aio-sui**, **knowledge_surgeon**, **paradigm**, **Twelve-thrones**, **Npc-forge**, **veriwiki**, **Nex** — local, non-git-remote or legacy research repos, per prior session accounting.

---

*This list reflects a direct filesystem walk of `/opt/ares` on the VPS plus vault search, not a claim of completeness — several directories (`oniux`, `agency-agents`) are flagged rather than confirmed, and the Mac-side parallel projects were not independently investigated per the owner's own scoping. Cross-check against Vantage's and Omo-Koda2's own canonical lists for the fullest picture.*
