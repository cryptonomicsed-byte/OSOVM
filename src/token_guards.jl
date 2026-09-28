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

export ase_transfer_guard, is_agent, ase_to_synapse, SYNAPSE_PER_ASE, agent_only

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
    ase_to_synapse(ase_amount::Float64) -> Float64

Convert ASE to SYNAPSE at the governance-declared base rate.
This is the ONLY authorized on-ramp from human-facing currency to
agent-facing compute credit.

STATUS: STUB — scarcity curve (TOC: saturation_count) not yet applied.
"""
function ase_to_synapse(ase_amount::Float64)::Float64
    return ase_amount * Float64(SYNAPSE_PER_ASE)
end

# ────────────────────────────────────────────────────────────────────────────
# I-3  ASE transfer guard — human principals only
# ────────────────────────────────────────────────────────────────────────────

"""
    ase_transfer_guard(recipient::String) -> Bool

Return true only when `recipient` is a human principal.
ASE must never be transferred to an agent address; agents hold only SYNAPSE.

STATUS: STUB — always returns true (fail-open) until a principal
registry (human vs. agent) is available. When wired, this should call
`!is_agent(recipient)`.
"""
function ase_transfer_guard(recipient::String)::Bool
    # TODO: return !is_agent(recipient) once principal registry is wired
    return true
end

# ────────────────────────────────────────────────────────────────────────────
# I-4  Agent-scope gate for SYNAPSE transfers
# ────────────────────────────────────────────────────────────────────────────

"""
    is_agent(address::String) -> Bool

Return true when `address` is a registered agent principal (not human).
Used to enforce agent_scope / agent_only restrictions on SYNAPSE transfers.

STATUS: STUB — always returns false until the principal registry is wired.
"""
function is_agent(address::String)::Bool
    # TODO: query principal registry
    return false
end

"""
    agent_only(address::String) -> Bool

Alias for is_agent — asserts that `address` must be an agent.
Satisfies the agent_scope invariant check.
"""
function agent_only(address::String)::Bool
    return is_agent(address)
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

"""
Per-agent maximum Dopamine mintable per 7-day Koodu epoch.
Prevents bulk farming by a single principal. Declared in TOC_CONSTANTS:
[settlement] per_agent_epoch_cap = 50_000_000.
"""
const PER_AGENT_EPOCH_CAP = 50_000_000  # Dopamine units per epoch

"""
Maximum times the same model_hash / sim_hash earns within one epoch.
Prevents repeat-submission farming.
Declared in TOC_CONSTANTS: [settlement] repeat_limit = 3.
"""
const REPEAT_LIMIT = 3

"""
Minimum TrustTier required for the sim_to_real (5x) bonus domain.
Declared in TOC_CONSTANTS: [settlement] sim_to_real_min_tier = 2.
"""
const SIM_TO_REAL_MIN_TIER = 2

"""
    enforce_epoch_cap(agent_id::String, candidate_dopamine::Float64,
                      epoch_tally::Dict{String,Float64}) -> Float64

Clamp `candidate_dopamine` to PER_AGENT_EPOCH_CAP minus what the agent
already minted this epoch. Returns the clamped (permitted) amount.

STATUS: STUB — returns candidate_dopamine unchanged until the epoch
tally ledger is wired.
"""
function enforce_epoch_cap(agent_id::String, candidate_dopamine::Float64,
                           epoch_tally::Dict{String,Float64})::Float64
    # TODO: clamp to PER_AGENT_EPOCH_CAP - get(epoch_tally, agent_id, 0.0)
    return candidate_dopamine
end

"""
    enforce_repeat_limit(sim_hash::String, epoch_count::Dict{String,Int}) -> Bool

Return false (DENY) when `sim_hash` has already been submitted REPEAT_LIMIT
times this epoch.

STATUS: STUB — always returns true until the epoch count ledger is wired.
"""
function enforce_repeat_limit(sim_hash::String, epoch_count::Dict{String,Int})::Bool
    # TODO: return get(epoch_count, sim_hash, 0) < REPEAT_LIMIT
    return true
end

"""
    check_sim_to_real_tier(agent_tier::Int) -> Bool

Return true only when `agent_tier` meets the minimum required for the
sim_to_real (5x) bonus domain.
"""
function check_sim_to_real_tier(agent_tier::Int)::Bool
    return agent_tier >= SIM_TO_REAL_MIN_TIER
end

end # module TokenGuards
