# osovm-witness-bridge

Off-chain submitter bridging two physical-work producers into OSOVM's
`techgnosis::proof_of_witness` module on Sui:

| Source | Produces | On-chain entry function |
|---|---|---|
| **Scarabswarm** (PoSim drone sim) | `trajectory_hash` (SHA256 of downsampled checkpoints) + Merkle root | `submit_attestation(sensor_id, data_hash, merkle_root)` |
| **Witness-firmware** (LoRa DePIN) | physics-proof payload hash + Ed25519 signature | `submit_witness(attestation_id, witness_sensor_id, signature)` |

## What was built

1. **`proof_of_witness.move`** (in `../move_contracts/sources/`)
   - **Ed25519 fix**: `submit_witness` now calls `sui::ed25519::ed25519_verify`
     over the primary sensor's `data_hash` — replacing the old
     "for now, just check we have quorum" stub. Each sensor's 32-byte Ed25519
     public key is recorded at `register_sensor`.
   - **Token reconciliation**: validation emits a soulbound `MeritReceipt`
     event (receipt_id, sensor_id, merkle_root, witness_count, timestamp)
     instead of minting a token. `claim_reward` → `claim_receipt`; the
     `total_rewards_distributed` counter → `total_merit_receipts`. Aligns with
     the locked Gen-3 canon (USDC-only; Àṣẹ is soulbound merit, not a coin).
   - **Nonce bookkeeping fix**: per-sensor nonce is now persisted, so replay
     protection actually advances.

2. **This crate** (Rust) — computes the crypto and emits ready-to-run
   `sui client call` invocations:
   - `generate-key` — mint an Ed25519 keypair (secret + public, hex)
   - `sign` — sign a `data_hash` (the exact bytes the contract verifies)
   - `merkle-root` — deterministic Merkle root over checkpoint blobs
   - `register-sensor` / `submit-attestation` / `submit-witness` — emit the
     `sui client call` command line

## Verification boundary (honest)

**Verified locally (real, reproducible):**
- `cargo test` — 10 tests pass: signature round-trip (Ed25519 sign→verify),
  tampered-message/wrong-key rejection, key lengths (32/64 bytes match the
  contract constants), Merkle determinism + odd-leaf promotion.
- `sui move build` — the contract compiles to bytecode, zero errors/warnings
  in `proof_of_witness.move`.

**Not yet verified (needs a devnet deploy + funded key):**
- The live on-chain round-trip (`sui client call …` against a deployed package).
  The signatures are RFC 8032 Ed25519 (ed25519-dalek), which is the same scheme
  `sui::ed25519::ed25519_verify` implements, so cross-implementation verification
  is expected to match — but the actual on-chain proof requires deploying
  `techgnosis` and running the emitted command with the operator's devnet key.

## Usage

```sh
cargo build --release

# 1. one-time: mint a keypair for each sensor
witness-bridge generate-key
#   -> secret_seed (keep private), public_key (register on-chain)

# 2. register the sensor (admin) — real package/oracle/registry IDs from deploy
witness-bridge register-sensor \
  --package 0x<PACKAGE_ID> --oracle 0x<ORACLE_OBJ> --registry 0x<REGISTRY_OBJ> \
  --sensor 1 --metadata 0000 --location 0000 --public-key <PUB_HEX>

# 3. primary sensor commits an attestation (Scarabswarm trajectory)
witness-bridge submit-attestation \
  --package 0x<PACKAGE_ID> --oracle 0x<ORACLE_OBJ> --registry 0x<REGISTRY_OBJ> \
  --sensor 1 --data-hash <TRAJECTORY_HASH_HEX> --merkle-root <ROOT_HEX>

# 4. witness signs the data_hash and submits (Witness-firmware)
SIG=$(witness-bridge sign --secret <WITNESS_SECRET> --data-hash <DATA_HASH_HEX>)
witness-bridge submit-witness \
  --package 0x<PACKAGE_ID> --oracle 0x<ORACLE_OBJ> --registry 0x<REGISTRY_OBJ> \
  --attestation 0 --witness 9 --signature $SIG
```

The printed command is the transport step — run it (it is the `sui client call`)
against the configured network.

## Testnet deployment (verified 2026-08-27)

The `techgnosis` package containing `proof_of_witness` is **already published**
on Sui testnet. The `init()` created and shared the two proof_of_witness objects
at publish time, so no further deploy is needed — only the IDs, which are
recorded in `testnet.env`:

| Piece | Object ID |
|---|---|
| Package | `0xb3b6ef1ddaec611ade78909f1eb44e704a882be0406fb16e0d78b344a08050af` |
| `proof_of_witness::WitnessOracle` | `0x03380e98b5a2f1f6aee5922d0c99ccd391417df95f379e6855f7f8cfa554b401` |
| `proof_of_witness::SensorRegistry` | `0x6b38050454f1ce992b1ae0a5a7c08e5b11c4c7edab081ca59bb764854724cd98` |

```sh
source testnet.env
witness-bridge register-sensor \
  --package "$PACKAGE_ID" --oracle "$ORACLE_ID" --registry "$REGISTRY_ID" \
  --sensor 1 --metadata 0000 --location 0000 --public-key <PUB_HEX>
```

The remaining runtime gap is gas (the testnet operator address holds ~0.0075 SUI;
top up via the faucet before the first on-chain call).

## Note on the Schnorr→Ed25519 mapping

Witness-firmware's `WitnessIdentity` currently signs with secp256k1/BIP-340
Schnorr (its transport/application identity). The on-chain contract is
Ed25519-native (cheapest, first-class `sui::ed25519` support). The bridge
therefore uses Ed25519 for the on-chain witness signature; the firmware's
existing Schnorr identity remains valid off-chain and can be mapped to an
Ed25519 key at the submitter (or the firmware can sign Ed25519 directly —
a future firmware change, out of scope here).
