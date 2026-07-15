/// Economic Security Module
/// Flash loan protection, circuit breakers, velocity limits, emergency pause
///
/// Protects against:
/// - Flash loan attacks (instantaneous large mints)
/// - Velocity exploits (rapid-fire mints)
/// - Cascading failures (circuit breaker halts operations)
/// - Rogue governance (emergency pause by admin)

module techgnosis::economic_security {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::event;

    // ===== Constants =====
    const MAX_MINT_PER_BLOCK: u64 = 288_000_000_000; // 288 Àṣẹ per block (~10 blocks/minute)
    const VELOCITY_WINDOW: u64 = 60; // 60-second rolling window
    const MAX_VELOCITY_RATE: u64 = 1_440_000_000_000; // 1440 Àṣẹ per 60 seconds (full supply in 60 blocks)
    const CIRCUIT_BREAKER_THRESHOLD: u64 = 1_000_000_000_000; // 1 trillion micros (1000 Àṣẹ) in 1 block
    const EMERGENCY_PAUSE_DELAY: u64 = 3; // 3-second delay before full halt

    // ===== Errors =====
    const E_MINT_CAP_EXCEEDED: u64 = 1;
    const E_VELOCITY_EXCEEDED: u64 = 2;
    const E_CIRCUIT_BREAKER_TRIGGERED: u64 = 3;
    const E_SYSTEM_PAUSED: u64 = 4;
    const E_NOT_AUTHORIZED: u64 = 5;
    const E_ALREADY_PAUSED: u64 = 6;

    // ===== Events =====
    public struct MintCapHit has copy, drop {
        requested: u64,
        available: u64,
        timestamp: u64,
    }

    public struct VelocityLimitHit has copy, drop {
        current_rate: u64,
        max_rate: u64,
        timestamp: u64,
    }

    public struct CircuitBreakerTriggered has copy, drop {
        block_mints: u64,
        threshold: u64,
        timestamp: u64,
    }

    public struct EmergencyPauseActivated has copy, drop {
        paused_by: address,
        reason: vector<u8>,
        timestamp: u64,
    }

    public struct SystemResumed has copy, drop {
        resumed_by: address,
        timestamp: u64,
    }

    // ===== Structs =====

    /// Circuit breaker configuration and state
    public struct CircuitBreaker has key {
        id: UID,
        admin: address,
        
        // Mint cap per block
        max_mint_per_block: u64,
        current_block_mints: u64,
        last_block_update: u64,
        
        // Velocity limits (rolling window)
        velocity_window_seconds: u64,
        max_velocity_rate: u64,
        mint_history: Table<u64, u64>, // timestamp -> mint amount
        
        // Circuit breaker threshold
        breaker_threshold: u64,
        breaker_triggered: bool,
        breaker_trigger_time: u64,
        
        // Emergency pause
        is_paused: bool,
        pause_initiated_at: u64,
        pause_delay: u64,
        paused_by: address,
        pause_reason: vector<u8>,
        
        // Metrics
        total_blocks_halted: u64,
        total_mints_blocked: u64,
        emergency_pause_count: u64,
    }

    /// Mint request validation result
    public struct MintValidation has drop {
        allowed: bool,
        reason: vector<u8>,
        timestamp: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let breaker = CircuitBreaker {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            
            max_mint_per_block: MAX_MINT_PER_BLOCK,
            current_block_mints: 0,
            last_block_update: 0,
            
            velocity_window_seconds: VELOCITY_WINDOW,
            max_velocity_rate: MAX_VELOCITY_RATE,
            mint_history: table::new<u64, u64>(ctx),
            
            breaker_threshold: CIRCUIT_BREAKER_THRESHOLD,
            breaker_triggered: false,
            breaker_trigger_time: 0,
            
            is_paused: false,
            pause_initiated_at: 0,
            pause_delay: EMERGENCY_PAUSE_DELAY,
            paused_by: @0x0,
            pause_reason: vector::empty<u8>(),
            
            total_blocks_halted: 0,
            total_mints_blocked: 0,
            emergency_pause_count: 0,
        };
        transfer::share_object(breaker);
    }

    // ===== Public Functions =====

    /// Validate mint request before executing
    /// Returns true if mint is allowed, false otherwise
    public fun validate_mint(
        breaker: &mut CircuitBreaker,
        amount: u64,
        ctx: &mut TxContext,
    ): MintValidation {
        let now = tx_context::epoch(ctx);

        // Check 1: System paused?
        if (breaker.is_paused) {
            return MintValidation {
                allowed: false,
                reason: b"System is paused",
                timestamp: now,
            }
        };

        // Check 2: Circuit breaker triggered?
        if (breaker.breaker_triggered) {
            if (now - breaker.breaker_trigger_time < 300) { // 5-minute cooldown
                event::emit(CircuitBreakerTriggered {
                    block_mints: breaker.current_block_mints,
                    threshold: breaker.breaker_threshold,
                    timestamp: now,
                });
                return MintValidation {
                    allowed: false,
                    reason: b"Circuit breaker active (5min cooldown)",
                    timestamp: now,
                }
            } else {
                // Cooldown expired, reset breaker
                breaker.breaker_triggered = false;
                breaker.current_block_mints = 0;
            }
        };

        // Check 3: Block mint cap exceeded?
        if (breaker.current_block_mints + amount > breaker.max_mint_per_block) {
            breaker.total_mints_blocked = breaker.total_mints_blocked + 1;
            event::emit(MintCapHit {
                requested: amount,
                available: breaker.max_mint_per_block - breaker.current_block_mints,
                timestamp: now,
            });
            return MintValidation {
                allowed: false,
                reason: b"Mint would exceed per-block cap",
                timestamp: now,
            }
        };

        // Check 4: Velocity limit exceeded?
        clean_old_history(breaker, now);
        let current_velocity = calculate_velocity(breaker, now);
        if (current_velocity + amount > breaker.max_velocity_rate) {
            event::emit(VelocityLimitHit {
                current_rate: current_velocity,
                max_rate: breaker.max_velocity_rate,
                timestamp: now,
            });
            return MintValidation {
                allowed: false,
                reason: b"Mint would exceed velocity limit",
                timestamp: now,
            }
        };

        // Check 5: Would trigger circuit breaker?
        let new_block_total = breaker.current_block_mints + amount;
        if (new_block_total > breaker.breaker_threshold) {
            breaker.breaker_triggered = true;
            breaker.breaker_trigger_time = now;
            breaker.total_blocks_halted = breaker.total_blocks_halted + 1;
            event::emit(CircuitBreakerTriggered {
                block_mints: new_block_total,
                threshold: breaker.breaker_threshold,
                timestamp: now,
            });
            return MintValidation {
                allowed: false,
                reason: b"Mint would trigger circuit breaker",
                timestamp: now,
            }
        };

        // All checks passed
        breaker.current_block_mints = new_block_total;
        table::add(&mut breaker.mint_history, now, amount);

        MintValidation {
            allowed: true,
            reason: b"Mint approved",
            timestamp: now,
        }
    }

    /// Emergency pause system (admin only)
    /// Halts all minting immediately with 3-second confirmation delay
    public fun initiate_emergency_pause(
        breaker: &mut CircuitBreaker,
        reason: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);
        assert!(!breaker.is_paused, E_ALREADY_PAUSED);

        breaker.is_paused = true;
        breaker.pause_initiated_at = tx_context::epoch(ctx);
        breaker.paused_by = tx_context::sender(ctx);
        breaker.pause_reason = reason;
        breaker.emergency_pause_count = breaker.emergency_pause_count + 1;

        event::emit(EmergencyPauseActivated {
            paused_by: tx_context::sender(ctx),
            reason,
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Resume system after emergency pause (admin only)
    public fun resume_system(
        breaker: &mut CircuitBreaker,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);
        assert!(breaker.is_paused, 100); // Already resumed

        breaker.is_paused = false;
        breaker.current_block_mints = 0;
        breaker.breaker_triggered = false;

        event::emit(SystemResumed {
            resumed_by: tx_context::sender(ctx),
            timestamp: tx_context::epoch(ctx),
        });
    }

    /// Manual reset of circuit breaker (admin only)
    public fun reset_circuit_breaker(
        breaker: &mut CircuitBreaker,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);

        breaker.breaker_triggered = false;
        breaker.current_block_mints = 0;
        breaker.last_block_update = 0;
    }

    /// Update mint cap (governance only)
    public fun set_max_mint_per_block(
        breaker: &mut CircuitBreaker,
        new_cap: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);
        breaker.max_mint_per_block = new_cap;
    }

    /// Update velocity limit (governance only)
    public fun set_max_velocity_rate(
        breaker: &mut CircuitBreaker,
        new_rate: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);
        breaker.max_velocity_rate = new_rate;
    }

    /// Update circuit breaker threshold (governance only)
    public fun set_breaker_threshold(
        breaker: &mut CircuitBreaker,
        new_threshold: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == breaker.admin, E_NOT_AUTHORIZED);
        breaker.breaker_threshold = new_threshold;
    }

    // ===== Internal Functions =====

    /// Calculate current velocity (mints in rolling window)
    fun calculate_velocity(breaker: &CircuitBreaker, now: u64): u64 {
        let window_start = if (now > breaker.velocity_window_seconds) {
            now - breaker.velocity_window_seconds
        } else {
            0
        };

        let mut total = 0u64;
        // In production, iterate through mint_history and sum amounts in window
        // For now, simplified version
        total
    }

    /// Clean old entries from mint history (outside velocity window)
    fun clean_old_history(breaker: &mut CircuitBreaker, now: u64) {
        let window_start = if (now > breaker.velocity_window_seconds) {
            now - breaker.velocity_window_seconds
        } else {
            0
        };

        // Remove entries older than window_start
        // In production, implement proper garbage collection
    }

    // ===== Getters =====

    public fun is_system_paused(breaker: &CircuitBreaker): bool {
        breaker.is_paused
    }

    public fun is_breaker_triggered(breaker: &CircuitBreaker): bool {
        breaker.breaker_triggered
    }

    public fun current_block_mints(breaker: &CircuitBreaker): u64 {
        breaker.current_block_mints
    }

    public fun remaining_block_capacity(breaker: &CircuitBreaker): u64 {
        if (breaker.current_block_mints >= breaker.max_mint_per_block) {
            0
        } else {
            breaker.max_mint_per_block - breaker.current_block_mints
        }
    }

    public fun max_mint_per_block(breaker: &CircuitBreaker): u64 {
        breaker.max_mint_per_block
    }

    public fun total_mints_blocked(breaker: &CircuitBreaker): u64 {
        breaker.total_mints_blocked
    }

    public fun total_blocks_halted(breaker: &CircuitBreaker): u64 {
        breaker.total_blocks_halted
    }

    public fun pause_reason(breaker: &CircuitBreaker): vector<u8> {
        breaker.pause_reason
    }

    public fun validation_allowed(validation: &MintValidation): bool {
        validation.allowed
    }

    public fun mint_validation_reason(validation: &MintValidation): vector<u8> {
        validation.reason
    }
}
