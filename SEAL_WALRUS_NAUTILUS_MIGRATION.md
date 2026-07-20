# Seal / Walrus / Nautilus Migration Tracker

Working checklist for replacing homegrown "sealing"/storage/off-chain-compute
stand-ins with the real Sui-ecosystem products: **Seal** (decentralized
secrets management / threshold encryption), **Walrus** (decentralized blob
storage), **Nautilus** (verifiable off-chain TEE compute). Updated as we go —
do not treat anything below as done until it's checked off with a note on
how it was verified.

## Lisp → Clojure

- [x] N/A for OSOVM — grepped the full repo (`.jl`/`.move`/`.rs`/`.go`/`.md`),
      zero Lisp references anywhere. The Lisp→Clojure swap belongs to
      Omo-Koda2's Ọbàtálá `:4002` service (already Clojure per prior work).
      Nothing to change in this repo.

## Real architecture (confirmed 2026-07-20, corrects the original version of this doc)

GlyphIndex "sealing" and Sui "Seal" are two different things that share a
word:

- **GlyphIndex / GIX1** (memory vault, client-side AES-256-GCM under a
  BIPỌ̀N39-derived keyring) — this is the CORRECT, deliberate, canonical
  design. Verified: Vantage's `backend/glyph_index.py` (the frozen
  canonical reference implementation per `GLYPHINDEX_SPEC.md`) uses the
  exact same AES-256-GCM/keyring scheme. OSOVM's `glyphindex.jl` is
  correctly a synced port of that same wire format. **Not a gap, not
  touching it.**
- **Real Sui Seal** (decentralized key servers + on-chain `seal_approve`
  policy) — canonical, real implementation already lives in Omo-Koda2
  (`omokoda-core/src/memory/seal_bridge.rs` + `tee.rs`), gating that
  agent's TEE memory envelope's decryption key via the real
  `seal-cli fetch-keys` flow. This is OSOVM's sibling project's job, not
  OSOVM's — no duplicate integration belongs here.

## Audit: every "seal" in the codebase, and what it actually is today

- [x] `src/glyphindex.jl` — CONFIRMED CORRECT AS-IS (see above). No action.
- [x] `src/glyphindex.jl` — `walrus_blob_id::String` field CONFIRMED CORRECT
      AS-IS, same pattern as Seal above. Verified: Vantage's own
      `backend/routers/glyph_vault.py` (the canonical HTTP layer) also just
      accepts a caller-supplied `walrus_blob_id` string and never calls
      Walrus itself. The real Walrus HTTP client (`PUT
      {publisher}/v1/blobs`, real publisher/aggregator URLs) already exists
      in Omo-Koda2 (`omokoda-core/src/memory/walrus.rs` +
      `tools/walrus_tool.rs`) and hands the resulting blob id *into* the
      vault as metadata — the vault layer deliberately never does storage
      upload itself, in every repo, by design. Building an HTTP client into
      glyphindex.jl would duplicate that and break the pattern. Not a gap.
- [x] `src/zangbeto_receipts.jl` — DUAL SEAL implemented. `ReceiptBundle`
      now carries both: Layer 1 `seal` (existing SHA-256 tamper-evidence
      commitment, unchanged) + Layer 2 `seal_dek_fingerprint` (new — a
      real DEK fetched from Sui Seal's key servers via `src/seal_bridge.jl`,
      a direct port of Omo-Koda2's verified `seal_bridge.rs`
      request→fetch-keys pipeline, SHA-256-fingerprinted rather than held
      as a key, consistent with OSOVM never touching decryption keys).
      Fail-open: empty string when `SEAL_*` env vars aren't configured,
      never a fake value. Verified end-to-end both unconfigured (empty
      fingerprint) and configured (real 64-hex-char fingerprint via a real
      subprocess pipeline) against a live receipt. Zero regressions on the
      full test suite. `test/seal_bridge_test.jl`: 13/13.
- [x] `src/veilos_antispam.jl` — same DUAL SEAL treatment, same
      `seal_bridge.jl`. `SimulationReceipt` now carries `seal` (Layer 1,
      unchanged) + `seal_dek_fingerprint` (Layer 2). Also fixed 2 unrelated
      pre-existing bugs surfaced while getting this path to actually run
      for the first time (it had zero prior test coverage): missing
      `using Random` (crashed on `shuffle`), and `PILGRIMAGE_GATES` being
      indexed as a Dict when it's an ordered `Vector{Pair}`. Verified
      end-to-end both unconfigured and configured. Zero regressions.
- [x] `move_contracts/` — no `seal_approve` needed here. Real Seal
      integration and its on-chain policy belong to Omo-Koda2
      (`seal_bridge.rs` gates that project's own TEE memory envelope) —
      out of OSOVM's scope, not duplicating it. If OSOVM ever needs its
      own Seal-gated on-chain content in the future, revisit then.

## Nautilus (verifiable off-chain compute)

- [x] Wired to VeilSim F1/PoSim scoring, the use case identified above.
      `src/nautilus_attestation.jl` is a direct port of Omo-Koda2's real
      `nautilus_integration::attestation` pattern (same honesty level):
      `verify_quote` checks a `TeeQuote`'s `code_measurement` against the
      real, live SHA-256 of `veilsim_engine.jl` on disk
      (`code_measurement_of_engine()`, recomputed at call time, not
      cached) and derives a key from the quote's own fields. Honest about
      what it verifies: binds a result to a specific claimed engine build,
      but does not yet verify a real hardware attestation signature
      (SGX/TDX/Nitro), since no real enclave is deployed anywhere in this
      ecosystem — same documented limitation as Omo-Koda2's own
      implementation. `VeilSimEngine.compute_f1_attested(sim, sim_id,
      tee_quote)` wraps the existing, untouched `compute_f1` with this
      attestation; `F1Attestation.verified` is honest (false, never
      thrown, on a mismatched/stale quote). Verified end-to-end: a quote
      built from the real current engine measurement attests `verified=
      true`; a wrong measurement honestly reports `verified=false`.
      `test/nautilus_attestation_test.jl`: 9/9. Zero regressions on the
      full test suite.

## Verification standard for each item above

Before checking anything off: real SDK/API call made, response verified
end-to-end (not just "compiles"), and — where relevant — a live Sui
testnet transaction hash as proof, same standard as the rest of this
session's audit work.
