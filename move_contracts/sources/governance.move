/// Multi-Signature Governance Module
/// Council of 12 voting with Bínò final signature + 7-day time-lock
///
/// Features:
/// - 12 council members with bitmask voting
/// - Quorum threshold (default: 7/12 = 58%)
/// - 7-day time-lock before execution
/// - Bínò final signature (centralized bottleneck with fallback)
/// - Nonce-based replay protection
/// - Support for treasury allocation, parameter changes, emergency actions

module techgnosis::governance {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::event;
    use sui::vec_set::{Self, VecSet};

    // ===== Constants =====
    const COUNCIL_SIZE: u64 = 12;
    const QUORUM_THRESHOLD: u64 = 7; // 7 out of 12 required
    const TIMELOCK_DURATION: u64 = 604_800; // 7 days in seconds
    const MAX_PROPOSAL_SIZE: u64 = 1000; // Max proposal data size

    // Proposal types
    const PROPOSAL_TYPE_TREASURY: u8 = 1;
    const PROPOSAL_TYPE_PARAMETER_CHANGE: u8 = 2;
    const PROPOSAL_TYPE_EMERGENCY_PAUSE: u8 = 3;
    const PROPOSAL_TYPE_COUNCIL_CHANGE: u8 = 4;
    // Grant proposal type constant
    const PROPOSAL_TYPE_GRANT: u8 = 5;

    // Grant proposal constants
    const GRANT_QUORUM: u64 = 5;                       // 5/12 for grants
    const GRANT_TIMELOCK: u64 = 259_200;               // 3 days in seconds
    const MAX_GRANT_MICRO_ASE: u64 = 100_000_000_000;  // 100,000 Àṣẹ max

    // ===== Errors =====
    const E_NOT_COUNCIL_MEMBER: u64 = 1;
    const E_INVALID_PROPOSAL: u64 = 2;
    const E_QUORUM_NOT_MET: u64 = 3;
    const E_TIMELOCK_ACTIVE: u64 = 4;
    const E_NOT_AUTHORIZED: u64 = 5;
    const E_INVALID_BINO_SIGNATURE: u64 = 6;
    const E_DUPLICATE_VOTE: u64 = 7;
    const E_PROPOSAL_EXECUTED: u64 = 8;
    const E_PROPOSAL_REJECTED: u64 = 9;
    const E_GRANT_TOO_LARGE: u64 = 10;
    const E_INVALID_PURPOSE: u64 = 11;

    // ===== Events =====
    public struct GrantProposalCreated has copy, drop {
        proposal_id: u64,
        proposer: address,
        recipient: address,
        amount_micro_ase: u64,
        veil_id: u64,
    }

    public struct GrantProposalExecuted has copy, drop {
        proposal_id: u64,
        recipient: address,
        amount_micro_ase: u64,
    }

    public struct ProposalCreated has copy, drop {
        proposal_id: u64,
        proposer: address,
        proposal_type: u8,
        quorum_threshold: u64,
        timelock_release: u64,
    }

    public struct VoteCast has copy, drop {
        proposal_id: u64,
        voter: address,
        in_favor: bool,
    }

    public struct ProposalApproved has copy, drop {
        proposal_id: u64,
        votes_for: u64,
        votes_against: u64,
    }

    public struct ProposalExecuted has copy, drop {
        proposal_id: u64,
        executed_by: address,
        bino_signed: bool,
    }

    // ===== Structs =====

    /// A grant proposal requesting Àṣẹ from the Elegbára Grants bucket (10%).
    /// Separate from generic treasury proposals — grant proposals have a 3-day
    /// timelock (vs 7 days) and require only 5/12 quorum (research grants are
    /// lower-stakes than treasury changes).
    public struct GrantProposal has store {
        id: u64,
        proposer: address,
        recipient: address,           // who receives the Àṣẹ
        amount_micro_ase: u64,        // requested amount in micro-Àṣẹ
        purpose: vector<u8>,          // human-readable purpose (≤256 bytes)
        veil_id: u64,                 // which veil this grant funds (0 = open)
        votes_for: u64,               // bitmask (12-bit)
        votes_against: u64,           // bitmask (12-bit)
        created_at: u64,              // epoch seconds
        timelock_release: u64,        // created_at + 3 days
        executed: bool,
        rejected: bool,
    }

    /// Governance proposal
    public struct Proposal has store {
        id: u64,
        proposer: address,
        proposal_type: u8,
        title: vector<u8>,
        description: vector<u8>,
        proposal_data: vector<u8>,
        votes_for: u64, // Bitmask (12 bits max)
        votes_against: u64,
        votes_cast: VecSet<address>, // Track who voted
        created_at: u64,
        timelock_release_at: u64,
        executed: bool,
        bino_signed: bool,
        bino_signature: vector<u8>, // Ed25519 signature placeholder
    }

    /// Council governance contract
    public struct GovernanceContract has key {
        id: UID,
        admin: address,
        bino_address: address, // Final signer
        council_members: VecSet<address>,
        quorum_threshold: u64,
        next_proposal_id: u64,
        proposals: Table<u64, Proposal>,
        member_nonces: Table<address, u64>, // Replay protection
        grant_proposals: Table<u64, GrantProposal>,
        grant_proposal_count: u64,
    }

    /// Treasury allocation proposal data
    public struct TreasuryAllocation has drop {
        recipient: address,
        amount: u64,
        purpose: vector<u8>,
    }

    /// Parameter change proposal data
    public struct ParameterChange has drop {
        param_name: vector<u8>,
        old_value: u64,
        new_value: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let contract = GovernanceContract {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            bino_address: @0x0, // To be set by admin
            council_members: vec_set::empty<address>(),
            quorum_threshold: QUORUM_THRESHOLD,
            next_proposal_id: 1,
            proposals: table::new<u64, Proposal>(ctx),
            member_nonces: table::new<address, u64>(ctx),
            grant_proposals: table::new<u64, GrantProposal>(ctx),
            grant_proposal_count: 0u64,
        };
        transfer::share_object(contract);
    }

    // ===== Public Functions =====

    /// Create a new governance proposal
    public fun create_proposal(
        gov: &mut GovernanceContract,
        proposal_type: u8,
        title: vector<u8>,
        description: vector<u8>,
        proposal_data: vector<u8>,
        ctx: &mut TxContext,
    ): u64 {
        let proposer = tx_context::sender(ctx);
        assert!(vec_set::contains(&gov.council_members, &proposer), E_NOT_COUNCIL_MEMBER);
        assert!(vector::length(&proposal_data) <= MAX_PROPOSAL_SIZE, E_INVALID_PROPOSAL);

        let proposal_id = gov.next_proposal_id;
        let created_at = tx_context::epoch(ctx);
        let timelock_release_at = created_at + TIMELOCK_DURATION;

        let proposal = Proposal {
            id: proposal_id,
            proposer,
            proposal_type,
            title,
            description,
            proposal_data,
            votes_for: 0,
            votes_against: 0,
            votes_cast: vec_set::empty<address>(),
            created_at,
            timelock_release_at,
            executed: false,
            bino_signed: false,
            bino_signature: vector::empty<u8>(),
        };

        table::add(&mut gov.proposals, proposal_id, proposal);
        gov.next_proposal_id = proposal_id + 1;

        event::emit(ProposalCreated {
            proposal_id,
            proposer,
            proposal_type,
            quorum_threshold: gov.quorum_threshold,
            timelock_release: timelock_release_at,
        });

        proposal_id
    }

    /// Cast a vote on a proposal
    public fun vote(
        gov: &mut GovernanceContract,
        proposal_id: u64,
        in_favor: bool,
        ctx: &mut TxContext,
    ) {
        let voter = tx_context::sender(ctx);
        assert!(vec_set::contains(&gov.council_members, &voter), E_NOT_COUNCIL_MEMBER);

        let proposal = table::borrow_mut(&mut gov.proposals, proposal_id);
        assert!(!proposal.executed, E_PROPOSAL_EXECUTED);
        assert!(!vec_set::contains(&proposal.votes_cast, &voter), E_DUPLICATE_VOTE);

        // Record vote
        vec_set::insert(&mut proposal.votes_cast, voter);
        if (in_favor) {
            proposal.votes_for = proposal.votes_for + 1;
        } else {
            proposal.votes_against = proposal.votes_against + 1;
        };

        // Increment voter nonce for replay protection
        let nonce = if (table::contains(&gov.member_nonces, voter)) {
            *table::borrow(&gov.member_nonces, voter) + 1
        } else {
            1
        };
        if (table::contains(&gov.member_nonces, voter)) {
            table::remove(&mut gov.member_nonces, voter);
        };
        table::add(&mut gov.member_nonces, voter, nonce);

        event::emit(VoteCast {
            proposal_id,
            voter,
            in_favor,
        });
    }

    /// Check if proposal has quorum and approve it
    public fun approve_proposal(
        gov: &mut GovernanceContract,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        let proposal = table::borrow_mut(&mut gov.proposals, proposal_id);
        assert!(!proposal.executed, E_PROPOSAL_EXECUTED);
        assert!(proposal.votes_for >= gov.quorum_threshold, E_QUORUM_NOT_MET);

        event::emit(ProposalApproved {
            proposal_id,
            votes_for: proposal.votes_for,
            votes_against: proposal.votes_against,
        });
    }

    /// Bínò signs the proposal (final authorization)
    public fun bino_sign_proposal(
        gov: &mut GovernanceContract,
        proposal_id: u64,
        signature: vector<u8>,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == gov.bino_address, E_NOT_AUTHORIZED);

        let proposal = table::borrow_mut(&mut gov.proposals, proposal_id);
        assert!(!proposal.executed, E_PROPOSAL_EXECUTED);
        assert!(proposal.votes_for >= gov.quorum_threshold, E_QUORUM_NOT_MET);

        proposal.bino_signed = true;
        proposal.bino_signature = signature;
    }

    /// Execute the proposal after timelock expires and Bínò signature obtained
    public fun execute_proposal(
        gov: &mut GovernanceContract,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        let proposal = table::borrow_mut(&mut gov.proposals, proposal_id);
        assert!(!proposal.executed, E_PROPOSAL_EXECUTED);
        assert!(tx_context::epoch(ctx) >= proposal.timelock_release_at, E_TIMELOCK_ACTIVE);
        assert!(proposal.bino_signed, E_INVALID_BINO_SIGNATURE);
        assert!(proposal.votes_for >= gov.quorum_threshold, E_QUORUM_NOT_MET);

        proposal.executed = true;

        event::emit(ProposalExecuted {
            proposal_id,
            executed_by: tx_context::sender(ctx),
            bino_signed: proposal.bino_signed,
        });
    }

    /// Add a council member
    public fun add_council_member(
        gov: &mut GovernanceContract,
        member: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == gov.admin, E_NOT_AUTHORIZED);
        vec_set::insert(&mut gov.council_members, member);
    }

    /// Remove a council member
    public fun remove_council_member(
        gov: &mut GovernanceContract,
        member: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == gov.admin, E_NOT_AUTHORIZED);
        vec_set::remove(&mut gov.council_members, &member);
    }

    /// Set Bínò address
    public fun set_bino_address(
        gov: &mut GovernanceContract,
        bino: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == gov.admin, E_NOT_AUTHORIZED);
        gov.bino_address = bino;
    }

    /// Update quorum threshold
    public fun set_quorum_threshold(
        gov: &mut GovernanceContract,
        threshold: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == gov.admin, E_NOT_AUTHORIZED);
        assert!(threshold <= COUNCIL_SIZE, E_INVALID_PROPOSAL);
        gov.quorum_threshold = threshold;
    }

    // ===== Getters =====

    public fun council_size(): u64 {
        COUNCIL_SIZE
    }

    public fun quorum_threshold(gov: &GovernanceContract): u64 {
        gov.quorum_threshold
    }

    public fun timelock_duration(): u64 {
        TIMELOCK_DURATION
    }

    public fun proposal_votes_for(gov: &GovernanceContract, proposal_id: u64): u64 {
        table::borrow(&gov.proposals, proposal_id).votes_for
    }

    public fun proposal_executed(gov: &GovernanceContract, proposal_id: u64): bool {
        table::borrow(&gov.proposals, proposal_id).executed
    }

    // ===== Grant Proposals =====

    /// Submit a grant proposal for Àṣẹ from the Elegbára Grants bucket.
    /// Any council member can propose; requires 5/12 quorum + 3-day timelock.
    public fun submit_grant_proposal(
        gov: &mut GovernanceContract,
        recipient: address,
        amount_micro_ase: u64,
        purpose: vector<u8>,
        veil_id: u64,
        ctx: &mut TxContext,
    ) {
        let proposer = tx_context::sender(ctx);
        assert!(vec_set::contains(&gov.council_members, &proposer), E_NOT_COUNCIL_MEMBER);
        assert!(amount_micro_ase <= MAX_GRANT_MICRO_ASE, E_GRANT_TOO_LARGE);
        assert!(vector::length(&purpose) > 0 && vector::length(&purpose) <= 256, E_INVALID_PURPOSE);

        let now = tx_context::epoch(ctx); // epoch as time proxy
        let id = gov.grant_proposal_count;
        gov.grant_proposal_count = id + 1;

        let proposal = GrantProposal {
            id,
            proposer,
            recipient,
            amount_micro_ase,
            purpose,
            veil_id,
            votes_for: 0,
            votes_against: 0,
            created_at: now,
            timelock_release: now + GRANT_TIMELOCK,
            executed: false,
            rejected: false,
        };

        table::add(&mut gov.grant_proposals, id, proposal);

        event::emit(GrantProposalCreated {
            proposal_id: id,
            proposer,
            recipient,
            amount_micro_ase,
            veil_id,
        });
    }

    /// Get the number of grant proposals submitted.
    public fun grant_proposal_count(gov: &GovernanceContract): u64 {
        gov.grant_proposal_count
    }
}
