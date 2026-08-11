# oso_vm.jl — Ọ̀ṢỌ́ Virtual Machine
# Executes IR by dispatching to multi-language FFI backends
# Holy Trinity: Go (network), Julia (math), Rust (safety), Move (resources), Idris (proof)

module OsoVM

include("opcodes.jl")
include("oso_compiler.jl")

using .Opcodes
using .OsoCompiler

export execute_ir, VMState, create_vm

# Inheritance Wallet States
@enum WalletState begin
    OPEN = 1           # Available for claim
    PENDING = 2        # Candidate applied, awaiting council
    COUNCIL_READY = 3  # 12/12 council approval
    AWARDED = 4        # Bínò signed, inheritance transferred
end

# Individual Inheritance Wallet (1 of 1440)
mutable struct InheritanceWallet
    wallet_id::UInt16                        # 0-1439
    state::WalletState                       # Current state
    pending::String                          # Candidate shrine address
    approvals_mask::UInt16                   # Bitmask: 12 council votes
    next_eligible_ts::Int                    # Timestamp when 7 years passed
    winner::String                           # Final shrine that inherited
end

# Staking Vault (11.11% eternal lock per wallet)
mutable struct StakingVault
    locked_balance::Float64                  # Principal (11.11% locked)
    staked_since::Int                        # Timestamp of first stake
    last_claimed::Int                        # Last reward claim
    accrued_rewards::Float64                 # Pending 11.11% APY rewards
end

# VM State
mutable struct VMState
    ase_balance::Dict{String, Float64}       # Wallet → Aṣẹ balance
    staked::Dict{String, Float64}            # Wallet → Staked Aṣẹ
    receipts::Vector{String}                 # Immutable receipt hashes
    events::Vector{Dict{Symbol, Any}}        # Event log
    tithe_collected::Float64                 # Total tithe (3.69%)
    block_time::Int                          # Simulated block timestamp
    block_height::Int                        # Simulated block number
    chain_id::String                         # Network ID
    current_sender::String                   # Transaction origin
    halted::Bool                             # Execution state
    # 1440 Inheritance System (Sacred Governance)
    wallets::Vector{InheritanceWallet}       # 1440 inheritance wallets
    staking_vaults::Vector{StakingVault}     # 1440 staking vaults (11.11%)
    council::Vector{String}                  # Council of 12 addresses
    final_signer::String                     # Bínò (Ọbàtálá witness)
    has_inherited::Dict{String, Bool}        # Shrine → already inherited?
    # Profiling
    latency_log::Dict{UInt8, Vector{Float64}} # Opcode → [execution_times_ms]
    # Reentrancy guard: true while execute_instruction's critical dispatch
    # is running for this vm. Previously NONREENTRANT's guard was a no-op
    # (`return true` unconditionally, comment admitted "real impl would use
    # mutex") -- it now reflects real state and a real recursive-call block.
    in_execution::Bool
    # Universal Work cluster (real stateful tracking, replaces decorative
    # PROJECT/JOB stubs that previously just echoed args or called
    # FFI.mock_job with no persisted state or invariants).
    projects::Dict{String, Dict{Symbol, Any}}
    castings::Dict{String, Vector{Dict{Symbol, Any}}}   # project_id => [{wallet, role}]
    jobs::Dict{String, Dict{Symbol, Any}}
    shifts::Dict{String, Dict{Symbol, Any}}
    milestones::Dict{String, Dict{Symbol, Any}}
    deliverables::Dict{String, Dict{Symbol, Any}}
    timesheets::Dict{String, Dict{Symbol, Any}}
    invoices::Dict{String, Dict{Symbol, Any}}
    contracts::Dict{String, Dict{Symbol, Any}}
    disputes::Dict{String, Dict{Symbol, Any}}
    # Quadrinity Government cluster (real stateful tracking, replaces
    # call_ase_vault() offload for PROPOSAL/VOTE/DELEGATION/QUORUM/
    # EXECUTION/VETO/AMENDMENT/IMPEACHMENT/ELECTION/TERM/CABINET/
    # COMMITTEE/REFERENDUM/CONSTITUTION/LAW/COURT/VERDICT/APPEAL/
    # PARDON/SANCTION). Ballots (proposals, elections, referendums) share
    # one votes table keyed by ballot_id so quorum/tally logic is uniform.
    proposals::Dict{String, Dict{Symbol, Any}}
    votes::Dict{String, Dict{String, Any}}         # ballot_id => voter => choice
    delegations::Dict{String, String}              # delegator => delegate
    elections::Dict{String, Dict{Symbol, Any}}
    gov_terms::Dict{String, Dict{Symbol, Any}}
    cabinet::Dict{String, String}                  # official => role
    committees::Dict{String, Dict{Symbol, Any}}
    referendums::Dict{String, Dict{Symbol, Any}}
    constitution::Dict{Symbol, Any}                # {} until CONSTITUTION sets it once
    laws::Dict{String, Dict{Symbol, Any}}
    courts::Dict{String, Dict{Symbol, Any}}
    verdicts::Dict{String, Dict{Symbol, Any}}
    sanctions::Dict{String, Dict{Symbol, Any}}
end

function create_vm(; 
    council::Vector{String} = String[],
    final_signer::String = "bino_genesis")::VMState
    
    # Initialize 1440 wallets
    wallets = [InheritanceWallet(
        UInt16(i),
        OPEN,
        "",
        0x0000,
        0,  # Will be set when first offering distributed
        ""
    ) for i in 0:1439]
    
    # Initialize 1440 staking vaults
    vaults = [StakingVault(0.0, 0, 0, 0.0) for _ in 1:1440]
    
    return VMState(
        Dict{String, Float64}(),
        Dict{String, Float64}(),
        String[],
        Dict{Symbol, Any}[],
        0.0,
        0,
        0,
        "OSO-MAINNET-1",
        "genesis",
        false,
        wallets,
        vaults,
        council,
        final_signer,
        Dict{String, Bool}(),
        Dict{UInt8, Vector{Float64}}(),
        false,
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Vector{Dict{Symbol, Any}}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        Dict{String, Dict{Symbol, Any}}(),
        # Quadrinity Government cluster
        Dict{String, Dict{Symbol, Any}}(),   # proposals
        Dict{String, Dict{String, Any}}(),   # votes
        Dict{String, String}(),              # delegations
        Dict{String, Dict{Symbol, Any}}(),   # elections
        Dict{String, Dict{Symbol, Any}}(),   # gov_terms
        Dict{String, String}(),              # cabinet
        Dict{String, Dict{Symbol, Any}}(),   # committees
        Dict{String, Dict{Symbol, Any}}(),   # referendums
        Dict{Symbol, Any}(),                 # constitution
        Dict{String, Dict{Symbol, Any}}(),   # laws
        Dict{String, Dict{Symbol, Any}}(),   # courts
        Dict{String, Dict{Symbol, Any}}(),   # verdicts
        Dict{String, Dict{Symbol, Any}}()    # sanctions
    )
end

# FFI Stub Declarations (will call external libraries)
module FFI
    import ..VMState  # OsoVM.VMState, needed for impact_mint's type annotation

    # Julia FFI (math/simulation)
    function veil_sim(veil_id::Int, params::Dict)::Dict{String, Float64}
        # VeilSim PID controller
        f1 = get(params, :f1_target, 0.95)
        noise = rand() * 0.1 - 0.05
        actual_f1 = clamp(f1 + noise, 0.0, 1.0)
        
        ase = actual_f1 > 0.9 ? 5.0 : 0.0
        return Dict("f1" => actual_f1, "ase" => ase)
    end
    
    function impact_mint(ase_amount::Float64, vm::VMState)::Float64
        # Mint Aṣẹ for work performed
        sender = vm.current_sender
        vm.ase_balance[sender] = get(vm.ase_balance, sender, 0.0) + ase_amount
        return ase_amount
    end
    
    # Go FFI (networking/tithe distribution)
    function tithe_split(amount::Float64)::Dict{String, Float64}
        tithe = amount * 0.0369
        return Dict(
            "shrine" => tithe * 0.50,
            "inheritance" => tithe * 0.25,
            "hospital" => tithe * 0.15,
            "market" => tithe * 0.10
        )
    end
    
    # Rust FFI (safety/guards)
    function nonreentrant_guard(vm)::Bool
        # Reflects vm.in_execution, which execute_instruction now sets/
        # clears around its real dispatch (see the try/finally there) and
        # uses to reject genuine recursive re-entry -- no longer a
        # hardcoded true regardless of actual state.
        return vm.in_execution
    end
    
    # Move FFI (resource safety)
    function stake_ase(vm::VMState, sender::String, amount::Real)::Bool
        # amount must be non-negative -- previously balance >= amount let a
        # negative amount pass the check and then INCREASE the sender's
        # balance (subtracting a negative), a real exploit. Real (not
        # Float64) also accepts plain JSON integers, which previously
        # crashed with a MethodError since no Int64 method existed.
        amount = Float64(amount)
        if amount < 0.0
            return false
        end
        balance = get(vm.ase_balance, sender, 0.0)
        if balance >= amount
            vm.ase_balance[sender] = balance - amount
            vm.staked[sender] = get(vm.staked, sender, 0.0) + amount
            return true
        end
        return false
    end
    
    function unstake_ase(vm::VMState, sender::String, amount::Real)::Bool
        # Same negative-amount exploit as stake_ase, plus the same
        # Int64-vs-Float64 crash; fixed the same way.
        amount = Float64(amount)
        if amount < 0.0
            return false
        end
        staked = get(vm.staked, sender, 0.0)
        if staked >= amount
            vm.staked[sender] = staked - amount
            vm.ase_balance[sender] = get(vm.ase_balance, sender, 0.0) + amount
            return true
        end
        return false
    end
    
    # Idris FFI (dependent type proofs - stub)
    function verify_receipt(hash::String)::Bool
        # Real impl would verify cryptographic proof
        return length(hash) >= 64
    end
    
    # Python FFI (prototyping)
    function mock_job(job_data::Dict)::Dict{String, Any}
        return Dict("ase_minted" => 5.0, "status" => "complete")
    end
    
    # 7×7 Badge Verification (external)
    function has_seven_by_seven_badge(shrine::String)::Bool
        # Real impl would check TechGnØŞ.EXE badge registry
        # For now, stub returns true
        return true
    end
    
    # Sabbath Check (Saturday UTC)
    function is_saturday_utc(timestamp::Int)::Bool
        # Real impl would check day of week in UTC
        # 0 = Sunday, 6 = Saturday
        days_since_epoch = div(timestamp, 86400)
        day_of_week = (days_since_epoch + 4) % 7  # Jan 1, 1970 was Thursday
        return day_of_week == 6
    end
    
    # 11.11% APY Calculation
    function calculate_apy_rewards(principal::Float64, seconds_staked::Int)::Float64
        # APY = 11.11%
        # rewards = principal * (1 + 0.1111)^(seconds/year) - principal
        years = seconds_staked / (365.25 * 24 * 3600)
        return principal * ((1.1111 ^ years) - 1.0)
    end
end

"""
Execute a single instruction
"""

function is_critical(opcode::UInt8)::Bool
    # Locally-executable opcodes -- everything else offloads to the
    # (currently stub) ase-vault via call_ase_vault(). This list was
    # originally missing 13 opcodes (0x12,0x18,0x19,0x23,0x27,0x28,0x29,
    # 0x2a,0x35,0x37,0x38,0xa0,0xa6) that already had real elseif branches
    # written below -- they were unreachable dead code, silently replaced
    # by the fake stub at runtime. Also adds 4 opcodes (0x2b,0x3c,0x3d,0x3e)
    # whose real handlers were missing entirely and are implemented below.
    return opcode in [
        0x11, 0x12, 0x18, 0x19, 0x1f, 0x20, 0x21, 0x22, 0x23,
        0x27, 0x28, 0x29, 0x2a, 0x2b, 0x30, 0x31, 0x32, 0x33, 0x34,
        0x35, 0x37, 0x38, 0x3c, 0x3d, 0x3e, 0xa0, 0xa6,
        # Universal Work cluster: real stateful handlers below replace
        # what were either decorative echoes (PROJECT/JOB, already listed
        # above) or full offload-to-stub (the other 8, added here).
        0x17, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x24, 0x25,
        # Quadrinity Government cluster: real stateful handlers below
        # replace call_ase_vault() offload for all 20 opcodes 0x40-0x53.
        0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53,
    ]
end

function call_ase_vault(instr::OsoCompiler.Instruction)::Any
    # Offload to ase-vault via HTTP
    try
        # Simulation of HTTP call to ase-vault
        # response = HTTP.post("http://localhost:5000/execute", body=JSON.json(instr))
        # return JSON.parse(String(response.body))
        return Dict("status" => "offloaded", "vault_receipt" => "v-$(hash(instr))")
    catch e
        return Dict("error" => "ase-vault unreachable", "details" => string(e))
    end
end

# Quadrinity Government cluster (real stateful tracking, not decorative).
# Extracted into its own function -- inlining these 20 branches into
# execute_instruction pushed that function to ~900 lines / 50+ elseif
# branches, which made a single julia invocation of the test suite hang
# mid-compile (LLVM SLP-vectorizer codegen pass, confirmed via SIGTERM
# backtrace during `timeout 90 julia test/quadrinity_gov_test.jl` -- not
# an infinite loop in the test itself). Splitting clusters into their own
# functions keeps each function's codegen tractable; behavior unchanged.
function handle_quadrinity_government_1(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x40  # PROPOSAL -- governance motion
        proposal_id = get(args, :id, "")
        isempty(proposal_id) && return Dict("error" => "proposal id required", "success" => false)
        haskey(vm.proposals, proposal_id) && return Dict("error" => "proposal already exists: $proposal_id", "success" => false)
        vm.proposals[proposal_id] = Dict{Symbol, Any}(
            :id => proposal_id, :title => get(args, :title, ""), :proposer => vm.current_sender,
            :status => :open,
        )
        return Dict("proposal" => proposal_id, "status" => "open", "success" => true)

    elseif opcode == 0x41  # VOTE -- cast a ballot on a proposal/election/referendum
        ballot_id = get(args, :ballot_id, "")
        is_known = haskey(vm.proposals, ballot_id) || haskey(vm.elections, ballot_id) || haskey(vm.referendums, ballot_id)
        is_known || return Dict("error" => "unknown ballot: $ballot_id", "success" => false)
        choice = get(args, :choice, "")
        isempty(choice) && return Dict("error" => "choice required", "success" => false)
        voter = get(args, :voter, vm.current_sender)
        haskey(vm.delegations, voter) && return Dict("error" => "voter has delegated, cannot vote directly: $voter", "success" => false)
        ballot = get!(vm.votes, ballot_id, Dict{String, Any}())
        haskey(ballot, voter) && return Dict("error" => "already voted: $voter on $ballot_id", "success" => false)
        ballot[voter] = choice
        return Dict("ballot" => ballot_id, "voter" => voter, "choice" => choice, "success" => true)

    elseif opcode == 0x42  # DELEGATION -- proxy voting
        delegator = get(args, :delegator, vm.current_sender)
        delegate = get(args, :delegate, "")
        isempty(delegate) && return Dict("error" => "delegate required", "success" => false)
        delegator == delegate && return Dict("error" => "cannot delegate to self", "success" => false)
        haskey(vm.delegations, delegator) && return Dict("error" => "already delegated: $delegator", "success" => false)
        vm.delegations[delegator] = delegate
        return Dict("delegator" => delegator, "delegate" => delegate, "success" => true)

    elseif opcode == 0x43  # QUORUM -- check whether a ballot has reached quorum
        ballot_id = get(args, :ballot_id, "")
        haskey(vm.proposals, ballot_id) || haskey(vm.elections, ballot_id) || haskey(vm.referendums, ballot_id) ||
            return Dict("error" => "unknown ballot: $ballot_id", "success" => false)
        threshold = Float64(get(args, :threshold, 0.5))
        (threshold <= 0.0 || threshold > 1.0) && return Dict("error" => "threshold must be in (0,1]", "success" => false)
        council_size = max(length(vm.council), 1)
        cast_votes = length(get(vm.votes, ballot_id, Dict{String, Any}()))
        met = cast_votes >= ceil(Int, council_size * threshold)
        if haskey(vm.proposals, ballot_id)
            vm.proposals[ballot_id][:quorum_met] = met
        end
        return Dict("ballot" => ballot_id, "quorum_met" => met, "votes_cast" => cast_votes, "success" => true)

    elseif opcode == 0x44  # EXECUTION -- enact a proposal that has quorum and a yes majority
        proposal_id = get(args, :proposal_id, "")
        haskey(vm.proposals, proposal_id) || return Dict("error" => "unknown proposal: $proposal_id", "success" => false)
        p = vm.proposals[proposal_id]
        p[:status] == :executed && return Dict("error" => "already executed: $proposal_id", "success" => false)
        p[:status] == :vetoed && return Dict("error" => "vetoed, cannot execute: $proposal_id", "success" => false)
        get(p, :quorum_met, false) || return Dict("error" => "quorum not met: $proposal_id", "success" => false)
        ballot = get(vm.votes, proposal_id, Dict{String, Any}())
        yes = sum(v == "yes" for v in values(ballot); init=0); no = sum(v == "no" for v in values(ballot); init=0)
        yes > no || return Dict("error" => "no majority: yes=$yes no=$no", "success" => false)
        p[:status] = :executed
        return Dict("proposal" => proposal_id, "status" => "executed", "yes" => yes, "no" => no, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x40-0x44", "success" => false)
    end
end

function handle_quadrinity_government_2(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x45  # VETO -- final_signer overrides a proposal before/after execution
        proposal_id = get(args, :proposal_id, "")
        haskey(vm.proposals, proposal_id) || return Dict("error" => "unknown proposal: $proposal_id", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may veto", "success" => false)
        vm.proposals[proposal_id][:status] == :vetoed && return Dict("error" => "already vetoed: $proposal_id", "success" => false)
        vm.proposals[proposal_id][:status] = :vetoed
        return Dict("proposal" => proposal_id, "status" => "vetoed", "success" => true)

    elseif opcode == 0x46  # AMENDMENT -- modify an enacted law, requires an executed proposal
        law_id = get(args, :law_id, "")
        haskey(vm.laws, law_id) || return Dict("error" => "unknown law: $law_id", "success" => false)
        proposal_id = get(args, :proposal_id, "")
        haskey(vm.proposals, proposal_id) && vm.proposals[proposal_id][:status] == :executed ||
            return Dict("error" => "amendment requires an executed proposal", "success" => false)
        new_text = get(args, :text, "")
        isempty(new_text) && return Dict("error" => "amendment text required", "success" => false)
        vm.laws[law_id][:text] = new_text
        vm.laws[law_id][:amended_by] = proposal_id
        return Dict("law" => law_id, "status" => "amended", "success" => true)

    elseif opcode == 0x47  # IMPEACHMENT -- remove an official, requires an executed proposal
        official = get(args, :official, "")
        haskey(vm.cabinet, official) || return Dict("error" => "not a sitting official: $official", "success" => false)
        proposal_id = get(args, :proposal_id, "")
        haskey(vm.proposals, proposal_id) && vm.proposals[proposal_id][:status] == :executed ||
            return Dict("error" => "impeachment requires an executed proposal", "success" => false)
        delete!(vm.cabinet, official)
        return Dict("official" => official, "status" => "removed", "success" => true)

    elseif opcode == 0x48  # ELECTION -- open or close leadership selection
        election_id = get(args, :id, "")
        isempty(election_id) && return Dict("error" => "election id required", "success" => false)
        action = get(args, :action, "open")
        if action == "open"
            haskey(vm.elections, election_id) && return Dict("error" => "election already exists: $election_id", "success" => false)
            candidates = get(args, :candidates, String[])
            isempty(candidates) && return Dict("error" => "candidates required", "success" => false)
            vm.elections[election_id] = Dict{Symbol, Any}(:id => election_id, :candidates => candidates, :status => :open)
            return Dict("election" => election_id, "status" => "open", "success" => true)
        elseif action == "close"
            haskey(vm.elections, election_id) || return Dict("error" => "unknown election: $election_id", "success" => false)
            e = vm.elections[election_id]
            e[:status] == :closed && return Dict("error" => "already closed: $election_id", "success" => false)
            ballot = get(vm.votes, election_id, Dict{String, Any}())
            isempty(ballot) && return Dict("error" => "no votes cast", "success" => false)
            tally = Dict{String, Int}()
            for choice in values(ballot)
                tally[choice] = get(tally, choice, 0) + 1
            end
            winner = argmax(tally)
            e[:status] = :closed
            e[:winner] = winner
            return Dict("election" => election_id, "winner" => winner, "status" => "closed", "success" => true)
        else
            return Dict("error" => "action must be open or close", "success" => false)
        end

    elseif opcode == 0x49  # TERM -- an official's service period
        term_id = get(args, :id, "")
        isempty(term_id) && return Dict("error" => "term id required", "success" => false)
        haskey(vm.gov_terms, term_id) && return Dict("error" => "term already exists: $term_id", "success" => false)
        start_t = get(args, :start, 0); end_t = get(args, :end, 0)
        end_t <= start_t && return Dict("error" => "term end must be after start", "success" => false)
        vm.gov_terms[term_id] = Dict{Symbol, Any}(
            :id => term_id, :official => get(args, :official, ""), :start => start_t, :end => end_t,
        )
        return Dict("term" => term_id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x45-0x49", "success" => false)
    end
end

function handle_quadrinity_government_3(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x4a  # CABINET -- appoint an official to the executive council
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may appoint cabinet", "success" => false)
        official = get(args, :official, "")
        isempty(official) && return Dict("error" => "official required", "success" => false)
        haskey(vm.cabinet, official) && return Dict("error" => "already in cabinet: $official", "success" => false)
        role = get(args, :role, "")
        isempty(role) && return Dict("error" => "role required", "success" => false)
        vm.cabinet[official] = role
        return Dict("official" => official, "role" => role, "success" => true)

    elseif opcode == 0x4b  # COMMITTEE -- form a subgroup
        committee_id = get(args, :id, "")
        isempty(committee_id) && return Dict("error" => "committee id required", "success" => false)
        haskey(vm.committees, committee_id) && return Dict("error" => "committee already exists: $committee_id", "success" => false)
        members = get(args, :members, String[])
        isempty(members) && return Dict("error" => "members required", "success" => false)
        vm.committees[committee_id] = Dict{Symbol, Any}(
            :id => committee_id, :members => members, :purpose => get(args, :purpose, ""),
        )
        return Dict("committee" => committee_id, "success" => true)

    elseif opcode == 0x4c  # REFERENDUM -- open direct vote (a ballot, like PROPOSAL but public)
        referendum_id = get(args, :id, "")
        isempty(referendum_id) && return Dict("error" => "referendum id required", "success" => false)
        haskey(vm.referendums, referendum_id) && return Dict("error" => "referendum already exists: $referendum_id", "success" => false)
        question = get(args, :question, "")
        isempty(question) && return Dict("error" => "question required", "success" => false)
        vm.referendums[referendum_id] = Dict{Symbol, Any}(:id => referendum_id, :question => question, :status => :open)
        return Dict("referendum" => referendum_id, "status" => "open", "success" => true)

    elseif opcode == 0x4d  # CONSTITUTION -- founding document, immutable once set
        !isempty(vm.constitution) && return Dict("error" => "constitution already set, immutable", "success" => false)
        text = get(args, :text, "")
        isempty(text) && return Dict("error" => "constitution text required", "success" => false)
        vm.constitution[:text] = text
        vm.constitution[:ratified_by] = vm.current_sender
        return Dict("status" => "ratified", "success" => true)

    elseif opcode == 0x4e  # LAW -- enacted rule, requires an executed proposal
        law_id = get(args, :id, "")
        isempty(law_id) && return Dict("error" => "law id required", "success" => false)
        haskey(vm.laws, law_id) && return Dict("error" => "law already exists: $law_id", "success" => false)
        proposal_id = get(args, :proposal_id, "")
        haskey(vm.proposals, proposal_id) && vm.proposals[proposal_id][:status] == :executed ||
            return Dict("error" => "law requires an executed proposal", "success" => false)
        vm.laws[law_id] = Dict{Symbol, Any}(
            :id => law_id, :text => get(args, :text, ""), :proposal_id => proposal_id, :status => :active,
        )
        return Dict("law" => law_id, "status" => "active", "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x4a-0x4e", "success" => false)
    end
end

function handle_quadrinity_government_4(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x4f  # COURT -- judicial body
        court_id = get(args, :id, "")
        isempty(court_id) && return Dict("error" => "court id required", "success" => false)
        haskey(vm.courts, court_id) && return Dict("error" => "court already exists: $court_id", "success" => false)
        judges = get(args, :judges, String[])
        isempty(judges) && return Dict("error" => "judges required", "success" => false)
        vm.courts[court_id] = Dict{Symbol, Any}(:id => court_id, :judges => judges)
        return Dict("court" => court_id, "success" => true)

    elseif opcode == 0x50  # VERDICT -- legal decision by an existing court
        verdict_id = get(args, :id, "")
        isempty(verdict_id) && return Dict("error" => "verdict id required", "success" => false)
        haskey(vm.verdicts, verdict_id) && return Dict("error" => "verdict already exists: $verdict_id", "success" => false)
        court_id = get(args, :court_id, "")
        haskey(vm.courts, court_id) || return Dict("error" => "unknown court: $court_id", "success" => false)
        ruling = get(args, :ruling, "")
        isempty(ruling) && return Dict("error" => "ruling required", "success" => false)
        vm.verdicts[verdict_id] = Dict{Symbol, Any}(
            :id => verdict_id, :court_id => court_id, :case => get(args, :case, ""),
            :ruling => ruling, :status => :final,
        )
        return Dict("verdict" => verdict_id, "status" => "final", "success" => true)

    elseif opcode == 0x51  # APPEAL -- challenge a final verdict, once
        verdict_id = get(args, :verdict_id, "")
        haskey(vm.verdicts, verdict_id) || return Dict("error" => "unknown verdict: $verdict_id", "success" => false)
        vm.verdicts[verdict_id][:status] != :final && return Dict("error" => "verdict not appealable: $verdict_id", "success" => false)
        vm.verdicts[verdict_id][:status] = :appealed
        vm.verdicts[verdict_id][:appeal_reason] = get(args, :reason, "")
        return Dict("verdict" => verdict_id, "status" => "appealed", "success" => true)

    elseif opcode == 0x52  # PARDON -- final_signer forgives an active sanction
        sanction_id = get(args, :sanction_id, "")
        haskey(vm.sanctions, sanction_id) || return Dict("error" => "unknown sanction: $sanction_id", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may pardon", "success" => false)
        vm.sanctions[sanction_id][:status] != :active && return Dict("error" => "sanction not active: $sanction_id", "success" => false)
        vm.sanctions[sanction_id][:status] = :pardoned
        return Dict("sanction" => sanction_id, "status" => "pardoned", "success" => true)

    elseif opcode == 0x53  # SANCTION -- punish a violation, tied to an existing verdict
        sanction_id = get(args, :id, "")
        isempty(sanction_id) && return Dict("error" => "sanction id required", "success" => false)
        haskey(vm.sanctions, sanction_id) && return Dict("error" => "sanction already exists: $sanction_id", "success" => false)
        verdict_id = get(args, :verdict_id, "")
        haskey(vm.verdicts, verdict_id) || return Dict("error" => "unknown verdict: $verdict_id", "success" => false)
        target = get(args, :target, "")
        isempty(target) && return Dict("error" => "target required", "success" => false)
        vm.sanctions[sanction_id] = Dict{Symbol, Any}(
            :id => sanction_id, :verdict_id => verdict_id, :target => target,
            :penalty => get(args, :penalty, ""), :status => :active,
        )
        return Dict("sanction" => sanction_id, "status" => "active", "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x4f-0x53", "success" => false)
    end
end

function handle_quadrinity_government(vm::VMState, opcode::UInt8, args)::Any
    if opcode in 0x40:0x44
        return handle_quadrinity_government_1(vm, opcode, args)
    elseif opcode in 0x45:0x49
        return handle_quadrinity_government_2(vm, opcode, args)
    elseif opcode in 0x4a:0x4e
        return handle_quadrinity_government_3(vm, opcode, args)
    elseif opcode in 0x4f:0x53
        return handle_quadrinity_government_4(vm, opcode, args)
    end
end


function execute_instruction(vm::VMState, instr::OsoCompiler.Instruction)::Any
    start_time = time()
    if vm.halted
        return nothing
    end
    
    opcode = instr.opcode

    # Offload non-critical opcodes
    if !is_critical(opcode) && opcode != 0x00 && opcode != 0x01
        result = call_ase_vault(instr)
        elapsed = (time() - start_time) * 1000
        times = get!(vm.latency_log, opcode, Float64[])
        push!(times, elapsed)
        return result
    end
    args = instr.args
    attr = Opcodes.get_attribute(opcode)

    # Real reentrancy guard: reject genuine recursive execute_instruction
    # calls on the same vm (e.g. an opcode handler calling back into
    # execute_instruction while one is already running for this vm).
    # Sequential top-level calls are unaffected -- the lock is always
    # released in the `finally` below before this function returns.
    if vm.in_execution
        return Dict("error" => "reentrant_call_blocked", "success" => false)
    end
    vm.in_execution = true
    try

    # Core opcodes (runtime-enforced)
    if opcode == 0x00  # HALT
        vm.halted = true
        return Dict("status" => "halted")
        
    elseif opcode == 0x01  # NOOP
        return Dict("status" => "noop")
        
    elseif opcode == 0x11  # IMPACT
        ase = get(args, :ase, 0.0)
        minted = FFI.impact_mint(ase, vm)
        
        # Execute nested attributes
        if haskey(args, :nested)
            for nested_instr in args[:nested]
                execute_instruction(vm, nested_instr)
            end
        end
        
        return Dict("ase_minted" => minted, "balance" => vm.ase_balance[vm.current_sender])
        
    elseif opcode == 0x12  # VEIL
        veil_id = get(args, :id, 1)
        params = Dict(:f1_target => get(args, :f1, 0.95))
        result = FFI.veil_sim(veil_id, params)
        return result
        
    elseif opcode == 0x27  # TITHE
        rate = get(args, :rate, 0.0369)
        balance = get(vm.ase_balance, vm.current_sender, 0.0)
        tithe_amount = balance * rate
        
        split = FFI.tithe_split(balance)
        vm.tithe_collected += tithe_amount
        
        return Dict("tithe" => tithe_amount, "split" => split)
        
    elseif opcode == 0x1f  # RECEIPT
        hash = get(args, :hash, "0x0")
        verified = FFI.verify_receipt(hash)
        if verified
            push!(vm.receipts, hash)
        end
        return Dict("receipt" => hash, "verified" => verified)
        
    elseif opcode == 0x20  # STAKE
        amount = get(args, :amount, 0.0)
        success = FFI.stake_ase(vm, vm.current_sender, amount)
        return Dict("staked" => amount, "success" => success)
        
    elseif opcode == 0x21  # UNSTAKE
        amount = get(args, :amount, 0.0)
        success = FFI.unstake_ase(vm, vm.current_sender, amount)
        return Dict("unstaked" => amount, "success" => success)
        
    elseif opcode == 0x22  # TRANSFER
        to = get(args, :to, "")
        amount = Float64(get(args, :amount, 0.0))

        # amount < 0 previously passed `from_balance >= amount` for any
        # sender (even balance 0), then INCREASED the sender's balance
        # (subtracting a negative) while DECREASING the recipient's --
        # a real balance-manipulation exploit against any wallet address.
        if amount < 0.0
            return Dict("transferred" => 0.0, "success" => false, "error" => "negative_amount_rejected")
        end

        from_balance = get(vm.ase_balance, vm.current_sender, 0.0)
        if from_balance >= amount
            vm.ase_balance[vm.current_sender] = from_balance - amount
            vm.ase_balance[to] = get(vm.ase_balance, to, 0.0) + amount
            return Dict("transferred" => amount, "to" => to, "success" => true)
        end
        return Dict("transferred" => 0.0, "success" => false)
        
    elseif opcode == 0x23  # BALANCE
        wallet = get(args, :wallet, vm.current_sender)
        return Dict("wallet" => wallet, "balance" => get(vm.ase_balance, wallet, 0.0))
        
    elseif opcode == 0x28  # NONREENTRANT
        guard = FFI.nonreentrant_guard(vm)
        return Dict("guarded" => guard)
        
    elseif opcode == 0x29  # REQUIRE
        condition = get(args, :condition, false)
        if !condition
            error("Requirement failed: $(get(args, :message, "unknown"))")
        end
        return Dict("required" => true)
        
    elseif opcode == 0x2a  # EMIT
        event_name = get(args, :event, "")
        event_data = Dict(k => v for (k, v) in args if k != :event)
        event = Dict(:name => event_name, :data => event_data, :block => vm.block_height)
        push!(vm.events, event)
        return Dict("event_emitted" => event_name)

    elseif opcode == 0x2b  # GENESIS_FLAW_TOKEN -- Block 0 only: "ASHE" (the
        # deliberate misspelling) mints 1.0 Àṣẹ; forever rejected after
        # block 0. Genesis-used state is tracked via vm.events (this
        # VMState has no metadata dict) rather than adding a new struct
        # field, which would require updating every create_vm() call site.
        token = get(args, :token, "ASHE")
        already_used = any(e -> get(e, :name, "") == "GenesisFlawUsed", vm.events)
        if vm.block_height == 0 && token == "ASHE" && !already_used
            vm.ase_balance[vm.current_sender] = get(vm.ase_balance, vm.current_sender, 0.0) + 1.0
            push!(vm.events, Dict(:name => "GenesisFlawUsed", :data => Dict("sender" => vm.current_sender), :block => vm.block_height))
            return Dict("genesis" => true, "token_minted" => "Àṣẹ", "amount" => 1.0, "block" => vm.block_height, "original_token" => "ASHE")
        else
            reason = vm.block_height != 0 ? "flaw_denied_post_genesis" :
                     token != "ASHE" ? "wrong_token" : "flaw_already_used"
            return Dict("genesis" => false, "error" => reason, "rejected_token" => token, "block" => vm.block_height)
        end

    elseif opcode == 0x3c  # AGENT_CONVERT -- burn Àṣẹ, emit a Dopamine
        # signal proportional to the amount burned (real burn/bookkeeping;
        # "Dopamine" here is a returned signal value, not a separately
        # tracked ledger -- no such ledger exists in this VMState).
        ase_amount = get(args, :ase_amount, 0.0)
        balance = get(vm.ase_balance, vm.current_sender, 0.0)
        if balance < ase_amount
            return Dict("success" => false, "error" => "insufficient_balance", "balance" => balance)
        end
        vm.ase_balance[vm.current_sender] = balance - ase_amount
        dopamine_signal = ase_amount * 1000.0  # conversion rate: 1 Àṣẹ -> 1000 Dopamine signal units
        push!(vm.events, Dict(:name => "AgentConvert", :data => Dict("sender" => vm.current_sender, "ase_burned" => ase_amount), :block => vm.block_height))
        return Dict("success" => true, "ase_burned" => ase_amount, "dopamine_signal" => dopamine_signal)

    elseif opcode == 0x3d  # JOB_PAYMENT -- 10% creator, 5% burn, 85% agent
        # conversion, per the opcode's own documented split.
        total_ase = get(args, :total_ase, 0.0)
        creator_address = get(args, :creator_address, "")
        balance = get(vm.ase_balance, vm.current_sender, 0.0)
        if balance < total_ase
            return Dict("success" => false, "error" => "insufficient_balance", "balance" => balance)
        end
        creator_share = total_ase * 0.10
        burn_share = total_ase * 0.05
        agent_share = total_ase * 0.85
        vm.ase_balance[vm.current_sender] = balance - total_ase
        if !isempty(creator_address)
            vm.ase_balance[creator_address] = get(vm.ase_balance, creator_address, 0.0) + creator_share
        end
        push!(vm.events, Dict(:name => "JobPayment", :data => Dict("sender" => vm.current_sender, "total" => total_ase), :block => vm.block_height))
        return Dict("success" => true, "creator_share" => creator_share, "burn_share" => burn_share, "agent_conversion_share" => agent_share)

    elseif opcode == 0x3e  # AGENT_BIRTH -- lock 10 Àṣẹ, emit the documented
        # 86B Dopamine / 86M Synapse endowment (returned values -- no
        # separate dopamine/synapse ledger exists in this VMState to
        # credit them into; same honest-signal pattern as AGENT_CONVERT).
        agent_id = get(args, :agent_id, "")
        birth_fee = 10.0
        balance = get(vm.ase_balance, vm.current_sender, 0.0)
        if balance < birth_fee
            return Dict("success" => false, "error" => "insufficient_balance_for_birth", "required" => birth_fee, "balance" => balance)
        end
        vm.ase_balance[vm.current_sender] = balance - birth_fee
        push!(vm.events, Dict(:name => "AgentBirth", :data => Dict("sender" => vm.current_sender, "agent_id" => agent_id), :block => vm.block_height))
        return Dict("success" => true, "agent_id" => agent_id, "ase_locked" => birth_fee, "dopamine_endowment" => 86_000_000_000.0, "synapse_endowment" => 86_000_000.0)

    # 1440 Inheritance Wallet Opcodes (Sacred Governance)
    elseif opcode == 0x30  # CANDIDATE_APPLY
        wallet_id = UInt16(get(args, :walletId, 0))
        shrine = get(args, :shrine, "")
        
        if wallet_id >= 1440
            return Dict("error" => "invalid wallet_id", "wallet_id" => wallet_id)
        end
        
        w = vm.wallets[wallet_id + 1]  # Julia 1-indexed
        
        # Validations
        if !(w.state in [OPEN, PENDING])
            return Dict("error" => "wallet not open", "state" => w.state)
        end
        
        if vm.block_time < w.next_eligible_ts
            return Dict("error" => "7 years not passed", "next_eligible" => w.next_eligible_ts)
        end
        
        if get(vm.has_inherited, shrine, false)
            return Dict("error" => "shrine already inherited")
        end
        
        if !FFI.has_seven_by_seven_badge(shrine)
            return Dict("error" => "7×7 badge required")
        end
        
        if w.state == OPEN
            w.state = PENDING
            w.pending = shrine
            w.approvals_mask = 0x0000
            push!(vm.events, Dict(:name => "CandidateApplied", :wallet_id => wallet_id, :shrine => shrine))
            return Dict("status" => "pending", "wallet_id" => wallet_id, "shrine" => shrine)
        else  # PENDING
            if w.pending != shrine
                return Dict("error" => "different candidate", "pending" => w.pending)
            end
            return Dict("status" => "already_pending", "wallet_id" => wallet_id)
        end
        
    elseif opcode == 0x31  # COUNCIL_APPROVE
        wallet_id = UInt16(get(args, :walletId, 0))
        
        if wallet_id >= 1440
            return Dict("error" => "invalid wallet_id")
        end
        
        # Check if sender is council member
        sender = vm.current_sender
        if !(sender in vm.council)
            return Dict("error" => "not council member")
        end
        
        w = vm.wallets[wallet_id + 1]
        
        if !(w.state in [PENDING, COUNCIL_READY])
            return Dict("error" => "not in pending state")
        end
        
        # Get council index (0-11)
        idx = findfirst(==(sender), vm.council)
        if idx === nothing
            return Dict("error" => "not council")
        end
        idx = idx - 1  # Convert to 0-indexed
        
        bit = UInt16(1 << idx)
        
        # Check if already voted
        if (w.approvals_mask & bit) != 0
            return Dict("error" => "already voted")
        end
        
        # Record vote
        w.approvals_mask |= bit
        
        # Count approvals
        count = count_ones(w.approvals_mask)
        
        push!(vm.events, Dict(:name => "CouncilApproved", :wallet_id => wallet_id, :council => sender, :count => count))
        
        # Check if 12/12 reached
        if count >= 12
            w.state = COUNCIL_READY
            return Dict("status" => "council_ready", "wallet_id" => wallet_id, "approvals" => count)
        end
        
        return Dict("status" => "approved", "wallet_id" => wallet_id, "approvals" => count)
        
    elseif opcode == 0x32  # FINAL_SIGN
        wallet_id = UInt16(get(args, :walletId, 0))
        
        if wallet_id >= 1440
            return Dict("error" => "invalid wallet_id")
        end
        
        # Only Bínò can sign
        if vm.current_sender != vm.final_signer
            return Dict("error" => "only Bínò can sign")
        end
        
        w = vm.wallets[wallet_id + 1]
        
        if w.state != COUNCIL_READY
            return Dict("error" => "council not ready", "state" => w.state)
        end
        
        # Award the inheritance
        w.state = AWARDED
        w.winner = w.pending
        vm.has_inherited[w.pending] = true
        
        # Transfer locked balance to winner's shrine
        vault = vm.staking_vaults[wallet_id + 1]
        transfer_amount = vault.locked_balance
        vm.ase_balance[w.winner] = get(vm.ase_balance, w.winner, 0.0) + transfer_amount
        
        push!(vm.events, Dict(
            :name => "InheritanceAwarded",
            :wallet_id => wallet_id,
            :winner => w.winner,
            :amount => transfer_amount,
            :signed_by => vm.current_sender
        ))
        
        return Dict(
            "status" => "awarded",
            "wallet_id" => wallet_id,
            "winner" => w.winner,
            "amount" => transfer_amount
        )
        
    elseif opcode == 0x33  # DISTRIBUTE_OFFERING
        amount = get(args, :amount, 0.0)
        
        # 25% goes to 1440 inheritance wallets
        inheritance = amount * 0.25
        per_wallet = inheritance / 1440
        
        for i in 1:1440
            vault = vm.staking_vaults[i]
            vault.locked_balance += per_wallet
            
            # Set staked_since if first deposit
            if vault.staked_since == 0
                vault.staked_since = vm.block_time
                # Set next eligible timestamp (7 years from now)
                vm.wallets[i].next_eligible_ts = vm.block_time + (7 * 365 * 24 * 3600)
            end
            
            vault.last_claimed = vm.block_time
        end
        
        push!(vm.events, Dict(
            :name => "OfferingDistributed",
            :total => amount,
            :inheritance_portion => inheritance,
            :per_wallet => per_wallet
        ))
        
        return Dict(
            "status" => "distributed",
            "total" => amount,
            "inheritance" => inheritance,
            "per_wallet" => per_wallet
        )
        
    elseif opcode == 0x34  # CLAIM_REWARDS
        wallet_id = UInt16(get(args, :walletId, 0))
        
        if wallet_id >= 1440
            return Dict("error" => "invalid wallet_id")
        end
        
        w = vm.wallets[wallet_id + 1]
        vault = vm.staking_vaults[wallet_id + 1]
        
        # Only winner can claim
        if w.winner != vm.current_sender
            return Dict("error" => "not owner", "winner" => w.winner)
        end
        
        # Sabbath fasting (no claims on Saturday UTC)
        if FFI.is_saturday_utc(vm.block_time)
            return Dict("error" => "Sabbath fasting - no claims on Saturday UTC")
        end
        
        # Calculate accrued rewards
        if vault.staked_since > 0
            seconds_staked = vm.block_time - vault.last_claimed
            new_rewards = FFI.calculate_apy_rewards(vault.locked_balance, seconds_staked)
            vault.accrued_rewards += new_rewards
        end
        
        # Transfer rewards
        reward = vault.accrued_rewards
        vault.accrued_rewards = 0.0
        vault.last_claimed = vm.block_time
        
        vm.ase_balance[vm.current_sender] = get(vm.ase_balance, vm.current_sender, 0.0) + reward
        
        push!(vm.events, Dict(
            :name => "RewardsClaimed",
            :wallet_id => wallet_id,
            :shrine => vm.current_sender,
            :amount => reward
        ))
        
        return Dict(
            "status" => "claimed",
            "wallet_id" => wallet_id,
            "reward" => reward,
            "locked_balance" => vault.locked_balance
        )
    
    # Chain Context Opcodes (reassigned)
    elseif opcode == 0x35  # TIMESTAMP
        return Dict("timestamp" => vm.block_time)
        
    elseif opcode == 0x37  # CHAINID
        return Dict("chain_id" => vm.chain_id)
        
    elseif opcode == 0x38  # ORIGIN
        return Dict("origin" => vm.current_sender)
        
    # Universal Work cluster (real stateful tracking, not decorative)
    elseif opcode == 0x18  # PROJECT
        project_id = get(args, :id, "")
        isempty(project_id) && return Dict("error" => "project_id required", "success" => false)
        haskey(vm.projects, project_id) && return Dict("error" => "project already exists: $project_id", "success" => false)
        budget = Float64(get(args, :budget, 0.0))
        budget < 0 && return Dict("error" => "budget cannot be negative", "success" => false)
        vm.projects[project_id] = Dict{Symbol, Any}(
            :id => project_id, :sector => get(args, :sector, ""),
            :budget => budget, :creator => vm.current_sender, :status => :open,
        )
        return Dict("project" => project_id, "status" => "open", "success" => true)

    elseif opcode == 0x17  # CASTING -- assign a wallet to a role on a project
        project_id = get(args, :project_id, "")
        haskey(vm.projects, project_id) || return Dict("error" => "unknown project: $project_id", "success" => false)
        role = get(args, :role, "")
        isempty(role) && return Dict("error" => "role required", "success" => false)
        wallet = get(args, :wallet, vm.current_sender)
        casting = get!(vm.castings, project_id, Dict{Symbol, Any}[])
        any(c -> c[:wallet] == wallet && c[:role] == role, casting) &&
            return Dict("error" => "already cast: $wallet as $role", "success" => false)
        push!(casting, Dict{Symbol, Any}(:wallet => wallet, :role => role))
        return Dict("project" => project_id, "wallet" => wallet, "role" => role, "success" => true)

    elseif opcode == 0x19  # JOB -- a task unit under a project
        project_id = get(args, :project_id, "")
        haskey(vm.projects, project_id) || return Dict("error" => "unknown project: $project_id", "success" => false)
        vm.projects[project_id][:status] == :closed &&
            return Dict("error" => "project closed: $project_id", "success" => false)
        job_id = get(args, :id, "")
        isempty(job_id) && return Dict("error" => "job id required", "success" => false)
        haskey(vm.jobs, job_id) && return Dict("error" => "job already exists: $job_id", "success" => false)
        reward = Float64(get(args, :reward, 0.0))
        reward < 0 && return Dict("error" => "reward cannot be negative", "success" => false)
        vm.jobs[job_id] = Dict{Symbol, Any}(
            :id => job_id, :project_id => project_id, :reward => reward, :status => :open,
        )
        return Dict("job" => job_id, "project_id" => project_id, "status" => "open", "success" => true)

    elseif opcode == 0x1a  # SHIFT -- a logged time block against a job
        job_id = get(args, :job_id, "")
        haskey(vm.jobs, job_id) || return Dict("error" => "unknown job: $job_id", "success" => false)
        start_t = get(args, :start, 0); end_t = get(args, :end, 0)
        end_t <= start_t && return Dict("error" => "shift end must be after start", "success" => false)
        shift_id = get(args, :id, "shift-$(length(vm.shifts) + 1)")
        haskey(vm.shifts, shift_id) && return Dict("error" => "shift already exists: $shift_id", "success" => false)
        vm.shifts[shift_id] = Dict{Symbol, Any}(
            :id => shift_id, :job_id => job_id, :worker => get(args, :worker, vm.current_sender),
            :start => start_t, :end => end_t, :hours => (end_t - start_t) / 3600.0,
        )
        return Dict("shift" => shift_id, "hours" => vm.shifts[shift_id][:hours], "success" => true)

    elseif opcode == 0x1b  # MILESTONE -- completion marker on a project, monotonic 0..100
        project_id = get(args, :project_id, "")
        haskey(vm.projects, project_id) || return Dict("error" => "unknown project: $project_id", "success" => false)
        pct = Float64(get(args, :percent, 0.0))
        (pct < 0 || pct > 100) && return Dict("error" => "percent must be 0..100", "success" => false)
        prior = get(vm.projects[project_id], :milestone_pct, 0.0)
        pct < prior && return Dict("error" => "milestone cannot regress ($prior -> $pct)", "success" => false)
        vm.projects[project_id][:milestone_pct] = pct
        milestone_id = get(args, :id, "milestone-$(length(vm.milestones) + 1)")
        vm.milestones[milestone_id] = Dict{Symbol, Any}(:id => milestone_id, :project_id => project_id, :percent => pct)
        pct == 100.0 && (vm.projects[project_id][:status] = :closed)
        return Dict("milestone" => milestone_id, "percent" => pct, "success" => true)

    elseif opcode == 0x1c  # DELIVERABLE -- output artifact tied to a job
        job_id = get(args, :job_id, "")
        haskey(vm.jobs, job_id) || return Dict("error" => "unknown job: $job_id", "success" => false)
        artifact_hash = get(args, :hash, "")
        isempty(artifact_hash) && return Dict("error" => "artifact hash required", "success" => false)
        deliverable_id = get(args, :id, "deliverable-$(length(vm.deliverables) + 1)")
        vm.deliverables[deliverable_id] = Dict{Symbol, Any}(
            :id => deliverable_id, :job_id => job_id, :hash => artifact_hash,
        )
        vm.jobs[job_id][:status] = :delivered
        return Dict("deliverable" => deliverable_id, "job" => job_id, "success" => true)

    elseif opcode == 0x1d  # TIMESHEET -- aggregate hours from real shifts
        job_id = get(args, :job_id, "")
        worker = get(args, :worker, vm.current_sender)
        matching = [s for s in values(vm.shifts) if s[:job_id] == job_id && s[:worker] == worker]
        isempty(matching) && return Dict("error" => "no shifts logged for worker on job $job_id", "success" => false)
        total_hours = sum(s[:hours] for s in matching)
        timesheet_id = get(args, :id, "timesheet-$(length(vm.timesheets) + 1)")
        vm.timesheets[timesheet_id] = Dict{Symbol, Any}(
            :id => timesheet_id, :job_id => job_id, :worker => worker,
            :hours => total_hours, :shift_count => length(matching),
        )
        return Dict("timesheet" => timesheet_id, "hours" => total_hours, "success" => true)

    elseif opcode == 0x1e  # INVOICE -- payment request derived from a real timesheet
        timesheet_id = get(args, :timesheet_id, "")
        haskey(vm.timesheets, timesheet_id) || return Dict("error" => "unknown timesheet: $timesheet_id", "success" => false)
        rate = Float64(get(args, :rate, 0.0))
        rate < 0 && return Dict("error" => "rate cannot be negative", "success" => false)
        amount = vm.timesheets[timesheet_id][:hours] * rate
        invoice_id = get(args, :id, "invoice-$(length(vm.invoices) + 1)")
        vm.invoices[invoice_id] = Dict{Symbol, Any}(
            :id => invoice_id, :timesheet_id => timesheet_id, :rate => rate,
            :amount => amount, :status => :pending, :disputed => false,
        )
        return Dict("invoice" => invoice_id, "amount" => amount, "success" => true)

    elseif opcode == 0x24  # CONTRACT -- binding agreement between two parties
        party_a = get(args, :party_a, vm.current_sender)
        party_b = get(args, :party_b, "")
        isempty(party_b) && return Dict("error" => "party_b required", "success" => false)
        contract_id = get(args, :id, "contract-$(length(vm.contracts) + 1)")
        haskey(vm.contracts, contract_id) && return Dict("error" => "contract already exists: $contract_id", "success" => false)
        vm.contracts[contract_id] = Dict{Symbol, Any}(
            :id => contract_id, :party_a => party_a, :party_b => party_b,
            :terms => get(args, :terms, ""), :status => :active,
        )
        return Dict("contract" => contract_id, "status" => "active", "success" => true)

    elseif opcode == 0x25  # DISPUTE -- raise a conflict on a contract or invoice, freezes payment
        target_type = get(args, :target_type, "")
        target_id = get(args, :target_id, "")
        if target_type == "invoice"
            haskey(vm.invoices, target_id) || return Dict("error" => "unknown invoice: $target_id", "success" => false)
            vm.invoices[target_id][:disputed] = true
        elseif target_type == "contract"
            haskey(vm.contracts, target_id) || return Dict("error" => "unknown contract: $target_id", "success" => false)
            vm.contracts[target_id][:status] = :disputed
        else
            return Dict("error" => "target_type must be invoice or contract", "success" => false)
        end
        dispute_id = get(args, :id, "dispute-$(length(vm.disputes) + 1)")
        vm.disputes[dispute_id] = Dict{Symbol, Any}(
            :id => dispute_id, :target_type => target_type, :target_id => target_id,
            :reason => get(args, :reason, ""), :status => :open,
        )
        return Dict("dispute" => dispute_id, "target" => target_id, "success" => true)

    # Quadrinity Government cluster (real stateful tracking, not decorative)
    elseif opcode in 0x40:0x53  # Quadrinity Government cluster
        return handle_quadrinity_government(vm, opcode, args)

    # Òrìṣà spiritual attributes (invocations)
    elseif opcode == 0xa0  # ORISA_OBATALA
        return Dict("orisa" => "Ọbàtálá", "aspect" => "purity", "ase" => 1.0)
        
    elseif opcode == 0xa6  # ORISA_ESU
        return Dict("orisa" => "Èṣù", "aspect" => "crossroads", "message" => "Choice granted")
        
    else
        # Unknown opcode - log and continue
        @warn "Unknown opcode: 0x$(string(opcode, base=16, pad=2)) ($attr)"
        res = Dict("status" => "unknown_opcode", "opcode" => opcode)
    end
    
    elapsed = (time() - start_time) * 1000
    times = get!(vm.latency_log, opcode, Float64[])
    push!(times, elapsed)
    
    return res
    finally
        vm.in_execution = false
    end
end

"""
Execute IR program on VM
"""
function execute_ir(vm::VMState, ir::OsoCompiler.IR; sender::String="genesis")::Vector{Any}
    vm.current_sender = sender
    vm.halted = false
    
    results = Any[]
    batch = OsoCompiler.Instruction[]
    
    for instr in ir
        # Batching logic: collect sequential critical opcodes
        if is_critical(instr.opcode)
            push!(batch, instr)
        else
            # Flush batch before non-critical
            if !isempty(batch)
                append!(results, execute_batch(vm, batch))
                empty!(batch)
            end
            
            # Execute non-critical
            try
                result = execute_instruction(vm, instr)
                push!(results, result)
            catch e
                push!(results, Dict("error" => string(e)))
            end
        end

        if vm.halted
            break
        end
    end
    
    # Final flush
    if !isempty(batch)
        append!(results, execute_batch(vm, batch))
    end
    
    return results
end

function execute_batch(vm::VMState, batch::Vector{OsoCompiler.Instruction})::Vector{Any}
    if isempty(batch) return [] end
    
    # println("📦 Batching $(length(batch)) Sui transactions...")
    start_time = time()
    
    results = Any[]
    for instr in batch
        try
            result = execute_instruction(vm, instr)
            push!(results, result)
            if vm.halted
                break
            end
        catch e
            push!(results, Dict("error" => string(e)))
            break
        end
    end
    return results
end

"""
Pretty print VM state
"""
function print_state(vm::VMState)
    println("\n=== Ọ̀ṢỌ́ VM State ===")
    println("Chain: $(vm.chain_id)")
    println("Block: $(vm.block_height) | Time: $(vm.block_time)")
    println("\nAṣẹ Balances:")
    for (wallet, balance) in vm.ase_balance
        println("  $wallet: $balance Aṣẹ")
    end
    println("\nStaked:")
    for (wallet, staked) in vm.staked
        println("  $wallet: $staked Aṣẹ")
    end
    println("\nTithe Collected: $(vm.tithe_collected) Aṣẹ")
    println("Receipts: $(length(vm.receipts))")
    println("Events: $(length(vm.events))")
    println("===================\n")
end

end # module
