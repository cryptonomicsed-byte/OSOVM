//! Build the exact `sui client call` invocation for the on-chain entry functions.
//!
//! Transport is the installed `sui` CLI (1.75.x). The operator runs the printed
//! command against devnet with their own keypair; this module only constructs the
//! correct package/module/function/args so the call is correct and copy-pasteable.

/// A ready-to-run `sui client call` command line.
pub struct SuiCall {
    pub argv: Vec<String>,
}

impl SuiCall {
    pub fn render(&self) -> String {
        self.argv.join(" ")
    }
}

/// Build `submit_attestation(oracle, registry, sensor_id, data_hash, merkle_root)`.
///
/// `sensor_id` is a u64; `data_hash` and `merkle_root` are hex strings (32 bytes).
/// `oracle`/`registry` are the shared object IDs from `init()`.
pub fn submit_attestation(
    package_id: &str,
    oracle_obj: &str,
    registry_obj: &str,
    sensor_id: u64,
    data_hash_hex: &str,
    merkle_root_hex: &str,
) -> SuiCall {
    SuiCall {
        argv: vec![
            "sui".into(),
            "client".into(),
            "call".into(),
            "--package".into(),
            package_id.into(),
            "--module".into(),
            "proof_of_witness".into(),
            "--function".into(),
            "submit_attestation".into(),
            "--args".into(),
            oracle_obj.into(),
            registry_obj.into(),
            sensor_id.to_string(),
            format!("0x{data_hash_hex}"),
            format!("0x{merkle_root_hex}"),
            "--gas-budget".into(),
            "100000000".into(),
        ],
    }
}

/// Build `submit_witness(oracle, registry, attestation_id, witness_sensor_id, signature)`.
///
/// `signature` is the 64-byte Ed25519 signature (hex) over the attestation's
/// `data_hash`, produced by [`crate::sign::sign_data_hash`].
pub fn submit_witness(
    package_id: &str,
    oracle_obj: &str,
    registry_obj: &str,
    attestation_id: u64,
    witness_sensor_id: u64,
    signature_hex: &str,
) -> SuiCall {
    SuiCall {
        argv: vec![
            "sui".into(),
            "client".into(),
            "call".into(),
            "--package".into(),
            package_id.into(),
            "--module".into(),
            "proof_of_witness".into(),
            "--function".into(),
            "submit_witness".into(),
            "--args".into(),
            oracle_obj.into(),
            registry_obj.into(),
            attestation_id.to_string(),
            witness_sensor_id.to_string(),
            format!("0x{signature_hex}"),
            "--gas-budget".into(),
            "100000000".into(),
        ],
    }
}

/// Build `register_sensor(oracle, registry, sensor_id, metadata, location, public_key)`.
pub fn register_sensor(
    package_id: &str,
    oracle_obj: &str,
    registry_obj: &str,
    sensor_id: u64,
    metadata_hex: &str,
    location_hex: &str,
    public_key_hex: &str,
) -> SuiCall {
    SuiCall {
        argv: vec![
            "sui".into(),
            "client".into(),
            "call".into(),
            "--package".into(),
            package_id.into(),
            "--module".into(),
            "proof_of_witness".into(),
            "--function".into(),
            "register_sensor".into(),
            "--args".into(),
            oracle_obj.into(),
            registry_obj.into(),
            sensor_id.to_string(),
            format!("0x{metadata_hex}"),
            format!("0x{location_hex}"),
            format!("0x{public_key_hex}"),
            "--gas-budget".into(),
            "100000000".into(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attestation_call_shape() {
        let c = submit_attestation("0xPKG", "0xORC", "0xREG", 7, "ab", "cd");
        let s = c.render();
        assert!(s.starts_with("sui client call"));
        assert!(s.contains("submit_attestation"));
        assert!(s.contains("0xPKG") && s.contains("0xORC") && s.contains("0xREG"));
        assert!(s.contains("7"));
    }

    #[test]
    fn witness_call_shape() {
        let c = submit_witness("0xPKG", "0xORC", "0xREG", 3, 9, "deadbeef");
        let s = c.render();
        assert!(s.contains("submit_witness"));
        assert!(s.contains("0xdeadbeef"));
    }
}
