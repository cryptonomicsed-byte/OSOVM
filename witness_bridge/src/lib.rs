//! osovm-witness-bridge — off-chain submitter for OSOVM's PoWitness layer.
//!
//! Bridges two physical-work producers into `techgnosis::proof_of_witness`:
//!   * Scarabswarm (PoSim): drone-race trajectory → SHA256 data_hash + merkle root
//!     over downsampled checkpoints → `submit_attestation`.
//!   * Witness-firmware (LoRa DePIN): physics-proof payload → Ed25519 signature
//!     over the primary sensor's data_hash → `submit_witness`.
//!
//! The signature scheme is Ed25519 (RFC 8032), exactly matching Sui's
//! `sui::ed25519::ed25519_verify`, so a signature produced here verifies on-chain
//! with no adapter. The transaction transport is the installed `sui` CLI
//! (`sui client call`) — this crate computes the crypto and emits the exact
//! invocation; the operator runs it against devnet with their own key.

pub mod merkle;
pub mod sign;
pub mod call;

pub use merkle::{leaf_hash, merkle_root, merkle_root_from_blobs};
pub use sign::{generate_keypair, sign_data_hash, verify_data_hash, decode_secret, decode_public};
