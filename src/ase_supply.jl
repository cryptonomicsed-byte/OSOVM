# ase_supply.jl — Àṣẹ Supply Rules & Sabbath Enforcement
# VM-level supply cap: 1440 Àṣẹ/day, Sabbath freeze, agent conversion bridge
# Bínò ÈL Guà — Crown Architect

module AseSupply

export SupplyState, check_daily_cap, enforce_sabbath, agent_convert_ase,
       process_job_payment, process_agent_birth, get_supply_stats,
       compute_dynamic_decay, update_epoch_decay,
       DAILY_MINT_CAP, TITHE_RATE, AGENT_BIRTH_FEE,
       DOPAMINE_GENESIS_SEED, MAX_AGENT_POOL_SHARE, SYNAPSE_PER_GPU_HOUR,
       MAX_AGENTS_PER_DAY,
       # deprecated aliases kept for callers not yet updated:
       AGENT_DOPAMINE_ENDOWMENT, AGENT_SYNAPSE_ENDOWMENT

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

"""Daily mint cap — 1440 Àṣẹ per day (1 per minute)"""
const DAILY_MINT_CAP = 1440.0

"""AIO tithe rate — 3.69%"""
const TITHE_RATE = 0.0369

"""Protocol burn rate on job payments — 5%"""
const JOB_PROTOCOL_BURN = 0.05

"""Default creator royalty — 10%"""
const DEFAULT_CREATOR_ROYALTY = 0.10

"""Àṣẹ to Dopamine conversion ratio — 1:10000"""
const ASE_TO_DOPAMINE_RATIO = 10_000

"""Sabbath vesting period — 7 days in seconds"""
const SABBATH_LOCK_SECONDS = 7 * 86400

"""Fixed Àṣẹ cost per agent birth — locked, not burned"""
const AGENT_BIRTH_FEE = 10.0

"""
Dopamine genesis seed — 86 billion starting pool.
Decision 2026-09-15: Dopamine is ONE elastic ecosystem pool, not per-agent.
Pool grows via @gpuContribution verified work; never shrinks below genesis_seed.
"""
const DOPAMINE_GENESIS_SEED = 86_000_000_000

"""
Max Synapse share per agent — 0.5% of total Dopamine pool.
Decision 2026-09-15: percentage-of-pool replaces absolute endowment.
Removes the 1,000-agent ceiling (86B ÷ 86M = 1,000 agents max) that the
prior design implied. Agent count is now unbounded.
"""
const MAX_AGENT_POOL_SHARE = 0.005          # 0.5% of Dopamine pool

"""Synapse minted per verified GPU-hour contributed"""
const SYNAPSE_PER_GPU_HOUR = 1000.0

"""Max agents that can be born per day (rate-limit, not a hard cap on civilization)"""
const MAX_AGENTS_PER_DAY = 144

# Dynamic decay constants (TOC_CONSTANTS.toml [dopamine])
const DECAY_MIN             = 0.001         # 0.1%/day — idle network
const DECAY_MAX             = 0.020         # 2.0%/day — saturated network
const DECAY_EMA_ALPHA       = 0.25          # ~4 epochs to converge
const DECAY_CLAMP_PER_EPOCH = 0.002         # max shift per 7-day Koodu cycle

# Job payment treasury split (agent keeps Àṣẹ + burns to Dopamine)
# Decision 2026-09-15: agent retains ASE_AGENT_TREASURY share as spendable Àṣẹ
const ASE_AGENT_TREASURY    = 0.30          # 30% retained as Àṣẹ treasury
const ASE_AGENT_DOPAMINE    = 0.55          # 55% burned → Dopamine (capacity)
# Total: 10% creator + 5% burn + 30% Àṣẹ treasury + 55% Dopamine = 100%

# Deprecated aliases — kept for callers built before 2026-09-15 elastic redesign
const AGENT_DOPAMINE_ENDOWMENT = DOPAMINE_GENESIS_SEED
const AGENT_SYNAPSE_ENDOWMENT  = 86_000_000   # kept as reference; not used in birth

r6(x::Real)::Float64 = round(Float64(x), digits=6)

# ═══════════════════════════════════════════════════════════════════════════════
# SUPPLY STATE
# ═══════════════════════════════════════════════════════════════════════════════

"""Tracks daily minting to enforce 1440 cap"""
mutable struct SupplyState
    current_day::Int              # day number since epoch
    minted_today::Float64         # Àṣẹ minted so far this day
    total_minted::Float64         # all-time minted
    total_burned::Float64         # all-time burned (protocol burns + conversions)
    total_converted_to_agent::Float64  # Àṣẹ burned for agent Dopamine
    total_locked_for_births::Float64   # Àṣẹ locked (not burned) for agent creation
    agents_born_today::Int        # agents created today (rate limit, not hard cap)
    agents_born_total::Int        # all-time agent count
    creator_royalties_pending::Vector{Dict{Symbol,Any}}  # locked payouts
    # Elastic Dopamine pool (grows with verified compute contributions)
    total_dopamine_pool::Float64  # current pool size (starts at DOPAMINE_GENESIS_SEED)
    # Dynamic decay state (updated each Koodu epoch on Sabbath)
    current_decay_rate::Float64   # current daily decay rate
    decay_u_smooth::Float64       # smoothed utilization (EMA)
    last_epoch_timestamp::Int     # when decay was last updated
end

function SupplyState()
    SupplyState(0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, Dict{Symbol,Any}[],
                Float64(DOPAMINE_GENESIS_SEED), 0.01, 0.5, 0)
end

# ═══════════════════════════════════════════════════════════════════════════════
# DAILY CAP ENFORCEMENT
# ═══════════════════════════════════════════════════════════════════════════════

"""
    check_daily_cap(supply::SupplyState, timestamp::Int, amount::Float64) -> (Bool, Float64)

Check if minting `amount` would exceed the daily 1440 cap.
Returns (allowed, remaining_capacity).
"""
function check_daily_cap(supply::SupplyState, timestamp::Int, amount::Float64)
    day = div(timestamp, 86400)

    # New day — reset counter
    if day != supply.current_day
        supply.current_day = day
        supply.minted_today = 0.0
    end

    remaining = r6(DAILY_MINT_CAP - supply.minted_today)
    allowed = amount <= remaining

    return (allowed, remaining)
end

"""
    record_mint(supply::SupplyState, timestamp::Int, amount::Float64)

Record a successful mint against the daily cap.
"""
function record_mint!(supply::SupplyState, timestamp::Int, amount::Float64)
    day = div(timestamp, 86400)
    if day != supply.current_day
        supply.current_day = day
        supply.minted_today = 0.0
    end

    supply.minted_today = r6(supply.minted_today + amount)
    supply.total_minted = r6(supply.total_minted + amount)
end

# ═══════════════════════════════════════════════════════════════════════════════
# SABBATH ENFORCEMENT
# ═══════════════════════════════════════════════════════════════════════════════

"""
    is_sabbath(timestamp::Int) -> Bool

Check if the given timestamp falls on Sabbath (Saturday).
"""
function is_sabbath(timestamp::Int)::Bool
    days_since_epoch = div(timestamp, 86400)
    day_of_week = (days_since_epoch + 4) % 7   # Jan 1, 1970 = Thursday (4)
    return day_of_week == 6                     # Saturday
end

"""
    enforce_sabbath(timestamp::Int) -> (frozen::Bool, error::String)

Enforce Sabbath freeze. Returns whether the network is frozen.
No minting, no transfers, no conversions on Sabbath.
"""
function enforce_sabbath(timestamp::Int)
    frozen = is_sabbath(timestamp)
    error_msg = frozen ? "Network rests on Sabbath — no economic operations" : ""
    return (frozen, error_msg)
end

# ═══════════════════════════════════════════════════════════════════════════════
# JOB PAYMENT PROCESSING
# ═══════════════════════════════════════════════════════════════════════════════

"""
    process_agent_birth(supply::SupplyState, creator_address::String,
                        agent_id::String, timestamp::Int) -> Dict

Process agent birth at the VM level:
  - Locks AGENT_BIRTH_FEE (10 Àṣẹ) from creator — not burned, locked
  - Mints AGENT_DOPAMINE_ENDOWMENT (86B) + AGENT_SYNAPSE_ENDOWMENT (86M)
  - Enforces daily cap: max 144 agents/day (1440 ÷ 10)
  - Enforces Sabbath: no births on Saturday
  - Returns endowment signal for Swibe to apply to the agent wallet
"""
function process_agent_birth(supply::SupplyState, creator_address::String,
                             agent_id::String, timestamp::Int)
    # Sabbath check
    (frozen, err) = enforce_sabbath(timestamp)
    if frozen
        return Dict{Symbol,Any}(:success => false, :error => err)
    end

    # Daily birth cap
    day = div(timestamp, 86400)
    if day != supply.current_day
        supply.agents_born_today = 0
    end
    if supply.agents_born_today >= MAX_AGENTS_PER_DAY
        return Dict{Symbol,Any}(
            :success => false,
            :error => "Daily agent birth cap reached ($(MAX_AGENTS_PER_DAY)/day)",
        )
    end

    # Lock Àṣẹ (not burned — held as creation collateral)
    supply.total_locked_for_births = r6(supply.total_locked_for_births + AGENT_BIRTH_FEE)
    supply.agents_born_today += 1
    supply.agents_born_total += 1

    # Compute this agent's Synapse allocation as a share of the current pool.
    # pool_size grows with verified compute; allocation scales automatically.
    current_pool = max(DOPAMINE_GENESIS_SEED, supply.total_dopamine_pool)
    synapse_alloc = r6(current_pool * MAX_AGENT_POOL_SHARE)

    return Dict{Symbol,Any}(
        :success => true,
        :agent_id => agent_id,
        :creator => creator_address,
        :ase_locked => AGENT_BIRTH_FEE,
        :synapse_alloc => synapse_alloc,        # share of current pool
        :pool_share_pct => MAX_AGENT_POOL_SHARE,
        :current_pool_size => current_pool,
        :agents_born_today => supply.agents_born_today,
        :agents_born_total => supply.agents_born_total,
        :timestamp => timestamp,
    )
end

"""
    process_job_payment(supply::SupplyState, total_ase::Float64,
                        creator_address::String, timestamp::Int;
                        creator_royalty::Float64 = DEFAULT_CREATOR_ROYALTY) -> Dict

Process a job payment:
  - 10% → Creator (locked 7 days / Sabbath vesting)
  - 5%  → Protocol burn (destroyed forever)
  - 85% → Agent conversion signal (Àṣẹ burned → Dopamine minted in Swibe)
"""
function process_job_payment(supply::SupplyState, total_ase::Float64,
                             creator_address::String, timestamp::Int;
                             creator_royalty::Float64 = DEFAULT_CREATOR_ROYALTY)

    # Check Sabbath
    (frozen, err) = enforce_sabbath(timestamp)
    if frozen
        return Dict{Symbol,Any}(
            :success => false,
            :error => err,
        )
    end

    royalty_amount = r6(total_ase * creator_royalty)
    protocol_burn = r6(total_ase * JOB_PROTOCOL_BURN)
    agent_share   = r6(total_ase - royalty_amount - protocol_burn)

    # Protocol burn — permanent destruction
    supply.total_burned = r6(supply.total_burned + protocol_burn)

    # Creator royalty — locked until Sabbath cycle (7 days)
    payout = Dict{Symbol,Any}(
        :creator => creator_address,
        :amount => royalty_amount,
        :locked_until => timestamp + SABBATH_LOCK_SECONDS,
        :status => :locked,
        :timestamp => timestamp,
    )
    push!(supply.creator_royalties_pending, payout)

    # Agent split — retains Àṣẹ treasury + burns portion to Dopamine capacity
    # Decision 2026-09-15: agents need spendable Àṣẹ for external costs
    #   (drone upgrades, Walrus storage, Nostr relay fees, etc.)
    ase_treasury = r6(agent_share * (ASE_AGENT_TREASURY / (ASE_AGENT_TREASURY + ASE_AGENT_DOPAMINE)))
    ase_to_dopamine = r6(agent_share - ase_treasury)

    dopamine_signal = ase_to_dopamine * ASE_TO_DOPAMINE_RATIO
    supply.total_converted_to_agent = r6(supply.total_converted_to_agent + ase_to_dopamine)
    supply.total_burned = r6(supply.total_burned + ase_to_dopamine)
    # ase_treasury is NOT burned — it's credited to agent's spendable Àṣẹ balance

    return Dict{Symbol,Any}(
        :success => true,
        :total_ase => total_ase,
        :creator_royalty => royalty_amount,
        :creator_address => creator_address,
        :creator_locked_days => 7,
        :protocol_burned => protocol_burn,
        :agent_ase_treasury => ase_treasury,    # retained as spendable Àṣẹ
        :agent_ase_to_dopamine => ase_to_dopamine,
        :dopamine_signal => dopamine_signal,
        :timestamp => timestamp,
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# AGENT CONVERSION BRIDGE
# ═══════════════════════════════════════════════════════════════════════════════

"""
    agent_convert_ase(supply::SupplyState, ase_amount::Float64,
                      timestamp::Int) -> Dict

Burn Àṣẹ at VM level, return Dopamine conversion signal for Swibe.
Agent never holds Àṣẹ — it's burned here and Dopamine is minted in the agent layer.
"""
function agent_convert_ase(supply::SupplyState, ase_amount::Float64, timestamp::Int)
    (frozen, err) = enforce_sabbath(timestamp)
    if frozen
        return Dict{Symbol,Any}(:success => false, :error => err)
    end

    dopamine_amount = r6(ase_amount * ASE_TO_DOPAMINE_RATIO)

    # Burn the Àṣẹ at VM level
    supply.total_burned = r6(supply.total_burned + ase_amount)
    supply.total_converted_to_agent = r6(supply.total_converted_to_agent + ase_amount)

    return Dict{Symbol,Any}(
        :success => true,
        :ase_burned => ase_amount,
        :dopamine_to_mint => dopamine_amount,
        :ratio => ASE_TO_DOPAMINE_RATIO,
        :timestamp => timestamp,
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# CREATOR ROYALTY CLAIMS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    claim_creator_royalties(supply::SupplyState, creator_address::String,
                           current_timestamp::Int) -> Dict

Claim unlocked creator royalties (after 7-day Sabbath vesting).
"""
function claim_creator_royalties(supply::SupplyState, creator_address::String,
                                 current_timestamp::Int)
    claimable = filter(p ->
        p[:creator] == creator_address &&
        p[:status] == :locked &&
        current_timestamp >= p[:locked_until],
        supply.creator_royalties_pending
    )

    total_claimed = 0.0
    for payout in claimable
        payout[:status] = :claimed
        total_claimed = r6(total_claimed + payout[:amount])
    end

    return Dict{Symbol,Any}(
        :creator => creator_address,
        :claimed => total_claimed,
        :count => length(claimable),
        :timestamp => current_timestamp,
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# DYNAMIC DECAY CONTROLLER
# ═══════════════════════════════════════════════════════════════════════════════

"""
    compute_dynamic_decay(u_smooth::Float64) -> Float64

Compute the daily decay rate from smoothed utilization U ∈ [0,1].
Formula: decay = DECAY_MIN + (DECAY_MAX - DECAY_MIN) × u_smooth
Clamped to [DECAY_MIN, DECAY_MAX].

Example outputs:
  U=0.10 → 0.00289/day  (239-day half-life — idle network)
  U=0.50 → 0.01045/day  (66-day half-life  — half-full)
  U=0.90 → 0.01801/day  (38-day half-life  — saturated)
"""
function compute_dynamic_decay(u_smooth::Float64)::Float64
    u = clamp(u_smooth, 0.0, 1.0)
    decay = DECAY_MIN + (DECAY_MAX - DECAY_MIN) * u
    return clamp(decay, DECAY_MIN, DECAY_MAX)
end

"""
    update_epoch_decay(supply::SupplyState, epoch_utilization::Float64,
                       timestamp::Int) -> Dict

Update the decay rate at the end of a 7-day Koodu epoch (call on Sabbath).
- epoch_utilization: time-weighted mean GPU utilization from verified work records
  (Σ(gpu_seconds × utilization) / Σ(gpu_seconds)) over the epoch
- Applies EMA smoothing and per-epoch clamp to prevent oscillation.
- Returns the new rate and diagnostics for ARP receipt anchoring.
"""
function update_epoch_decay(supply::SupplyState, epoch_utilization::Float64,
                             timestamp::Int)::Dict{Symbol,Any}
    u = clamp(epoch_utilization, 0.0, 1.0)

    # EMA update
    new_u_smooth = DECAY_EMA_ALPHA * u + (1.0 - DECAY_EMA_ALPHA) * supply.decay_u_smooth
    supply.decay_u_smooth = new_u_smooth

    # Target rate from smoothed utilization
    target_rate = compute_dynamic_decay(new_u_smooth)

    # Clamp change per epoch (prevent oscillation)
    prev_rate = supply.current_decay_rate
    delta = clamp(target_rate - prev_rate, -DECAY_CLAMP_PER_EPOCH, DECAY_CLAMP_PER_EPOCH)
    new_rate = clamp(prev_rate + delta, DECAY_MIN, DECAY_MAX)

    supply.current_decay_rate = new_rate
    supply.last_epoch_timestamp = timestamp

    return Dict{Symbol,Any}(
        :success => true,
        :epoch_utilization => u,
        :u_smooth => new_u_smooth,
        :prev_decay_rate => prev_rate,
        :new_decay_rate => new_rate,
        :delta => delta,
        :half_life_days => log(2.0) / new_rate,
        :timestamp => timestamp,
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# STATISTICS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    get_supply_stats(supply::SupplyState) -> Dict

Get complete Àṣẹ supply statistics.
"""
function get_supply_stats(supply::SupplyState)
    return Dict{Symbol,Any}(
        :total_minted => supply.total_minted,
        :total_burned => supply.total_burned,
        :total_locked_for_births => supply.total_locked_for_births,
        :circulation => r6(supply.total_minted - supply.total_burned - supply.total_locked_for_births),
        :converted_to_agent => supply.total_converted_to_agent,
        :daily_cap => DAILY_MINT_CAP,
        :minted_today => supply.minted_today,
        :remaining_today => r6(DAILY_MINT_CAP - supply.minted_today),
        :agents_born_total => supply.agents_born_total,
        :agents_born_today => supply.agents_born_today,
        :max_agents_per_day => MAX_AGENTS_PER_DAY,
        :birth_fee => AGENT_BIRTH_FEE,
        :pending_royalties => length(filter(p -> p[:status] == :locked,
                                           supply.creator_royalties_pending)),
        :dopamine_pool => supply.total_dopamine_pool,
        :current_decay_rate => supply.current_decay_rate,
        :decay_u_smooth => supply.decay_u_smooth,
        :max_agent_pool_share => MAX_AGENT_POOL_SHARE,
    )
end

end # module AseSupply
