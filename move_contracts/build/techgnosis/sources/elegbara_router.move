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

    // ===== Errors =====
    const E_ZERO_AMOUNT: u64 = 105;
    const E_NOT_ADMIN: u64 = 101;

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
        total_esu_tax_collected: u64,
        total_burned: u64,
        total_agents_born: u64,
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
            total_esu_tax_collected: 0,
            total_burned: 0,
            total_agents_born: 0,
        };
        transfer::share_object(router);
    }

    // ===== Core: Èṣù tithe extraction (pure) =====
    public fun extract_esu_tax(amount: u64): (u64, u64) {
        let tax = (amount * ESU_TAX_BPS) / BPS_DENOM;
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

    // ===== Agent birth (fee paid in T) =====
    public fun process_agent_birth<T>(
        router: &mut ElegbaraRouter<T>,
        payment: Coin<T>,
        agent_id: address,
    ) {
        let paid = coin::value(&payment);
        assert!(paid > 0, E_ZERO_AMOUNT);
        let mut bal = coin::into_balance(payment);

        let burn_amt = (paid * BIRTH_BURN_BPS) / BPS_DENOM;
        let elegbara_amt = (paid * BIRTH_ELEGBARA_BPS) / BPS_DENOM;
        let inheritance_amt = (paid * BIRTH_INHERITANCE_BPS) / BPS_DENOM;

        balance::join(&mut router.lottery_burn, balance::split(&mut bal, burn_amt)); // burn sink
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
    }

    // ===== Admin withdraw from a sub-wallet (governance uses this to disburse) =====
    public fun withdraw_reserve<T>(
        router: &mut ElegbaraRouter<T>, amount: u64, ctx: &mut TxContext,
    ): Coin<T> {
        assert!(tx_context::sender(ctx) == router.admin, E_NOT_ADMIN);
        coin::from_balance(balance::split(&mut router.reserve, amount), ctx)
    }

    // ===== Getters =====
    public fun total_esu_tax<T>(r: &ElegbaraRouter<T>): u64 { r.total_esu_tax_collected }
    public fun total_burned<T>(r: &ElegbaraRouter<T>): u64 { r.total_burned }
    public fun total_agents_born<T>(r: &ElegbaraRouter<T>): u64 { r.total_agents_born }
    public fun veilsim_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.veilsim) }
    public fun reserve_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.reserve) }
    public fun ubi_balance<T>(r: &ElegbaraRouter<T>): u64 { balance::value(&r.ubi) }
    public fun esu_tax_bps(): u64 { ESU_TAX_BPS }
}
