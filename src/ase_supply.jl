# ase_supply.jl — Àṣẹ Supply Rules & Sabbath Enforcement
# VM-level supply cap: 1440 Àṣẹ/day, Sabbath freeze, agent conversion bridge
# Bínò ÈL Guà — Crown Architect

module AseSupply

export SupplyState, check_daily_cap, enforce_sabbath, agent_convert_ase,
       process_job_payment, process_agent_birth, get_supply_stats,
       DAILY_MINT_CAP, TITHE_RATE, AGENT_BIRTH_FEE,
       AGENT_DOPAMINE_ENDOWMENT, AGENT_SYNAPSE_ENDOWMENT, MAX_AGENTS_PER_DAY

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

"""Dopamine endowment per agent — 86 billion (one per neuron)"""
const AGENT_DOPAMINE_ENDOWMENT = 86_000_000_000

"""Synapse endowment per agent — 86 million (one per synaptic bundle)"""
const AGENT_SYNAPSE_ENDOWMENT = 86_000_000

"""Max agents that can be born per day at full capacity (1440 ÷ 10)"""
const MAX_AGENTS_PER_DAY = 144

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
    agents_born_today::Int        # agents created today (max 144)
    agents_born_total::Int        # all-time agent count
    creator_royalties_pending::Vector{Dict{Symbol,Any}}  # locked payouts
end

function SupplyState()
    SupplyState(0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, Dict{Symbol,Any}[])
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

    return Dict{Symbol,Any}(
        :success => true,
        :agent_id => agent_id,
        :creator => creator_address,
        :ase_locked => AGENT_BIRTH_FEE,
        :dopamine_endowment => AGENT_DOPAMINE_ENDOWMENT,
        :synapse_endowment => AGENT_SYNAPSE_ENDOWMENT,
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

    # Agent conversion — Àṣẹ burned, signal Swibe to mint Dopamine
    dopamine_amount = agent_share * ASE_TO_DOPAMINE_RATIO
    supply.total_converted_to_agent = r6(supply.total_converted_to_agent + agent_share)
    supply.total_burned = r6(supply.total_burned + agent_share)

    return Dict{Symbol,Any}(
        :success => true,
        :total_ase => total_ase,
        :creator_royalty => royalty_amount,
        :creator_address => creator_address,
        :creator_locked_days => 7,
        :protocol_burned => protocol_burn,
        :agent_ase_burned => agent_share,
        :dopamine_signal => dopamine_amount,
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
    )
end

end # module AseSupply
