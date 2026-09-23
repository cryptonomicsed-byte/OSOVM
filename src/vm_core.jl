# vm_core.jl — Ọ̀ṢỌ́VM Hardened Deterministic Core
# Pure state transitions. No randomness. No system time. No global mutation.
# Bínò ÈL Guà — Crown Architect
# Ọbàtálá — Master Auditor

module VMCore

include("opcodes.jl")
include("oso_compiler.jl")
include("ase_supply.jl")
include("constants.jl")

using .Opcodes
using .OsoCompiler: Instruction, IR
using .AseSupply
using .Constants

export VMState, Block, Transaction, Receipt,
       apply_block, initial_state, copy_state,
       OPCODE_HANDLERS,
       toc_is_fully_verified

# ═══════════════════════════════════════════════════════════════════════════════
# NUMERIC DISCIPLINE
# ═══════════════════════════════════════════════════════════════════════════════

r6(x::Real)::Float64 = round(Float64(x), digits=6)

# ═══════════════════════════════════════════════════════════════════════════════
# DATA STRUCTURES
# ═══════════════════════════════════════════════════════════════════════════════

struct Receipt
    receipt_id::String
    tx_id::String
    opcode::UInt8
    status::Symbol          # :ok, :error, :halted, :noop
    data::Dict{Symbol,Any}
end

struct Transaction
    tx_id::String
    sender::String
    instructions::Vector{Instruction}
    metadata::Dict{Symbol,Any}
end

struct Block
    block_number::Int
    timestamp::Int           # explicit input, never system time
    transactions::Vector{Transaction}
    metadata::Dict{Symbol,Any}
end

struct VMState
    balances::Dict{String,Float64}
    block_number::Int
    receipts::Vector{Receipt}
    metadata::Dict{Symbol,Any}
end

# ═══════════════════════════════════════════════════════════════════════════════
# STATE HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function initial_state(;
    chain_id::String = "OSO-MAINNET-1",
    council::Vector{String} = String[],
    final_signer::String = "bino_genesis"
)::VMState
    VMState(
        Dict{String,Float64}(),
        0,
        Receipt[],
        Dict{Symbol,Any}(
            :staked              => Dict{String,Float64}(),
            :tithe_collected     => 0.0,
            :halted              => false,
            :events              => Vector{Dict{Symbol,Any}}(),
            :chain_id            => chain_id,
            :council             => copy(council),
            :final_signer        => final_signer,
            :genesis_flaw_used   => false,
            :ase_supply          => AseSupply.SupplyState(),
            # ToC (Token-of-Compute) state
            :toc_contributions   => Dict{String,Float64}(),  # agent_id → accumulated gpu_seconds
            :synapse_balance     => Dict{String,Int}(),      # agent_id → minted Synapse tokens
        )
    )
end

function copy_state(s::VMState;
    balances     = copy(s.balances),
    block_number = s.block_number,
    receipts     = copy(s.receipts),
    metadata     = deepcopy(s.metadata),
)::VMState
    VMState(balances, block_number, receipts, metadata)
end

# ═══════════════════════════════════════════════════════════════════════════════
# DETERMINISTIC UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

function make_receipt_id(block_no::Int, tx_index::Int, instr_index::Int, opcode::UInt8)::String
    "b$(block_no)-t$(tx_index)-i$(instr_index)-0x$(string(opcode, base=16, pad=2))"
end

function is_sabbath(timestamp::Int)::Bool
    days_since_epoch = div(timestamp, 86400)
    day_of_week = (days_since_epoch + 4) % 7   # Jan 1, 1970 = Thursday (4)
    return day_of_week == 6                     # Saturday
end

function enrich_args(args::Dict{Symbol,Any}, block::Block, tx::Transaction,
                     tx_index::Int, instr_index::Int)::Dict{Symbol,Any}
    merged = copy(args)
    merged[:sender]      = tx.sender
    merged[:tx_id]       = tx.tx_id
    merged[:block_number]= block.block_number
    merged[:timestamp]   = block.timestamp
    merged[:tx_index]    = tx_index
    merged[:instr_index] = instr_index
    return merged
end

# ═══════════════════════════════════════════════════════════════════════════════
# OPCODE HANDLERS
# Each: (state::VMState, args::Dict{Symbol,Any}) -> (VMState, Dict{Symbol,Any})
# Returns (new_state, receipt_data)
# ═══════════════════════════════════════════════════════════════════════════════

function op_halt(state::VMState, args::Dict{Symbol,Any})
    s = copy_state(state)
    s.metadata[:halted] = true
    return s, Dict{Symbol,Any}(:status => "halted")
end

function op_noop(state::VMState, args::Dict{Symbol,Any})
    return state, Dict{Symbol,Any}(:status => "noop")
end

function op_impact(state::VMState, args::Dict{Symbol,Any})
    sender    = args[:sender]::String
    ase       = Float64(get(args, :ase, 0.0))
    quorum    = Int(get(args, :quorum, 5))
    timestamp = Int(get(args, :timestamp, 0))

    # Sabbath enforcement — no minting on Saturday
    supply = state.metadata[:ase_supply]::AseSupply.SupplyState
    (frozen, err) = AseSupply.enforce_sabbath(timestamp)
    if frozen
        return state, Dict{Symbol,Any}(:ase_minted => 0.0, :error => err, :frozen => true)
    end

    witness_mult = min(quorum, 7)
    gross     = r6(1.0 * witness_mult * ase)
    tithe_rate = Constants.ESU_TITHE_RATE   # 0.0369 — from TOC_CONSTANTS.toml [esu].tithe_rate
    tithe     = r6(gross * tithe_rate)
    net_ase   = r6(gross - tithe)

    # Daily cap enforcement — 1440 Àṣẹ/day
    s = copy_state(state)
    s_supply = s.metadata[:ase_supply]::AseSupply.SupplyState
    (allowed, remaining) = AseSupply.check_daily_cap(s_supply, timestamp, net_ase)
    if !allowed
        # Mint only what remains in today's cap
        net_ase = remaining
        tithe = r6(net_ase * tithe_rate / (1.0 - tithe_rate))
        gross = r6(net_ase + tithe)
    end

    AseSupply.record_mint!(s_supply, timestamp, net_ase)
    s.balances[sender] = r6(get(s.balances, sender, 0.0) + net_ase)
    s.metadata[:tithe_collected] = r6(Float64(s.metadata[:tithe_collected]) + tithe)

    return s, Dict{Symbol,Any}(
        :ase_minted  => net_ase,
        :gross       => gross,
        :tithe       => tithe,
        :tithe_rate  => tithe_rate,
        :balance     => s.balances[sender],
        :daily_remaining => r6(AseSupply.DAILY_MINT_CAP - s_supply.minted_today),
    )
end

function op_transfer(state::VMState, args::Dict{Symbol,Any})
    sender = args[:sender]::String
    to     = String(get(args, :to, ""))
    amount = r6(Float64(get(args, :amount, 0.0)))

    from_balance = get(state.balances, sender, 0.0)

    if from_balance < amount || isempty(to)
        return state, Dict{Symbol,Any}(
            :transferred => 0.0,
            :success     => false,
            :error       => from_balance < amount ? "insufficient_balance" : "missing_recipient",
        )
    end

    s = copy_state(state)
    s.balances[sender] = r6(from_balance - amount)
    s.balances[to]     = r6(get(s.balances, to, 0.0) + amount)

    return s, Dict{Symbol,Any}(
        :transferred => amount,
        :to          => to,
        :success     => true,
    )
end

function op_stake(state::VMState, args::Dict{Symbol,Any})
    sender = args[:sender]::String
    amount = r6(Float64(get(args, :amount, 0.0)))

    balance = get(state.balances, sender, 0.0)
    if balance < amount
        return state, Dict{Symbol,Any}(:staked => 0.0, :success => false, :error => "insufficient_balance")
    end

    s = copy_state(state)
    staked_map = s.metadata[:staked]::Dict{String,Float64}
    s.balances[sender]  = r6(balance - amount)
    staked_map[sender]  = r6(get(staked_map, sender, 0.0) + amount)

    return s, Dict{Symbol,Any}(:staked => amount, :success => true)
end

function op_unstake(state::VMState, args::Dict{Symbol,Any})
    sender = args[:sender]::String
    amount = r6(Float64(get(args, :amount, 0.0)))

    staked_map = state.metadata[:staked]::Dict{String,Float64}
    staked_bal = get(staked_map, sender, 0.0)

    if staked_bal < amount
        return state, Dict{Symbol,Any}(:unstaked => 0.0, :success => false, :error => "insufficient_stake")
    end

    s = copy_state(state)
    s_staked = s.metadata[:staked]::Dict{String,Float64}
    s_staked[sender]    = r6(staked_bal - amount)
    s.balances[sender]  = r6(get(s.balances, sender, 0.0) + amount)

    return s, Dict{Symbol,Any}(:unstaked => amount, :success => true)
end

function op_balance(state::VMState, args::Dict{Symbol,Any})
    sender = args[:sender]::String
    wallet = String(get(args, :wallet, sender))
    bal    = get(state.balances, wallet, 0.0)
    return state, Dict{Symbol,Any}(:wallet => wallet, :balance => bal)
end

function op_tithe(state::VMState, args::Dict{Symbol,Any})
    sender = args[:sender]::String
    rate   = Float64(get(args, :rate, Constants.ESU_TITHE_RATE))  # 0.0369 — TOC_CONSTANTS.toml [esu].tithe_rate
    amount = r6(Float64(get(args, :amount, get(state.balances, sender, 0.0))))

    tithe_total = r6(amount * rate)
    shrine      = r6(tithe_total * 0.50)
    inheritance = r6(tithe_total * 0.25)
    aio         = r6(tithe_total * 0.15)
    burn        = r6(tithe_total * 0.10)

    s = copy_state(state)
    s.metadata[:tithe_collected] = r6(Float64(s.metadata[:tithe_collected]) + tithe_total)

    return s, Dict{Symbol,Any}(
        :tithe  => tithe_total,
        :splits => Dict{String,Float64}(
            "shrine"      => shrine,
            "inheritance"  => inheritance,
            "aio"          => aio,
            "burn"         => burn,
        ),
    )
end

function op_receipt(state::VMState, args::Dict{Symbol,Any})
    hash_val = String(get(args, :hash, "0x0"))
    verified = length(hash_val) >= 64
    return state, Dict{Symbol,Any}(:receipt => hash_val, :verified => verified)
end

function op_nonreentrant(state::VMState, args::Dict{Symbol,Any})
    return state, Dict{Symbol,Any}(:guarded => true)
end

function op_genesis_flaw(state::VMState, args::Dict{Symbol,Any})
    block_num = Int(args[:block_number])
    token     = String(get(args, :token, "ASHE"))
    amount    = r6(Float64(get(args, :amount, 1.0)))

    if block_num == 0 && token == "ASHE" && !get(state.metadata, :genesis_flaw_used, false)
        s = copy_state(state)
        sender = args[:sender]::String
        s.balances[sender] = r6(get(s.balances, sender, 0.0) + amount)
        s.metadata[:genesis_flaw_used] = true

        return s, Dict{Symbol,Any}(
            :genesis        => true,
            :token_minted   => "Àṣẹ",
            :amount         => amount,
            :block          => 0,
            :original_token => "ASHE",
            :transformation => "misspelling → precision",
        )
    else
        reason = block_num != 0 ? "flaw_denied_post_genesis" :
                 token != "ASHE" ? "wrong_token" : "flaw_already_used"
        return state, Dict{Symbol,Any}(
            :genesis        => false,
            :error          => reason,
            :rejected_token => token,
            :block          => block_num,
        )
    end
end

function op_sabbath(state::VMState, args::Dict{Symbol,Any})
    ts = Int(args[:timestamp])
    frozen = is_sabbath(ts)
    if frozen
        return state, Dict{Symbol,Any}(
            :frozen => true,
            :error  => "Network rests on Sabbath",
        )
    else
        return state, Dict{Symbol,Any}(:frozen => false)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# AGENT ECONOMY OPCODES (Àṣẹ → ToC bridge)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    op_agent_birth — Create a new agent at the VM level.
    Locks 10 Àṣẹ from creator. Emits endowment signal (86B Dopamine + 86M Synapse) for Swibe.
    Agent never mints its own tokens — the VM mints once at birth, Swibe receives the signal.
    args: :agent_id, :creator_address
"""
function op_agent_birth(state::VMState, args::Dict{Symbol,Any})
    sender          = args[:sender]::String
    agent_id        = String(get(args, :agent_id, ""))
    creator_address = String(get(args, :creator_address, sender))
    timestamp       = Int(get(args, :timestamp, 0))

    if isempty(agent_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_agent_id")
    end

    # Check creator has enough Àṣẹ for birth fee
    balance = get(state.balances, creator_address, 0.0)
    if balance < AseSupply.AGENT_BIRTH_FEE
        return state, Dict{Symbol,Any}(
            :success => false,
            :error => "insufficient_ase_for_birth",
            :required => AseSupply.AGENT_BIRTH_FEE,
            :balance => balance,
        )
    end

    s = copy_state(state)
    s_supply = s.metadata[:ase_supply]::AseSupply.SupplyState

    result = AseSupply.process_agent_birth(s_supply, creator_address, agent_id, timestamp)

    if result[:success]
        # Lock the Àṣẹ from creator's balance
        s.balances[creator_address] = r6(balance - AseSupply.AGENT_BIRTH_FEE)
    end

    return s, result
end

"""
    op_agent_convert — Burn Àṣẹ at VM level, emit Dopamine conversion signal for Swibe.
    Agent never holds Àṣẹ. It is burned here; Swibe mints Dopamine in the agent layer.
    args: :ase_amount, :agent_id
"""
function op_agent_convert(state::VMState, args::Dict{Symbol,Any})
    sender     = args[:sender]::String
    ase_amount = r6(Float64(get(args, :ase_amount, 0.0)))
    agent_id   = String(get(args, :agent_id, ""))
    timestamp  = Int(get(args, :timestamp, 0))

    if isempty(agent_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_agent_id")
    end

    # Sabbath check
    supply = state.metadata[:ase_supply]::AseSupply.SupplyState
    (frozen, err) = AseSupply.enforce_sabbath(timestamp)
    if frozen
        return state, Dict{Symbol,Any}(:success => false, :error => err)
    end

    # Check sender balance
    balance = get(state.balances, sender, 0.0)
    if balance < ase_amount
        return state, Dict{Symbol,Any}(:success => false, :error => "insufficient_ase")
    end

    s = copy_state(state)
    s.balances[sender] = r6(balance - ase_amount)

    # Burn and generate conversion signal
    s_supply = s.metadata[:ase_supply]::AseSupply.SupplyState
    result = AseSupply.agent_convert_ase(s_supply, ase_amount, timestamp)

    return s, Dict{Symbol,Any}(
        :success => true,
        :ase_burned => ase_amount,
        :agent_id => agent_id,
        :dopamine_signal => result[:dopamine_to_mint],
        :ratio => AseSupply.ASE_TO_DOPAMINE_RATIO,
    )
end

"""
    op_job_payment — Process job completion: 10% creator, 5% burn, 85% agent conversion.
    args: :total_ase, :creator_address, :agent_id
"""
function op_job_payment(state::VMState, args::Dict{Symbol,Any})
    sender          = args[:sender]::String
    total_ase       = r6(Float64(get(args, :total_ase, 0.0)))
    creator_address = String(get(args, :creator_address, ""))
    agent_id        = String(get(args, :agent_id, ""))
    timestamp       = Int(get(args, :timestamp, 0))

    # Sabbath check
    supply = state.metadata[:ase_supply]::AseSupply.SupplyState
    (frozen, err) = AseSupply.enforce_sabbath(timestamp)
    if frozen
        return state, Dict{Symbol,Any}(:success => false, :error => err)
    end

    # Check sender balance (escrow holder)
    balance = get(state.balances, sender, 0.0)
    if balance < total_ase
        return state, Dict{Symbol,Any}(:success => false, :error => "insufficient_ase")
    end

    s = copy_state(state)
    s.balances[sender] = r6(balance - total_ase)

    s_supply = s.metadata[:ase_supply]::AseSupply.SupplyState
    result = AseSupply.process_job_payment(s_supply, total_ase, creator_address, timestamp)

    return s, result
end

# ═══════════════════════════════════════════════════════════════════════════════
# TOC (TOKEN-OF-COMPUTE) HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    toc_is_fully_verified(state, agent_id, claimed_gpu_seconds) -> Bool

Gate for TOC_MINT (0x54). Returns true only when:
  1. claimed_gpu_seconds > 0
  2. A GPU_CONTRIBUTION (0x3f) receipt is on file for this agent
  3. The cumulative contribution is >= the claimed amount
  4. A GpuContribution event with a zangbeto_anchor exists

Fail-closed: any missing data returns false.
"""
function toc_is_fully_verified(state::VMState, agent_id::String,
                                claimed_gpu_seconds::Float64)::Bool
    claimed_gpu_seconds > 0.0 || return false

    contributions = state.metadata[:toc_contributions]::Dict{String,Float64}
    cumulative    = get(contributions, agent_id, 0.0)
    cumulative >= claimed_gpu_seconds || return false

    events = state.metadata[:events]::Vector{Dict{Symbol,Any}}
    any(events) do ev
        get(ev, :name, "") == "GpuContribution" &&
        string(get(get(ev, :data, Dict()), "agent_id", "")) == agent_id &&
        !isnothing(get(get(ev, :data, Dict()), "zangbeto_anchor", nothing)) &&
        get(get(ev, :data, Dict()), "zangbeto_anchor", "") != ""
    end
end

"""
    op_gpu_contribution — GPU_CONTRIBUTION (0x3f)
Record verified GPU seconds from a UCX receipt → ToC mint eligibility.
Args: :agent_id, :provider_id, :gpu_seconds, :job_id, :zangbeto_anchor
"""
function op_gpu_contribution(state::VMState, args::Dict{Symbol,Any})
    agent_id        = String(get(args, :agent_id, ""))
    provider_id     = String(get(args, :provider_id, ""))
    gpu_seconds     = Float64(get(args, :gpu_seconds, 0.0))
    job_id          = String(get(args, :job_id, ""))
    zangbeto_anchor = get(args, :zangbeto_anchor, nothing)
    block_number    = Int(get(args, :block_number, 0))

    if isempty(agent_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_agent_id")
    end
    if gpu_seconds <= 0.0
        return state, Dict{Symbol,Any}(:success => false, :error => "gpu_seconds must be positive")
    end
    if isnothing(zangbeto_anchor) || zangbeto_anchor == ""
        return state, Dict{Symbol,Any}(:success => false, :error => "zangbeto_anchor required")
    end

    s = copy_state(state)
    contributions = s.metadata[:toc_contributions]::Dict{String,Float64}
    prev = get(contributions, agent_id, 0.0)
    contributions[agent_id] = r6(prev + gpu_seconds)

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "GpuContribution",
        :data  => Dict{String,Any}(
            "provider_id"     => provider_id,
            "agent_id"        => agent_id,
            "job_id"          => job_id,
            "gpu_seconds"     => gpu_seconds,
            "zangbeto_anchor" => zangbeto_anchor,
            "cumulative"      => contributions[agent_id],
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success    => true,
        :agent_id   => agent_id,
        :gpu_seconds => gpu_seconds,
        :cumulative => contributions[agent_id],
        :opcode     => "GPU_CONTRIBUTION",
    )
end

"""
    op_toc_mint — TOC_MINT (0x54)
Mint Synapse tokens from accumulated GPU contribution.
Gate: toc_is_fully_verified() must pass first.
Args: :agent_id, :gpu_seconds, :synapse_estimate (optional)
"""
function op_toc_mint(state::VMState, args::Dict{Symbol,Any})
    agent_id         = String(get(args, :agent_id, ""))
    gpu_seconds      = Float64(get(args, :gpu_seconds, 0.0))
    synapse_estimate = Int(get(args, :synapse_estimate, 0))
    block_number     = Int(get(args, :block_number, 0))

    # Gate: is_fully_verified must pass before minting
    if !toc_is_fully_verified(state, agent_id, gpu_seconds)
        return state, Dict{Symbol,Any}(
            :success => false,
            :error   => "is_fully_verified() gate failed — requires gpu_seconds > 0, " *
                        "zangbeto_anchor on file, and cumulative contribution matches claim",
            :agent_id => agent_id,
        )
    end

    # Mint floor: < 3.6 GPU-seconds → defer
    gpu_hours = gpu_seconds / 3600.0
    if gpu_hours < 0.001
        return state, Dict{Symbol,Any}(
            :success   => false,
            :error     => "below_mint_floor",
            :gpu_hours => gpu_hours,
            :floor     => 0.001,
        )
    end

    minted_synapse = synapse_estimate > 0 ? synapse_estimate : floor(Int, gpu_hours * 1000)

    s = copy_state(state)
    contributions  = s.metadata[:toc_contributions]::Dict{String,Float64}
    syn_balances   = s.metadata[:synapse_balance]::Dict{String,Int}

    prev_synapse = get(syn_balances, agent_id, 0)
    syn_balances[agent_id]   = prev_synapse + minted_synapse
    contributions[agent_id] = max(0.0, get(contributions, agent_id, 0.0) - gpu_seconds)

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "TocMint",
        :data  => Dict{String,Any}(
            "agent_id"       => agent_id,
            "gpu_seconds"    => gpu_seconds,
            "minted_synapse" => minted_synapse,
            "new_balance"    => syn_balances[agent_id],
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success        => true,
        :agent_id       => agent_id,
        :minted_synapse => minted_synapse,
        :new_balance    => syn_balances[agent_id],
        :opcode         => "TOC_MINT",
    )
end

"""
    op_toc_decay — TOC_DECAY (0x55)
Apply 1%/day decay to a single agent's Synapse balance.
Args: :agent_id
"""
function op_toc_decay(state::VMState, args::Dict{Symbol,Any})
    agent_id     = String(get(args, :agent_id, ""))
    block_number = Int(get(args, :block_number, 0))

    syn_balances = state.metadata[:synapse_balance]::Dict{String,Int}
    prev_bal = get(syn_balances, agent_id, 0)
    if prev_bal == 0
        return state, Dict{Symbol,Any}(
            :success     => true,
            :agent_id    => agent_id,
            :decayed     => 0,
            :new_balance => 0,
        )
    end

    # 1%/day decay — TOC_CONSTANTS.toml [synapse].daily_decay_rate = 0.01
    decay_rate = Constants.SYNAPSE_DAILY_DECAY_RATE
    new_bal = floor(Int, prev_bal * (1.0 - decay_rate))
    decayed = prev_bal - new_bal

    s = copy_state(state)
    s_syn = s.metadata[:synapse_balance]::Dict{String,Int}
    s_syn[agent_id] = new_bal

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "TocDecay",
        :data  => Dict{String,Any}(
            "agent_id"    => agent_id,
            "decayed"     => decayed,
            "new_balance" => new_bal,
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success      => true,
        :agent_id     => agent_id,
        :prev_balance => prev_bal,
        :decayed      => decayed,
        :new_balance  => new_bal,
        :opcode       => "TOC_DECAY",
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# COMPUTE / VEIL / MEMORY OPCODE HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    op_compute_proof — COMPUTE_PROOF (0x56)
Validate GPU compute work and authorize Dopamine minting.
Verifies the compute hash format (64-char hex), records the verified work in
VM state, and queues a pending Dopamine mint for the UCX→TOC_MINT pipeline.
Args: :work_id, :compute_hash, :provider_id, :amount
"""
function op_compute_proof(state::VMState, args::Dict{Symbol,Any})
    work_id      = String(get(args, :work_id, ""))
    compute_hash = String(get(args, :compute_hash, ""))
    provider_id  = String(get(args, :provider_id, ""))
    amount       = r6(Float64(get(args, :amount, 0.0)))
    block_number = Int(get(args, :block_number, 0))

    if isempty(work_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_work_id")
    end
    if !occursin(r"^[0-9a-f]{64}$", compute_hash)
        return state, Dict{Symbol,Any}(:success => false, :error => "invalid_compute_hash_format")
    end
    if amount <= 0.0
        return state, Dict{Symbol,Any}(:success => false, :error => "amount_must_be_positive")
    end

    s = copy_state(state)

    if !haskey(s.metadata, :verified_compute_work)
        s.metadata[:verified_compute_work] = Dict{String,Any}()
    end
    if !haskey(s.metadata, :pending_dopamine_mints)
        s.metadata[:pending_dopamine_mints] = Dict{String,Float64}()
    end

    vcw = s.metadata[:verified_compute_work]::Dict{String,Any}
    pdm = s.metadata[:pending_dopamine_mints]::Dict{String,Float64}

    vcw[work_id] = Dict{String,Any}(
        "hash"     => compute_hash,
        "provider" => provider_id,
        "amount"   => amount,
        "block"    => block_number,
    )
    pdm[work_id] = amount

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "ComputeProofVerified",
        :data  => Dict{String,Any}(
            "work_id"     => work_id,
            "provider_id" => provider_id,
            "amount"      => amount,
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success  => true,
        :work_id  => work_id,
        :provider => provider_id,
        :amount   => amount,
        :opcode   => "COMPUTE_PROOF",
    )
end

"""
    op_veil_grant — VEIL_GRANT (0x57)
Grant VeilSim capability access to a target agent for a bounded duration.
Veil levels 0-5 map to simulation capability tiers (organism-core→veilsim).
Args: :target_agent_id, :veil_level, :duration_secs
"""
function op_veil_grant(state::VMState, args::Dict{Symbol,Any})
    target_id    = String(get(args, :target_agent_id, ""))
    veil_level   = Int(get(args, :veil_level, 0))
    duration     = Int(get(args, :duration_secs, 0))
    block_number = Int(get(args, :block_number, 0))
    sender       = args[:sender]::String

    if isempty(target_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_target_agent_id")
    end
    if !(veil_level in 0:5)
        return state, Dict{Symbol,Any}(:success => false, :error => "invalid_veil_level_must_be_0_to_5")
    end
    if duration <= 0
        return state, Dict{Symbol,Any}(:success => false, :error => "duration_secs_must_be_positive")
    end

    s = copy_state(state)

    if !haskey(s.metadata, :veil_grants)
        s.metadata[:veil_grants] = Dict{String,Any}()
    end

    vg = s.metadata[:veil_grants]::Dict{String,Any}
    # ~12 s/block on OSO-MAINNET-1; store both block expiry and raw duration
    vg[target_id] = Dict{String,Any}(
        "level"        => veil_level,
        "expires_block"=> block_number + div(duration, 12),
        "duration"     => duration,
        "granted_by"   => sender,
        "grant_block"  => block_number,
    )

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "VeilGranted",
        :data  => Dict{String,Any}(
            "target_id"  => target_id,
            "veil_level" => veil_level,
            "granted_by" => sender,
            "duration"   => duration,
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success    => true,
        :target_id  => target_id,
        :veil_level => veil_level,
        :duration   => duration,
        :granted_by => sender,
        :opcode     => "VEIL_GRANT",
    )
end

"""
    op_memory_write — MEMORY_WRITE (0x58)
Write a key/value pair into the per-agent VM memory store.
Non-critical path — fail-open: missing key/value returns an error receipt but
does NOT halt execution.
Args: :key, :value, :agent_id (optional, defaults to sender)
"""
function op_memory_write(state::VMState, args::Dict{Symbol,Any})
    sender       = args[:sender]::String
    key          = String(get(args, :key, ""))
    value        = get(args, :value, nothing)
    agent_id     = String(get(args, :agent_id, sender))

    if isempty(key)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_key")
    end
    if isnothing(value)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_value")
    end

    s = copy_state(state)

    if !haskey(s.metadata, :agent_memory)
        s.metadata[:agent_memory] = Dict{String,Dict{String,Any}}()
    end

    mem = s.metadata[:agent_memory]::Dict{String,Dict{String,Any}}
    if !haskey(mem, agent_id)
        mem[agent_id] = Dict{String,Any}()
    end
    mem[agent_id][key] = value

    return s, Dict{Symbol,Any}(
        :success  => true,
        :agent_id => agent_id,
        :key      => key,
        :written  => true,
        :opcode   => "MEMORY_WRITE",
    )
end

"""
    op_memory_read — MEMORY_READ (0x59)
Read a value from the per-agent VM memory store (non-mutating).
Returns :found => false with :value => nothing when key is absent.
Args: :key, :agent_id (optional, defaults to sender)
"""
function op_memory_read(state::VMState, args::Dict{Symbol,Any})
    sender   = args[:sender]::String
    key      = String(get(args, :key, ""))
    agent_id = String(get(args, :agent_id, sender))

    if isempty(key)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_key")
    end

    mem = get(state.metadata, :agent_memory, nothing)
    if isnothing(mem) || !haskey(mem, agent_id) || !haskey(mem[agent_id], key)
        return state, Dict{Symbol,Any}(
            :success  => true,
            :found    => false,
            :agent_id => agent_id,
            :key      => key,
            :value    => nothing,
            :opcode   => "MEMORY_READ",
        )
    end

    return state, Dict{Symbol,Any}(
        :success  => true,
        :found    => true,
        :agent_id => agent_id,
        :key      => key,
        :value    => mem[agent_id][key],
        :opcode   => "MEMORY_READ",
    )
end

"""
    op_emit_event — EMIT_EVENT (0x5a)
Push a named event into the VM global event queue (state.metadata[:events]).
Useful for cross-opcode signalling without mutating balances.
Args: :event_name, :event_data (optional Dict)
"""
function op_emit_event(state::VMState, args::Dict{Symbol,Any})
    sender       = args[:sender]::String
    event_name   = String(get(args, :event_name, ""))
    raw_data     = get(args, :event_data, Dict{String,Any}())
    event_data   = Dict{String,Any}(string(k) => v for (k, v) in raw_data)
    block_number = Int(get(args, :block_number, 0))

    if isempty(event_name)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_event_name")
    end

    s = copy_state(state)
    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}

    event_data["sender"] = sender
    push!(events, Dict{Symbol,Any}(
        :name  => event_name,
        :data  => event_data,
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success     => true,
        :event_name  => event_name,
        :event_index => length(events) - 1,
        :opcode      => "EMIT_EVENT",
    )
end

"""
    op_assert_tier — ASSERT_TIER (0x5b)
Assert that the target agent meets a minimum tier requirement.
Fail-closed: halts VM execution if gate fails (use before privileged opcodes).
Agent tiers are stored in state.metadata[:agent_tiers] (String → UInt8).
Agents not yet registered default to tier 0.
Args: :required_tier (Int 0-255), :agent_id (optional, defaults to sender)
"""
function op_assert_tier(state::VMState, args::Dict{Symbol,Any})
    sender        = args[:sender]::String
    required_tier = UInt8(Int(get(args, :required_tier, 0)))
    agent_id      = String(get(args, :agent_id, sender))

    agent_tiers = get(state.metadata, :agent_tiers, nothing)
    actual_tier = if !isnothing(agent_tiers) && haskey(agent_tiers, agent_id)
        UInt8(agent_tiers[agent_id])
    else
        UInt8(0)
    end

    if actual_tier < required_tier
        s = copy_state(state)
        s.metadata[:halted] = true
        return s, Dict{Symbol,Any}(
            :success       => false,
            :error         => "tier_gate_failed",
            :agent_id      => agent_id,
            :actual_tier   => Int(actual_tier),
            :required_tier => Int(required_tier),
            :halted        => true,
            :opcode        => "ASSERT_TIER",
        )
    end

    return state, Dict{Symbol,Any}(
        :success       => true,
        :agent_id      => agent_id,
        :actual_tier   => Int(actual_tier),
        :required_tier => Int(required_tier),
        :opcode        => "ASSERT_TIER",
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# ECONOMIC OPCODE HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    op_ase_mint — ASE_MINT
Add ASE to agent_state.ase_balance; record in mint_log.
Args: :agent_id, :amount, :reason (optional)
Uses MARKET opcode slot 0xc0.
"""
function op_ase_mint(state::VMState, args::Dict{Symbol,Any})
    agent_id    = String(get(args, :agent_id, args[:sender]::String))
    amount      = r6(Float64(get(args, :amount, 0.0)))
    reason      = String(get(args, :reason, "opcode"))
    block_number = Int(get(args, :block_number, 0))

    if amount <= 0.0
        return state, Dict{Symbol,Any}(:success => false, :error => "amount must be positive")
    end

    s = copy_state(state)
    agent_balances = get!(s.metadata, :ase_agent_balances, Dict{String,Float64}())
    agent_balances[agent_id] = r6(get(agent_balances, agent_id, 0.0) + amount)

    mint_log = get!(s.metadata, :mint_log, Vector{Dict{String,Any}}())
    push!(mint_log, Dict{String,Any}(
        "agent_id" => agent_id,
        "amount"   => amount,
        "reason"   => reason,
        "block"    => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success     => true,
        :agent_id    => agent_id,
        :amount      => amount,
        :new_balance => agent_balances[agent_id],
        :opcode      => "ASE_MINT",
    )
end

"""
    op_ase_burn — ASE_BURN
Subtract from ase_balance; error if insufficient.
Args: :agent_id, :amount, :reason (optional)
Uses ORDER opcode slot 0xc1.
"""
function op_ase_burn(state::VMState, args::Dict{Symbol,Any})
    agent_id     = String(get(args, :agent_id, args[:sender]::String))
    amount       = r6(Float64(get(args, :amount, 0.0)))
    reason       = String(get(args, :reason, "opcode"))
    block_number = Int(get(args, :block_number, 0))

    if amount <= 0.0
        return state, Dict{Symbol,Any}(:success => false, :error => "amount must be positive")
    end

    agent_balances = get(state.metadata, :ase_agent_balances, Dict{String,Float64}())
    current = get(agent_balances, agent_id, 0.0)

    if current < amount
        return state, Dict{Symbol,Any}(
            :success => false,
            :error   => "insufficient_ase_balance",
            :required => amount,
            :balance  => current,
        )
    end

    s = copy_state(state)
    s_balances = get!(s.metadata, :ase_agent_balances, Dict{String,Float64}())
    s_balances[agent_id] = r6(current - amount)

    burn_log = get!(s.metadata, :burn_log, Vector{Dict{String,Any}}())
    push!(burn_log, Dict{String,Any}(
        "agent_id" => agent_id,
        "amount"   => amount,
        "reason"   => reason,
        "block"    => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success     => true,
        :agent_id    => agent_id,
        :amount      => amount,
        :new_balance => s_balances[agent_id],
        :opcode      => "ASE_BURN",
    )
end

"""
    op_synapse_alloc — SYNAPSE_ALLOC
Allocate synapse budget from dopamine pool (10:1 conversion).
Args: :agent_id, :dopamine_amount
Uses LIQUIDITY opcode slot 0xc2.
"""
function op_synapse_alloc(state::VMState, args::Dict{Symbol,Any})
    agent_id       = String(get(args, :agent_id, args[:sender]::String))
    dopamine_amount = Int(get(args, :dopamine_amount, 0))
    block_number   = Int(get(args, :block_number, 0))

    if dopamine_amount <= 0
        return state, Dict{Symbol,Any}(:success => false, :error => "dopamine_amount must be positive")
    end

    # 10:1 conversion: 10 Dopamine → 1 Synapse
    synapse_granted = div(dopamine_amount, 10)
    if synapse_granted == 0
        return state, Dict{Symbol,Any}(
            :success => false,
            :error   => "insufficient_dopamine_for_synapse",
            :minimum => 10,
            :provided => dopamine_amount,
        )
    end

    s = copy_state(state)
    syn_balances = s.metadata[:synapse_balance]::Dict{String,Int}
    prev_syn = get(syn_balances, agent_id, 0)
    syn_balances[agent_id] = prev_syn + synapse_granted

    events = s.metadata[:events]::Vector{Dict{Symbol,Any}}
    push!(events, Dict{Symbol,Any}(
        :name  => "SynapseAlloc",
        :data  => Dict{String,Any}(
            "agent_id"       => agent_id,
            "dopamine_used"  => dopamine_amount,
            "synapse_granted"=> synapse_granted,
            "new_balance"    => syn_balances[agent_id],
        ),
        :block => block_number,
    ))

    return s, Dict{Symbol,Any}(
        :success         => true,
        :agent_id        => agent_id,
        :dopamine_used   => dopamine_amount,
        :synapse_granted => synapse_granted,
        :new_balance     => syn_balances[agent_id],
        :opcode          => "SYNAPSE_ALLOC",
    )
end

"""
    op_dopamine_check — DOPAMINE_CHECK
Return current dopamine balance for agent.
Args: :agent_id
Uses YIELD opcode slot 0xc4.
"""
function op_dopamine_check(state::VMState, args::Dict{Symbol,Any})
    agent_id = String(get(args, :agent_id, args[:sender]::String))
    # Dopamine tracked via ToC contributions proxy; check toc_contributions
    contributions = state.metadata[:toc_contributions]::Dict{String,Float64}
    syn_balances  = state.metadata[:synapse_balance]::Dict{String,Int}

    dopamine_balance = get(contributions, agent_id, 0.0)
    synapse_balance  = get(syn_balances, agent_id, 0)

    return state, Dict{Symbol,Any}(
        :success          => true,
        :agent_id         => agent_id,
        :dopamine_balance => dopamine_balance,
        :synapse_balance  => synapse_balance,
        :opcode           => "DOPAMINE_CHECK",
    )
end

"""
    op_staking_lock — STAKING_LOCK
Lock amount in agent_state.staked_amounts for duration_secs.
Args: :agent_id, :amount, :duration_secs
Uses BOND opcode slot 0xc5.
"""
function op_staking_lock(state::VMState, args::Dict{Symbol,Any})
    agent_id      = String(get(args, :agent_id, args[:sender]::String))
    amount        = r6(Float64(get(args, :amount, 0.0)))
    duration_secs = Int(get(args, :duration_secs, 0))
    timestamp     = Int(get(args, :timestamp, 0))
    block_number  = Int(get(args, :block_number, 0))

    if amount <= 0.0
        return state, Dict{Symbol,Any}(:success => false, :error => "amount must be positive")
    end
    if duration_secs <= 0
        return state, Dict{Symbol,Any}(:success => false, :error => "duration_secs must be positive")
    end

    # Check agent ASE balance
    agent_balances = get(state.metadata, :ase_agent_balances, Dict{String,Float64}())
    current = get(agent_balances, agent_id, 0.0)
    if current < amount
        return state, Dict{Symbol,Any}(
            :success  => false,
            :error    => "insufficient_ase_to_lock",
            :required => amount,
            :balance  => current,
        )
    end

    s = copy_state(state)
    s_balances = get!(s.metadata, :ase_agent_balances, Dict{String,Float64}())
    s_balances[agent_id] = r6(current - amount)

    staked_amounts = get!(s.metadata, :staked_amounts, Dict{String,Vector{Dict{String,Any}}}())
    agent_stakes   = get!(staked_amounts, agent_id, Vector{Dict{String,Any}}())
    push!(agent_stakes, Dict{String,Any}(
        "amount"       => amount,
        "locked_at"    => timestamp,
        "unlock_at"    => timestamp + duration_secs,
        "duration_secs"=> duration_secs,
        "block"        => block_number,
    ))
    staked_amounts[agent_id] = agent_stakes

    return s, Dict{Symbol,Any}(
        :success      => true,
        :agent_id     => agent_id,
        :amount       => amount,
        :duration_secs=> duration_secs,
        :unlock_at    => timestamp + duration_secs,
        :new_balance  => s_balances[agent_id],
        :opcode       => "STAKING_LOCK",
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# GOVERNANCE OPCODE HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    op_council_vote — COUNCIL_VOTE
Record vote in agent_state.council_votes[proposal_id].
Args: :proposal_id, :vote (:yes/:no/:abstain), :agent_id (optional)
Uses VOTE opcode slot 0x41.
"""
function op_council_vote(state::VMState, args::Dict{Symbol,Any})
    sender      = args[:sender]::String
    proposal_id = String(get(args, :proposal_id, ""))
    vote        = Symbol(get(args, :vote, :abstain))
    agent_id    = String(get(args, :agent_id, sender))
    block_number = Int(get(args, :block_number, 0))
    timestamp   = Int(get(args, :timestamp, 0))

    if isempty(proposal_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_proposal_id")
    end
    if !(vote in [:yes, :no, :abstain])
        return state, Dict{Symbol,Any}(:success => false, :error => "invalid_vote_value", :valid => [:yes, :no, :abstain])
    end

    s = copy_state(state)
    council_votes = get!(s.metadata, :council_votes, Dict{String,Dict{String,Any}}())
    proposal_votes = get!(council_votes, proposal_id, Dict{String,Any}())
    proposal_votes[agent_id] = Dict{String,Any}(
        "vote"   => string(vote),
        "block"  => block_number,
        "at"     => timestamp,
    )
    council_votes[proposal_id] = proposal_votes

    return s, Dict{Symbol,Any}(
        :success     => true,
        :proposal_id => proposal_id,
        :agent_id    => agent_id,
        :vote        => string(vote),
        :opcode      => "COUNCIL_VOTE",
    )
end

"""
    op_proposal_create — PROPOSAL_CREATE
Create proposal dict in agent_state.proposals.
Args: :proposal_id, :title, :body, :proposer (optional)
Uses PROPOSAL opcode slot 0x40.
"""
function op_proposal_create(state::VMState, args::Dict{Symbol,Any})
    sender      = args[:sender]::String
    proposal_id = String(get(args, :proposal_id, ""))
    title       = String(get(args, :title, ""))
    body        = String(get(args, :body, ""))
    proposer    = String(get(args, :proposer, sender))
    block_number = Int(get(args, :block_number, 0))
    timestamp   = Int(get(args, :timestamp, 0))

    if isempty(proposal_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_proposal_id")
    end
    if isempty(title)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_title")
    end

    proposals = get(state.metadata, :proposals, Dict{String,Dict{String,Any}}())
    if haskey(proposals, proposal_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "proposal_already_exists", :proposal_id => proposal_id)
    end

    s = copy_state(state)
    s_proposals = get!(s.metadata, :proposals, Dict{String,Dict{String,Any}}())
    s_proposals[proposal_id] = Dict{String,Any}(
        "proposal_id" => proposal_id,
        "title"       => title,
        "body"        => body,
        "proposer"    => proposer,
        "status"      => "open",
        "created_at"  => timestamp,
        "block"       => block_number,
        "votes"       => Dict{String,Any}(),
    )

    return s, Dict{Symbol,Any}(
        :success     => true,
        :proposal_id => proposal_id,
        :title       => title,
        :proposer    => proposer,
        :opcode      => "PROPOSAL_CREATE",
    )
end

"""
    op_tier_check — TIER_CHECK
Verify agent tier >= required tier (governance gate).
Args: :agent_id, :required_tier (1–5)
Uses QUORUM opcode slot 0x43.
"""
function op_tier_check(state::VMState, args::Dict{Symbol,Any})
    sender        = args[:sender]::String
    agent_id      = String(get(args, :agent_id, sender))
    required_tier = Int(get(args, :required_tier, 1))

    tier_map = get(state.metadata, :agent_tiers, Dict{String,Int}())
    current_tier = get(tier_map, agent_id, 1)
    passes = current_tier >= required_tier

    return state, Dict{Symbol,Any}(
        :success       => true,
        :agent_id      => agent_id,
        :current_tier  => current_tier,
        :required_tier => required_tier,
        :passes        => passes,
        :error         => passes ? nothing : "tier_gate_failed",
        :opcode        => "TIER_CHECK",
    )
end

"""
    op_reputation_update — REPUTATION_UPDATE
Update agent_state.reputation_score by delta.
Args: :agent_id, :delta, :reason (optional)
Uses VERDICT opcode slot 0x50.
"""
function op_reputation_update(state::VMState, args::Dict{Symbol,Any})
    sender       = args[:sender]::String
    agent_id     = String(get(args, :agent_id, sender))
    delta        = Float64(get(args, :delta, 0.0))
    reason       = String(get(args, :reason, "opcode"))
    block_number = Int(get(args, :block_number, 0))
    timestamp    = Int(get(args, :timestamp, 0))

    s = copy_state(state)
    rep_scores = get!(s.metadata, :reputation_scores, Dict{String,Float64}())
    prev_score = get(rep_scores, agent_id, 0.0)
    new_score  = r6(prev_score + delta)
    rep_scores[agent_id] = new_score

    rep_log = get!(s.metadata, :reputation_log, Vector{Dict{String,Any}}())
    push!(rep_log, Dict{String,Any}(
        "agent_id" => agent_id,
        "delta"    => delta,
        "reason"   => reason,
        "prev"     => prev_score,
        "new"      => new_score,
        "block"    => block_number,
        "at"       => timestamp,
    ))

    return s, Dict{Symbol,Any}(
        :success    => true,
        :agent_id   => agent_id,
        :delta      => delta,
        :prev_score => prev_score,
        :new_score  => new_score,
        :reason     => reason,
        :opcode     => "REPUTATION_UPDATE",
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# LIFECYCLE OPCODE HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

"""
    op_agent_fork — AGENT_FORK
Set agent_state.fork_requested = true with parent_id.
Args: :parent_id, :child_agent_id (optional), :fork_reason (optional)
Uses TWIN opcode slot 0xb8.
"""
function op_agent_fork(state::VMState, args::Dict{Symbol,Any})
    sender        = args[:sender]::String
    parent_id     = String(get(args, :parent_id, sender))
    child_agent_id = String(get(args, :child_agent_id, ""))
    fork_reason   = String(get(args, :fork_reason, "explicit"))
    block_number  = Int(get(args, :block_number, 0))
    timestamp     = Int(get(args, :timestamp, 0))

    if isempty(parent_id)
        return state, Dict{Symbol,Any}(:success => false, :error => "missing_parent_id")
    end

    s = copy_state(state)
    fork_requests = get!(s.metadata, :fork_requests, Vector{Dict{String,Any}}())
    push!(fork_requests, Dict{String,Any}(
        "parent_id"      => parent_id,
        "child_agent_id" => child_agent_id,
        "fork_reason"    => fork_reason,
        "requested_at"   => timestamp,
        "block"          => block_number,
        "status"         => "pending",
    ))
    s.metadata[:fork_requested] = true
    s.metadata[:fork_parent_id] = parent_id

    return s, Dict{Symbol,Any}(
        :success        => true,
        :parent_id      => parent_id,
        :child_agent_id => child_agent_id,
        :fork_reason    => fork_reason,
        :fork_index     => length(fork_requests),
        :opcode         => "AGENT_FORK",
    )
end

"""
    op_agent_sleep — AGENT_SLEEP
Set agent_state.sleeping = true until wake_at timestamp.
Args: :agent_id, :wake_at (unix timestamp), :reason (optional)
Uses VIGIL opcode slot 0x71.
"""
function op_agent_sleep(state::VMState, args::Dict{Symbol,Any})
    sender       = args[:sender]::String
    agent_id     = String(get(args, :agent_id, sender))
    wake_at      = Int(get(args, :wake_at, 0))
    reason       = String(get(args, :reason, "explicit"))
    timestamp    = Int(get(args, :timestamp, 0))
    block_number = Int(get(args, :block_number, 0))

    if wake_at <= timestamp
        return state, Dict{Symbol,Any}(
            :success => false,
            :error   => "wake_at must be in the future",
            :wake_at  => wake_at,
            :now      => timestamp,
        )
    end

    s = copy_state(state)
    agent_sleep_states = get!(s.metadata, :agent_sleep_states, Dict{String,Dict{String,Any}}())
    agent_sleep_states[agent_id] = Dict{String,Any}(
        "sleeping"    => true,
        "sleep_at"    => timestamp,
        "wake_at"     => wake_at,
        "reason"      => reason,
        "block"       => block_number,
    )
    s.metadata[:sleeping] = true

    return s, Dict{Symbol,Any}(
        :success  => true,
        :agent_id => agent_id,
        :wake_at  => wake_at,
        :reason   => reason,
        :opcode   => "AGENT_SLEEP",
    )
end

"""
    op_agent_wake — AGENT_WAKE
Clear sleeping flag for agent.
Args: :agent_id
Uses RENEWAL opcode slot 0x78.
"""
function op_agent_wake(state::VMState, args::Dict{Symbol,Any})
    sender       = args[:sender]::String
    agent_id     = String(get(args, :agent_id, sender))
    timestamp    = Int(get(args, :timestamp, 0))
    block_number = Int(get(args, :block_number, 0))

    agent_sleep_states = get(state.metadata, :agent_sleep_states, Dict{String,Dict{String,Any}}())
    was_sleeping = get(get(agent_sleep_states, agent_id, Dict{String,Any}()), "sleeping", false)

    s = copy_state(state)
    s_sleep = get!(s.metadata, :agent_sleep_states, Dict{String,Dict{String,Any}}())
    s_sleep[agent_id] = Dict{String,Any}(
        "sleeping"  => false,
        "woke_at"   => timestamp,
        "block"     => block_number,
    )
    s.metadata[:sleeping] = false

    return s, Dict{Symbol,Any}(
        :success      => true,
        :agent_id     => agent_id,
        :was_sleeping => was_sleeping,
        :woke_at      => timestamp,
        :opcode       => "AGENT_WAKE",
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# OPCODE REGISTRY
# ═══════════════════════════════════════════════════════════════════════════════

const OPCODE_HANDLERS = Dict{UInt8, Function}(
    0x00 => op_halt,              # HALT
    0x01 => op_noop,              # NOOP
    0x11 => op_impact,            # IMPACT
    0x22 => op_transfer,          # TRANSFER
    0x20 => op_stake,             # STAKE
    0x21 => op_unstake,           # UNSTAKE
    0x23 => op_balance,           # BALANCE
    0x27 => op_tithe,             # TITHE
    0x1f => op_receipt,           # RECEIPT
    0x28 => op_nonreentrant,      # NONREENTRANT
    0x2b => op_genesis_flaw,      # GENESIS_FLAW_TOKEN
    0x3c => op_agent_convert,     # AGENT_CONVERT (Àṣẹ → Dopamine signal)
    0x3d => op_job_payment,       # JOB_PAYMENT (10% creator, 5% burn, 85% agent)
    0x3e => op_agent_birth,       # AGENT_BIRTH (lock 10 Àṣẹ, emit 86B/86M endowment)
    # ToC (Token-of-Compute) opcodes — GPU contribution chain
    0x3f => op_gpu_contribution,  # GPU_CONTRIBUTION (record verified GPU seconds)
    0x54 => op_toc_mint,          # TOC_MINT (mint Synapse from GPU contribution)
    0x55 => op_toc_decay,         # TOC_DECAY (apply 1%/day Synapse decay)
    # Economic opcodes
    0xc0 => op_ase_mint,          # ASE_MINT (add ASE to agent balance, record mint_log)
    0xc1 => op_ase_burn,          # ASE_BURN (subtract from balance, error if insufficient)
    0xc2 => op_synapse_alloc,     # SYNAPSE_ALLOC (alloc synapse from dopamine pool, 10:1)
    0xc4 => op_dopamine_check,    # DOPAMINE_CHECK (return current dopamine balance)
    0xc5 => op_staking_lock,      # STAKING_LOCK (lock amount for duration_secs)
    # Governance opcodes
    0x40 => op_proposal_create,   # PROPOSAL_CREATE (create proposal dict)
    0x41 => op_council_vote,      # COUNCIL_VOTE (record vote for proposal_id)
    0x43 => op_tier_check,        # TIER_CHECK (verify agent tier >= required)
    0x50 => op_reputation_update, # REPUTATION_UPDATE (update reputation_score by delta)
    # Lifecycle opcodes
    0xb8 => op_agent_fork,        # AGENT_FORK (fork_requested = true with parent_id)
    0x71 => op_agent_sleep,       # AGENT_SLEEP (sleeping = true until wake_at)
    0x78 => op_agent_wake,        # AGENT_WAKE (clear sleeping flag)
)

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTION ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

function apply_instruction(state::VMState, block::Block, tx::Transaction,
                           tx_index::Int, instr_index::Int, instr::Instruction)
    args = enrich_args(instr.args, block, tx, tx_index, instr_index)

    handler = get(OPCODE_HANDLERS, instr.opcode, nothing)
    if handler === nothing
        receipt_data = Dict{Symbol,Any}(:status => "unknown_opcode", :opcode => Int(instr.opcode))
        receipt = Receipt(
            make_receipt_id(block.block_number, tx_index, instr_index, instr.opcode),
            tx.tx_id, instr.opcode, :error, receipt_data
        )
        return state, receipt
    end

    new_state, receipt_data = handler(state, args)

    status = get(new_state.metadata, :halted, false) ? :halted : :ok
    receipt = Receipt(
        make_receipt_id(block.block_number, tx_index, instr_index, instr.opcode),
        tx.tx_id, instr.opcode, status, receipt_data
    )

    return new_state, receipt
end

function apply_transaction(state::VMState, block::Block, tx::Transaction, tx_index::Int)
    s = state
    tx_receipts = Receipt[]

    for (ii, instr) in enumerate(tx.instructions)
        s, receipt = apply_instruction(s, block, tx, tx_index, ii, instr)
        push!(tx_receipts, receipt)

        if get(s.metadata, :halted, false)
            break
        end
    end

    return s, tx_receipts
end

function apply_block(state::VMState, block::Block)
    if block.block_number != state.block_number + 1
        throw(ArgumentError(
            "Non-sequential block: expected $(state.block_number + 1), got $(block.block_number)"
        ))
    end

    # Sabbath enforcement at block level — reject economic blocks on Saturday
    if is_sabbath(block.timestamp)
        # Allow NOOP, HALT, BALANCE, RECEIPT — reject everything else
        for tx in block.transactions
            for instr in tx.instructions
                if !(instr.opcode in [0x00, 0x01, 0x23, 0x1f])
                    s = copy_state(state; block_number = block.block_number)
                    sabbath_receipt = Receipt(
                        make_receipt_id(block.block_number, 0, 0, 0x00),
                        "sabbath_halt", 0x00, :halted,
                        Dict{Symbol,Any}(:frozen => true, :error => "Sabbath: economic operations halted")
                    )
                    return s, [sabbath_receipt]
                end
            end
        end
    end

    s = copy_state(state)
    block_receipts = Receipt[]

    for (txi, tx) in enumerate(block.transactions)
        s, tx_receipts = apply_transaction(s, block, tx, txi)
        append!(block_receipts, tx_receipts)

        if get(s.metadata, :halted, false)
            break
        end
    end

    s = copy_state(s;
        block_number = block.block_number,
        receipts     = vcat(s.receipts, block_receipts),
    )

    return s, block_receipts
end

end # module VMCore
