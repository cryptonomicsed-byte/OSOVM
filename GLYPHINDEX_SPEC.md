# GlyphIndex — Ecosystem Specification (v1)

GlyphIndex is the sovereign memory layer of the Ọmọ Kọ́dà / Technosis
ecosystem: every memory an agent forms is content-addressed to a single
Unicode glyph, sealed under keys derived from the agent's BIPỌ̀N39 identity,
journaled with auditable receipts, and anchorable on Sui via a Merkle root.
Storage providers (Walrus, Vantage, OSOVM vaults) only ever hold ciphertext.

This document freezes the three wire formats. The **canonical reference
implementation** is `Vantage/backend/glyph_index.py`; the frozen test vectors
it generated are embedded in every repo's test suite.

## Implementations by repo

| Repo | Module | Role |
|---|---|---|
| Vantage | `backend/glyph_index.py`, `backend/routers/glyph_vault.py` | Canonical reference + BlockMesh hub API |
| OSOVM | `src/glyphindex.jl` | VM memory primitive: vault, journal, opcodes 0xF0–0xF4 |
| BIPON39 | `src/glyphindex.rs` | GIX-KDF-v1 key hierarchy (identity root) |
| If-Script | `src/glyph/mod.rs` | Glyph↔Odù linkage, `cast_with_memory` |
| Zangbeto | `crates/crypto-kernel/src/glyph_audit.rs` | Keyless audit: envelopes, receipts, anchors |
| larql | `crates/larql-glyph` | LQL verbs (DESCRIBE/SELECT/WALK/INFER) over glyph graphs |
| zerolang | `std/glyphindex.0` | Graph-native fold + envelope validation |
| Omo-Koda2 | `omokoda-memory/src/glyph_memory.jl` | SOMA/REM integration, birth registration |
| Axiom | `src/nodeTypes/glyphMemoryNode.ts` | Galaxy visualization, semantic zoom |
| Cloakseed | `src/utils/glyphVault.js` | WebCrypto sealing, duress/decoy vaults |
| Koodu | `glyph-adapter.js` | Block Mesh permissioned glyph sharing |
| Loom | `glyph_memory.py`, `glyph_fractal.jl` | REM fractal clustering over embeddings |

## 1. GIX-FOLD-v1 — content → glyph

```
h            = SHA-256(chunk utf-8)          # 32 bytes
canonical_id = hex(h)                        # the true address
n            = big-endian integer of h
idx          = n mod 63,422
```

`idx` maps, in order, into the valid printable BMP ranges (surrogates,
controls, and noncharacters excluded — a folded glyph is always a valid
scalar in every language runtime):

| Range | Start | Count |
|---|---|---|
| R1 | U+0020 | 55,264 (through U+D7FF) |
| R2 | U+E000 | 7,632 (through U+FDCF) |
| R3 | U+FDF0 | 526 (through U+FFFD) |

The glyph is a **display alias**. All addressing uses `canonical_id`, so
glyph collisions are cosmetic, never a correctness issue.

**Odù linkage** (Digital Calabash): `odu_base = h[0]` (0–255),
`odu_composed = h[0] << 8 | h[1]` (0–65,535).

## 2. GIX-KDF-v1 — key hierarchy

```
master seed  = BIPỌ̀N39 mnemonic_to_seed (64 bytes), or any wallet seed ≥ 32B
             | fallback: PBKDF2-HMAC-SHA256(passphrase,
             |             salt = "GIX1" || owner, 600,000 iters, 64 bytes)

subkey       = HKDF-SHA256(ikm = seed, salt = "GLYPHINDEX/v1",
                           info = label || owner || ":" || purpose)
labels:  "gix:enc:"     encryption key (32B)
         "gix:mac:"     receipt MAC key (32B)
         "gix:duress:"  decoy-vault encryption key (32B, Cloakseed panic mode)
```

Duress keys share no material with primary keys: a coerced passphrase opens a
disjoint decoy vault. Default `purpose` is `"glyph-memory"`.

## 3. GIX1 — sealed blob envelope

```
bytes:  "GIX1" | version(0x01) | flags(1) | nonce(12) | ciphertext || tag(16)
cipher: AES-256-GCM, 16-byte tag
AAD:    "GIX1" || canonical_id (ascii hex) || "|" || owner (utf-8)
flags:  bit0 = payload zlib-deflated before encryption
```

Payload plaintext is canonical JSON (sorted keys, no whitespace):
`{"canonical_id", "glyph", "ts", "chunk", "odu": [base, composed]}`.
Openers MUST verify the GCM tag, then that the inner `canonical_id` matches
the address, then that `SHA-256(chunk)` re-derives it.

## 4. Receipts and anchoring

```
receipt = { canonical_id, blob_sha256 = hex(SHA-256(sealed blob)), owner,
            hmac = HMAC-SHA256(mac_key, canonical_id_ascii || blob_sha256_bytes) }

merkle leaf  = SHA-256(canonical_id_bytes || SHA-256(sealed blob))
merkle tree  = leaves sorted by canonical_id; pairwise SHA-256; odd leaf promoted
empty root   = SHA-256("GIX1:empty")
             = 58cc47f0d238cea8bb764f7a927a54b398c8baf5de0a2332c03008038c3fd9a8
```

The root is the value anchored on Sui; Zangbeto recomputes it from the stored
blob set to detect substitution or withholding.

## 5. OSOVM opcode surface

| Opcode | Byte | Effect |
|---|---|---|
| `GLYPH_STORE` | 0xF0 | journal a sealed chunk into the agent vault |
| `GLYPH_EXPAND` | 0xF1 | serve sealed blob + metadata by canonical id |
| `GLYPH_SEARCH` | 0xF2 | semantic top-k over the vault |
| `GLYPH_ANCHOR` | 0xF3 | emit the vault Merkle root for Sui anchoring |
| `GLYPH_AUDIT` | 0xF4 | Zangbeto envelope/receipt audit |

## 6. Frozen cross-language vectors

Seed `000102…3f` (bytes 0–63), owner `0xabc123`, purpose `glyph-memory`:

```
enc_key        39a5e39cb799872fa548f02b6b60a3876dd085016f389ebee2c3ad03b80512ed
mac_key        8004b049f4e1f8df5f8afa7b1005c471c2dace0640b2103bc6b78fd5d9808d24
duress_enc_key ad80c87d330d59d6efb8d9283c839e0db8b74f5693ff2ed85bfac8a9401caf3e
```

| text | canonical_id | glyph cp | odù base | odù composed |
|---|---|---|---|---|
| `Àṣẹ` | `e328…db1b` | 21841 | 227 | 58152 |
| `hello` | `2cf2…9824` | 23636 | 44 | 11506 |
| `GlyphIndex` | `44bb…a7ec` | 13726 | 68 | 17595 |
| `😊🚀 Unicode test` | `bdf2…8683` | 64591 | 189 | 48626 |
| `Ọ̀rúnmìlà` | `cca6…d523` | 17963 | 204 | 52390 |

Full ids live in each repo's test suite.

## 7. Non-goals of v1

Embeddings are deliberately **not** a wire format — each runtime may use any
embedder (the reference ships a dependency-free hashing 3-gram fallback;
production plugs sentence-transformers/FAISS/HNSW behind the same interface).
Payment/fee flows (Sui escrow, sponsored transactions) and BlockMesh
permission grants ride on top of receipts and are specified per-repo.
