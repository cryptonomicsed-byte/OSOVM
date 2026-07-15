/// Ṣàngó Field Anchor — Waggle signals become on-chain, non-repudiable facts.
///
/// Connection Map v2 §7:
/// - Finalization anchors gold findings; a relay watches `FieldAnchored`
///   events and re-deposits them on the Waggle field at the top evidence
///   tier (`on-chain-anchored`) — the chain is the instrument, the relay is
///   the watch.
/// - Bounded (Mandelbrot robustness) verdicts that cross the significance
///   threshold — a very deep bounded island or a very fast escape — are
///   anchorable too, making robustness claims auditable and defensible to
///   external parties. Middling verdicts stay off-chain: anchoring noise
///   would cheapen the tier.
/// - Reputation decays with THE SAME kernel math as the field's signals
///   (halves at exactly one half-life; exponential or heavy-tailed
///   power-law), so trust and scent run on one decay physics with one set
///   of tunables instead of two systems that drift apart.
///
/// Intensities and stability scores are milli-fixed-point (0..=10_000 for
/// intensity 0..10; 0..=1_000 for stability 0..1) — Move has no floats, and
/// the field's decimal values must round-trip exactly through the relay.
module techgnosis::sango_field_anchor {
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::string::String;

    // ===== Constants =====

    /// Significance thresholds for bounded anchoring (stability in milli).
    const DEEP_ISLAND_MIN_MILLI: u64 = 900; // s >= 0.9: anchor-worthy robustness
    const FAST_ESCAPE_MAX_MILLI: u64 = 100; // s <= 0.1: anchor-worthy fragility

    /// Decay kernels — the same two the Waggle field runs.
    const KERNEL_EXP: u8 = 0;
    const KERNEL_POWER: u8 = 1; // alpha = 1: intensity * H / (H + age)

    // ===== Errors =====
    const E_NOT_SIGNIFICANT: u64 = 1;
    const E_BAD_KERNEL: u64 = 2;
    const E_STABILITY_RANGE: u64 = 3;

    // ===== Events (the relay's watch feed) =====

    public struct FieldAnchored has copy, drop {
        resource: String,
        kind: String,
        intensity_milli: u64,
        receipt_id: String,
        anchored_by: address,
        timestamp_ms: u64,
    }

    public struct BoundedAnchored has copy, drop {
        resource: String,
        stability_milli: u64,
        escape: u64,
        maxiter: u64,
        receipt_id: String,
        anchored_by: address,
        timestamp_ms: u64,
    }

    // ===== Anchor objects =====

    /// A gold finding, finalized. Owning this object is owning the claim.
    public struct GoldAnchor has key, store {
        id: UID,
        resource: String,
        intensity_milli: u64,
        receipt_id: String,
        anchored_at_ms: u64,
    }

    /// A robustness verdict significant enough to be worth defending.
    public struct BoundedAnchor has key, store {
        id: UID,
        resource: String,
        stability_milli: u64,
        escape: u64,
        maxiter: u64,
        receipt_id: String,
        anchored_at_ms: u64,
    }

    /// Reputation that decays like a signal: same kernels, same half-life
    /// semantics. `score_milli` is the value at `updated_at_ms`; the live
    /// score is always computed lazily — nothing rewrites it on a timer,
    /// exactly like the field.
    public struct Reputation has key, store {
        id: UID,
        subject: address,
        score_milli: u64,
        half_life_ms: u64,
        kernel: u8,
        updated_at_ms: u64,
    }

    // ===== Anchoring =====

    public fun anchor_gold(
        resource: String,
        intensity_milli: u64,
        receipt_id: String,
        ctx: &mut TxContext,
    ): GoldAnchor {
        let now = tx_context::epoch_timestamp_ms(ctx);
        event::emit(FieldAnchored {
            resource,
            kind: std::string::utf8(b"gold"),
            intensity_milli,
            receipt_id,
            anchored_by: tx_context::sender(ctx),
            timestamp_ms: now,
        });
        GoldAnchor {
            id: object::new(ctx),
            resource,
            intensity_milli,
            receipt_id,
            anchored_at_ms: now,
        }
    }

    /// Anchors only significant verdicts: deep islands or fast escapes.
    /// The fragile middle is real information for the field, but not worth
    /// the permanence (and cost) of the chain.
    public fun anchor_bounded(
        resource: String,
        stability_milli: u64,
        escape: u64,
        maxiter: u64,
        receipt_id: String,
        ctx: &mut TxContext,
    ): BoundedAnchor {
        assert!(stability_milli <= 1000, E_STABILITY_RANGE);
        assert!(
            stability_milli >= DEEP_ISLAND_MIN_MILLI || stability_milli <= FAST_ESCAPE_MAX_MILLI,
            E_NOT_SIGNIFICANT
        );
        let now = tx_context::epoch_timestamp_ms(ctx);
        event::emit(BoundedAnchored {
            resource,
            stability_milli,
            escape,
            maxiter,
            receipt_id,
            anchored_by: tx_context::sender(ctx),
            timestamp_ms: now,
        });
        BoundedAnchor {
            id: object::new(ctx),
            resource,
            stability_milli,
            escape,
            maxiter,
            receipt_id,
            anchored_at_ms: now,
        }
    }

    public fun share_gold(anchor: GoldAnchor) {
        transfer::public_share_object(anchor)
    }

    public fun share_bounded(anchor: BoundedAnchor) {
        transfer::public_share_object(anchor)
    }

    // ===== Reputation on signal-decay physics (§7.4) =====

    public fun new_reputation(
        subject: address,
        score_milli: u64,
        half_life_ms: u64,
        kernel: u8,
        ctx: &mut TxContext,
    ): Reputation {
        assert!(kernel == KERNEL_EXP || kernel == KERNEL_POWER, E_BAD_KERNEL);
        Reputation {
            id: object::new(ctx),
            subject,
            score_milli,
            half_life_ms,
            kernel,
            updated_at_ms: tx_context::epoch_timestamp_ms(ctx),
        }
    }

    /// The live score at `now_ms`, decayed with the field's kernels in
    /// integer arithmetic. Both kernels halve at exactly one half-life —
    /// the same contract the Go substrate keeps, so `half_life_ms` means
    /// the same thing on-chain as in the scent field.
    ///
    /// exp:   score >> (age / H), then linear within the fractional
    ///        half-life (factor 1 - rem/(2H); exact at rem = 0 and rem = H).
    /// power: alpha = 1 heavy tail — score * H / (H + age); exact halving
    ///        at age = H, ~9% left after 10 half-lives vs exp's ~0.1%.
    public fun current_score(rep: &Reputation, now_ms: u64): u64 {
        decayed(rep.score_milli, rep.kernel, rep.half_life_ms, now_ms - rep.updated_at_ms)
    }

    fun decayed(score: u64, kernel: u8, half_life_ms: u64, age_ms: u64): u64 {
        if (age_ms == 0 || score == 0) return score;
        if (kernel == KERNEL_POWER) {
            // alpha = 1: scale = H, intensity * scale / (scale + age)
            return ((score as u128) * (half_life_ms as u128)
                / ((half_life_ms as u128) + (age_ms as u128)) as u64)
        };
        let halvings = age_ms / half_life_ms;
        if (halvings >= 64) return 0;
        let base = score >> (halvings as u8);
        let rem = age_ms % half_life_ms;
        base - ((base as u128) * (rem as u128) / (2 * (half_life_ms as u128)) as u64)
    }

    /// Corroboration history feeds trust (§7.2): a confirmation event adds
    /// to the decayed score, capped at 1000 milli — reinforcement semantics,
    /// again exactly the field's.
    public fun reinforce(rep: &mut Reputation, delta_milli: u64, ctx: &TxContext) {
        let now = tx_context::epoch_timestamp_ms(ctx);
        let live = current_score(rep, now);
        let bumped = live + delta_milli;
        rep.score_milli = if (bumped > 1000) { 1000 } else { bumped };
        rep.updated_at_ms = now;
    }

    // ===== Tests =====

    #[test_only]
    use sui::tx_context;

    #[test]
    fun exp_halves_at_one_half_life() {
        assert!(decayed(1000, KERNEL_EXP, 3600_000, 3600_000) == 500, 0);
        assert!(decayed(1000, KERNEL_EXP, 3600_000, 7200_000) == 250, 1);
        assert!(decayed(1000, KERNEL_EXP, 3600_000, 0) == 1000, 2);
    }

    #[test]
    fun power_halves_at_one_half_life_with_heavy_tail() {
        assert!(decayed(1000, KERNEL_POWER, 3600_000, 3600_000) == 500, 0);
        // 10 half-lives: power keeps 1/11 ≈ 90 milli; exp is at ~0
        assert!(decayed(1000, KERNEL_POWER, 3600_000, 36_000_000) == 90, 1);
        assert!(decayed(1000, KERNEL_EXP, 3600_000, 36_000_000) < 2, 2);
    }

    #[test]
    fun bounded_anchor_rejects_the_middle() {
        let mut ctx = tx_context::dummy();
        let anchor = anchor_bounded(
            std::string::utf8(b"loom://strategy/sniper"),
            950, 400, 400,
            std::string::utf8(b"r-1"),
            &mut ctx,
        );
        share_bounded(anchor);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_SIGNIFICANT)]
    fun middling_verdicts_are_not_anchorable() {
        let mut ctx = tx_context::dummy();
        let anchor = anchor_bounded(
            std::string::utf8(b"loom://strategy/warrior"),
            500, 200, 400,
            std::string::utf8(b"r-2"),
            &mut ctx,
        );
        share_bounded(anchor);
    }
}
