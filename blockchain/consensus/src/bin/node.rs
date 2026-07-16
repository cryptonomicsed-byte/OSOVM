// **Ọ̀ṢỌ́ Consensus Node**
// Standalone binary for running a blockchain node

use oso_consensus::{Validator, ValidatorSet, OsoConsensusNode};
use std::io::{self, Write};

#[tokio::main]
async fn main() -> io::Result<()> {
    // Initialize logging
    tracing_subscriber::fmt::init();

    println!("🛡️🌀⚛️🕯️🔥 Ọ̀ṢỌ́ CONSENSUS NODE");
    println!("===================================");
    println!();

    // Read node configuration
    print!("Enter node ID (e.g., 'council_1'): ");
    io::stdout().flush()?;
    let mut node_id = String::new();
    io::stdin().read_line(&mut node_id)?;
    let node_id = node_id.trim().to_string();

    print!("Number of validators (default 13): ");
    io::stdout().flush()?;
    let mut num_validators = String::new();
    io::stdin().read_line(&mut num_validators)?;
    let num_validators: usize = num_validators.trim().parse().unwrap_or(13);

    // Create validator set (default: Council of 12 + Bínò)
    let validators = if num_validators == 13 {
        vec![
            Validator::new("council_1".to_string(), [1u8; 32]),
            Validator::new("council_2".to_string(), [2u8; 32]),
            Validator::new("council_3".to_string(), [3u8; 32]),
            Validator::new("council_4".to_string(), [4u8; 32]),
            Validator::new("council_5".to_string(), [5u8; 32]),
            Validator::new("council_6".to_string(), [6u8; 32]),
            Validator::new("council_7".to_string(), [7u8; 32]),
            Validator::new("council_8".to_string(), [8u8; 32]),
            Validator::new("council_9".to_string(), [9u8; 32]),
            Validator::new("council_10".to_string(), [10u8; 32]),
            Validator::new("council_11".to_string(), [11u8; 32]),
            Validator::new("council_12".to_string(), [12u8; 32]),
            Validator::new("bino".to_string(), [13u8; 32]),
        ]
    } else {
        // Generate custom validators
        (0..num_validators)
            .map(|i| {
                let mut pubkey = [0u8; 32];
                pubkey[0] = i as u8; // `as` already truncates/wraps into 0..=255
                Validator::new(format!("validator_{}", i), pubkey)
            })
            .collect()
    };

    let validator_set = ValidatorSet::new(validators, 9)
        .expect("Failed to create validator set");

    println!();
    println!("✓ Created validator set with {} validators", validator_set.len());
    println!("  Threshold: {}", validator_set.threshold());
    println!();

    // Create consensus node
    let node = OsoConsensusNode::new(node_id.clone(), validator_set.validators().to_vec(), 9)
        .expect("Failed to create consensus node");

    println!("✓ Initialized consensus node: {}", node_id);
    println!("✓ Current block height: {}", node.block_height());
    println!("✓ Current state root: {:?}", hex::encode(node.state_root()));
    println!();

    println!("Node is ready!");
    println!("Waiting for network connections...");
    println!();

    // Keep the node running
    tokio::signal::ctrl_c().await?;
    println!();
    println!("Shutting down...");

    Ok(())
}
