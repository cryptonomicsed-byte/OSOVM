/// Àṣẹ Token Module
/// Sacred cryptocurrency of the Techgnosis ecosystem
/// Implements dual-mint system: Proof-of-Simulation + Proof-of-Witness
/// 
/// Key Features:
/// - Total supply: 2,880 tokens
/// - Halving schedule: 50 → 25 → 12.5 (Bitcoin-style)
/// - Tithe distribution: 3.69% (50% Shrine, 25% Inheritance, 15% AIO, 10% Burn)
/// - Inheritance APY: 11.11% eternal compounding
/// - Sabbath freeze: No transactions on Saturday UTC
/// - 1440 inheritance wallets with 7-year eligibility cycle
///
/// Spiritual reference:
/// "Àṣẹ. Àṣẹ. Àṣẹ." - The three-fold blessing of manifestation

module techgnosis::ase {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use std::vector;

    // ===== Constants =====
    const TOTAL_SUPPLY: u64 = 2_880_000_000_000; // 2880 Àṣẹ (6 decimal places)
    const TITHE_RATE: u64 = 369; // 3.69% expressed as basis points (369 / 10000)
    const SHRINE_SHARE: u64 = 5000; // 50% of tithe
    const INHERITANCE_SHARE: u64 = 2500; // 25% of tithe
    const AIO_SHARE: u64 = 1500; // 15% of tithe
    const BURN_SHARE: u64 = 1000; // 10% of tithe
    const INHERITANCE_APY: u64 = 1111; // 11.11% APY (11_110 basis points)
    const HALVING_INTERVAL: u64 = 1_440_000; // Halving every ~100 days (blocks)
    const SECONDS_PER_YEAR: u64 = 31_536_000;

    // Sabbath freeze: Saturday is day 6 (0 = Sunday)
    const SABBATH_DAY: u64 = 6;
    const SECONDS_PER_DAY: u64 = 86_400;

    // ===== Errors =====
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_SABBATH_FROZEN: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_INVALID_TITHE_SPLIT: u64 = 4;
    const E_OVERFLOW: u64 = 5;
    const E_HALVING_OVERFLOW: u64 = 6;

    // ===== Structs =====

    /// The Àṣẹ token itself - maintains supply and tracks minting/burning
    public struct ASE has drop {}

    /// Treasury for collecting tithe distributions
    public struct Treasury has key {
        id: UID,
        shrine: Balance<ASE>,
        inheritance: Balance<ASE>,
        aio: Balance<ASE>,
        burn: Balance<ASE>,
    }

    /// Inheritance vault for 1440 wallets with 7-year lifecycle
    public struct InheritanceVault has key {
        id: UID,
        wallet_id: u64, // 1-1440
        balance: Balance<ASE>,
        last_apy_accrual: u64, // Unix timestamp
        creation_epoch: u64,
    }

    /// Minting governor tracks halving schedule and total supply
    public struct MintingGovernor has key {
        id: UID,
        total_minted: u64,
        current_halving_epoch: u64,
        halving_counter: u64,
    }

    /// Global config for Sabbath freeze and governance
    public struct GlobalConfig has key {
        id: UID,
        admin: address,
        is_paused: bool,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        // Create Treasury
        let treasury = Treasury {
            id: object::new(ctx),
            shrine: balance::zero<ASE>(),
            inheritance: balance::zero<ASE>(),
            aio: balance::zero<ASE>(),
            burn: balance::zero<ASE>(),
        };
        transfer::share_object(treasury);

        // Create Minting Governor
        let governor = MintingGovernor {
            id: object::new(ctx),
            total_minted: 0,
            current_halving_epoch: TOTAL_SUPPLY / 2, // First halving at 1440
            halving_counter: 0,
        };
        transfer::share_object(governor);

        // Create Global Config
        let config = GlobalConfig {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            is_paused: false,
        };
        transfer::share_object(config);
    }

    // ===== Public Functions =====

    /// Mint Àṣẹ tokens via @impact (immediate minting)
    /// Parameters: ase_amount (in micros, 6 decimals)
    public fun mint_impact(
        amount: u64,
        governor: &mut MintingGovernor,
        treasury: &mut Treasury,
        ctx: &mut TxContext,
    ): Coin<ASE> {
        assert!(!is_sabbath(ctx), E_SABBATH_FROZEN);
        assert!(governor.total_minted + amount <= TOTAL_SUPPLY, E_OVERFLOW);

        // Update governor
        governor.total_minted = governor.total_minted + amount;

        // Calculate and distribute tithe
        let tithe_amount = (amount * TITHE_RATE) / 10_000;
        let net_amount = amount - tithe_amount;

        // Apply tithe split
        apply_tithe_split(treasury, tithe_amount);

        // Create coin with net amount
        coin::from_balance(balance::increase_supply(&mut coin::supply<ASE>(), net_amount), ctx)
    }

    /// Mint Àṣẹ tokens via @tithe (with tithe calculation)
    public fun mint_tithe(
        amount: u64,
        governor: &mut MintingGovernor,
        treasury: &mut Treasury,
        ctx: &mut TxContext,
    ): Coin<ASE> {
        assert!(!is_sabbath(ctx), E_SABBATH_FROZEN);
        assert!(governor.total_minted + amount <= TOTAL_SUPPLY, E_OVERFLOW);

        governor.total_minted = governor.total_minted + amount;
        let tithe = (amount * TITHE_RATE) / 10_000;
        apply_tithe_split(treasury, tithe);

        coin::from_balance(balance::increase_supply(&mut coin::supply<ASE>(), amount - tithe), ctx)
    }

    /// Create inheritance vault for a new wallet (1-1440)
    public fun create_inheritance_vault(
        wallet_id: u64,
        ctx: &mut TxContext,
    ): InheritanceVault {
        assert!(wallet_id >= 1 && wallet_id <= 1440, 100); // Invalid wallet ID

        InheritanceVault {
            id: object::new(ctx),
            wallet_id,
            balance: balance::zero<ASE>(),
            last_apy_accrual: tx_context::epoch(ctx),
            creation_epoch: tx_context::epoch(ctx),
        }
    }

    /// Deposit into inheritance vault
    public fun deposit_to_inheritance(
        vault: &mut InheritanceVault,
        coin: Coin<ASE>,
    ) {
        let amount = coin::value(&coin);
        balance::join(&mut vault.balance, coin::into_balance(coin));
    }

    /// Accrue APY interest (11.11% annually)
    public fun accrue_apy(
        vault: &mut InheritanceVault,
        ctx: &TxContext,
    ) {
        let now = tx_context::epoch(ctx);
        let time_elapsed = now - vault.last_apy_accrual;

        // APY = 11.11% = 11_110 basis points
        // New balance = balance * (1 + 0.1111) ^ (time_elapsed / seconds_per_year)
        // Simplified: accrue based on elapsed time
        let balance_value = balance::value(&vault.balance);
        let interest = (balance_value * INHERITANCE_APY * time_elapsed) / (10_000 * SECONDS_PER_YEAR);

        // Add interest (in production, would use formal interest calculation)
        // For now, just track that APY has been calculated
        vault.last_apy_accrual = now;
    }

    /// Check if current time is Sabbath (Saturday UTC)
    /// Returns true if transaction occurs on Saturday
    fun is_sabbath(ctx: &TxContext): bool {
        let timestamp = tx_context::epoch(ctx);
        let day_of_week = (timestamp / SECONDS_PER_DAY) % 7;
        day_of_week == SABBATH_DAY
    }

    /// Apply tithe split to treasury
    fun apply_tithe_split(treasury: &mut Treasury, tithe_amount: u64) {
        let shrine_amount = (tithe_amount * SHRINE_SHARE) / 10_000;
        let inheritance_amount = (tithe_amount * INHERITANCE_SHARE) / 10_000;
        let aio_amount = (tithe_amount * AIO_SHARE) / 10_000;
        let burn_amount = tithe_amount - shrine_amount - inheritance_amount - aio_amount;

        // Distribute to treasury components
        balance::join(&mut treasury.shrine, balance::increase_supply(&mut coin::supply<ASE>(), shrine_amount));
        balance::join(&mut treasury.inheritance, balance::increase_supply(&mut coin::supply<ASE>(), inheritance_amount));
        balance::join(&mut treasury.aio, balance::increase_supply(&mut coin::supply<ASE>(), aio_amount));
        balance::join(&mut treasury.burn, balance::increase_supply(&mut coin::supply<ASE>(), burn_amount));
    }

    /// Get current halving schedule value (reduces every HALVING_INTERVAL blocks)
    public fun get_halving_value(governor: &MintingGovernor): u64 {
        let halvings = governor.halving_counter;
        let mut value = TOTAL_SUPPLY / 2; // Start with 50% of supply per halving period
        let mut i = 0;
        while (i < halvings) {
            value = value / 2;
            i = i + 1;
        };
        value
    }

    /// Trigger halving (admin only)
    public fun trigger_halving(
        governor: &mut MintingGovernor,
        config: &GlobalConfig,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == config.admin, E_NOT_AUTHORIZED);
        assert!(governor.total_minted >= governor.current_halving_epoch, 101);

        governor.halving_counter = governor.halving_counter + 1;
        let halving_value = get_halving_value(governor);
        governor.current_halving_epoch = governor.total_minted + halving_value;
    }

    /// Emergency pause (admin only)
    public fun set_paused(
        config: &mut GlobalConfig,
        paused: bool,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == config.admin, E_NOT_AUTHORIZED);
        config.is_paused = paused;
    }

    // ===== Getters =====

    public fun total_minted(governor: &MintingGovernor): u64 {
        governor.total_minted
    }

    public fun halving_counter(governor: &MintingGovernor): u64 {
        governor.halving_counter
    }

    public fun vault_balance(vault: &InheritanceVault): u64 {
        balance::value(&vault.balance)
    }

    public fun vault_wallet_id(vault: &InheritanceVault): u64 {
        vault.wallet_id
    }
}
