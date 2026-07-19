"""
    AseMinting - Àṣẹ token minting and distribution system
    
Mints Àṣẹ rewards based on VeilSim F1 scores with 50/25/15/10 distribution.
"""

module AseMinting

include("veils_777.jl")
include("veil_index.jl")
include("veilsim_scorer.jl")

using .Veils777
using .VeilIndex
using .VeilSimScorer

export mint_ase_for_veil, distribute_ase_offering, AseVeilMinted,
       get_ase_balance, transfer_ase, ase_transaction_log, AseWallet

# ============================================================================
# DATA STRUCTURES
# ============================================================================

"""Àṣẹ wallet"""
mutable struct AseWallet
    address::String
    balance::Float64
    transaction_count::Int
    created_at::DateTime
    locked::Bool
end

"""Àṣẹ transaction"""
struct AseTransaction
    tx_id::String
    from::String
    to::String
    amount::Float64
    reason::String  # "veil_reward", "offering", "transfer", etc
    veil_id::Union{Int, Nothing}
    f1_score::Union{Float64, Nothing}
    timestamp::DateTime
    confirmed::Bool
end

"""Àṣẹ minting event"""
struct AseVeilMinted
    veil_id::Int
    f1_score::Float64
    base_amount::Float64
    bonus_amount::Float64
    total_amount::Float64
    timestamp::DateTime
    treasury_share::Float64
    inheritance_share::Float64
    council_share::Float64
    shrine_share::Float64
end

# ============================================================================
# CONSTANTS
# ============================================================================

"""Distribution ratios for offerings (50/25/15/10)"""
const DISTRIBUTION_RATIOS = Dict(
    "treasury" => 0.50,
    "inheritance" => 0.25,
    "council" => 0.15,
    "shrine" => 0.10
)

"""Special wallet addresses"""
const SHRINE_WALLET = "obatala_shrine_0xDEADBEEF"
const COUNCIL_WALLET = "council_0xCAFEBABE"
const INHERITANCE_POOL = "inheritance_1440_0x1234ABCD"
const TREASURY_VAULT = "treasury_vault_0x5678EFGH"

# ============================================================================
# GLOBAL STATE
# ============================================================================

"""Wallet registry: address -> AseWallet"""
const WALLETS = Dict{String, AseWallet}()

"""Transaction log"""
const TRANSACTION_LOG = AseTransaction[]

"""Minting events log"""
const MINTING_LOG = AseVeilMinted[]

"""Global Àṣẹ supply tracker"""
mutable struct AseSupply
    total_minted::Float64
    total_burned::Float64
    circulation::Float64
    timestamp::DateTime
end

const GLOBAL_SUPPLY = AseSupply(0.0, 0.0, 0.0, now())

# ============================================================================
# WALLET MANAGEMENT
# ============================================================================

"""
    create_wallet(address::String) -> AseWallet

Create a new wallet.
"""
function create_wallet(address::String)::AseWallet
    if haskey(WALLETS, address)
        return WALLETS[address]
    end
    
    wallet = AseWallet(address, 0.0, 0, now(), false)
    WALLETS[address] = wallet
    
    return wallet
end

"""
    get_ase_balance(address::String) -> Float64

Get Àṣẹ balance for a wallet.
"""
function get_ase_balance(address::String)::Float64
    if !haskey(WALLETS, address)
        return 0.0
    end
    return WALLETS[address].balance
end

"""
    lock_wallet(address::String)

Lock a wallet to prevent transfers.
"""
function lock_wallet(address::String)
    if haskey(WALLETS, address)
        WALLETS[address].locked = true
    end
end

"""
    unlock_wallet(address::String)

Unlock a wallet.
"""
function unlock_wallet(address::String)
    if haskey(WALLETS, address)
        WALLETS[address].locked = false
    end
end

# ============================================================================
# MINTING LOGIC
# ============================================================================

"""
    mint_ase_for_veil(veil_id::Int, f1_score::Float64, 
                      wallet_address::String = "") -> AseVeilMinted

Mint Àṣẹ based on veil F1 score with 50/25/15/10 distribution.
"""
function mint_ase_for_veil(veil_id::Int, f1_score::Float64, 
                          wallet_address::String = "")::AseVeilMinted
    
    # Verify F1 score is in valid range
    if f1_score < 0.0 || f1_score > 1.0
        error("F1 score must be between 0.0 and 1.0, got $f1_score")
    end
    
    # Check threshold
    if f1_score < VeilSimScorer.F1_THRESHOLD
        # Return zero mint event
        return AseVeilMinted(
            veil_id, f1_score, 0.0, 0.0, 0.0, now(),
            0.0, 0.0, 0.0, 0.0
        )
    end
    
    # Calculate reward
    base_reward = VeilSimScorer.calculate_reward(f1_score)
    
    # Bonus scaling by F1 score (0-1 maps to 0-100%)
    bonus_multiplier = max(0.0, f1_score - VeilSimScorer.F1_THRESHOLD) * 2.0  # 0.1 range -> 0-0.2 bonus
    bonus_reward = base_reward * bonus_multiplier
    
    total_amount = base_reward + bonus_reward
    
    # Calculate distribution
    treasury_amt = total_amount * DISTRIBUTION_RATIOS["treasury"]
    inheritance_amt = total_amount * DISTRIBUTION_RATIOS["inheritance"]
    council_amt = total_amount * DISTRIBUTION_RATIOS["council"]
    shrine_amt = total_amount * DISTRIBUTION_RATIOS["shrine"]
    
    # Create minting event
    mint_event = AseVeilMinted(
        veil_id,
        f1_score,
        base_reward,
        bonus_reward,
        total_amount,
        now(),
        treasury_amt,
        inheritance_amt,
        council_amt,
        shrine_amt
    )
    
    # Record minting
    push!(MINTING_LOG, mint_event)
    
    # Distribute Àṣẹ
    distribute_ase_offering(mint_event, wallet_address)
    
    # Update supply
    GLOBAL_SUPPLY.total_minted += total_amount
    GLOBAL_SUPPLY.circulation += total_amount
    GLOBAL_SUPPLY.timestamp = now()
    
    return mint_event
end

# ============================================================================
# DISTRIBUTION
# ============================================================================

"""
    distribute_ase_offering(mint_event::AseVeilMinted, wallet_address::String = "")

Distribute minted Àṣẹ according to 50/25/15/10 ratio.
"""
function distribute_ase_offering(mint_event::AseVeilMinted, wallet_address::String = "")
    
    # Ensure wallets exist
    create_wallet(TREASURY_VAULT)
    create_wallet(INHERITANCE_POOL)
    create_wallet(COUNCIL_WALLET)
    create_wallet(SHRINE_WALLET)
    
    if !isempty(wallet_address)
        create_wallet(wallet_address)
    end
    
    # Treasury (50%)
    transfer_ase(TREASURY_VAULT, mint_event.treasury_share, 
                 "Veil $(mint_event.veil_id) F1 scoring - treasury portion",
                 mint_event.veil_id, mint_event.f1_score)
    
    # Inheritance Pool (25%)
    transfer_ase(INHERITANCE_POOL, mint_event.inheritance_share,
                 "Veil $(mint_event.veil_id) F1 scoring - inheritance portion",
                 mint_event.veil_id, mint_event.f1_score)
    
    # Council of 12 (15%)
    transfer_ase(COUNCIL_WALLET, mint_event.council_share,
                 "Veil $(mint_event.veil_id) F1 scoring - council portion",
                 mint_event.veil_id, mint_event.f1_score)
    
    # Ọbàtálá Shrine (10%)
    transfer_ase(SHRINE_WALLET, mint_event.shrine_share,
                 "Veil $(mint_event.veil_id) F1 scoring - shrine offering",
                 mint_event.veil_id, mint_event.f1_score)
    
    # Direct wallet reward (if specified)
    if !isempty(wallet_address)
        # Give wallet a 5% bonus of the base reward
        wallet_bonus = mint_event.base_reward * 0.05
        if wallet_bonus > 0.0
            transfer_ase(wallet_address, wallet_bonus,
                       "Veil $(mint_event.veil_id) F1 scoring - direct reward",
                       mint_event.veil_id, mint_event.f1_score)
        end
    end
end

# ============================================================================
# TRANSFERS
# ============================================================================

"""
    transfer_ase(to_address::String, amount::Float64, reason::String = "",
                veil_id::Union{Int, Nothing} = nothing,
                f1_score::Union{Float64, Nothing} = nothing) -> AseTransaction

Transfer Àṣẹ from system pool to wallet.
"""
function transfer_ase(to_address::String, amount::Float64, reason::String = "",
                     veil_id::Union{Int, Nothing} = nothing,
                     f1_score::Union{Float64, Nothing} = nothing)::AseTransaction
    
    if amount < 0.0
        error("Cannot transfer negative Àṣẹ")
    end
    
    # Get or create wallet
    wallet = create_wallet(to_address)
    
    if wallet.locked
        error("Wallet $to_address is locked")
    end
    
    # Generate transaction ID
    tx_id = "ASE_$(hash(to_address, time()))_$(length(TRANSACTION_LOG)+1)"
    
    # Create transaction
    tx = AseTransaction(
        tx_id,
        "system",
        to_address,
        amount,
        reason,
        veil_id,
        f1_score,
        now(),
        true
    )
    
    # Record transaction
    push!(TRANSACTION_LOG, tx)
    
    # Update wallet
    wallet.balance += amount
    wallet.transaction_count += 1
    
    # Emit transaction event
    emit_ase_transaction(tx)
    
    return tx
end

"""
    emit_ase_transaction(tx::AseTransaction)

Emit Àṣẹ transaction event.
"""
function emit_ase_transaction(tx::AseTransaction)
    event = Dict(
        "type" => "AseTransferred",
        "tx_id" => tx.tx_id,
        "from" => tx.from,
        "to" => tx.to,
        "amount" => tx.amount,
        "reason" => tx.reason,
        "veil_id" => tx.veil_id,
        "f1_score" => tx.f1_score,
        "timestamp" => string(tx.timestamp),
        "confirmed" => tx.confirmed
    )
    
    # Log
    if tx.amount > 0.0
        println("[AseTransferred] $(tx.to): +$(tx.amount) ($(tx.reason))")
    end
    
    return event
end

# ============================================================================
# STATISTICS
# ============================================================================

"""
    get_minting_stats() -> Dict

Get Àṣẹ minting statistics.
"""
function get_minting_stats()::Dict
    return Dict(
        "total_minted" => GLOBAL_SUPPLY.total_minted,
        "total_burned" => GLOBAL_SUPPLY.total_burned,
        "circulation" => GLOBAL_SUPPLY.circulation,
        "minting_events" => length(MINTING_LOG),
        "transactions" => length(TRANSACTION_LOG),
        "wallets_active" => length(WALLETS),
        "timestamp" => string(GLOBAL_SUPPLY.timestamp)
    )
end

"""
    ase_transaction_log(n::Int = -1) -> Vector{AseTransaction}

Get Àṣẹ transaction log. If n > 0, return last n transactions.
"""
function ase_transaction_log(n::Int = -1)::Vector{AseTransaction}
    if n < 0
        return copy(TRANSACTION_LOG)
    else
        return copy(TRANSACTION_LOG[max(1, length(TRANSACTION_LOG)-n+1):end])
    end
end

"""
    get_wallet_info(address::String) -> Dict

Get detailed wallet information.
"""
function get_wallet_info(address::String)::Dict
    if !haskey(WALLETS, address)
        return Dict("error" => "Wallet $address not found")
    end
    
    wallet = WALLETS[address]
    
    # Get wallet transactions
    wallet_txs = filter(tx -> tx.to == address, TRANSACTION_LOG)
    
    return Dict(
        "address" => address,
        "balance" => wallet.balance,
        "transaction_count" => wallet.transaction_count,
        "created_at" => string(wallet.created_at),
        "locked" => wallet.locked,
        "transactions" => length(wallet_txs),
        "recent_transactions" => [
            Dict(
                "amount" => tx.amount,
                "reason" => tx.reason,
                "timestamp" => string(tx.timestamp)
            ) for tx in wallet_txs[end-4:end]
        ]
    )
end

"""
    distribution_breakdown() -> Dict

Get 50/25/15/10 distribution breakdown.
"""
function distribution_breakdown()::Dict
    total_minted = GLOBAL_SUPPLY.total_minted
    
    return Dict(
        "total_minted" => total_minted,
        "treasury_50" => Dict(
            "percentage" => 50,
            "amount" => total_minted * 0.50,
            "balance" => get_ase_balance(TREASURY_VAULT)
        ),
        "inheritance_25" => Dict(
            "percentage" => 25,
            "amount" => total_minted * 0.25,
            "balance" => get_ase_balance(INHERITANCE_POOL),
            "wallets_in_pool" => 1440
        ),
        "council_15" => Dict(
            "percentage" => 15,
            "amount" => total_minted * 0.15,
            "balance" => get_ase_balance(COUNCIL_WALLET),
            "council_members" => 12
        ),
        "shrine_10" => Dict(
            "percentage" => 10,
            "amount" => total_minted * 0.10,
            "balance" => get_ase_balance(SHRINE_WALLET),
            "shrine" => "Ọbàtálá"
        )
    )
end

end # module AseMinting
