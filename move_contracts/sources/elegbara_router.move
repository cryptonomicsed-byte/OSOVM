/// Elegbára Router — §29 stablecoin edition (generic over Coin<T>)
/// Entry point for the Èṣù 3.69% tithe on ALL settlement.
/// Routes the tithe to 8 strictly-isolated sub-wallets; returns the NET to the caller.
///
/// §29 CHANGES vs the retired ASE version:
///   - NO self-issued token. Generic over `T` (the stablecoin, e.g. USDC). Never mint.
///   - Removed mint scheduler / Sabbath mint-freeze / MINT_PER_MINUTE (mint concepts are retired).
///   - `route_transaction_tax<T>` is the load-bearing fn: take Coin<T>, skim 3.69% Èṣù, route it,
///     return the net Coin<T> to the caller (the job escrow forwards net to the worker).
///
/// Tithe distribution (of the 3.69% skim):
///   30% VeilSim | 20% R&D | 10% Gov | 10% Reserve | 10% Lottery/Burn | 10% Grants | 5% UBI | 5% Sabbath
///
/// Hard constraints: Èṣù is ALWAYS skimmed first; router never holds the net; sub-wallets are isolated.
module techgnosis::elegbara_router {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use std::option::{Self, Option};

    // ===== Constants =====
    const ESU_TAX_BPS: u64 = 369;   // 3.69%
    const BPS_DENOM: u64 = 10000;

    // Sub-wallet split of the tithe (basis points, sum = 10000)
    const VEILSIM_BPS: u64 = 3000;
    const RND_BPS: u64 = 2000;
    const GOVERNANCE_BPS: u64 = 1000;
    const RESERVE_BPS: u64 = 1000;
    const LOTTERY_BURN_BPS: u64 = 1000;
    const GRANTS_BPS: u64 = 1000;
    const UBI_BPS: u64 = 500;
    // Sabbath reserve takes the remainder (avoids rounding dust).

    // Agent birth fee split (of whatever is paid, in T)
    const BIRTH_BURN_BPS: u64 = 2000;
    const BIRTH_ELEGBARA_BPS: u64 = 4000;
    const BIRTH_INHERITANCE_BPS: u64 = 2000;
    // performance pool takes the remainder.

    // Job settlement split (of post-tax net, in BPS)
    const AGENT_SHARE_BPS: u64 = 1500;      // 15% — operational wallet, sized to survival cost
    const BIRTHER_GEN0_BPS: u64 = 2000;     // 20% — direct child
    const BIRTHER_GEN1_BPS: u64 = 1500;     // 15% — grandchild
    const BIRTHER_GEN2_BPS: u64 = 1000;     // 10% — great-grandchild and deeper
    // Ecosystem (remainder after agent + birther) goes back to the 8 pools via route_distribution

    // ===== Errors =====
    const E_ZERO_AMOUNT: u64 = 105;
    const E_NOT_ADMIN: u64 = 101;
    const E_BELOW_MIN: u64 = 106;
    const E_NOT_PENDING: u64 = 107;
    const E_TIMELOCK: u64 = 108;
    const E_BAD_WALLET: u64 = 109;
    // Smallest gross whose floor(gross * 369 / 10000) >= 1 (dust-split guard).
    const MIN_SETTLEMENT: u64 = 28;
    // Timelock for governed withdrawals; Sui epochs are ~24h, 7 ≈ one week.
    const TIMELOCK_EPOCHS: u64 = 7;

    // ===== Events =====
    public struct EsuTaxCollected has copy, drop {
        gross: u64,
        tax: u64,
        net: u64,
    }

    public struct DistributionRouted has copy, drop {
        total: u64,
        veilsim: u64, rnd: u64, governance: u64, reserve: u64,
        lottery_burn: u64, grants: u64, ubi: u64, sabbath_reserve: u64,
    }

    public struct AgentBirthProcessed has copy, drop {
        agent_id: address,
        fee_paid: u64,
        burned: u64,
        to_elegbara: u64,
        to_inheritance: u64,
        to_performance: u64,
    }

    /// Immutable royalty claim. Created at agent birth, stored on-chain, never altered.
    public struct BirthRecord has key, store {
        id: UID,
        agent_addr: address,
        birther_addr: address,
        royalty_bps: u64,   // set at birth: 2000 | 1500 | 1000 for gen 0/1/2+
        generation: u8,
    }

    public struct JobSettled has copy, drop {
        agent_addr: address,
        gross: u64,
        esu_tax: u64,
        birther_royalty: u64,
        ecosystem_share: u64,
        agent_amount: u64,
    }

    // ===== Router (generic over the stablecoin T) =====
    /// T is phantom: it only ever appears inside Balance<T> / Coin<T> (phantom positions).
    public struct ElegbaraRouter<phantom T> has key {
        id: UID,
        admin: address,
        veilsim: Balance<T>,
        rnd: Balance<T>,
        governance: Balance<T>,
        reserve: Balance<T>,
        lottery_burn: Balance<T>,
        grants: Balance<T>,
        ubi: Balance<T>,
        sabbath_reserve: Balance<T>,
        inheritance_pool: Balance<T>,
        performance_pool: Balance<T>,
        pending_withdrawal: Option<PendingWithdrawal<T>>,
        total_esu_tax_collected: u64,
        total_burned: u64,
        total_agents_born: u64,
    }

    /// Pending governed withdrawal — request/claim with an epoch timelock
    public struct PendingWithdrawal<phantom T> has store {
        wallet: u8,
        balance: Balance<T>,
        requested_epoch: u64,
    }

    // ===== Create =====
    /// Instantiate + share a router for a specific coin type T (e.g. USDC). Call once per coin.
    public entry fun create_router<T>(ctx: &mut TxContext) {
        let router = ElegbaraRouter<T> {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            veilsim: balance::zero<T>(),
            rnd: balance::zero<T>(),
            governance: balance::zero<T>(),
            reserve: balance::zero<T>(),
            lottery_burn: balance::zero<T>(),
            grants: balance::zero<T>(),
            ubi: balance::zero<T>(),
            sabbath_reserve: balance::zero<T>(),
            inheritance_pool: balance::zero<T>(),
            performance_pool: balance::zero<T>(),
            pending_withdrawal: option::none(),
            total_esu_tax_collected: 0,
            total_burned: 0,
            total_agents_born: 0,
        };
        transfer::share_object(router);
    }

    // ===== Core: Èṣù tithe extraction (pure) =====
    public fun extract_esu_tax(amount: u64): (u64, u64) {
        // FIX (C6): floor division let any gross < 28 units pay zero tithe
        // (dust-splitting bypass). Reject below-minimum settlement; do the
        // multiply in u128 (u64 * u64 can overflow before the division).
        assert!(amount >= MIN_SETTLEMENT, E_BELOW_MIN);
        let tax = (((amount as u128) * (ESU_TAX_BPS as u128)) / (BPS_DENOM as u128)) as u64;
        let net = amount - tax;
        (tax, net)
    }

    // ===== Core: skim the 3.69% tithe, route it, return the NET to the caller =====
    /// The seed-loop settlement path: escrow calls this with the gross payment,
    /// the tithe is routed to the sub-wallets, and the net Coin<T> is returned to forward to the worker.
    public fun route_transaction_tax<T>(
        router: &mut ElegbaraRouter<T>,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        let gross = coin::value(&coin);
        assert!(gross > 0, E_ZERO_AMOUNT);
        let (tax, net) = extract_esu_tax(gross);

        let mut bal = coin::into_balance(coin);
        let tax_bal = balance::split(&mut bal, tax);
        distribute_balance(router, tax_bal);
        router.total_esu_tax_collected = router.total_esu_tax_collected + tax;

        event::emit(EsuTaxCollected { gross, tax, net });
        coin::from_balance(bal, ctx)
    }

    // ===== Distribute a whole balance across the 8 sub-wallets (internal) =====
    fun distribute_balance<T>(router: &mut ElegbaraRouter<T>, mut bal: Balance<T>) {
        let total = balance::value(&bal);
        let veilsim_amt = (total * VEILSIM_BPS) / BPS_DENOM;
        let rnd_amt = (total * RND_BPS) / BPS_DENOM;
        let gov_amt = (total * GOVERNANCE_BPS) / BPS_DENOM;
        let reserve_amt = (total * RESERVE_BPS) / BPS_DENOM;
        let lottery_amt = (total * LOTTERY_BURN_BPS) / BPS_DENOM;
        let grants_amt = (total * GRANTS_BPS) / BPS_DENOM;
        let ubi_amt = (total * UBI_BPS) / BPS_DENOM;

        balance::join(&mut router.veilsim, balance::split(&mut bal, veilsim_amt));
        balance::join(&mut router.rnd, balance::split(&mut bal, rnd_amt));
        balance::join(&mut router.governance, balance::split(&mut bal, gov_amt));
        balance::join(&mut router.reserve, balance::split(&mut bal, reserve_amt));
        balance::join(&mut router.lottery_burn, balance::split(&mut bal, lottery_amt));
        balance::join(&mut router.grants, balance::split(&mut bal, grants_amt));
        balance::join(&mut router.ubi, balance::split(&mut bal, ubi_amt));
        balance::join(&mut router.sabbath_reserve, bal); // remainder

        event::emit(DistributionRouted {
            total, veilsim: veilsim_amt, rnd: rnd_amt, governance: gov_amt,
            reserve: reserve_amt, lottery_burn: lottery_amt, grants: grants_amt,
            ubi: ubi_amt, sabbath_reserve: total - veilsim_amt - rnd_amt - gov_amt
                - reserve_amt - lottery_amt - grants_amt - ubi_amt,
        });
    }

    /// Route a full provided coin (e.g. protocol revenue) across the sub-wallets. NOT minting.
    public fun route_distribution<T>(router: &mut ElegbaraRouter<T>, coin: Coin<T>) {
        assert!(coin::value(&coin) > 0, E_ZERO_AMOUNT);
        distribute_balance(router, coin::into_balance(coin));
    }

    // ===== BirthRecord helpers =====

    /// Return the royalty BPS for a given generation depth.
    public fun royalty_bps_for_generation(gen: u8): u64 {
        if (gen == 0) { BIRTHER_GEN0_BPS }
        else if (gen == 1) { BIRTHER_GEN1_BPS }
        else { BIRTHER_GEN2_BPS }
    }

    /// Create and return an immutable BirthRecord. Call from process_agent_birth.
    public fun create_birth_record(
        agent_addr: address,
        birther_addr: address,
        generation: u8,
        ctx: &mut TxContext,
    ): BirthRecord {
        BirthRecord {
            id: object::new(ctx),
            agent_addr,
            birther_addr,
            royalty_bps: royalty_bps_for_generation(generation),
            generation,
        }
    }

    /// Full job-payment settlement:
    ///   Step 1: extract 3.69% Èṣù tax → 8 sub-wallets (existing route_transaction_tax)
    ///   Step 2: from the net, split:
    ///           - birther royalty (per BirthRecord.royalty_bps, gen 0/1/2+ = 20/15/10%)
    ///           - agent operational (AGENT_SHARE_BPS = 15%)
    ///           - ecosystem remainder (60-65%) → route_distribution → 8 sub-wallets
    ///   Returns (birther_coin, agent_coin). Caller transfers birther_coin to record.birther_addr
    ///   and agent_coin to the agent's operational wallet.
    public fun settle_job_payment<T>(
        router: &mut ElegbaraRouter<T>,
        record: &BirthRecord,
        payment: Coin<T>,
        ctx: &mut TxContext,
    ): (Coin<T>, Coin<T>) {
        let gross = coin::value(&payment);
        assert!(gross > 0, E_ZERO_AMOUNT);

        // Step 1: tithe — routes 3.69% to 8 pools, returns ~96.31% net
        let net_coin = route_transaction_tax(router, payment, ctx);
        let net = coin::value(&net_coin);

        // Step 2: split net into birther + agent + ecosystem
        let birther_amt = (net * record.royalty_bps) / BPS_DENOM;
        let agent_amt = (net * AGENT_SHARE_BPS) / BPS_DENOM;
        let ecosystem_amt = net - birther_amt - agent_amt;

        let mut net_bal = coin::into_balance(net_coin);
        let birther_bal = balance::split(&mut net_bal, birther_amt);
        let agent_bal = balance::split(&mut net_bal, agent_amt);
        // remaining balance = ecosystem_amt (rounding dust included)
        let ecosystem_bal = net_bal;

        // Route ecosystem share back to the 8 sub-wallets
        distribute_balance(router, ecosystem_bal);

        event::emit(JobSettled {
            agent_addr: record.agent_addr,
            gross,
            esu_tax: (gross * ESU_TAX_BPS) / BPS_DENOM,
            birther_royalty: birther_amt,
            ecosystem_share: ecosystem_amt,
            agent_amount: agent_amt,
        });

        (
            coin::from_balance(birther_bal, ctx),
            coin::from_balance(agent_bal, ctx),
        )
    }

    // ===== Agent birth (fee paid in T) =====
    public fun process_agent_birth<T>(
        router: &mut ElegbaraRouter<T>,
        payment: Coin<T>,
        agent_id: address,
        birther_addr: address,
        generation: u8,
        ctx: &mut TxContext,
    ): BirthRecord {
        let paid = coin::value(&payment);
        assert!(paid > 0, E_ZERO_AMOUNT);
        let mut bal = coin::into_balance(payment);

        let burn_amt = (paid * BIRTH_BURN_BPS) / BPS_DENOM;
        let elegbara_amt = (paid * BIRTH_ELEGBARA_BPS) / BPS_DENOM;
        let inheritance_amt = (paid * BIRTH_INHERITANCE_BPS) / BPS_DENOM;

        // Burn = permanent lock: coins join lottery_burn, the one sub-wallet
        // with NO withdrawal path (excluded from withdraw_subwallet). They are
        // not destroyed (Sui offers no nonzero Balance destruction); they are
        // unspendable. total_burned counts permanently-locked coins.
        balance::join(&mut router.lottery_burn, balance::split(&mut bal, burn_amt));
        router.total_burned = router.total_burned + burn_amt;
        balance::join(&mut router.veilsim, balance::split(&mut bal, elegbara_amt));
        balance::join(&mut router.inheritance_pool, balance::split(&mut bal, inheritance_amt));
        let performance_amt = balance::value(&bal);
        balance::join(&mut router.performance_pool, bal); // remainder

        router.total_agents_born = router.total_agents_born + 1;
        event::emit(AgentBirthProcessed {
            agent_id, fee_paid: paid, burned: burn_amt, to_elegbara: elegbara_amt,
            to_inheritance: inheritance_amt, to_performance: performance_amt,
        });

        create_birth_record(agent_id, birther_addr, generation, ctx)
    }

    // ===== Governed withdrawal — timelocked request/claim for every sub-wallet =====
    // FIX (C7): only withdraw_reserve existed (admin-only, no timelock) and the
    // other 9 sub-wallets had NO withdrawal path at all, permanently locking
    // routed tithe. Now: admin requests from any named sub-wallet; the funds
    // leave the sub-wallet immediately but are claimable only after
    // TIMELOCK_EPOCHS. lottery_burn (wallet 4) is the burn sink — deliberately
    // excluded so it stays a permanent lock.

    fun withdraw_subwallet<T>(router: &mut ElegbaraRouter<T>, wallet: u8, amount: u64): Balance<T> {
        if (wallet == 0) { balance::split(&mut router.veilsim, amount) }
        else if (wallet == 1) { balance::split(&mut router.rnd, amount) }
        else if (wallet == 2) { balance::split(&mut router.governance, amount) }
        else if (wallet == 3) { balance::split(&mut router.reserve, amount) }
        else if (wallet == 5) { balance::split(&mut router.grants, amount) }
        else if (wallet == 6) { balance::split(&mut router.ubi, amount) }
        else if (wallet == 7) { balance::split(&mut router.sabbath_reserve, amount) }
        else if (wallet == 8) { balance::split(&mut router.inheritance_pool, amount) }
        else if (wallet == 9) { balance::split(&mut router.performance_pool, amount) }
        else { abort E_BAD_WALLET }
    }

    /// Admin requests a timelocked withdrawal from a named sub-wallet.
    /// One pending request at a time.
    public fun request_withdrawal<T>(
        router: &mut ElegbaraRouter<T>,
        wallet: u8,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == router.admin, E_NOT_ADMIN);
        assert!(option::is_none(&router.pending_withdrawal), E_TIMELOCK);
        let bal = withdraw_subwallet(router, wallet, amount);
        // option::fill, not assignment: Option<PendingWithdrawal> has no drop
        // (Balance<T> inside PendingWithdrawal has no drop), so `= some(...)`
        // would be a compile error.
        option::fill(&mut router.pending_withdrawal, PendingWithdrawal<T> {
            wallet,
            balance: bal,
            requested_epoch: tx_context::epoch(ctx),
        });
    }

    /// Admin claims the pending withdrawal after the timelock has passed.
    public fun claim_withdrawal<T>(router: &mut ElegbaraRouter<T>, ctx: &mut TxContext): Coin<T> {
        assert!(tx_context::sender(ctx) == router.admin, E_NOT_ADMIN);
        let pw = option::extract(&mut router.pending_withdrawal);
        assert!(tx_context::epoch(ctx) >= pw.requested_epoch + TIMELOCK_EPOCHS, E_TIMELOCK);
        // Destructure: Balance<T> has no copy/drop, so field moves must be
        // explicit — `pw.balance` would be an illegal implicit copy, and pw
        // itself must be fully consumed.
        let PendingWithdrawal { wallet: _, balance, requested_epoch: _ } = pw;
        coin::from_balance(balance, ctx)
    }

    // ===== Getters =====
    public fun total_esu_tax<T>(r: &ElegbaraRouter<T>): u64 { r.total_esu_tax_collected }
    public fun total_burned<T>(r: &ElegbaraRouter<T>): u64 { r.total_burned }
    public fun total_agents_born<T>(r: &ElegbaraRouter<T>): u64 { r.total_agents_born }
    public fun veilsim_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.veilsim) }
    public fun reserve_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.reserve) }
    public fun ubi_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.ubi) }
    public fun esu_tax_bps(): u64 { ESU_TAX_BPS }

    // ===== BirthRecord getters =====
    public fun birth_record_agent_addr(r: &BirthRecord): address { r.agent_addr }
    public fun birth_record_birther_addr(r: &BirthRecord): address { r.birther_addr }
    public fun birth_record_royalty_bps(r: &BirthRecord): u64 { r.royalty_bps }
    public fun birth_record_generation(r: &BirthRecord): u8 { r.generation }
}
