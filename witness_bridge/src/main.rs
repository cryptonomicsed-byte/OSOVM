//! witness-bridge CLI — drive the OSOVM PoWitness submitter.
//!
//! Subcommands:
//!   generate-key             mint an Ed25519 keypair for a sensor
//!   sign                     sign a data_hash (produces the submit_witness signature)
//!   merkle-root              merkle root over checkpoint blobs
//!   register-sensor          emit `sui client call register_sensor`
//!   submit-attestation       emit `sui client call submit_attestation`
//!   submit-witness           emit `sui client call submit_witness`

use clap::{Parser, Subcommand};

use osovm_witness_bridge::{
    call::{register_sensor, submit_attestation, submit_witness},
    decode_secret, generate_keypair, merkle_root_from_blobs, sign_data_hash,
};

#[derive(Parser)]
#[command(name = "witness-bridge", version, about = "OSOVM PoWitness off-chain submitter")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Generate a fresh Ed25519 keypair (prints secret + public as hex).
    GenerateKey,
    /// Sign a data_hash with a secret seed (prints the 64-byte signature).
    Sign {
        /// Secret seed as hex (32 bytes).
        #[arg(long)]
        secret: String,
        /// data_hash as hex (the exact bytes signed on-chain).
        #[arg(long)]
        data_hash: String,
    },
    /// Compute the Merkle root over checkpoint blobs (hex inputs, order-preserving).
    MerkleRoot {
        /// One or more checkpoint blobs as hex.
        #[arg(long, num_args = 1..)]
        inputs: Vec<String>,
    },
    /// Emit a `sui client call` for register_sensor.
    RegisterSensor {
        #[arg(long)] package: String,
        #[arg(long)] oracle: String,
        #[arg(long)] registry: String,
        #[arg(long)] sensor: u64,
        #[arg(long)] metadata: String,
        #[arg(long)] location: String,
        #[arg(long)] public_key: String,
    },
    /// Emit a `sui client call` for submit_attestation.
    SubmitAttestation {
        #[arg(long)] package: String,
        #[arg(long)] oracle: String,
        #[arg(long)] registry: String,
        #[arg(long)] sensor: u64,
        #[arg(long)] data_hash: String,
        #[arg(long)] merkle_root: String,
    },
    /// Emit a `sui client call` for submit_witness.
    SubmitWitness {
        #[arg(long)] package: String,
        #[arg(long)] oracle: String,
        #[arg(long)] registry: String,
        #[arg(long)] attestation: u64,
        #[arg(long)] witness: u64,
        #[arg(long)] signature: String,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::GenerateKey => {
            let (secret, public) = generate_keypair();
            println!("secret_seed (32 bytes, keep private): {}", hex::encode(secret));
            println!("public_key (32 bytes, register on-chain): {}", hex::encode(public));
        }
        Cmd::Sign { secret, data_hash } => {
            let key = decode_secret(&secret).expect("invalid secret seed");
            let msg = hex::decode(data_hash.trim()).expect("invalid data_hash hex");
            let sig = sign_data_hash(&key, &msg);
            println!("signature (64 bytes): {}", hex::encode(sig));
        }
        Cmd::MerkleRoot { inputs } => {
            let blobs: Vec<Vec<u8>> = inputs
                .iter()
                .map(|h| hex::decode(h.trim()).expect("invalid hex input"))
                .collect();
            let refs: Vec<&[u8]> = blobs.iter().map(|b| b.as_slice()).collect();
            let root = merkle_root_from_blobs(&refs);
            println!("merkle_root (32 bytes): {}", hex::encode(root));
        }
        Cmd::RegisterSensor { package, oracle, registry, sensor, metadata, location, public_key } => {
            let c = register_sensor(&package, &oracle, &registry, sensor, &metadata, &location, &public_key);
            println!("{}", c.render());
        }
        Cmd::SubmitAttestation { package, oracle, registry, sensor, data_hash, merkle_root } => {
            let c = submit_attestation(&package, &oracle, &registry, sensor, &data_hash, &merkle_root);
            println!("{}", c.render());
        }
        Cmd::SubmitWitness { package, oracle, registry, attestation, witness, signature } => {
            let c = submit_witness(&package, &oracle, &registry, attestation, witness, &signature);
            println!("{}", c.render());
        }
    }
}
