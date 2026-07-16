use oso_consensus::{
    BFTConsensus, Block, BlockHeader, OsoConsensusNode, State, Transaction, Validator,
    ValidatorSet,
};

#[tokio::test]
async fn test_consensus_node_creation() {
    let validators = vec![
        Validator::new("council_1".to_string(), [1u8; 32]),
        Validator::new("council_2".to_string(), [2u8; 32]),
        Validator::new("council_3".to_string(), [3u8; 32]),
    ];

    let node = OsoConsensusNode::new("council_1".to_string(), validators, 3);
    assert!(node.is_ok());
}

#[test]
fn test_block_validation() {
    let header = BlockHeader::new(1, [0u8; 32], 1000, [1u8; 32], [2u8; 32], 1);
    let tx = Transaction::Transfer {
        from: "alice".to_string(),
        to: "bob".to_string(),
        amount: 100,
        nonce: 0,
    };
    let block = Block::new(header, vec![tx]);

    assert!(block.verify_structure().is_ok());
}

#[test]
fn test_state_transfers() {
    let mut state = State::new();

    // Initialize accounts
    state.update_balance("alice", 1000).unwrap();
    state.update_balance("bob", 500).unwrap();

    // Perform transfer
    let result = state.transfer("alice", "bob", 200);
    assert!(result.is_ok());

    // Verify balances
    assert_eq!(state.get_account("alice").unwrap().ase_balance, 800);
    assert_eq!(state.get_account("bob").unwrap().ase_balance, 700);
}

#[test]
fn test_state_invalid_transfer() {
    let mut state = State::new();
    state.update_balance("alice", 100).unwrap();

    // Try to transfer more than available
    let result = state.transfer("alice", "bob", 200);
    assert!(result.is_err());
}

#[test]
fn test_validator_set_standard() {
    let validators = vec![
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
    ];

    let validator_set = ValidatorSet::standard(validators);
    assert!(validator_set.is_ok());

    let vs = validator_set.unwrap();
    assert_eq!(vs.len(), 13);
    assert_eq!(vs.threshold(), 9); // 2/3 of 13 = 8.66, rounded to 9
}

#[test]
fn test_transaction_types() {
    let tx1 = Transaction::Transfer {
        from: "alice".to_string(),
        to: "bob".to_string(),
        amount: 100,
        nonce: 1,
    };
    assert_eq!(tx1.sender(), "alice");
    assert_eq!(tx1.nonce(), 1);

    let tx2 = Transaction::TechGnosDeploy {
        bytecode: vec![1, 2, 3],
        sender: "carol".to_string(),
        gas: 1000,
        nonce: 2,
    };
    assert_eq!(tx2.sender(), "carol");
    assert_eq!(tx2.nonce(), 2);
    assert_eq!(tx2.gas_budget(), 1000);
}

#[test]
fn test_bft_consensus_rounds() {
    let validators = vec![
        Validator::new("council_1".to_string(), [1u8; 32]),
        Validator::new("council_2".to_string(), [2u8; 32]),
        Validator::new("council_3".to_string(), [3u8; 32]),
    ];

    let validator_set = ValidatorSet::new(validators, 3).unwrap();
    let consensus = BFTConsensus::new("council_1".to_string(), validator_set);

    assert_eq!(consensus.current_round(), 0);

    consensus.next_round();
    assert_eq!(consensus.current_round(), 1);

    consensus.next_round();
    assert_eq!(consensus.current_round(), 2);
}
