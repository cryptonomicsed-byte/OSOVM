# vm_core.jl — Ọ̀ṢỌ́VM Hardened Deterministic Core
# Pure state transitions. No randomness. No system time. No global mutation.
# Bínò ÈL Guà — Crown Architect
# Ọbàtálá — Master Auditor

module VMCore

include("opcodes.jl")
include("oso_compiler.jl")
include("ase_supply.jl")

using .Opcodes
using .OsoCompiler: Instruction, IR
using .AseSupply

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
    tithe_rate = 0.0369
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
    rate   = Float64(get(args, :rate, 0.0369))
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

    new_bal = floor(Int, prev_bal * 0.99)
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
