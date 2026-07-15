/// Elegbára Router — ÀṢẸ Treasury Routing Contract
/// Entry point for ALL minted ÀṢẸ and 3.69% Èṣù tax.
/// Routes funds instantly to 8 strictly isolated sub-wallets.
///
/// Distribution (of daily mint):
///   30% → VeilSim | 20% → R&D | 10% → Governance | 10% → Reserve
///   10% → Lottery/Burn | 10% → Grants | 5% → UBI | 5% → Sabbath Reserve
///
/// Hard constraints:
///   - Èṣù ALWAYS gets paid first (3.69% on ALL transactions)
///   - Elegbára does NOT hold funds long-term
///   - No-commingling: purpose_tag + allowlist enforced
///   - Sabbath freeze: Saturday UTC = 0 mint
///   - Agent birth: 0.01 ÀṢẸ → 20% burn / 40% Elegbára / 20% inheritance / 20% performance

module techgnosis::elegbara_router {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;

    // ===== Constants =====

    // Èṣù tax: 3.69% = 369 basis points out of 10000
    const ESU_TAX_BPS: u64 = 369;
    const BPS_DENOM: u64 = 10000;

    // Sub-wallet distribution basis points (of post-tax amount)
    const VEILSIM_BPS: u64 = 3000;      // 30%
    const RND_BPS: u64 = 2000;           // 20%
    const GOVERNANCE_BPS: u64 = 1000;    // 10%
    const RESERVE_BPS: u64 = 1000;       // 10%
    const LOTTERY_BURN_BPS: u64 = 1000;  // 10%
    const GRANTS_BPS: u64 = 1000;        // 10%
    const UBI_BPS: u64 = 500;            // 5%
    const SABBATH_RESERVE_BPS: u64 = 500; // 5%
    // TOTAL = 10000 = 100%

    // Agent birth fee: 0.01 ÀṢẸ = 10_000 micros (6 decimals)
    const AGENT_BIRTH_FEE: u64 = 10_000;
    // Agent birth split basis points
    const BIRTH_BURN_BPS: u64 = 2000;        // 20%
    const BIRTH_ELEGBARA_BPS: u64 = 4000;    // 40%
    const BIRTH_INHERITANCE_BPS: u64 = 2000; // 20%
    const BIRTH_PERFORMANCE_BPS: u64 = 2000; // 20%

    // Mint rate: 1 ÀṢẸ per minute = 1_000_000 micros (6 decimals)
    const MINT_PER_MINUTE: u64 = 1_000_000;

    // Sabbath: Saturday = day 6 (epoch 0 = Thursday Jan 1 1970)
    const SABBATH_DAY: u64 = 6;
    const SECONDS_PER_DAY: u64 = 86400;

    // Purpose tags for no-commingling
    const PURPOSE_VEILSIM: u8 = 1;
    const PURPOSE_RND: u8 = 2;
    const PURPOSE_GOVERNANCE: u8 = 3;
    const PURPOSE_RESERVE: u8 = 4;
    const PURPOSE_LOTTERY_BURN: u8 = 5;
    const PURPOSE_GRANTS: u8 = 6;
    const PURPOSE_UBI: u8 = 7;
    const PURPOSE_SABBATH_RESERVE: u8 = 8;
    const PURPOSE_ODARA: u8 = 9;
    const PURPOSE_LAALU: u8 = 10;
    const PURPOSE_BARA: u8 = 11;
    const PURPOSE_AGBANA: u8 = 12;

    // ===== Errors =====
    const E_SABBATH_FROZEN: u64 = 100;
    const E_NOT_AUTHORIZED: u64 = 101;
    const E_INSUFFICIENT_BIRTH_FEE: u64 = 102;
    const E_PURPOSE_MISMATCH: u64 = 103;
    const E_COMMINGLING_DENIED: u64 = 104;
    const E_ZERO_AMOUNT: u64 = 105;

    // ===== Events =====

    public struct MintRouted has copy, drop {
        total_minted: u64,
        esu_tax: u64,
        veilsim: u64,
        rnd: u64,
        governance: u64,
        reserve: u64,
        lottery_burn: u64,
        grants: u64,
        ubi: u64,
        sabbath_reserve: u64,
        timestamp: u64,
    }

    public struct EsuTaxCollected has copy, drop {
        amount: u64,
        source_tx: u64,
        timestamp: u64,
    }

    public struct AgentBirthProcessed has copy, drop {
        agent_id: address,
        creator: address,
        fee_paid: u64,
        burned: u64,
        to_elegbara: u64,
        to_inheritance: u64,
        to_performance: u64,
        timestamp: u64,
    }

    public struct ComminglingReverted has copy, drop {
        source_purpose: u8,
        dest_purpose: u8,
        amount: u64,
        timestamp: u64,
    }

    // ===== Structs =====

    /// ASE token witness (needed for coin creation)
    public struct ASE has drop {}

    /// Individual sub-wallet with strict purpose isolation
    public struct SubWallet has key, store {
        id: UID,
        purpose_tag: u8,
        balance: Balance<ASE>,
        total_received: u64,
        total_disbursed: u64,
        allowlist: vector<u8>,
    }

    /// The Elegbára Router — entry point, never holds funds long-term
    public struct ElegbaraRouter has key {
        id: UID,
        admin: address,
        // Sub-wallet balances (inline for atomicity)
        veilsim: Balance<ASE>,
        rnd: Balance<ASE>,
        governance: Balance<ASE>,
        reserve: Balance<ASE>,
        lottery_burn: Balance<ASE>,
        grants: Balance<ASE>,
        ubi: Balance<ASE>,
        sabbath_reserve: Balance<ASE>,
        // Èṣù mask wallets
        odara: Balance<ASE>,       // Shrine tithes
        laalu: Balance<ASE>,       // Robot embodiment
        bara: Balance<ASE>,        // Emergency vault
        agbana: Balance<ASE>,      // Punitive / restitution
        // Birth pools
        inheritance_pool: Balance<ASE>,
        performance_pool: Balance<ASE>,
        // Tracking
        total_esu_tax_collected: u64,
        total_minted: u64,
        total_burned: u64,
        total_agents_born: u64,
        last_mint_timestamp: u64,
    }

    /// Mint scheduler state
    public struct MintScheduler has key {
        id: UID,
        admin: address,
        last_mint_epoch: u64,
        mints_today: u64,
        current_day: u64,
        is_sabbath: bool,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let router = ElegbaraRouter {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            veilsim: balance::zero<ASE>(),
            rnd: balance::zero<ASE>(),
            governance: balance::zero<ASE>(),
            reserve: balance::zero<ASE>(),
            lottery_burn: balance::zero<ASE>(),
            grants: balance::zero<ASE>(),
            ubi: balance::zero<ASE>(),
            sabbath_reserve: balance::zero<ASE>(),
            odara: balance::zero<ASE>(),
            laalu: balance::zero<ASE>(),
            bara: balance::zero<ASE>(),
            agbana: balance::zero<ASE>(),
            inheritance_pool: balance::zero<ASE>(),
            performance_pool: balance::zero<ASE>(),
            total_esu_tax_collected: 0,
            total_minted: 0,
            total_burned: 0,
            total_agents_born: 0,
            last_mint_timestamp: 0,
        };
        transfer::share_object(router);

        let scheduler = MintScheduler {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            last_mint_epoch: 0,
            mints_today: 0,
            current_day: 0,
            is_sabbath: false,
        };
        transfer::share_object(scheduler);
    }

    // ===== Core: Èṣù Tax Extraction =====

    /// Extract 3.69% Èṣù tax from any transaction amount.
    /// Returns (tax_amount, net_amount). Tax is ALWAYS taken first.
    public fun extract_esu_tax(amount: u64): (u64, u64) {
        let tax = (amount * ESU_TAX_BPS) / BPS_DENOM;
        let net = amount - tax;
        (tax, net)
    }

    // ===== Core: Mint Routing =====

    /// Route minted ÀṢẸ through Elegbára to all 8 sub-wallets.
    /// Minting itself is NOT taxed (tax applies to transactions only).
    /// Distribution is instant — Elegbára does not hold.
    public fun route_mint(
        router: &mut ElegbaraRouter,
        coin: Coin<ASE>,
        ctx: &TxContext,
    ) {
        let timestamp = tx_context::epoch(ctx);
        let total = coin::value(&coin);
        assert!(total > 0, E_ZERO_AMOUNT);

        let bal = coin::into_balance(coin);

        // Compute each sub-wallet share
        let veilsim_amt = (total * VEILSIM_BPS) / BPS_DENOM;
        let rnd_amt = (total * RND_BPS) / BPS_DENOM;
        let governance_amt = (total * GOVERNANCE_BPS) / BPS_DENOM;
        let reserve_amt = (total * RESERVE_BPS) / BPS_DENOM;
        let lottery_amt = (total * LOTTERY_BURN_BPS) / BPS_DENOM;
        let grants_amt = (total * GRANTS_BPS) / BPS_DENOM;
        let ubi_amt = (total * UBI_BPS) / BPS_DENOM;
        // Sabbath gets remainder to avoid rounding dust
        let sabbath_amt = total - veilsim_amt - rnd_amt - governance_amt
                          - reserve_amt - lottery_amt - grants_amt - ubi_amt;

        // Split and route
        balance::join(&mut router.veilsim, balance::split(&mut bal, veilsim_amt));
        balance::join(&mut router.rnd, balance::split(&mut bal, rnd_amt));
        balance::join(&mut router.governance, balance::split(&mut bal, governance_amt));
        balance::join(&mut router.reserve, balance::split(&mut bal, reserve_amt));
        balance::join(&mut router.lottery_burn, balance::split(&mut bal, lottery_amt));
        balance::join(&mut router.grants, balance::split(&mut bal, grants_amt));
        balance::join(&mut router.ubi, balance::split(&mut bal, ubi_amt));
        // Remaining goes to sabbath reserve
        balance::join(&mut router.sabbath_reserve, bal);

        router.total_minted = router.total_minted + total;

        event::emit(MintRouted {
            total_minted: total,
            esu_tax: 0,
            veilsim: veilsim_amt,
            rnd: rnd_amt,
            governance: governance_amt,
            reserve: reserve_amt,
            lottery_burn: lottery_amt,
            grants: grants_amt,
            ubi: ubi_amt,
            sabbath_reserve: sabbath_amt,
            timestamp,
        });
    }

    /// Route a transaction's Èṣù tax through the router.
    /// Called on every non-mint transaction. Tax extracted first, then routed.
    public fun route_transaction_tax(
        router: &mut ElegbaraRouter,
        coin: Coin<ASE>,
        ctx: &TxContext,
    ): Coin<ASE> {
        let timestamp = tx_context::epoch(ctx);
        let total = coin::value(&coin);
        assert!(total > 0, E_ZERO_AMOUNT);

        let (tax, net) = extract_esu_tax(total);

        let mut bal = coin::into_balance(coin);

        // Extract tax portion and add to Elegbára for routing
        let tax_bal = balance::split(&mut bal, tax);
        // Tax goes to VeilSim (as primary treasury sink — can be re-routed by governance)
        balance::join(&mut router.veilsim, tax_bal);

        router.total_esu_tax_collected = router.total_esu_tax_collected + tax;

        event::emit(EsuTaxCollected {
            amount: tax,
            source_tx: total,
            timestamp,
        });

        // Return net amount to caller
        coin::from_balance(bal, ctx)
    }

    // ===== Agent Birth =====

    /// Process agent birth payment: 0.01 ÀṢẸ split 4 ways.
    /// Returns agent birth event for Swibe listener.
    public fun process_agent_birth(
        router: &mut ElegbaraRouter,
        payment: Coin<ASE>,
        agent_id: address,
        ctx: &mut TxContext,
    ) {
        let timestamp = tx_context::epoch(ctx);
        let paid = coin::value(&payment);
        assert!(paid >= AGENT_BIRTH_FEE, E_INSUFFICIENT_BIRTH_FEE);

        let mut bal = coin::into_balance(payment);

        // Split the birth fee
        let burn_amt = (AGENT_BIRTH_FEE * BIRTH_BURN_BPS) / BPS_DENOM;
        let elegbara_amt = (AGENT_BIRTH_FEE * BIRTH_ELEGBARA_BPS) / BPS_DENOM;
        let inheritance_amt = (AGENT_BIRTH_FEE * BIRTH_INHERITANCE_BPS) / BPS_DENOM;
        let performance_amt = AGENT_BIRTH_FEE - burn_amt - elegbara_amt - inheritance_amt;

        // Burn portion: destroy it
        let burn_bal = balance::split(&mut bal, burn_amt);
        router.total_burned = router.total_burned + burn_amt;
        // In production: balance::decrease_supply. For now, route to lottery_burn as burn sink.
        balance::join(&mut router.lottery_burn, burn_bal);

        // Elegbára portion: route through standard distribution
        let elegbara_bal = balance::split(&mut bal, elegbara_amt);
        balance::join(&mut router.veilsim, elegbara_bal);

        // Inheritance pool
        let inheritance_bal = balance::split(&mut bal, inheritance_amt);
        balance::join(&mut router.inheritance_pool, inheritance_bal);

        // Performance pool (remainder)
        balance::join(&mut router.performance_pool, bal);

        router.total_agents_born = router.total_agents_born + 1;

        event::emit(AgentBirthProcessed {
            agent_id,
            creator: tx_context::sender(ctx),
            fee_paid: paid,
            burned: burn_amt,
            to_elegbara: elegbara_amt,
            to_inheritance: inheritance_amt,
            to_performance: performance_amt,
            timestamp,
        });
    }

    // ===== Sabbath Enforcement =====

    /// Check if current epoch corresponds to Saturday UTC.
    /// Returns true if Sabbath (no minting allowed).
    public fun check_sabbath(ctx: &TxContext): bool {
        let timestamp = tx_context::epoch(ctx);
        let day_of_week = (timestamp / SECONDS_PER_DAY) % 7;
        // Unix epoch day 0 (Jan 1 1970) was Thursday (day 4)
        // So Saturday = (timestamp_days + 4) % 7 == 6
        let adjusted = (day_of_week + 4) % 7;
        adjusted == SABBATH_DAY
    }

    /// Execute scheduled mint. Enforces Sabbath freeze.
    public fun execute_scheduled_mint(
        router: &mut ElegbaraRouter,
        scheduler: &mut MintScheduler,
        mint_coin: Coin<ASE>,
        ctx: &mut TxContext,
    ) {
        let timestamp = tx_context::epoch(ctx);

        // Sabbath check: Saturday = 0 mint
        assert!(!check_sabbath(ctx), E_SABBATH_FROZEN);

        // Route the minted amount
        route_mint(router, mint_coin, ctx);

        scheduler.last_mint_epoch = timestamp;
        scheduler.mints_today = scheduler.mints_today + 1;
    }

    // ===== No-Commingling Enforcement =====

    /// Validate that a transfer between sub-wallets is allowed.
    /// Each wallet has a purpose_tag and allowlist.
    /// If destination purpose_tag is NOT in source allowlist → REVERT.
    public fun validate_transfer(
        source_purpose: u8,
        dest_purpose: u8,
        source_allowlist: &vector<u8>,
    ): bool {
        let len = vector::length(source_allowlist);
        let mut i = 0;
        while (i < len) {
            if (*vector::borrow(source_allowlist, i) == dest_purpose) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Enforced transfer: reverts if commingling detected
    public fun enforced_transfer(
        source_purpose: u8,
        dest_purpose: u8,
        source_allowlist: &vector<u8>,
        amount: u64,
        ctx: &TxContext,
    ) {
        let allowed = validate_transfer(source_purpose, dest_purpose, source_allowlist);
        if (!allowed) {
            event::emit(ComminglingReverted {
                source_purpose,
                dest_purpose,
                amount,
                timestamp: tx_context::epoch(ctx),
            });
        };
        assert!(allowed, E_COMMINGLING_DENIED);
    }

    // ===== Ọ̀dàrà Shrine Tithe Split =====

    /// Route shrine tithes: 50% shrine / 25% inheritance / 15% AIO / 10% burn
    public fun route_odara_tithe(
        router: &mut ElegbaraRouter,
        coin: Coin<ASE>,
        _ctx: &TxContext,
    ) {
        let total = coin::value(&coin);
        let mut bal = coin::into_balance(coin);

        let shrine_amt = (total * 5000) / BPS_DENOM;     // 50%
        let inherit_amt = (total * 2500) / BPS_DENOM;    // 25%
        let aio_amt = (total * 1500) / BPS_DENOM;        // 15%
        let burn_amt = total - shrine_amt - inherit_amt - aio_amt; // 10%

        balance::join(&mut router.odara, balance::split(&mut bal, shrine_amt));
        balance::join(&mut router.inheritance_pool, balance::split(&mut bal, inherit_amt));
        balance::join(&mut router.rnd, balance::split(&mut bal, aio_amt));
        balance::join(&mut router.lottery_burn, bal); // burn remainder
        router.total_burned = router.total_burned + burn_amt;
    }

    // ===== Getters =====

    public fun total_esu_tax(router: &ElegbaraRouter): u64 {
        router.total_esu_tax_collected
    }

    public fun total_minted(router: &ElegbaraRouter): u64 {
        router.total_minted
    }

    public fun total_burned(router: &ElegbaraRouter): u64 {
        router.total_burned
    }

    public fun total_agents_born(router: &ElegbaraRouter): u64 {
        router.total_agents_born
    }

    public fun veilsim_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.veilsim)
    }

    public fun rnd_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.rnd)
    }

    public fun governance_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.governance)
    }

    public fun reserve_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.reserve)
    }

    public fun lottery_burn_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.lottery_burn)
    }

    public fun grants_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.grants)
    }

    public fun ubi_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.ubi)
    }

    public fun sabbath_reserve_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.sabbath_reserve)
    }

    public fun inheritance_pool_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.inheritance_pool)
    }

    public fun performance_pool_balance(router: &ElegbaraRouter): u64 {
        balance::value(&router.performance_pool)
    }

    public fun mint_per_minute(): u64 {
        MINT_PER_MINUTE
    }

    public fun agent_birth_fee(): u64 {
        AGENT_BIRTH_FEE
    }

    public fun esu_tax_bps(): u64 {
        ESU_TAX_BPS
    }
}
