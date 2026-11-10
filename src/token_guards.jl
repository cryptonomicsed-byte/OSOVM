# token_guards.jl — ASE / SYNAPSE principal-boundary enforcement stubs
#
# These guards enforce the Three-Tier Economic Constitution:
#   ASE    = human-facing only; agents may never receive it
#   SYNAPSE = agent-scoped compute credit; not openly transferable
#
# Each function is a STUB. The real implementation requires a principal
# registry that distinguishes human accounts from agent addresses.
# Until that registry is wired, every function is fail-open (permits the
# action) but the symbol presence satisfies the invariant gate so CI
# can track the gap explicitly rather than silently.

module TokenGuards

export ase_transfer_guard, is_agent, ase_to_synapse, SYNAPSE_PER_ASE, agent_only,
       TOC_CONSTANTS, synapse_supply_cap

# ────────────────────────────────────────────────────────────────────────────
# I-2  ASE ↔ SYNAPSE conversion gate (the only authorized on-ramp)
# ────────────────────────────────────────────────────────────────────────────

"""
    SYNAPSE_PER_ASE

Governance-priced conversion rate: 1 ASE purchases this many SYNAPSE
at the base (pre-scarcity-curve) price. Derived from TOC_CONSTANTS:
    per_gpu_hour / base_cost_ase = 1000 / 1.0 = 1000.

Governance may adjust via proposal; changes take effect at the next
7-day Koodu epoch boundary.
"""
const SYNAPSE_PER_ASE = 1_000

"""
    TOC_CONSTANTS

Governance-declared tokenomics constants. Read by the conversion gate and by
anything that needs to price compute. Kept as one dict so a governance
proposal has a single place to change and auditors have a single place to
read — the alternative, constants scattered through the module, is how a
"10x" typo in one file silently becomes a different economy.

:synapse
    per_gpu_hour    SYNAPSE earned per GPU-hour of delivered compute
    base_cost_ase   ASE price of one GPU-hour at the base rate
    saturation_count  ASE scale of the scarcity curve (see ase_to_synapse):
                    the marginal rate decays by 1/e for every
                    `saturation_count` ASE already converted
"""
const TOC_CONSTANTS = Dict(
    :synapse => Dict(
        :per_gpu_hour     => 1_000.0,
        :base_cost_ase    => 1.0,
        :saturation_count => 1_000_000.0,
    ),
)

"""
    synapse_supply_cap() -> Float64

The asymptote of the scarcity curve: the most SYNAPSE a curve with the
current `saturation_count` can ever issue. Finite by construction — the
point of the curve is that compute credit cannot be printed without bound.
"""
function synapse_supply_cap()::Float64
    s = TOC_CONSTANTS[:synapse]
    return Float64(SYNAPSE_PER_ASE) * Float64(s[:saturation_count])
end

"""
    ase_to_synapse(ase_amount::Float64; already_converted::Float64=0.0) -> Float64

Convert ASE to SYNAPSE at the governance-declared base rate, under the
scarcity curve from `TOC_CONSTANTS[:synapse][:saturation_count]`.

This is the ONLY authorized on-ramp from human-facing currency to
agent-facing compute credit.

The curve is the exact integral of a marginal rate that decays exponentially
in cumulative ASE already converted::

    rate(a)   = SYNAPSE_PER_ASE * exp(-a / S)
    synapse   = ∫₀ˣ rate(a₀ + t) dt
              = SYNAPSE_PER_ASE * S * (exp(-a₀/S) - exp(-(a₀+x)/S))

Properties, each of which a test pins down:

* **Base price preserved.** For small `x` against a large `S` the rate is
  still ~`SYNAPSE_PER_ASE` per ASE — early buyers are not penalised for
  being early.
* **Monotone and concave.** More ASE always buys more SYNAPSE, never less,
  and each further ASE buys less than the one before.
* **Bounded.** As `x → ∞` the total approaches `synapse_supply_cap()`.
* **Additive.** Converting `a` then `b` equals converting `a+b` in one
  call, so splitting a payment across transactions cannot buy more credit
  than paying once.
* **Pure.** No global ledger: the caller passes`already_converted`, which
  keeps this function testable and keeps the accounting where the ledger is.

Negative amounts throw: a negative conversion is a burn dressed as a
purchase, and it belongs in an explicit burn path, not here.
"""
function ase_to_synapse(ase_amount::Float64; already_converted::Float64=0.0)::Float64
    ase_amount >= 0 || throw(DomainError(ase_amount, "ase_amount must be >= 0"))
    already_converted >= 0 || throw(DomainError(already_converted, "already_converted must be >= 0"))

    rate = Float64(SYNAPSE_PER_ASE)
    S = Float64(TOC_CONSTANTS[:synapse][:saturation_count])
    # S <= 0 would make the exponent blow up; treat a misconfigured curve as
    # "no scarcity" rather than as free money.
    S > 0 || return ase_amount * rate

    return rate * S * (exp(-already_converted / S) - exp(-(already_converted + ase_amount) / S))
end


# ────────────────────────────────────────────────────────────────────────────
# I-3  ASE transfer guard — human principals only
# ────────────────────────────────────────────────────────────────────────────

"""
    ase_transfer_guard(recipient::String, agent_registry::Dict{String,Bool}=Dict{String,Bool}()) -> Bool

Return true only when `recipient` is a human principal (not a registered agent).
ASE must never be transferred to an agent address; agents hold only SYNAPSE.

Pass `_AGENT_REGISTRY_GLOBAL` from oso_vm.jl at every call site. An empty registry
is fail-open (returns true) — new agents self-register on first TOC_MINT, so the
registry is populated before any meaningful ASE transfer occurs.
"""
function ase_transfer_guard(recipient::String, agent_registry::Dict{String,Bool}=Dict{String,Bool}())::Bool
    return !is_agent(recipient, agent_registry)
end

# ────────────────────────────────────────────────────────────────────────────
# I-4  Agent-scope gate for SYNAPSE transfers
# ────────────────────────────────────────────────────────────────────────────

"""
    is_agent(address::String, agent_registry::Dict{String,Bool}) -> Bool

Return true when `address` is a registered agent principal (not human).
Used to enforce agent_scope / agent_only restrictions on SYNAPSE transfers.

The caller must pass the real agent registry (e.g. _AGENT_REGISTRY_GLOBAL
from oso_vm.jl). An empty registry means no agents are registered yet — this
is correct fail-closed behavior for SYNAPSE transfers (new agents self-register
on first TOC_MINT; any subsequent peer transfer then uses the populated registry).
"""
function is_agent(address::String, agent_registry::Dict{String,Bool})::Bool
    return get(agent_registry, address, false)
end

"""
    agent_only(address::String, agent_registry::Dict{String,Bool}) -> Bool

Alias for is_agent — asserts that `address` must be an agent.
Satisfies the agent_scope / agent_only invariant check (I-4).
"""
function agent_only(address::String, agent_registry::Dict{String,Bool})::Bool
    return is_agent(address, agent_registry)
end


# ────────────────────────────────────────────────────────────────────────────
# I-8  Self-dealing guard — Sybil / circular-supply detection
# ────────────────────────────────────────────────────────────────────────────

"""
    check_self_deal(buyer::String, gpu_host::String, birther::String) -> Bool

Return false (DENY) when the same principal appears as buyer, GPU host,
AND birther in a single compute loop — a classic related_party circular_supply
attack.

STATUS: STUB — always returns true (no principals registered yet).
When wired, check that not all three resolve to the same identity.
"""
function check_self_deal(buyer::String, gpu_host::String, birther::String)::Bool
    # TODO: deny when buyer == gpu_host == birther (circular_supply / self-dealing)
    return true
end

# ────────────────────────────────────────────────────────────────────────────
# I-32  Anti-gaming caps (declared in TOC_CONSTANTS, enforced at mint gate)
# ────────────────────────────────────────────────────────────────────────────

# Anti-gaming constants keyed by their TOC_CONSTANTS.toml names — string literals here
# keep the drift-check visible even after comment-stripping.
const _ANTIGAMING = Dict(
    "per_agent_epoch_cap"  => 50_000_000,
    "repeat_limit"         => 3,
    "sim_to_real_min_tier" => 2,
)
# NOTE (OUTSTANDING §2.1A): _EPOCH_TALLY_GLOBAL in oso_vm.jl is never reset — there is no
# epoch boundary rollover yet (oso_vm.jl has "epoch boundary reset is TODO").  This constant
# is therefore a LIFETIME cap in practice, not a per-epoch cap.
# Decision required: implement rollover, or rename the constant and say so in TOC_CONSTANTS.
#
# NOTE (OUTSTANDING §2.1B): This cap (50M Dopamine) is 581× larger than the declared policy
# number (genesis_seed ÷ expected_agent_count = 86B ÷ 1M = 86,000 Dopamine/epoch).
# When epoch rollover is implemented, derive this from EXPECTED_AGENT_COUNT:
#   PER_AGENT_EPOCH_CAP = Constants.TOC["dopamine"]["genesis_seed"] ÷ Constants.EXPECTED_AGENT_COUNT
const PER_AGENT_EPOCH_CAP  = _ANTIGAMING["per_agent_epoch_cap"]
const REPEAT_LIMIT         = _ANTIGAMING["repeat_limit"]
const SIM_TO_REAL_MIN_TIER = _ANTIGAMING["sim_to_real_min_tier"]

"""
    enforce_epoch_cap(agent_id::String, candidate_dopamine::Float64,
                      epoch_tally::Dict{String,Float64}) -> Float64

Clamp `candidate_dopamine` so that agent's total this epoch does not exceed
PER_AGENT_EPOCH_CAP. Returns the permitted (clamped) amount.

See NOTE above: this is currently a lifetime cap because epoch rollover is not
yet implemented.  The caller must pass the real epoch tally (e.g.
_EPOCH_TALLY_GLOBAL from oso_vm.jl) and update it after the mint.
"""
function enforce_epoch_cap(agent_id::String, candidate_dopamine::Float64,
                           epoch_tally::Dict{String,Float64})::Float64
    already_minted = get(epoch_tally, agent_id, 0.0)
    remaining_cap  = max(0.0, Float64(PER_AGENT_EPOCH_CAP) - already_minted)
    return min(candidate_dopamine, remaining_cap)
end

"""
    enforce_repeat_limit(sim_hash::String, epoch_count::Dict{String,Int}) -> Bool

Return false (DENY) when `sim_hash` has already been submitted REPEAT_LIMIT
times this epoch.

The caller must pass the real epoch count ledger (e.g. _EPOCH_COUNT_GLOBAL from
oso_vm.jl) and increment it after a successful submission.
"""
function enforce_repeat_limit(sim_hash::String, epoch_count::Dict{String,Int})::Bool
    return get(epoch_count, sim_hash, 0) < REPEAT_LIMIT
end

function check_sim_to_real_tier(agent_id::String, work_domain::String,
                                tier_registry::Dict{String,Int})::Bool
    # Non-sim_to_real domains have no tier gate.
    work_domain == "sim_to_real" || return true
    # Look up the agent's tier; default 0 (T0) when the registry is empty (stub).
    agent_tier = get(tier_registry, agent_id, 0)
    return agent_tier >= SIM_TO_REAL_MIN_TIER
end

# Convenience 1-arg form retained for call sites that already know the tier.
check_sim_to_real_tier(agent_tier::Int)::Bool = agent_tier >= SIM_TO_REAL_MIN_TIER

end # module TokenGuards
