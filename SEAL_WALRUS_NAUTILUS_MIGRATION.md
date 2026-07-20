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

## Audit: every "seal" in the codebase, and what it actually is today

- [ ] `src/glyphindex.jl` — "sealing/unsealing" is a custom AES-256-GCM
      scheme under BIPỌ̀N39-derived keys (see file header comment). This is
      the real candidate for Seal: replace the custom encryption with real
      **Seal** threshold encryption (`@mysten/seal` SDK + on-chain
      `seal_approve` access-control policy in Move). Needs a design decision
      on what the Move-side access policy should check (BIPỌ̀N39 identity?
      wallet ownership? something else).
- [ ] `src/glyphindex.jl` — `walrus_blob_id::String` field exists but is
      never populated by a real Walrus API call anywhere (grepped: zero
      Walrus SDK/HTTP calls in the repo). Wire real blob upload/fetch via
      Walrus (`walrus store` / publisher-aggregator HTTP API) instead of
      leaving it as a dead placeholder field.
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
- [ ] `move_contracts/` — zero Seal/Walrus/Nautilus references anywhere.
      Once the Move-side access-control policy design is decided (see
      glyphindex item above), add the real `seal_approve`-style entry
      function(s) to the relevant module (`privacy_layer.move` is the
      likely home).

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
