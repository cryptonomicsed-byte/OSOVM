/// Proof-of-Witness Module
/// Validates IoT sensor attestations for real-world impact minting
///
/// Features:
/// - 5-witness quorum validation (sensor cluster)
/// - Replay protection via nonce + timestamp
/// - Merkle root commitment to sensor data
/// - Ed25519 signature verification (witness signs the primary sensor's data_hash)
/// - Issues SOULBOUND MERIT RECEIPTS on validation (no token mint — the ecosystem
///   canon is USDC-only; Àṣẹ is soulbound merit, not a minted coin)
///
/// NOTE (2026-08-26): token reconciliation applied. This module previously claimed
/// to "Mints Àṣẹ" via SENSOR_REWARD / claim_reward; that conflicted with the locked
/// Gen-3 economic canon. Validation now emits a MeritReceipt event (receipt_id,
/// sensor_id, merkle_root, timestamp) — an attestation record, not a coin.

module techgnosis::proof_of_witness {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::event;
    use sui::vec_set::{Self, VecSet};
    use sui::ed25519::{Self, ed25519_verify};
    use std::vector;

    // ===== Constants =====
    const WITNESS_QUORUM: u64 = 5; // 5 sensors must attest
    const WITNESS_TIMEOUT: u64 = 3600; // 1 hour window for witness submission
    const MAX_SENSOR_ID: u64 = 1000; // Maximum 1000 IoT sensors
    const ED25519_PUBLIC_KEY_LEN: u64 = 32; // Ed25519 public key length in bytes
    const ED25519_SIGNATURE_LEN: u64 = 64; // Ed25519 signature length in bytes

    // ===== Errors =====
    const E_INSUFFICIENT_WITNESSES: u64 = 1;
    const E_INVALID_SENSOR_ID: u64 = 2;
    const E_DUPLICATE_WITNESS: u64 = 3;
    const E_WITNESS_TIMEOUT: u64 = 4;
    const E_INVALID_SIGNATURE: u64 = 5;
    const E_NOT_AUTHORIZED: u64 = 7;
    const E_SENSOR_ALREADY_ATTESTED: u64 = 8;
    const E_INVALID_PUBLIC_KEY: u64 = 9;
    const E_SENSOR_NOT_REGISTERED: u64 = 10;

    // ===== Events =====
    public struct SensorAttestation has copy, drop {
        sensor_id: u64,
        timestamp: u64,
        data_hash: vector<u8>,
        witness_count: u64,
    }

    public struct WitnessSubmitted has copy, drop {
        attestation_id: u64,
        witness_id: u64,
        sensor_data_hash: vector<u8>,
    }

    public struct AttestationValidated has copy, drop {
        attestation_id: u64,
        merkle_root: vector<u8>,
        timestamp: u64,
    }

    /// Soulbound merit receipt — the reward is an attestation record, NOT a coin.
    /// This is the OSOVM RECEIPT primitive for physical witness work (aligned with
    /// the ip-layer Creation Receipt / osovm_op). Non-transferable by construction:
    /// it is an emitted event, not a balance.
    public struct MeritReceipt has copy, drop {
        receipt_id: u64,
        sensor_id: u64,
        merkle_root: vector<u8>,
        witness_count: u64,
        timestamp: u64,
    }

    // ===== Structs =====

    /// Sensor attestation (off-chain IoT data commitment)
    public struct SensorAttest has store {
        sensor_id: u64,
        nonce: u64, // Prevents replay attacks
        timestamp: u64,
        data_hash: vector<u8>, // Hash of sensor reading
        merkle_root: vector<u8>, // Commit to full dataset
        witnesses: VecSet<u64>, // Set of witness sensor IDs
        witness_signatures: Table<u64, vector<u8>>, // Signature per witness
        witness_timestamps: Table<u64, u64>, // Timestamp per witness
        validated: bool,
        receipt_claimed: bool,
    }

    /// Witness oracle for IoT sensor network
    public struct WitnessOracle has key {
        id: UID,
        admin: address,
        registered_sensors: VecSet<u64>,
        active_attestations: Table<u64, SensorAttest>,
        attestation_counter: u64,
        total_merit_receipts: u64,
        sensor_nonces: Table<u64, u64>, // Nonce tracking per sensor
    }

    /// Sensor metadata registry (includes Ed25519 public key per sensor)
    public struct SensorRegistry has key {
        id: UID,
        sensors: Table<u64, vector<u8>>, // sensor_id -> metadata
        sensor_locations: Table<u64, vector<u8>>, // GPS coordinates or region
        sensor_public_keys: Table<u64, vector<u8>>, // sensor_id -> Ed25519 pubkey (32 bytes)
        sensor_last_attestation: Table<u64, u64>, // Last successful attestation
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let oracle = WitnessOracle {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            registered_sensors: vec_set::empty<u64>(),
            active_attestations: table::new<u64, SensorAttest>(ctx),
            attestation_counter: 0,
            total_merit_receipts: 0,
            sensor_nonces: table::new<u64, u64>(ctx),
        };
        transfer::share_object(oracle);

        let registry = SensorRegistry {
            id: object::new(ctx),
            sensors: table::new<u64, vector<u8>>(ctx),
            sensor_locations: table::new<u64, vector<u8>>(ctx),
            sensor_public_keys: table::new<u64, vector<u8>>(ctx),
            sensor_last_attestation: table::new<u64, u64>(ctx),
        };
        transfer::share_object(registry);
    }

    // ===== Public Functions =====

    /// Register a new IoT sensor. The sensor's Ed25519 public key (32 bytes) is
    /// recorded so witness signatures can be verified on-chain.
    public fun register_sensor(
        oracle: &mut WitnessOracle,
        registry: &mut SensorRegistry,
        sensor_id: u64,
        metadata: vector<u8>,
        location: vector<u8>,
        public_key: vector<u8>,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == oracle.admin, E_NOT_AUTHORIZED);
        assert!(sensor_id <= MAX_SENSOR_ID, E_INVALID_SENSOR_ID);
        assert!(vector::length(&public_key) == ED25519_PUBLIC_KEY_LEN, E_INVALID_PUBLIC_KEY);

        vec_set::insert(&mut oracle.registered_sensors, sensor_id);
        table::add(&mut registry.sensors, sensor_id, metadata);
        table::add(&mut registry.sensor_locations, sensor_id, location);
        table::add(&mut registry.sensor_public_keys, sensor_id, public_key);
        table::add(&mut oracle.sensor_nonces, sensor_id, 0);
    }

    /// Submit sensor attestation (primary sensor)
    public fun submit_attestation(
        oracle: &mut WitnessOracle,
        _registry: &mut SensorRegistry,
        sensor_id: u64,
        data_hash: vector<u8>,
        merkle_root: vector<u8>,
        ctx: &mut TxContext,
    ): u64 {
        assert!(vec_set::contains(&oracle.registered_sensors, &sensor_id), E_INVALID_SENSOR_ID);

        let attestation_id = oracle.attestation_counter;
        oracle.attestation_counter = attestation_id + 1;

        let nonce = if (table::contains(&oracle.sensor_nonces, sensor_id)) {
            let current_nonce = *table::borrow(&oracle.sensor_nonces, sensor_id);
            current_nonce + 1
        } else {
            1
        };

        // Persist the incremented nonce so replay-protection bookkeeping advances.
        if (table::contains(&oracle.sensor_nonces, sensor_id)) {
            table::remove(&mut oracle.sensor_nonces, sensor_id);
        };
        table::add(&mut oracle.sensor_nonces, sensor_id, nonce);

        let attestation = SensorAttest {
            sensor_id,
            nonce,
            timestamp: tx_context::epoch(ctx),
            data_hash,
            merkle_root,
            witnesses: vec_set::empty<u64>(),
            witness_signatures: table::new<u64, vector<u8>>(ctx),
            witness_timestamps: table::new<u64, u64>(ctx),
            validated: false,
            receipt_claimed: false,
        };

        table::add(&mut oracle.active_attestations, attestation_id, attestation);

        event::emit(SensorAttestation {
            sensor_id,
            timestamp: tx_context::epoch(ctx),
            data_hash,
            witness_count: 0,
        });

        attestation_id
    }

    /// Submit witness signature (secondary sensor).
    /// The witness's Ed25519 signature over the primary sensor's data_hash is
    /// verified on-chain BEFORE the witness is counted.
    public fun submit_witness(
        oracle: &mut WitnessOracle,
        registry: &SensorRegistry,
        attestation_id: u64,
        witness_sensor_id: u64,
        signature: vector<u8>,
        ctx: &TxContext,
    ) {
        assert!(vec_set::contains(&oracle.registered_sensors, &witness_sensor_id), E_INVALID_SENSOR_ID);
        assert!(table::contains(&registry.sensor_public_keys, witness_sensor_id), E_SENSOR_NOT_REGISTERED);

        let attestation = table::borrow_mut(&mut oracle.active_attestations, attestation_id);
        assert!(!attestation.validated, E_SENSOR_ALREADY_ATTESTED);
        assert!(!vec_set::contains(&attestation.witnesses, &witness_sensor_id), E_DUPLICATE_WITNESS);
        assert!(tx_context::epoch(ctx) <= attestation.timestamp + WITNESS_TIMEOUT, E_WITNESS_TIMEOUT);

        // Real Ed25519 verification: the witness signs the primary's data_hash to
        // prove it independently observed the same sensor reading.
        let public_key = &registry.sensor_public_keys[witness_sensor_id];
        assert!(vector::length(&signature) == ED25519_SIGNATURE_LEN, E_INVALID_SIGNATURE);
        assert!(ed25519_verify(&signature, public_key, &attestation.data_hash), E_INVALID_SIGNATURE);

        vec_set::insert(&mut attestation.witnesses, witness_sensor_id);
        table::add(&mut attestation.witness_signatures, witness_sensor_id, signature);
        table::add(&mut attestation.witness_timestamps, witness_sensor_id, tx_context::epoch(ctx));

        event::emit(WitnessSubmitted {
            attestation_id,
            witness_id: witness_sensor_id,
            sensor_data_hash: attestation.data_hash,
        });
    }

    /// Validate attestation when quorum (5 witnesses) is reached.
    /// Emits a soulbound MeritReceipt instead of minting a token.
    public fun validate_attestation(
        oracle: &mut WitnessOracle,
        registry: &mut SensorRegistry,
        attestation_id: u64,
        ctx: &TxContext,
    ) {
        let attestation = table::borrow_mut(&mut oracle.active_attestations, attestation_id);
        assert!(!attestation.validated, E_SENSOR_ALREADY_ATTESTED);
        assert!(vec_set::length(&attestation.witnesses) >= WITNESS_QUORUM, E_INSUFFICIENT_WITNESSES);

        attestation.validated = true;
        oracle.total_merit_receipts = oracle.total_merit_receipts + 1;

        // Update sensor last attestation time
        let sensor_id = attestation.sensor_id;
        if (table::contains(&registry.sensor_last_attestation, sensor_id)) {
            table::remove(&mut registry.sensor_last_attestation, sensor_id);
        };
        table::add(&mut registry.sensor_last_attestation, sensor_id, tx_context::epoch(ctx));

        event::emit(AttestationValidated {
            attestation_id,
            merkle_root: attestation.merkle_root,
            timestamp: tx_context::epoch(ctx),
        });

        // Soulbound merit receipt — the reward, with no token mint.
        event::emit(MeritReceipt {
            receipt_id: attestation_id,
            sensor_id: attestation.sensor_id,
            merkle_root: attestation.merkle_root,
            witness_count: vec_set::length(&attestation.witnesses),
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Claim the merit receipt after successful validation.
    /// Returns the receipt_id (attestation_id) — an attestation record, not a coin.
    public fun claim_receipt(
        oracle: &mut WitnessOracle,
        attestation_id: u64,
        _ctx: &TxContext,
    ): u64 {
        let attestation = table::borrow_mut(&mut oracle.active_attestations, attestation_id);
        assert!(attestation.validated, 100); // Not validated
        assert!(!attestation.receipt_claimed, 101); // Already claimed

        attestation.receipt_claimed = true;
        attestation_id
    }

    // ===== Getters =====

    public fun oracle_total_merit_receipts(oracle: &WitnessOracle): u64 {
        oracle.total_merit_receipts
    }

    public fun oracle_attestation_count(oracle: &WitnessOracle): u64 {
        oracle.attestation_counter
    }

    public fun attestation_witness_count(oracle: &WitnessOracle, attestation_id: u64): u64 {
        vec_set::length(&oracle.active_attestations[attestation_id].witnesses)
    }

    public fun attestation_validated(oracle: &WitnessOracle, attestation_id: u64): bool {
        oracle.active_attestations[attestation_id].validated
    }

    public fun sensor_public_key(registry: &SensorRegistry, sensor_id: u64): vector<u8> {
        *table::borrow(&registry.sensor_public_keys, sensor_id)
    }

    public fun witness_quorum(): u64 {
        WITNESS_QUORUM
    }
}
