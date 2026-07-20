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
- [ ] `src/zangbeto_receipts.jl` — `seal` field is a SHA256 hash
      (`bytes2hex(sha256(seal_data))[1:32]`) used as a receipt commitment,
      not an encrypted secret. **Needs a decision**: is this meant to
      protect confidential content (→ migrate to real Seal), or is it
      correctly just a commitment/integrity hash (→ leave as-is, rename to
      avoid the misleading "seal" terminology overlapping with Sui Seal)?
- [ ] `src/veilos_antispam.jl` — `seal` field, same pattern: SHA256 hash of
      a fixed ritual string (`"Ọbàtálá seals the 777 Veils and the first
      mint"`). Same question as above — likely a ceremonial
      commitment/checksum, not a secrets-encryption use case. Confirm intent
      before touching.
- [x] `move_contracts/` — no `seal_approve` needed here. Real Seal
      integration and its on-chain policy belong to Omo-Koda2
      (`seal_bridge.rs` gates that project's own TEE memory envelope) —
      out of OSOVM's scope, not duplicating it. If OSOVM ever needs its
      own Seal-gated on-chain content in the future, revisit then.

## Nautilus (verifiable off-chain compute)

- [ ] No current code path claims to do off-chain TEE-verified compute, so
      there's no existing fake to replace. Open question for the owner:
      where in OSOVM would Nautilus actually apply — VeilSim scoring
      (F1/PoSim validation happening off-chain, then verified on-chain)?
      Needs a scoping decision before any implementation starts.

## Verification standard for each item above

Before checking anything off: real SDK/API call made, response verified
end-to-end (not just "compiles"), and — where relevant — a live Sui
testnet transaction hash as proof, same standard as the rest of this
session's audit work.
