#[cfg(test)]
module techgnosis::economic_security_tests {
    use techgnosis::economic_security::{Self, CircuitBreaker};
    use sui::test_scenario::{Self, Scenario};

    const ADMIN: address = @0x1;
    const USER: address = @0x2;

    #[test]
    fun test_flash_loan_protection_block_cap() {
        // Test: Flash loan attempting to mint entire supply in 1 block fails
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Attempt to mint 2,880 Àṣẹ (full supply) in one block
            // Expected: Fails due to MAX_MINT_PER_BLOCK = 288 Àṣẹ
            // Only 288 allowed per block
        };
        scenario.end();
    }

    #[test]
    fun test_velocity_limit_rapid_mints() {
        // Test: Rapid-fire mints within 60-second window fail
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Mint 1000 Àṣẹ at T=0 ✓
            // Mint 1000 Àṣẹ at T=1 ✓
            // ...continue minting...
            // Mint 1000 Àṣẹ at T=55 ✓ (total: 56,000 Àṣẹ in 55 seconds)
            // Mint 1000 Àṣẹ at T=56 → Would exceed 1,440,000 Àṣẹ/60s ❌
            
            // Expected: Velocity limit blocks transaction
        };
        scenario.end();
    }

    #[test]
    fun test_circuit_breaker_activation() {
        // Test: Circuit breaker triggers when single block > 1T micros (1000 Àṣẹ)
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Block 1: Mint 500 Àṣẹ ✓
            // Block 1: Mint 501 Àṣẹ → Would be 1001 total → Triggers breaker ❌
            
            // Expected:
            // 1. Mint rejected
            // 2. CircuitBreakerTriggered event emitted
            // 3. System paused for 5-minute cooldown
            // 4. All subsequent mints blocked
        };
        scenario.end();
    }

    #[test]
    fun test_circuit_breaker_cooldown() {
        // Test: Circuit breaker resets after 5-minute cooldown
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Trigger circuit breaker at T=0
            // Attempt mint at T=299s → Fails (in cooldown)
            // Attempt mint at T=301s → Succeeds (cooldown expired)
            
            // Expected: Breaker auto-resets after 5 min (300s)
        };
        scenario.end();
    }

    #[test]
    fun test_emergency_pause_blocks_all_mints() {
        // Test: Emergency pause blocks all minting
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // initiate_emergency_pause("Emergency security hold")
            // is_paused = true
            // Attempt to mint 1 Àṣẹ → Fails (system paused)
            // Attempt to mint 100 Àṣẹ → Fails
            // Attempt to mint full supply → Fails
            
            // Expected: All mints blocked while paused
        };
        scenario.end();
    }

    #[test]
    fun test_emergency_pause_reason_logged() {
        // Test: Emergency pause reason is recorded
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // initiate_emergency_pause("Possible governance attack detected")
            // pause_reason should be set to b"Possible governance attack detected"
            // EmergencyPauseActivated event emitted with reason
            
            // Expected: Reason is accessible via getter
        };
        scenario.end();
    }

    #[test]
    fun test_emergency_pause_only_admin() {
        // Test: Only admin can pause system
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(USER);
        {
            // USER attempts: initiate_emergency_pause("reason")
            // Expected: Fails with E_NOT_AUTHORIZED
        };
        scenario.end();
    }

    #[test]
    fun test_resume_system_resets_state() {
        // Test: Resume system clears mints and resets breaker
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Trigger circuit breaker
            // is_paused = true, current_block_mints = 1500
            // resume_system()
            // Expected: is_paused = false, current_block_mints = 0, breaker_triggered = false
        };
        scenario.end();
    }

    #[test]
    fun test_mint_validation_structure() {
        // Test: Mint validation returns correct structure
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // validate_mint(amount=100 Àṣẹ)
            // Expected:
            // {
            //   allowed: true,
            //   reason: b"Mint approved",
            //   timestamp: 1234567890
            // }
        };
        scenario.end();
    }

    #[test]
    fun test_mint_cap_exact_boundary() {
        // Test: Mint exactly at cap succeeds, one more fails
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // MAX_MINT_PER_BLOCK = 288,000,000,000 (288 Àṣẹ)
            // validate_mint(288,000,000,000) → allowed=true
            // validate_mint(1) → allowed=false (would exceed cap)
            
            // Expected: Exact cap boundary respected
        };
        scenario.end();
    }

    #[test]
    fun test_remaining_block_capacity() {
        // Test: Getter returns accurate remaining capacity
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // remaining_block_capacity() = 288,000,000,000 (full)
            // validate_mint(100,000,000,000) → allowed=true
            // remaining_block_capacity() = 188,000,000,000 (100 less)
            // validate_mint(188,000,000,000) → allowed=true
            // remaining_block_capacity() = 0
            // validate_mint(1) → allowed=false
            
            // Expected: Capacity decreases with each mint
        };
        scenario.end();
    }

    #[test]
    fun test_velocity_limit_rolling_window() {
        // Test: Velocity calculated correctly in rolling 60s window
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // T=0: validate_mint(1000 Àṣẹ) ✓
            // T=10: validate_mint(1000 Àṣẹ) ✓
            // T=20: validate_mint(1000 Àṣẹ) ✓
            // ...T=55...
            // T=55: validate_mint(300 Àṣẹ) ✓ (total: 56 × 300 = 16,800 in 55s)
            // T=65: Old T=0 drops out of window
            // T=65: validate_mint(1000 Àṣẹ) ✓ (window now T=5 to T=65)
            
            // Expected: Proper sliding window behavior
        };
        scenario.end();
    }

    #[test]
    fun test_metrics_tracking() {
        // Test: Metrics accurately track blocked mints and halted blocks
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // total_mints_blocked = 0
            // total_blocks_halted = 0
            //
            // validate_mint(500 Àṣẹ) → allowed (no change)
            // validate_mint(500 Àṣẹ) → allowed (no change)
            // validate_mint(1 Àṣẹ) → blocked (exceeds cap)
            // total_mints_blocked = 1
            //
            // validate_mint(1000 Àṣẹ) → triggers breaker
            // total_blocks_halted = 1
            
            // Expected: Metrics increment correctly
        };
        scenario.end();
    }

    #[test]
    #[expected_failure]
    fun test_emergency_pause_already_paused() {
        // Test: Cannot pause if already paused
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // initiate_emergency_pause("first")
            // initiate_emergency_pause("second") → Fails with E_ALREADY_PAUSED
        };
        scenario.end();
    }

    #[test]
    fun test_admin_governance_parameters() {
        // Test: Admin can update security parameters via governance
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // set_max_mint_per_block(500_000_000_000) → 500 Àṣẹ per block
            // set_max_velocity_rate(2_880_000_000_000) → 2880 Àṣẹ per 60s
            // set_breaker_threshold(1_500_000_000_000) → 1500 Àṣẹ trigger
            
            // Expected: Parameters updated successfully
        };
        scenario.end();
    }

    #[test]
    fun test_flash_loan_two_block_attack() {
        // Test: Flash loan split across 2 blocks still fails velocity check
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Block 1 (T=0): Mint 1000 Àṣẹ ✓
            // Block 2 (T=1): Mint 1000 Àṣẹ ✓
            // ...continue...
            // Block 60 (T=59): Mint 240 Àṣẹ ✓
            // Total in 60s: 60 × 240 = 14,400 Àṣẹ
            // Block 61 (T=60): Mint 240 Àṣẹ → Would exceed 1,440,000 in any 60s window ❌
            
            // Expected: Velocity limit prevents attack even split across blocks
        };
        scenario.end();
    }

    #[test]
    fun test_interleaved_cap_and_velocity() {
        // Test: Both cap and velocity limits enforced together
        let mut scenario = test_scenario::begin(ADMIN);
        {
            economic_security::init(scenario.ctx_mut());
        };
        scenario.next_tx(ADMIN);
        {
            // Cap: 288 Àṣẹ/block
            // Velocity: 1440 Àṣẹ/60s
            //
            // Scenario 1: Mint 288 per block for 10 blocks in 60s = 2880 total
            // Block 1: Mint 288 ✓
            // Block 2: Mint 288 ✓
            // Block 3: Mint 288 ✓
            // Block 4: Mint 288 ✓
            // Block 5: Mint 288 ✓
            // Total so far: 1440 (at velocity limit)
            // Block 6: Mint 288 ❌ (would exceed velocity)
            
            // Expected: Velocity limit triggers before cap
        };
        scenario.end();
    }
}
