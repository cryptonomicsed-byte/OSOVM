# inheritance.jl — 1440 Inheritance Wallet System
# Sacred governance: 7×7 badge → Council of 12 → Bínò final sign

module Inheritance

include("flaw_tokens.jl")
using .FlawTokens: generate_flaw_token, verify_flaw_token

export InheritanceWallet, init_1440_wallets, candidate_apply, council_approve,
       final_sign, distribute_offering, claim_rewards, accrue_rewards, is_sabbath

# 1440 Inheritance Wallet Structure
mutable struct InheritanceWallet
    id::Int
    state::Int                    # 1=Open, 2=Pending, 3=CouncilReady, 4=Awarded
    pending::String               # Candidate shrine address
    winner::String                # Final awarded address
    approvals_mask::Int           # Bitmask of council approvals (12 bits)
    next_eligible_ts::Int         # Next claim timestamp (7 years)
    locked_balance::Float64       # Principal locked (11.11% APY)
    accrued_rewards::Float64      # Accumulated yield
    staked_since::Int             # Timestamp of first stake
    last_claimed::Int             # Last reward claim timestamp
    flaw_token::String            # Soulbound Genesis Flaw Token — the one
                                   # entitlement mark for this wallet, minted
                                   # once at genesis, never reassigned, never
                                   # transferable (no setter exists for it)
end

"""
Initialize all 1440 wallets in Open state, each soulbound to its own
unique Genesis Flaw Token (see flaw_tokens.jl). The token is generated
once here, at genesis, and is permanent for the life of the wallet.
"""
function init_1440_wallets(start_ts::Int=0)::Vector{InheritanceWallet}
    wallets = InheritanceWallet[]

    for i in 1:1440
        push!(wallets, InheritanceWallet(
            i,                  # id
            1,                  # state = Open
            "",                 # pending
            "",                 # winner
            0,                  # approvals_mask
            start_ts,           # next_eligible_ts (immediate for first claim)
            0.0,                # locked_balance
            0.0,                # accrued_rewards
            0,                  # staked_since
            start_ts,           # last_claimed
            generate_flaw_token(i)  # flaw_token — soulbound at birth
        ))
    end

    return wallets
end

"""
Check if date is Saturday (Sabbath - no claims allowed)
"""
function is_sabbath(timestamp::Int)::Bool
    # Simple modulo check: Saturday is day 6 in 0-indexed week
    day_of_week = div(timestamp, 86400) % 7
    return day_of_week == 6
end

"""
Opcode 0x30: candidateApply
Begin inheritance claim (requires 7×7 badge AND the wallet's Genesis Flaw
Token — presenting the correct flaw_token is what proves standing to claim
*this specific* wallet; the 7×7 badge alone only proves general eligibility
to inherit *some* wallet).
"""
function candidate_apply(
    wallet_id::Int,
    shrine::String,
    wallets::Vector{InheritanceWallet},
    has_inherited::Dict{String, Bool},
    current_time::Int,
    has_seven_by_seven::Bool,
    presented_flaw_token::String
)::Dict{Symbol, Any}

    if wallet_id < 1 || wallet_id > 1440
        return Dict(:success => false, :error => "invalid wallet_id")
    end

    w = wallets[wallet_id]

    # Validate state
    if !(w.state in [1, 2])
        return Dict(:success => false, :error => "wallet not open")
    end

    # Check 7-year waiting period
    if current_time < w.next_eligible_ts
        return Dict(:success => false, :error => "7 years not passed")
    end

    # Check if shrine already inherited
    if get(has_inherited, shrine, false)
        return Dict(:success => false, :error => "already inherited")
    end

    # Require 7×7 badge
    if !has_seven_by_seven
        return Dict(:success => false, :error => "7x7 badge required")
    end

    # Require the correct Genesis Flaw Token for THIS wallet — this is the
    # actual entitlement check, distinct from the 7x7 badge above.
    if !verify_flaw_token(wallet_id, presented_flaw_token)
        return Dict(:success => false, :error => "wrong flaw token for this wallet")
    end

    # Apply or update candidate
    if w.state == 1
        w.state = 2  # Pending
        w.pending = shrine
        w.approvals_mask = 0

        return Dict(
            :success => true,
            :wallet_id => wallet_id,
            :candidate => shrine,
            :event => "CandidateApplied"
        )
    else
        # Re-application (state == 2)
        if w.pending != shrine
            return Dict(:success => false, :error => "different candidate")
        end

        return Dict(
            :success => true,
            :wallet_id => wallet_id,
            :candidate => shrine,
            :event => "CandidateReapplied"
        )
    end
end

"""
Opcode 0x31: councilApprove
Council of 12 vote on candidate
"""
function council_approve(
    wallet_id::Int,
    council_member::String,
    wallets::Vector{InheritanceWallet},
    council::Vector{String}
)::Dict{Symbol, Any}

    # Verify council membership
    council_idx = findfirst(==(council_member), council)
    if council_idx === nothing
        return Dict(:success => false, :error => "not council member")
    end

    if wallet_id < 1 || wallet_id > 1440
        return Dict(:success => false, :error => "invalid wallet_id")
    end

    w = wallets[wallet_id]

    # Check state
    if !(w.state in [2, 3])
        return Dict(:success => false, :error => "not pending")
    end

    # Check if already voted
    bit = 1 << (council_idx - 1)
    if (w.approvals_mask & bit) != 0
        return Dict(:success => false, :error => "already voted")
    end

    # Record approval
    w.approvals_mask |= bit

    # Count approvals
    approval_count = count_ones(w.approvals_mask)

    # Transition to CouncilReady if all 12 approved
    if approval_count >= 12
        w.state = 3  # CouncilReady
    end

    return Dict(
        :success => true,
        :wallet_id => wallet_id,
        :council_member => council_member,
        :approvals => approval_count,
        :event => "CouncilApproved",
        :ready => (w.state == 3)
    )
end

"""
Opcode 0x32: finalSign
Bínò final seal (Ọbàtálá witness)
"""
function final_sign(
    wallet_id::Int,
    signer::String,
    wallets::Vector{InheritanceWallet},
    has_inherited::Dict{String, Bool},
    final_signer::String,
    current_time::Int
)::Dict{Symbol, Any}

    # Only Bínò can sign
    if signer != final_signer
        return Dict(:success => false, :error => "only Bínò can sign")
    end

    if wallet_id < 1 || wallet_id > 1440
        return Dict(:success => false, :error => "invalid wallet_id")
    end

    w = wallets[wallet_id]

    # Check council approval
    if w.state != 3
        return Dict(:success => false, :error => "council not ready")
    end

    # Award wallet
    w.state = 4  # Awarded
    w.winner = w.pending
    w.next_eligible_ts = current_time + (7 * 365 * 86400)  # 7 years from now
    has_inherited[w.winner] = true

    return Dict(
        :success => true,
        :wallet_id => wallet_id,
        :winner => w.winner,
        :event => "FinalSigned",
        :next_eligible => w.next_eligible_ts
    )
end

"""
Opcode 0x33: distributeOffering
25% of tithe flows to 1440 vaults
"""
function distribute_offering(
    amount::Float64,
    wallets::Vector{InheritanceWallet},
    current_time::Int
)::Dict{Symbol, Any}

    # 25% to inheritance
    inheritance_share = amount * 0.25
    per_wallet = inheritance_share / 1440.0

    # Distribute to each vault
    for w in wallets
        w.locked_balance += per_wallet

        # Initialize staking timestamp if first deposit
        if w.staked_since == 0
            w.staked_since = current_time
        end

        # Accrue rewards before adding new principal
        accrue_rewards(w, current_time)
    end

    return Dict(
        :success => true,
        :total_distributed => inheritance_share,
        :per_wallet => per_wallet,
        :wallets_funded => 1440
    )
end

"""
Accrue 11.11% APY rewards
Formula: rewards = principal × 0.1111 × (time_elapsed / year)
"""
function accrue_rewards(wallet::InheritanceWallet, current_time::Int)::Nothing
    if wallet.locked_balance <= 0 || wallet.staked_since == 0
        return nothing
    end

    time_elapsed = current_time - wallet.last_claimed

    if time_elapsed <= 0
        return nothing
    end

    # 11.11% APY
    annual_rate = 0.1111
    seconds_per_year = 365.25 * 86400

    # Calculate accrued rewards
    time_fraction = time_elapsed / seconds_per_year
    new_rewards = wallet.locked_balance * annual_rate * time_fraction

    wallet.accrued_rewards += new_rewards
    wallet.last_claimed = current_time

    nothing
end

"""
Opcode 0x34: claimRewards
Unlock 11.11% yield (Sabbath-aware)
"""
function claim_rewards(
    wallet_id::Int,
    claimer::String,
    wallets::Vector{InheritanceWallet},
    current_time::Int
)::Dict{Symbol, Any}

    # Sabbath check
    if is_sabbath(current_time)
        return Dict(:success => false, :error => "Sabbath fasting - no claims on Saturday")
    end

    if wallet_id < 1 || wallet_id > 1440
        return Dict(:success => false, :error => "invalid wallet_id")
    end

    w = wallets[wallet_id]

    # Only winner can claim
    if w.winner != claimer
        return Dict(:success => false, :error => "not wallet owner")
    end

    # Accrue latest rewards
    accrue_rewards(w, current_time)

    # Claim all accrued rewards
    rewards = w.accrued_rewards
    w.accrued_rewards = 0.0

    return Dict(
        :success => true,
        :wallet_id => wallet_id,
        :rewards_claimed => rewards,
        :event => "RewardsClaimed",
        :locked_balance => w.locked_balance
    )
end

end # module
