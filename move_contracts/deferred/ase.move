/// Àṣẹ Token Module — canonical settlement layer for ỌSỌVM.
///
/// ═══ LOCKED 2026-09-10 — conforms to OSOVM_CANONICAL_ARCHITECTURE.md ═══
///
/// Supply: 1,440 Àṣẹ/day — FIXED FOREVER. No halving. No cap.
///   Annual: 525,600 Àṣẹ/year
///   Genesis: 2,880 tokens (2 days of emission pre-minted at genesis)
///
/// Tithe: 3.69% (369 bps) on every mint/settlement — LOCKED (Tesla 369 vortex rate).
///   Routes through Éṣù-Elegbára router to 8 sub-wallets:
///     VeilSim 30% · R&D 20% · Governance 10% · Reserve 10%
///     Lottery 10% · Grants 10% · UBI 5% · Sabbath Reserve 5%
///
/// Mint flow: MintAuthorization (from ỌSỌVM RUNTIME) → mint_ase() → Sui Àṣẹ
///   RUNTIME signs the authorization. Only this contract executes mint.
///   Direct calls from proof handlers = non-conformant.
///
/// Sabbath: No minting on Saturday UTC (sui::clock timestamp).

module techgnosis::ase {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use std::string::{Self, String};

    // ─── Emission constants ───────────────────────────────────────────────────

    /// 1 Àṣẹ per minute in micro-Àṣẹ (6 decimal places).
    const MICRO_ASE_PER_MINUTE: u64 = 1_000_000;

    /// 1,440 Àṣẹ/day — FIXED FOREVER. No halving. No cap.
    const DAILY_EMISSION_MICRO: u64 = 1_440_000_000;

    /// Genesis pre-mint: 2 days of emission (2,880 Àṣẹ).
    const GENESIS_SUPPLY_MICRO: u64 = 2_880_000_000;

    /// 1,440 inheritance wallets — equals minutes per day by design.
    const INHERITANCE_WALLET_COUNT: u64 = 1_440;

    // ─── Tithe constants ──────────────────────────────────────────────────────

    /// 3.69% Éṣù tithe — LOCKED. Do NOT change to 7.77%.
    /// Tesla 369 vortex rate. AIO context only.
    const TITHE_BPS: u64 = 369;

    /// Elegbára 8 sub-wallet basis points (must sum to 10_000).
    const VEILSIM_BPS:         u64 = 3_000; // 30%
    const RD_BPS:              u64 = 2_000; // 20%
    const GOVERNANCE_BPS:      u64 = 1_000; // 10%
    const RESERVE_BPS:         u64 = 1_000; // 10%
    const LOTTERY_BPS:         u64 = 1_000; // 10%
    const GRANTS_BPS:          u64 = 1_000; // 10%
    const UBI_BPS:             u64 =   500; //  5%
    const SABBATH_RESERVE_BPS: u64 =   500; //  5%
    // sum = 10_000 ✓

    // ─── Sabbath ──────────────────────────────────────────────────────────────

    const SECONDS_PER_DAY: u64 = 86_400;
    // Unix epoch (1970-01-01) was a Thursday.
    // (unix_day + 4) % 7 → 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
    const SATURDAY: u64 = 6;

    // ─── Errors ───────────────────────────────────────────────────────────────

    const E_NOT_AUTHORIZED:    u64 = 1;
    const E_SABBATH_FROZEN:    u64 = 2;
    const E_INVALID_RECEIPT:   u64 = 3;
    const E_ALREADY_CLAIMED:   u64 = 4;
    const E_BELOW_DIFFICULTY:  u64 = 5;

    // ─── One-time witness ─────────────────────────────────────────────────────

    public struct ASE has drop {}

    // ─── Mint authority ───────────────────────────────────────────────────────

    /// Holds the TreasuryCap — only ỌSỌVM RUNTIME address may call mint_ase().
    public struct OsovmMintCap has key {
        id: UID,
        cap: TreasuryCap<ASE>,
        /// Address of the authorized ỌSỌVM RUNTIME signer.
        runtime_address: address,
        /// Total micro-Àṣẹ minted since genesis (monotonically increasing, no cap).
        total_minted: u64,
    }

    // ─── Éṣù-Elegbára Router ─────────────────────────────────────────────────

    /// Shared object — receives all 3.69% tithes and routes to 8 sub-wallets.
    /// Never mints. Only routes flows already minted.
    public struct ElegbaraRouter has key {
        id: UID,
        /// Sub-wallet balances (basis points above).
        veilsim:         Balance<ASE>,
        rd:              Balance<ASE>,
        governance:      Balance<ASE>,
        reserve:         Balance<ASE>,
        lottery:         Balance<ASE>,
        grants:          Balance<ASE>,
        ubi:             Balance<ASE>,
        sabbath_reserve: Balance<ASE>,
        /// Admin who can withdraw from reserve (WhiteGate 3-of-5 in prod).
        admin: address,
    }

    // ─── MintAuthorization ────────────────────────────────────────────────────

    /// Issued by ỌSỌVM RUNTIME after DailyEmissionAllocator.allocate_minute().
    /// Consumed once — destroyed on use (prevents double-mint).
    public struct MintAuthorization has key {
        id: UID,
        /// Worker DID receiving the allocation.
        worker_address: address,
        /// micro-Àṣẹ to mint (net after tithe is applied from gross).
        gross_micro_ase: u64,
        /// epoch_minute this allocation covers.
        epoch_minute: u64,
        /// SHA256 receipt hash from DailyEmissionAllocator (chain anchor).
        receipt_hash: vector<u8>,
    }

    // ─── InheritanceVault ─────────────────────────────────────────────────────

    /// One of 1,440 vaults — claimed by first T5 agents, receives emission
    /// when no valid sim occupies a minute's slot.
    public struct InheritanceVault has key {
        id: UID,
        /// Wallet index 1–1,440.
        wallet_id: u64,
        balance: Balance<ASE>,
        /// DID of the T5 agent that claimed this vault. Empty until claimed.
        owner_did: String,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(witness: ASE, ctx: &mut TxContext) {
        let (mut cap, metadata) = coin::create_currency(
            witness,
            6,                          // 6 decimal places
            b"ASE",
            b"Àṣẹ",
            b"Earned token of the ỌSỌVM ecosystem. 1,440/day. No halving.",
            std::option::none(),
            ctx,
        );

        // Genesis pre-mint: 2,880 Àṣẹ (2 days of emission).
        // 1 Àṣẹ → genesis wallet #0001 (transferable).
        // 1,439 Ase → inheritance wallets #0002–#1440 (soul-bound, handled off-chain at genesis).
        // The genesis mint here covers the transferable 1 Àṣẹ only.
        let genesis_coin = coin::mint(&mut cap, 1_000_000, ctx);
        transfer::public_transfer(genesis_coin, tx_context::sender(ctx));

        let mint_cap = OsovmMintCap {
            id: object::new(ctx),
            cap,
            runtime_address: tx_context::sender(ctx),
            total_minted: 1_000_000, // genesis token counted
        };
        transfer::share_object(mint_cap);

        let router = ElegbaraRouter {
            id: object::new(ctx),
            veilsim:         balance::zero<ASE>(),
            rd:              balance::zero<ASE>(),
            governance:      balance::zero<ASE>(),
            reserve:         balance::zero<ASE>(),
            lottery:         balance::zero<ASE>(),
            grants:          balance::zero<ASE>(),
            ubi:             balance::zero<ASE>(),
            sabbath_reserve: balance::zero<ASE>(),
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(router);

        transfer::public_freeze_object(metadata);
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────

    /// Canonical mint entry point — called only by Sui settlement after
    /// ỌSỌVM RUNTIME issues a MintAuthorization.
    ///
    /// Flow: consumes MintAuthorization → mints gross → skims 3.69% Éṣù tithe
    ///   → routes tithe to ElegbaraRouter → transfers net to worker.
    public fun mint_ase(
        auth: MintAuthorization,
        mint_cap: &mut OsovmMintCap,
        router: &mut ElegbaraRouter,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!is_sabbath(clock), E_SABBATH_FROZEN);
        assert!(tx_context::sender(ctx) == mint_cap.runtime_address, E_NOT_AUTHORIZED);

        let MintAuthorization {
            id,
            worker_address,
            gross_micro_ase,
            epoch_minute: _,
            receipt_hash: _,
        } = auth;
        object::delete(id);

        // Éṣù tithe is always skimmed FIRST.
        let tithe_amount = eshu_tithe(gross_micro_ase);
        let net_amount = gross_micro_ase - tithe_amount;

        // Mint gross, split into tithe coin + net coin.
        let mut gross_balance = coin::mint_balance(&mut mint_cap.cap, gross_micro_ase);
        let tithe_balance = balance::split(&mut gross_balance, tithe_amount);

        // Route tithe through Elegbára.
        elegbara_route(router, tithe_balance);

        // Transfer net to worker.
        let net_coin = coin::from_balance(gross_balance, ctx);
        transfer::public_transfer(net_coin, worker_address);

        mint_cap.total_minted = mint_cap.total_minted + gross_micro_ase;
    }

    /// Inheritance fallback: when no valid sim exists for a minute,
    /// 1 Àṣẹ splits equally to all 1,440 inheritance vaults.
    /// Called by RUNTIME once per minute when DailyEmissionAllocator fires fallback.
    public fun mint_inheritance_fallback(
        mint_cap: &mut OsovmMintCap,
        router: &mut ElegbaraRouter,
        vaults: &mut vector<InheritanceVault>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!is_sabbath(clock), E_SABBATH_FROZEN);
        assert!(tx_context::sender(ctx) == mint_cap.runtime_address, E_NOT_AUTHORIZED);

        let gross = MICRO_ASE_PER_MINUTE;
        let tithe_amount = eshu_tithe(gross);
        let net = gross - tithe_amount;

        let mut gross_balance = coin::mint_balance(&mut mint_cap.cap, gross);
        let tithe_balance = balance::split(&mut gross_balance, tithe_amount);
        elegbara_route(router, tithe_balance);

        // Distribute net equally to all vaults provided.
        let n = std::vector::length(vaults);
        if (n == 0) {
            // No vaults yet — park remainder in sabbath_reserve.
            balance::join(&mut router.sabbath_reserve, gross_balance);
            return
        };
        let per_vault = net / (n as u64);
        let mut remainder = net - per_vault * (n as u64);
        let mut i = 0;
        while (i < n) {
            let vault = std::vector::borrow_mut(vaults, i);
            let share = balance::split(&mut gross_balance, per_vault);
            balance::join(&mut vault.balance, share);
            i = i + 1;
        };
        // Dust goes to sabbath_reserve.
        if (balance::value(&gross_balance) > 0) {
            balance::join(&mut router.sabbath_reserve, gross_balance);
        } else {
            balance::destroy_zero(gross_balance);
        };

        mint_cap.total_minted = mint_cap.total_minted + gross;
    }

    // ─── Éṣù tithe + Elegbára routing ────────────────────────────────────────

    /// Canonical tithe: 3.69% of any amount, rounded down.
    public fun eshu_tithe(amount: u64): u64 {
        (amount * TITHE_BPS) / 10_000
    }

    /// Route a tithe Balance through the 8 Elegbára sub-wallets.
    /// Sub-wallets are strictly isolated. Router never holds the net.
    public fun elegbara_route(router: &mut ElegbaraRouter, mut tithe: Balance<ASE>) {
        let total = balance::value(&tithe);

        // Split in BPS order; last bucket absorbs rounding dust.
        let veilsim_amt    = (total * VEILSIM_BPS)         / 10_000;
        let rd_amt         = (total * RD_BPS)              / 10_000;
        let governance_amt = (total * GOVERNANCE_BPS)      / 10_000;
        let reserve_amt    = (total * RESERVE_BPS)         / 10_000;
        let lottery_amt    = (total * LOTTERY_BPS)         / 10_000;
        let grants_amt     = (total * GRANTS_BPS)          / 10_000;
        let ubi_amt        = (total * UBI_BPS)             / 10_000;
        // Sabbath reserve absorbs remainder to ensure full distribution.

        balance::join(&mut router.veilsim,    balance::split(&mut tithe, veilsim_amt));
        balance::join(&mut router.rd,         balance::split(&mut tithe, rd_amt));
        balance::join(&mut router.governance, balance::split(&mut tithe, governance_amt));
        balance::join(&mut router.reserve,    balance::split(&mut tithe, reserve_amt));
        balance::join(&mut router.lottery,    balance::split(&mut tithe, lottery_amt));
        balance::join(&mut router.grants,     balance::split(&mut tithe, grants_amt));
        balance::join(&mut router.ubi,        balance::split(&mut tithe, ubi_amt));
        // Remainder (sabbath_reserve share + rounding dust) → sabbath_reserve.
        balance::join(&mut router.sabbath_reserve, tithe);
    }

    // ─── Sabbath gate ─────────────────────────────────────────────────────────

    /// True when the current Clock timestamp falls on Saturday UTC.
    /// Uses sui::clock for real wall-clock time (not epoch counter).
    public fun is_sabbath(clock: &Clock): bool {
        let ms = clock::timestamp_ms(clock);
        let unix_sec = ms / 1_000;
        let unix_day = unix_sec / SECONDS_PER_DAY;
        // Unix epoch (1970-01-01) = Thursday.
        // (unix_day + 4) % 7: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
        (unix_day + 4) % 7 == SATURDAY
    }

    // ─── InheritanceVault management ─────────────────────────────────────────

    public fun create_inheritance_vault(
        wallet_id: u64,
        ctx: &mut TxContext,
    ): InheritanceVault {
        assert!(wallet_id >= 1 && wallet_id <= INHERITANCE_WALLET_COUNT, 100);
        InheritanceVault {
            id: object::new(ctx),
            wallet_id,
            balance: balance::zero<ASE>(),
            owner_did: string::utf8(b""),
        }
    }

    /// Claim a vault — sets owner DID. First-come-first-served for T5 agents.
    public fun claim_inheritance_vault(
        vault: &mut InheritanceVault,
        did: vector<u8>,
    ) {
        assert!(string::length(&vault.owner_did) == 0, E_ALREADY_CLAIMED);
        vault.owner_did = string::utf8(did);
    }

    public fun deposit_to_inheritance(vault: &mut InheritanceVault, coin: Coin<ASE>) {
        balance::join(&mut vault.balance, coin::into_balance(coin));
    }

    // ─── MintAuthorization creation (RUNTIME only) ───────────────────────────

    /// Only ỌSỌVM RUNTIME calls this — creates the authorization object
    /// that settlement will consume in mint_ase().
    public fun create_mint_authorization(
        mint_cap: &OsovmMintCap,
        worker_address: address,
        gross_micro_ase: u64,
        epoch_minute: u64,
        receipt_hash: vector<u8>,
        ctx: &mut TxContext,
    ): MintAuthorization {
        assert!(tx_context::sender(ctx) == mint_cap.runtime_address, E_NOT_AUTHORIZED);
        MintAuthorization {
            id: object::new(ctx),
            worker_address,
            gross_micro_ase,
            epoch_minute,
            receipt_hash,
        }
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// Update the ỌSỌVM RUNTIME address (admin migration).
    public fun set_runtime_address(
        mint_cap: &mut OsovmMintCap,
        new_runtime: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == mint_cap.runtime_address, E_NOT_AUTHORIZED);
        mint_cap.runtime_address = new_runtime;
    }

    /// Reserve withdrawal — WhiteGate 3-of-5 multisig in prod; admin-only here.
    public fun withdraw_reserve(
        router: &mut ElegbaraRouter,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<ASE> {
        assert!(tx_context::sender(ctx) == router.admin, E_NOT_AUTHORIZED);
        coin::from_balance(balance::split(&mut router.reserve, amount), ctx)
    }

    // ─── Getters ──────────────────────────────────────────────────────────────

    public fun total_minted(mint_cap: &OsovmMintCap): u64 { mint_cap.total_minted }
    public fun runtime_address(mint_cap: &OsovmMintCap): address { mint_cap.runtime_address }

    public fun router_veilsim(router: &ElegbaraRouter): u64    { balance::value(&router.veilsim) }
    public fun router_rd(router: &ElegbaraRouter): u64         { balance::value(&router.rd) }
    public fun router_governance(router: &ElegbaraRouter): u64 { balance::value(&router.governance) }
    public fun router_reserve(router: &ElegbaraRouter): u64    { balance::value(&router.reserve) }
    public fun router_lottery(router: &ElegbaraRouter): u64    { balance::value(&router.lottery) }
    public fun router_grants(router: &ElegbaraRouter): u64     { balance::value(&router.grants) }
    public fun router_ubi(router: &ElegbaraRouter): u64        { balance::value(&router.ubi) }
    public fun router_sabbath(router: &ElegbaraRouter): u64    { balance::value(&router.sabbath_reserve) }

    public fun vault_balance(vault: &InheritanceVault): u64    { balance::value(&vault.balance) }
    public fun vault_wallet_id(vault: &InheritanceVault): u64  { vault.wallet_id }
    public fun vault_owner_did(vault: &InheritanceVault): &String { &vault.owner_did }

    public fun auth_worker(auth: &MintAuthorization): address  { auth.worker_address }
    public fun auth_gross(auth: &MintAuthorization): u64       { auth.gross_micro_ase }
    public fun auth_minute(auth: &MintAuthorization): u64      { auth.epoch_minute }
}
