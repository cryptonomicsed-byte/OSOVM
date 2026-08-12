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
    # TechGnØŞ.EXE Church cluster (real stateful tracking, replaces
    # call_ase_vault() offload for LITURGY/SERMON/PRAYER/OFFERING/BLESSING/
    # CURSE/PROPHET/PRIEST/ACOLYTE/SHRINE/RELIC/SCRIPTURE/HERESY/
    # EXCOMMUNICATE/CANONIZE/MIRACLE/PILGRIMAGE/FAST/FEAST/BAPTISM/
    # COMMUNION/CONFESSION/PENANCE/ABSOLUTION/RESURRECTION). Clergy
    # hierarchy (acolyte -> priest) and confession/absolution lifecycle
    # are the real invariants; final_signer stands in for church authority
    # on canonize/excommunicate, matching Quadrinity's use of final_signer.
    liturgies::Dict{String, Dict{Symbol, Any}}
    sermons::Dict{String, Dict{Symbol, Any}}
    prayers::Dict{String, Dict{Symbol, Any}}
    offerings::Dict{String, Dict{Symbol, Any}}
    blessings::Dict{String, Dict{Symbol, Any}}
    curses::Dict{String, Dict{Symbol, Any}}
    prophets::Dict{String, Bool}                   # name => recognized
    priests::Dict{String, String}                  # name => ordained_by
    acolytes::Dict{String, String}                  # name => mentor priest
    shrines::Dict{String, Dict{Symbol, Any}}
    relics::Dict{String, Dict{Symbol, Any}}
    scriptures::Dict{String, Dict{Symbol, Any}}
    heresies::Dict{String, Dict{Symbol, Any}}
    excommunicated::Dict{String, Bool}
    canonized::Dict{String, Bool}
    miracles::Dict{String, Dict{Symbol, Any}}
    pilgrimages::Dict{String, Dict{Symbol, Any}}
    fasts::Dict{String, Dict{Symbol, Any}}
    feasts::Dict{String, Dict{Symbol, Any}}
    baptized::Dict{String, Bool}
    communions::Dict{String, Dict{Symbol, Any}}
    confessions::Dict{String, Dict{Symbol, Any}}
    penances::Dict{String, Dict{Symbol, Any}}
    resurrections::Dict{String, Dict{Symbol, Any}}
    # SimaaS Hospital cluster (real stateful tracking, replaces
    # call_ase_vault() offload for PATIENT/DIAGNOSIS/TREATMENT/
    # PRESCRIPTION/SURGERY/THERAPY/VITALS/ADMISSION/DISCHARGE/EMERGENCY/
    # TRIAGE/WARD/ICU/MORGUE/AUTOPSY/QUARANTINE/VACCINE/PANDEMIC/
    # RECOVERY/RELAPSE). A patient's care lifecycle (register -> diagnose
    # -> admit -> discharge, or -> morgue -> autopsy) is the real
    # invariant chain, mirroring Church's clergy progression pattern.
    patients::Dict{String, Dict{Symbol, Any}}
    diagnoses::Dict{String, Dict{Symbol, Any}}
    treatments::Dict{String, Dict{Symbol, Any}}
    prescriptions::Dict{String, Dict{Symbol, Any}}
    surgeries::Dict{String, Dict{Symbol, Any}}
    therapies::Dict{String, Dict{Symbol, Any}}
    vitals::Dict{String, Vector{Dict{Symbol, Any}}}   # patient_id => readings
    admissions::Dict{String, Dict{Symbol, Any}}       # patient_id => {ward_id, ...} while admitted
    wards::Dict{String, Dict{Symbol, Any}}            # id => {capacity, occupants}
    icus::Dict{String, Dict{Symbol, Any}}             # id => {capacity, occupants}
    morgue::Dict{String, Dict{Symbol, Any}}           # patient_id => {cause}
    autopsies::Dict{String, Dict{Symbol, Any}}
    quarantines::Dict{String, Dict{Symbol, Any}}      # patient_id => {reason, active}
    vaccinations::Dict{String, Vector{String}}        # patient_id => [vaccine names]
    pandemics::Dict{String, Dict{Symbol, Any}}
    recoveries::Dict{String, Dict{Symbol, Any}}       # patient_id => {condition, recovered_at}
    relapses::Dict{String, Dict{Symbol, Any}}
    # Òrìṣà Spiritual Layer cluster (real stateful tracking, replaces both
    # call_ase_vault() offload and the two decorative fixed-response
    # invocations ORISA_OBATALA/ORISA_ESU used to be). Divination lineage
    # (INITIATION -> DIVINER -> BABALAWO/IYALAWO) and the divination chain
    # (IFA_DIVINATION -> ODU -> ESE) are the real invariant chains.
    orisa_invocations::Dict{String, Dict{Symbol, Any}}   # id => {orisa, invoker}
    divinations::Dict{String, Dict{Symbol, Any}}
    odus::Dict{String, Dict{Symbol, Any}}
    eses::Dict{String, Dict{Symbol, Any}}
    ebos::Dict{String, Dict{Symbol, Any}}
    ase_invocations::Dict{String, Dict{Symbol, Any}}
    ancestral_calls::Dict{String, Dict{Symbol, Any}}
    libations::Dict{String, Dict{Symbol, Any}}
    initiated::Dict{String, Bool}
    diviners::Dict{String, String}          # name => initiated_by
    babalawos::Dict{String, Bool}
    iyalawos::Dict{String, Bool}
    iles::Dict{String, Dict{Symbol, Any}}
    egbes::Dict{String, Dict{Symbol, Any}}
    oris::Dict{String, Dict{Symbol, Any}}   # person => {destiny}, requires initiated
    eguns::Dict{String, Dict{Symbol, Any}}
    ajoguns::Dict{String, Dict{Symbol, Any}}
    ibejis::Dict{String, Dict{Symbol, Any}}
    # Economic Extensions cluster (real stateful tracking, replaces
    # call_ase_vault() offload for MARKET/ORDER/LIQUIDITY/SWAP/YIELD/
    # BOND/EQUITY/DIVIDEND/INTEREST/COLLATERAL/LOAN/REPAYMENT/DEFAULT/
    # LIQUIDATION/AUCTION/INSURANCE/CLAIM/PREMIUM/UNDERWRITE/HEDGE).
    # The real invariant chain: COLLATERAL -> LOAN -> REPAYMENT/DEFAULT
    # -> LIQUIDATION, and INSURANCE -> PREMIUM/UNDERWRITE -> CLAIM.
    markets::Dict{String, Dict{Symbol, Any}}
    orders::Dict{String, Dict{Symbol, Any}}
    liquidity_pools::Dict{String, Dict{Symbol, Any}}
    swaps::Dict{String, Dict{Symbol, Any}}
    yields::Dict{String, Dict{Symbol, Any}}
    bonds::Dict{String, Dict{Symbol, Any}}
    equities::Dict{String, Dict{Symbol, Any}}
    dividends::Dict{String, Dict{Symbol, Any}}
    interests::Dict{String, Dict{Symbol, Any}}
    collaterals::Dict{String, Dict{Symbol, Any}}
    loans::Dict{String, Dict{Symbol, Any}}
    repayments::Dict{String, Dict{Symbol, Any}}
    defaults::Dict{String, Dict{Symbol, Any}}     # loan_id => {...}
    liquidations::Dict{String, Dict{Symbol, Any}}
    auctions::Dict{String, Dict{Symbol, Any}}
    insurances::Dict{String, Dict{Symbol, Any}}
    claims::Dict{String, Dict{Symbol, Any}}
    premiums::Dict{String, Dict{Symbol, Any}}
    underwrites::Dict{String, Dict{Symbol, Any}}
    hedges::Dict{String, Dict{Symbol, Any}}
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
        Dict{String, Dict{Symbol, Any}}(),   # sanctions
        # TechGnØŞ.EXE Church cluster
        Dict{String, Dict{Symbol, Any}}(),   # liturgies
        Dict{String, Dict{Symbol, Any}}(),   # sermons
        Dict{String, Dict{Symbol, Any}}(),   # prayers
        Dict{String, Dict{Symbol, Any}}(),   # offerings
        Dict{String, Dict{Symbol, Any}}(),   # blessings
        Dict{String, Dict{Symbol, Any}}(),   # curses
        Dict{String, Bool}(),                # prophets
        Dict{String, String}(),              # priests
        Dict{String, String}(),              # acolytes
        Dict{String, Dict{Symbol, Any}}(),   # shrines
        Dict{String, Dict{Symbol, Any}}(),   # relics
        Dict{String, Dict{Symbol, Any}}(),   # scriptures
        Dict{String, Dict{Symbol, Any}}(),   # heresies
        Dict{String, Bool}(),                # excommunicated
        Dict{String, Bool}(),                # canonized
        Dict{String, Dict{Symbol, Any}}(),   # miracles
        Dict{String, Dict{Symbol, Any}}(),   # pilgrimages
        Dict{String, Dict{Symbol, Any}}(),   # fasts
        Dict{String, Dict{Symbol, Any}}(),   # feasts
        Dict{String, Bool}(),                # baptized
        Dict{String, Dict{Symbol, Any}}(),   # communions
        Dict{String, Dict{Symbol, Any}}(),   # confessions
        Dict{String, Dict{Symbol, Any}}(),   # penances
        Dict{String, Dict{Symbol, Any}}(),   # resurrections
        # SimaaS Hospital cluster
        Dict{String, Dict{Symbol, Any}}(),   # patients
        Dict{String, Dict{Symbol, Any}}(),   # diagnoses
        Dict{String, Dict{Symbol, Any}}(),   # treatments
        Dict{String, Dict{Symbol, Any}}(),   # prescriptions
        Dict{String, Dict{Symbol, Any}}(),   # surgeries
        Dict{String, Dict{Symbol, Any}}(),   # therapies
        Dict{String, Vector{Dict{Symbol, Any}}}(),  # vitals
        Dict{String, Dict{Symbol, Any}}(),   # admissions
        Dict{String, Dict{Symbol, Any}}(),   # wards
        Dict{String, Dict{Symbol, Any}}(),   # icus
        Dict{String, Dict{Symbol, Any}}(),   # morgue
        Dict{String, Dict{Symbol, Any}}(),   # autopsies
        Dict{String, Dict{Symbol, Any}}(),   # quarantines
        Dict{String, Vector{String}}(),      # vaccinations
        Dict{String, Dict{Symbol, Any}}(),   # pandemics
        Dict{String, Dict{Symbol, Any}}(),   # recoveries
        Dict{String, Dict{Symbol, Any}}(),   # relapses
        # Òrìṣà Spiritual Layer cluster
        Dict{String, Dict{Symbol, Any}}(),   # orisa_invocations
        Dict{String, Dict{Symbol, Any}}(),   # divinations
        Dict{String, Dict{Symbol, Any}}(),   # odus
        Dict{String, Dict{Symbol, Any}}(),   # eses
        Dict{String, Dict{Symbol, Any}}(),   # ebos
        Dict{String, Dict{Symbol, Any}}(),   # ase_invocations
        Dict{String, Dict{Symbol, Any}}(),   # ancestral_calls
        Dict{String, Dict{Symbol, Any}}(),   # libations
        Dict{String, Bool}(),                # initiated
        Dict{String, String}(),              # diviners
        Dict{String, Bool}(),                # babalawos
        Dict{String, Bool}(),                # iyalawos
        Dict{String, Dict{Symbol, Any}}(),   # iles
        Dict{String, Dict{Symbol, Any}}(),   # egbes
        Dict{String, Dict{Symbol, Any}}(),   # oris
        Dict{String, Dict{Symbol, Any}}(),   # eguns
        Dict{String, Dict{Symbol, Any}}(),   # ajoguns
        Dict{String, Dict{Symbol, Any}}(),   # ibejis
        # Economic Extensions cluster
        Dict{String, Dict{Symbol, Any}}(),   # markets
        Dict{String, Dict{Symbol, Any}}(),   # orders
        Dict{String, Dict{Symbol, Any}}(),   # liquidity_pools
        Dict{String, Dict{Symbol, Any}}(),   # swaps
        Dict{String, Dict{Symbol, Any}}(),   # yields
        Dict{String, Dict{Symbol, Any}}(),   # bonds
        Dict{String, Dict{Symbol, Any}}(),   # equities
        Dict{String, Dict{Symbol, Any}}(),   # dividends
        Dict{String, Dict{Symbol, Any}}(),   # interests
        Dict{String, Dict{Symbol, Any}}(),   # collaterals
        Dict{String, Dict{Symbol, Any}}(),   # loans
        Dict{String, Dict{Symbol, Any}}(),   # repayments
        Dict{String, Dict{Symbol, Any}}(),   # defaults
        Dict{String, Dict{Symbol, Any}}(),   # liquidations
        Dict{String, Dict{Symbol, Any}}(),   # auctions
        Dict{String, Dict{Symbol, Any}}(),   # insurances
        Dict{String, Dict{Symbol, Any}}(),   # claims
        Dict{String, Dict{Symbol, Any}}(),   # premiums
        Dict{String, Dict{Symbol, Any}}(),   # underwrites
        Dict{String, Dict{Symbol, Any}}()    # hedges
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
        # TechGnØŞ.EXE Church cluster: real stateful handlers below
        # replace call_ase_vault() offload for all 25 opcodes 0x60-0x78.
        0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73,
        0x74, 0x75, 0x76, 0x77, 0x78,
        # SimaaS Hospital cluster: real stateful handlers below replace
        # call_ase_vault() offload for all 20 opcodes 0x80-0x93.
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93,
        # Òrìṣà Spiritual Layer cluster: real stateful handlers below
        # replace call_ase_vault() offload for the other 23 opcodes, plus
        # the two decorative fixed-response branches 0xa0/0xa6 already
        # listed above.
        0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa7, 0xa8, 0xa9,
        0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3,
        0xb4, 0xb5, 0xb6, 0xb7, 0xb8,
        # Economic Extensions cluster: real stateful handlers below
        # replace call_ase_vault() offload for all 20 opcodes 0xc0-0xd3.
        0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
        0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3,
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

# TechGnØŞ.EXE Church cluster (real stateful tracking, not decorative).
# Split into 5 sub-functions of 5 opcodes each from the start -- a single
# 20-branch function (Quadrinity Government) reproducibly hung julia's LLVM
# codegen for 90s+; keeping each function small avoids that pathology.
function handle_church_1(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x60  # LITURGY -- sacred ritual
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "liturgy id required", "success" => false)
        haskey(vm.liturgies, id) && return Dict("error" => "liturgy already exists: $id", "success" => false)
        vm.liturgies[id] = Dict{Symbol, Any}(:id => id, :ritual => get(args, :ritual, ""), :celebrant => vm.current_sender)
        return Dict("liturgy" => id, "success" => true)

    elseif opcode == 0x61  # SERMON -- teaching, requires an ordained priest
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "sermon id required", "success" => false)
        preacher = get(args, :preacher, vm.current_sender)
        haskey(vm.priests, preacher) || return Dict("error" => "preacher must be an ordained priest: $preacher", "success" => false)
        vm.sermons[id] = Dict{Symbol, Any}(:id => id, :preacher => preacher, :topic => get(args, :topic, ""))
        return Dict("sermon" => id, "success" => true)

    elseif opcode == 0x62  # PRAYER -- invocation
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "prayer id required", "success" => false)
        haskey(vm.prayers, id) && return Dict("error" => "prayer already exists: $id", "success" => false)
        vm.prayers[id] = Dict{Symbol, Any}(:id => id, :petitioner => vm.current_sender, :text => get(args, :text, ""), :status => :pending)
        return Dict("prayer" => id, "status" => "pending", "success" => true)

    elseif opcode == 0x63  # OFFERING -- donation, requires an existing shrine
        id = get(args, :id, "offering-$(length(vm.offerings) + 1)")
        shrine_id = get(args, :shrine_id, "")
        haskey(vm.shrines, shrine_id) || return Dict("error" => "unknown shrine: $shrine_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount <= 0.0 && return Dict("error" => "offering amount must be positive", "success" => false)
        vm.offerings[id] = Dict{Symbol, Any}(:id => id, :donor => vm.current_sender, :shrine_id => shrine_id, :amount => amount)
        return Dict("offering" => id, "amount" => amount, "success" => true)

    elseif opcode == 0x64  # BLESSING -- divine favor, only a priest may grant
        id = get(args, :id, "blessing-$(length(vm.blessings) + 1)")
        grantor = get(args, :grantor, vm.current_sender)
        haskey(vm.priests, grantor) || return Dict("error" => "only a priest may bless: $grantor", "success" => false)
        target = get(args, :target, "")
        isempty(target) && return Dict("error" => "blessing target required", "success" => false)
        vm.blessings[id] = Dict{Symbol, Any}(:id => id, :target => target, :grantor => grantor)
        return Dict("blessing" => id, "target" => target, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x60-0x64", "success" => false)
    end
end

function handle_church_2(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x65  # CURSE -- spiritual penalty
        id = get(args, :id, "curse-$(length(vm.curses) + 1)")
        target = get(args, :target, "")
        isempty(target) && return Dict("error" => "curse target required", "success" => false)
        reason = get(args, :reason, "")
        isempty(reason) && return Dict("error" => "curse reason required", "success" => false)
        vm.curses[id] = Dict{Symbol, Any}(:id => id, :target => target, :reason => reason, :active => true)
        return Dict("curse" => id, "target" => target, "success" => true)

    elseif opcode == 0x66  # PROPHET -- recognize an oracle, final_signer only
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "prophet name required", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may recognize a prophet", "success" => false)
        get(vm.prophets, name, false) && return Dict("error" => "already a recognized prophet: $name", "success" => false)
        vm.prophets[name] = true
        return Dict("prophet" => name, "success" => true)

    elseif opcode == 0x67  # PRIEST -- ordain, requires the candidate was first an acolyte
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "priest name required", "success" => false)
        haskey(vm.priests, name) && return Dict("error" => "already a priest: $name", "success" => false)
        haskey(vm.acolytes, name) || return Dict("error" => "must first be an acolyte: $name", "success" => false)
        get(vm.excommunicated, name, false) && return Dict("error" => "excommunicated, cannot ordain: $name", "success" => false)
        delete!(vm.acolytes, name)
        vm.priests[name] = vm.current_sender
        return Dict("priest" => name, "ordained_by" => vm.current_sender, "success" => true)

    elseif opcode == 0x68  # ACOLYTE -- initiate, mentor must be a priest
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "acolyte name required", "success" => false)
        haskey(vm.acolytes, name) && return Dict("error" => "already an acolyte: $name", "success" => false)
        mentor = get(args, :mentor, vm.current_sender)
        haskey(vm.priests, mentor) || return Dict("error" => "mentor must be a priest: $mentor", "success" => false)
        vm.acolytes[name] = mentor
        return Dict("acolyte" => name, "mentor" => mentor, "success" => true)

    elseif opcode == 0x69  # SHRINE -- sacred space, keeper must be a priest
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "shrine id required", "success" => false)
        haskey(vm.shrines, id) && return Dict("error" => "shrine already exists: $id", "success" => false)
        keeper = get(args, :keeper, vm.current_sender)
        haskey(vm.priests, keeper) || return Dict("error" => "keeper must be a priest: $keeper", "success" => false)
        vm.shrines[id] = Dict{Symbol, Any}(:id => id, :keeper => keeper, :location => get(args, :location, ""))
        return Dict("shrine" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x65-0x69", "success" => false)
    end
end

function handle_church_3(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x6a  # RELIC -- artifact, requires an existing shrine
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "relic id required", "success" => false)
        haskey(vm.relics, id) && return Dict("error" => "relic already exists: $id", "success" => false)
        shrine_id = get(args, :shrine_id, "")
        haskey(vm.shrines, shrine_id) || return Dict("error" => "unknown shrine: $shrine_id", "success" => false)
        vm.relics[id] = Dict{Symbol, Any}(:id => id, :shrine_id => shrine_id, :name => get(args, :name, ""))
        return Dict("relic" => id, "success" => true)

    elseif opcode == 0x6b  # SCRIPTURE -- canon text
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "scripture id required", "success" => false)
        haskey(vm.scriptures, id) && return Dict("error" => "scripture already exists: $id", "success" => false)
        text = get(args, :text, "")
        isempty(text) && return Dict("error" => "scripture text required", "success" => false)
        vm.scriptures[id] = Dict{Symbol, Any}(:id => id, :text => text, :canonized => false)
        return Dict("scripture" => id, "success" => true)

    elseif opcode == 0x6c  # HERESY -- doctrinal violation, target must be clergy
        id = get(args, :id, "heresy-$(length(vm.heresies) + 1)")
        accused = get(args, :accused, "")
        (haskey(vm.priests, accused) || haskey(vm.acolytes, accused)) ||
            return Dict("error" => "accused must be clergy: $accused", "success" => false)
        charge = get(args, :charge, "")
        isempty(charge) && return Dict("error" => "heresy charge required", "success" => false)
        vm.heresies[id] = Dict{Symbol, Any}(:id => id, :accused => accused, :charge => charge, :status => :open)
        return Dict("heresy" => id, "success" => true)

    elseif opcode == 0x6d  # EXCOMMUNICATE -- expel, requires an open heresy charge, final_signer only
        target = get(args, :target, "")
        isempty(target) && return Dict("error" => "excommunicate target required", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may excommunicate", "success" => false)
        heresy_id = get(args, :heresy_id, "")
        haskey(vm.heresies, heresy_id) && vm.heresies[heresy_id][:accused] == target && vm.heresies[heresy_id][:status] == :open ||
            return Dict("error" => "requires an open heresy charge against target", "success" => false)
        vm.heresies[heresy_id][:status] = :resolved
        delete!(vm.priests, target)
        delete!(vm.acolytes, target)
        vm.excommunicated[target] = true
        return Dict("excommunicated" => target, "success" => true)

    elseif opcode == 0x6e  # CANONIZE -- declare saint, final_signer only, not excommunicated
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "canonize name required", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may canonize", "success" => false)
        get(vm.excommunicated, name, false) && return Dict("error" => "excommunicated, cannot canonize: $name", "success" => false)
        get(vm.canonized, name, false) && return Dict("error" => "already canonized: $name", "success" => false)
        vm.canonized[name] = true
        return Dict("canonized" => name, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x6a-0x6e", "success" => false)
    end
end

function handle_church_4(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x6f  # MIRACLE -- divine event, requires a witness
        id = get(args, :id, "miracle-$(length(vm.miracles) + 1)")
        witness = get(args, :witness, "")
        isempty(witness) && return Dict("error" => "miracle witness required", "success" => false)
        vm.miracles[id] = Dict{Symbol, Any}(:id => id, :witness => witness, :description => get(args, :description, ""))
        return Dict("miracle" => id, "success" => true)

    elseif opcode == 0x70  # PILGRIMAGE -- sacred journey, requires an existing shrine
        id = get(args, :id, "pilgrimage-$(length(vm.pilgrimages) + 1)")
        shrine_id = get(args, :shrine_id, "")
        haskey(vm.shrines, shrine_id) || return Dict("error" => "unknown shrine: $shrine_id", "success" => false)
        vm.pilgrimages[id] = Dict{Symbol, Any}(:id => id, :pilgrim => vm.current_sender, :shrine_id => shrine_id, :status => :underway)
        return Dict("pilgrimage" => id, "success" => true)

    elseif opcode == 0x71  # FAST -- ritual abstinence, end must be after start
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "fast id required", "success" => false)
        haskey(vm.fasts, id) && return Dict("error" => "fast already exists: $id", "success" => false)
        start_t = get(args, :start, 0); end_t = get(args, :end, 0)
        end_t <= start_t && return Dict("error" => "fast end must be after start", "success" => false)
        vm.fasts[id] = Dict{Symbol, Any}(:id => id, :practitioner => vm.current_sender, :start => start_t, :end => end_t)
        return Dict("fast" => id, "success" => true)

    elseif opcode == 0x72  # FEAST -- celebration
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "feast id required", "success" => false)
        haskey(vm.feasts, id) && return Dict("error" => "feast already exists: $id", "success" => false)
        vm.feasts[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""), :date => get(args, :date, 0))
        return Dict("feast" => id, "success" => true)

    elseif opcode == 0x73  # BAPTISM -- initiation, cannot double-baptize
        name = get(args, :name, vm.current_sender)
        get(vm.baptized, name, false) && return Dict("error" => "already baptized: $name", "success" => false)
        vm.baptized[name] = true
        return Dict("baptized" => name, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x6f-0x73", "success" => false)
    end
end

function handle_church_5(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x74  # COMMUNION -- sacred meal, participant must be baptized, priest must exist
        id = get(args, :id, "communion-$(length(vm.communions) + 1)")
        participant = get(args, :participant, vm.current_sender)
        get(vm.baptized, participant, false) || return Dict("error" => "participant must be baptized: $participant", "success" => false)
        priest = get(args, :priest, "")
        haskey(vm.priests, priest) || return Dict("error" => "unknown priest: $priest", "success" => false)
        vm.communions[id] = Dict{Symbol, Any}(:id => id, :participant => participant, :priest => priest)
        return Dict("communion" => id, "success" => true)

    elseif opcode == 0x75  # CONFESSION -- admission, priest must exist
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "confession id required", "success" => false)
        haskey(vm.confessions, id) && return Dict("error" => "confession already exists: $id", "success" => false)
        priest = get(args, :priest, "")
        haskey(vm.priests, priest) || return Dict("error" => "unknown priest: $priest", "success" => false)
        vm.confessions[id] = Dict{Symbol, Any}(:id => id, :confessor => vm.current_sender, :priest => priest, :sin => get(args, :sin, ""), :absolved => false)
        return Dict("confession" => id, "success" => true)

    elseif opcode == 0x76  # PENANCE -- atonement act, requires an existing unabsolved confession
        id = get(args, :id, "penance-$(length(vm.penances) + 1)")
        confession_id = get(args, :confession_id, "")
        haskey(vm.confessions, confession_id) || return Dict("error" => "unknown confession: $confession_id", "success" => false)
        vm.confessions[confession_id][:absolved] && return Dict("error" => "confession already absolved: $confession_id", "success" => false)
        act = get(args, :act, "")
        isempty(act) && return Dict("error" => "penance act required", "success" => false)
        vm.penances[id] = Dict{Symbol, Any}(:id => id, :confession_id => confession_id, :act => act)
        return Dict("penance" => id, "success" => true)

    elseif opcode == 0x77  # ABSOLUTION -- forgiveness, only the confession's own priest may grant
        confession_id = get(args, :confession_id, "")
        haskey(vm.confessions, confession_id) || return Dict("error" => "unknown confession: $confession_id", "success" => false)
        c = vm.confessions[confession_id]
        c[:absolved] && return Dict("error" => "already absolved: $confession_id", "success" => false)
        vm.current_sender == c[:priest] || return Dict("error" => "only the confessor's priest may absolve", "success" => false)
        c[:absolved] = true
        return Dict("confession" => confession_id, "status" => "absolved", "success" => true)

    elseif opcode == 0x78  # RESURRECTION -- rebirth, final_signer only, requires a witness
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "resurrection id required", "success" => false)
        haskey(vm.resurrections, id) && return Dict("error" => "resurrection already exists: $id", "success" => false)
        vm.current_sender == vm.final_signer || return Dict("error" => "only final_signer may declare a resurrection", "success" => false)
        subject = get(args, :subject, "")
        isempty(subject) && return Dict("error" => "resurrection subject required", "success" => false)
        witnessed_by = get(args, :witnessed_by, "")
        isempty(witnessed_by) && return Dict("error" => "resurrection requires a witness", "success" => false)
        vm.resurrections[id] = Dict{Symbol, Any}(:id => id, :subject => subject, :witnessed_by => witnessed_by)
        return Dict("resurrection" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x74-0x78", "success" => false)
    end
end

function handle_church(vm::VMState, opcode::UInt8, args)::Any
    if opcode in 0x60:0x64
        return handle_church_1(vm, opcode, args)
    elseif opcode in 0x65:0x69
        return handle_church_2(vm, opcode, args)
    elseif opcode in 0x6a:0x6e
        return handle_church_3(vm, opcode, args)
    elseif opcode in 0x6f:0x73
        return handle_church_4(vm, opcode, args)
    elseif opcode in 0x74:0x78
        return handle_church_5(vm, opcode, args)
    end
end

# SimaaS Hospital cluster (real stateful tracking, not decorative).
# Split into 4 sub-functions of 5 opcodes each from the start (see Church's
# comment for why: giant elseif chains hang julia's LLVM codegen here).
function handle_hospital_1(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x80  # PATIENT -- register a care recipient
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "patient id required", "success" => false)
        haskey(vm.patients, id) && return Dict("error" => "patient already registered: $id", "success" => false)
        vm.patients[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""), :status => :registered)
        return Dict("patient" => id, "success" => true)

    elseif opcode == 0x81  # DIAGNOSIS -- requires an existing patient
        id = get(args, :id, "diagnosis-$(length(vm.diagnoses) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        condition = get(args, :condition, "")
        isempty(condition) && return Dict("error" => "diagnosis condition required", "success" => false)
        vm.diagnoses[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :condition => condition)
        return Dict("diagnosis" => id, "success" => true)

    elseif opcode == 0x82  # TREATMENT -- requires an existing diagnosis
        id = get(args, :id, "treatment-$(length(vm.treatments) + 1)")
        diagnosis_id = get(args, :diagnosis_id, "")
        haskey(vm.diagnoses, diagnosis_id) || return Dict("error" => "unknown diagnosis: $diagnosis_id", "success" => false)
        vm.treatments[id] = Dict{Symbol, Any}(:id => id, :diagnosis_id => diagnosis_id, :plan => get(args, :plan, ""))
        return Dict("treatment" => id, "success" => true)

    elseif opcode == 0x83  # PRESCRIPTION -- requires an existing patient
        id = get(args, :id, "prescription-$(length(vm.prescriptions) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        medicine = get(args, :medicine, "")
        isempty(medicine) && return Dict("error" => "prescription medicine required", "success" => false)
        vm.prescriptions[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :medicine => medicine, :dosage => get(args, :dosage, ""))
        return Dict("prescription" => id, "success" => true)

    elseif opcode == 0x84  # SURGERY -- requires an existing patient and a named surgeon
        id = get(args, :id, "surgery-$(length(vm.surgeries) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        surgeon = get(args, :surgeon, "")
        isempty(surgeon) && return Dict("error" => "surgeon required", "success" => false)
        vm.surgeries[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :surgeon => surgeon, :procedure => get(args, :procedure, ""))
        return Dict("surgery" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x80-0x84", "success" => false)
    end
end

function handle_hospital_2(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x85  # THERAPY -- requires an existing patient
        id = get(args, :id, "therapy-$(length(vm.therapies) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        vm.therapies[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :type => get(args, :type, ""))
        return Dict("therapy" => id, "success" => true)

    elseif opcode == 0x86  # VITALS -- requires an existing patient, records a reading
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        reading = Dict{Symbol, Any}(:hr => get(args, :hr, 0), :bp => get(args, :bp, ""), :temp => get(args, :temp, 0.0))
        readings = get!(vm.vitals, patient_id, Dict{Symbol, Any}[])
        push!(readings, reading)
        return Dict("patient" => patient_id, "readings" => length(readings), "success" => true)

    elseif opcode == 0x87  # ADMISSION -- requires patient + ward with free capacity, not already admitted
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        haskey(vm.admissions, patient_id) && return Dict("error" => "already admitted: $patient_id", "success" => false)
        ward_id = get(args, :ward_id, "")
        haskey(vm.wards, ward_id) || return Dict("error" => "unknown ward: $ward_id", "success" => false)
        ward = vm.wards[ward_id]
        length(ward[:occupants]) >= ward[:capacity] && return Dict("error" => "ward at capacity: $ward_id", "success" => false)
        push!(ward[:occupants], patient_id)
        vm.admissions[patient_id] = Dict{Symbol, Any}(:ward_id => ward_id)
        vm.patients[patient_id][:status] = :admitted
        return Dict("patient" => patient_id, "ward" => ward_id, "success" => true)

    elseif opcode == 0x88  # DISCHARGE -- requires patient currently admitted
        patient_id = get(args, :patient_id, "")
        haskey(vm.admissions, patient_id) || return Dict("error" => "not admitted: $patient_id", "success" => false)
        ward_id = vm.admissions[patient_id][:ward_id]
        haskey(vm.wards, ward_id) && filter!(p -> p != patient_id, vm.wards[ward_id][:occupants])
        delete!(vm.admissions, patient_id)
        vm.patients[patient_id][:status] = :discharged
        return Dict("patient" => patient_id, "status" => "discharged", "success" => true)

    elseif opcode == 0x89  # EMERGENCY -- requires an existing patient, flags emergency status
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        vm.patients[patient_id][:emergency] = true
        return Dict("patient" => patient_id, "emergency" => true, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x85-0x89", "success" => false)
    end
end

function handle_hospital_3(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x8a  # TRIAGE -- requires an existing patient, assigns priority 1-5
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        priority = get(args, :priority, 0)
        (priority < 1 || priority > 5) && return Dict("error" => "priority must be 1-5", "success" => false)
        vm.patients[patient_id][:triage_priority] = priority
        return Dict("patient" => patient_id, "priority" => priority, "success" => true)

    elseif opcode == 0x8b  # WARD -- create a care unit with capacity
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "ward id required", "success" => false)
        haskey(vm.wards, id) && return Dict("error" => "ward already exists: $id", "success" => false)
        capacity = get(args, :capacity, 0)
        capacity <= 0 && return Dict("error" => "ward capacity must be positive", "success" => false)
        vm.wards[id] = Dict{Symbol, Any}(:id => id, :capacity => capacity, :occupants => String[])
        return Dict("ward" => id, "success" => true)

    elseif opcode == 0x8c  # ICU -- create an intensive-care unit with capacity
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "icu id required", "success" => false)
        haskey(vm.icus, id) && return Dict("error" => "icu already exists: $id", "success" => false)
        capacity = get(args, :capacity, 0)
        capacity <= 0 && return Dict("error" => "icu capacity must be positive", "success" => false)
        vm.icus[id] = Dict{Symbol, Any}(:id => id, :capacity => capacity, :occupants => String[])
        return Dict("icu" => id, "success" => true)

    elseif opcode == 0x8d  # MORGUE -- register a death, requires patient exists and not already deceased
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        haskey(vm.morgue, patient_id) && return Dict("error" => "already in morgue: $patient_id", "success" => false)
        vm.morgue[patient_id] = Dict{Symbol, Any}(:patient_id => patient_id, :cause => get(args, :cause, ""))
        vm.patients[patient_id][:status] = :deceased
        return Dict("patient" => patient_id, "status" => "deceased", "success" => true)

    elseif opcode == 0x8e  # AUTOPSY -- requires patient is in the morgue
        id = get(args, :id, "autopsy-$(length(vm.autopsies) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.morgue, patient_id) || return Dict("error" => "patient not in morgue: $patient_id", "success" => false)
        vm.autopsies[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :findings => get(args, :findings, ""))
        return Dict("autopsy" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x8a-0x8e", "success" => false)
    end
end

function handle_hospital_4(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0x8f  # QUARANTINE -- requires an existing patient
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        vm.quarantines[patient_id] = Dict{Symbol, Any}(:reason => get(args, :reason, ""), :active => true)
        return Dict("patient" => patient_id, "quarantined" => true, "success" => true)

    elseif opcode == 0x90  # VACCINE -- requires patient, cannot give the same vaccine twice
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        vaccine = get(args, :vaccine, "")
        isempty(vaccine) && return Dict("error" => "vaccine name required", "success" => false)
        given = get!(vm.vaccinations, patient_id, String[])
        vaccine in given && return Dict("error" => "already vaccinated with $vaccine", "success" => false)
        push!(given, vaccine)
        return Dict("patient" => patient_id, "vaccine" => vaccine, "success" => true)

    elseif opcode == 0x91  # PANDEMIC -- declare a mass outbreak
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "pandemic id required", "success" => false)
        haskey(vm.pandemics, id) && return Dict("error" => "pandemic already declared: $id", "success" => false)
        vm.pandemics[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""), :active => true)
        return Dict("pandemic" => id, "success" => true)

    elseif opcode == 0x92  # RECOVERY -- requires an existing diagnosis, marks the condition recovered
        patient_id = get(args, :patient_id, "")
        haskey(vm.patients, patient_id) || return Dict("error" => "unknown patient: $patient_id", "success" => false)
        condition = get(args, :condition, "")
        isempty(condition) && return Dict("error" => "recovery condition required", "success" => false)
        vm.recoveries[patient_id] = Dict{Symbol, Any}(:patient_id => patient_id, :condition => condition)
        return Dict("patient" => patient_id, "status" => "recovered", "success" => true)

    elseif opcode == 0x93  # RELAPSE -- requires a prior recorded recovery for that patient
        id = get(args, :id, "relapse-$(length(vm.relapses) + 1)")
        patient_id = get(args, :patient_id, "")
        haskey(vm.recoveries, patient_id) || return Dict("error" => "no recovery on record for: $patient_id", "success" => false)
        vm.relapses[id] = Dict{Symbol, Any}(:id => id, :patient_id => patient_id, :condition => vm.recoveries[patient_id][:condition])
        delete!(vm.recoveries, patient_id)
        return Dict("relapse" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0x8f-0x93", "success" => false)
    end
end

function handle_hospital(vm::VMState, opcode::UInt8, args)::Any
    if opcode in 0x80:0x84
        return handle_hospital_1(vm, opcode, args)
    elseif opcode in 0x85:0x89
        return handle_hospital_2(vm, opcode, args)
    elseif opcode in 0x8a:0x8e
        return handle_hospital_3(vm, opcode, args)
    elseif opcode in 0x8f:0x93
        return handle_hospital_4(vm, opcode, args)
    end
end

# Òrìṣà Spiritual Layer cluster (real stateful tracking, not decorative).
# Split into 5 sub-functions of 5 opcodes each from the start (same
# rationale as Church/Hospital -- giant elseif chains hang julia's codegen
# on this VPS). Divination lineage (INITIATION -> DIVINER -> BABALAWO/
# IYALAWO) and the divination chain (IFA_DIVINATION -> ODU -> ESE) are the
# real invariant chains; the 7 ORISA_* invocation opcodes share one
# generic dedupe-by-id pattern since they differ only in which òrìṣà.
function handle_orisa_1(vm::VMState, opcode::UInt8, args)::Any
    orisa_names = Dict{UInt8, String}(0xa0 => "Ọbàtálá", 0xa1 => "Ògún", 0xa2 => "Yemọja", 0xa3 => "Ṣàngó", 0xa4 => "Ọ̀ṣun")
    if opcode in keys(orisa_names)
        id = get(args, :id, "invocation-$(length(vm.orisa_invocations) + 1)")
        haskey(vm.orisa_invocations, id) && return Dict("error" => "invocation already exists: $id", "success" => false)
        vm.orisa_invocations[id] = Dict{Symbol, Any}(:id => id, :orisa => orisa_names[opcode], :invoker => vm.current_sender)
        return Dict("invocation" => id, "orisa" => orisa_names[opcode], "success" => true)
    else
        return Dict("error" => "unreachable: opcode not in 0xa0-0xa4", "success" => false)
    end
end

function handle_orisa_2(vm::VMState, opcode::UInt8, args)::Any
    orisa_names = Dict{UInt8, String}(0xa5 => "Ọya", 0xa6 => "Èṣù", 0xa7 => "Ọ̀rúnmìlà")
    if opcode in keys(orisa_names)
        id = get(args, :id, "invocation-$(length(vm.orisa_invocations) + 1)")
        haskey(vm.orisa_invocations, id) && return Dict("error" => "invocation already exists: $id", "success" => false)
        vm.orisa_invocations[id] = Dict{Symbol, Any}(:id => id, :orisa => orisa_names[opcode], :invoker => vm.current_sender)
        return Dict("invocation" => id, "orisa" => orisa_names[opcode], "success" => true)

    elseif opcode == 0xa8  # IFA_DIVINATION -- oracle reading, requires a real diviner
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "divination id required", "success" => false)
        haskey(vm.divinations, id) && return Dict("error" => "divination already exists: $id", "success" => false)
        diviner = get(args, :diviner, "")
        haskey(vm.diviners, diviner) || return Dict("error" => "unknown diviner: $diviner", "success" => false)
        vm.divinations[id] = Dict{Symbol, Any}(:id => id, :diviner => diviner, :querent => vm.current_sender)
        return Dict("divination" => id, "success" => true)

    elseif opcode == 0xa9  # ODU -- sacred sign, requires an existing divination session
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "odu id required", "success" => false)
        haskey(vm.odus, id) && return Dict("error" => "odu already exists: $id", "success" => false)
        divination_id = get(args, :divination_id, "")
        haskey(vm.divinations, divination_id) || return Dict("error" => "unknown divination: $divination_id", "success" => false)
        vm.odus[id] = Dict{Symbol, Any}(:id => id, :divination_id => divination_id, :sign => get(args, :sign, ""))
        return Dict("odu" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xa5-0xa9", "success" => false)
    end
end

function handle_orisa_3(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xaa  # ESE -- proverb/teaching, requires an existing odu
        id = get(args, :id, "ese-$(length(vm.eses) + 1)")
        odu_id = get(args, :odu_id, "")
        haskey(vm.odus, odu_id) || return Dict("error" => "unknown odu: $odu_id", "success" => false)
        vm.eses[id] = Dict{Symbol, Any}(:id => id, :odu_id => odu_id, :proverb => get(args, :proverb, ""))
        return Dict("ese" => id, "success" => true)

    elseif opcode == 0xab  # EBO -- sacrifice/offering, requires an existing orisa invocation
        id = get(args, :id, "ebo-$(length(vm.ebos) + 1)")
        invocation_id = get(args, :invocation_id, "")
        haskey(vm.orisa_invocations, invocation_id) || return Dict("error" => "unknown invocation: $invocation_id", "success" => false)
        vm.ebos[id] = Dict{Symbol, Any}(:id => id, :invocation_id => invocation_id, :offering => get(args, :offering, ""))
        return Dict("ebo" => id, "success" => true)

    elseif opcode == 0xac  # ASE_INVOCATION -- power call, requires an existing odu or invocation as source
        id = get(args, :id, "ase-$(length(vm.ase_invocations) + 1)")
        source_id = get(args, :source_id, "")
        (haskey(vm.odus, source_id) || haskey(vm.orisa_invocations, source_id)) ||
            return Dict("error" => "unknown source (must be an odu or invocation): $source_id", "success" => false)
        vm.ase_invocations[id] = Dict{Symbol, Any}(:id => id, :source_id => source_id, :invoker => vm.current_sender)
        return Dict("ase_invocation" => id, "success" => true)

    elseif opcode == 0xad  # ANCESTRAL_CALL -- connect lineage
        id = get(args, :id, "call-$(length(vm.ancestral_calls) + 1)")
        lineage = get(args, :lineage, "")
        isempty(lineage) && return Dict("error" => "lineage required", "success" => false)
        vm.ancestral_calls[id] = Dict{Symbol, Any}(:id => id, :caller => vm.current_sender, :lineage => lineage)
        return Dict("ancestral_call" => id, "success" => true)

    elseif opcode == 0xae  # LIBATION -- pour honor, requires an existing ancestor spirit (EGUN)
        id = get(args, :id, "libation-$(length(vm.libations) + 1)")
        egun_id = get(args, :egun_id, "")
        haskey(vm.eguns, egun_id) || return Dict("error" => "unknown ancestor spirit: $egun_id", "success" => false)
        vm.libations[id] = Dict{Symbol, Any}(:id => id, :egun_id => egun_id, :pourer => vm.current_sender)
        return Dict("libation" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xaa-0xae", "success" => false)
    end
end

function handle_orisa_4(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xaf  # INITIATION -- sacred entry, cannot double-initiate
        name = get(args, :name, vm.current_sender)
        get(vm.initiated, name, false) && return Dict("error" => "already initiated: $name", "success" => false)
        vm.initiated[name] = true
        return Dict("initiated" => name, "success" => true)

    elseif opcode == 0xb0  # DIVINER -- oracle priest, requires initiation
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "diviner name required", "success" => false)
        haskey(vm.diviners, name) && return Dict("error" => "already a diviner: $name", "success" => false)
        get(vm.initiated, name, false) || return Dict("error" => "must be initiated first: $name", "success" => false)
        vm.diviners[name] = vm.current_sender
        return Dict("diviner" => name, "success" => true)

    elseif opcode == 0xb1  # BABALAWO -- Ifá priest, requires diviner status
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "babalawo name required", "success" => false)
        haskey(vm.diviners, name) || return Dict("error" => "must be a diviner first: $name", "success" => false)
        get(vm.babalawos, name, false) && return Dict("error" => "already a babalawo: $name", "success" => false)
        vm.babalawos[name] = true
        return Dict("babalawo" => name, "success" => true)

    elseif opcode == 0xb2  # IYALAWO -- Ifá priestess, requires diviner status
        name = get(args, :name, "")
        isempty(name) && return Dict("error" => "iyalawo name required", "success" => false)
        haskey(vm.diviners, name) || return Dict("error" => "must be a diviner first: $name", "success" => false)
        get(vm.iyalawos, name, false) && return Dict("error" => "already an iyalawo: $name", "success" => false)
        vm.iyalawos[name] = true
        return Dict("iyalawo" => name, "success" => true)

    elseif opcode == 0xb3  # ILE -- sacred house
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "ile id required", "success" => false)
        haskey(vm.iles, id) && return Dict("error" => "ile already exists: $id", "success" => false)
        keeper = get(args, :keeper, "")
        isempty(keeper) && return Dict("error" => "ile keeper required", "success" => false)
        vm.iles[id] = Dict{Symbol, Any}(:id => id, :keeper => keeper)
        return Dict("ile" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xaf-0xb3", "success" => false)
    end
end

function handle_orisa_5(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xb4  # EGBE -- spiritual society
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "egbe id required", "success" => false)
        haskey(vm.egbes, id) && return Dict("error" => "egbe already exists: $id", "success" => false)
        members = get(args, :members, String[])
        isempty(members) && return Dict("error" => "egbe members required", "success" => false)
        vm.egbes[id] = Dict{Symbol, Any}(:id => id, :members => members)
        return Dict("egbe" => id, "success" => true)

    elseif opcode == 0xb5  # ORI -- inner head/destiny, requires initiation
        person = get(args, :person, vm.current_sender)
        get(vm.initiated, person, false) || return Dict("error" => "must be initiated first: $person", "success" => false)
        haskey(vm.oris, person) && return Dict("error" => "ori already assigned: $person", "success" => false)
        vm.oris[person] = Dict{Symbol, Any}(:person => person, :destiny => get(args, :destiny, ""))
        return Dict("ori" => person, "success" => true)

    elseif opcode == 0xb6  # EGUN -- ancestor spirit
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "egun id required", "success" => false)
        haskey(vm.eguns, id) && return Dict("error" => "egun already exists: $id", "success" => false)
        vm.eguns[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""))
        return Dict("egun" => id, "success" => true)

    elseif opcode == 0xb7  # AJOGUN -- malevolent force occurrence
        id = get(args, :id, "ajogun-$(length(vm.ajoguns) + 1)")
        harm = get(args, :harm, "")
        isempty(harm) && return Dict("error" => "ajogun harm description required", "success" => false)
        vm.ajoguns[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""), :harm => harm)
        return Dict("ajogun" => id, "success" => true)

    elseif opcode == 0xb8  # IBEJI -- twin spirit, requires two distinct twins
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "ibeji id required", "success" => false)
        haskey(vm.ibejis, id) && return Dict("error" => "ibeji already exists: $id", "success" => false)
        twin1 = get(args, :twin1, ""); twin2 = get(args, :twin2, "")
        (isempty(twin1) || isempty(twin2)) && return Dict("error" => "both twins required", "success" => false)
        twin1 == twin2 && return Dict("error" => "twins must be distinct", "success" => false)
        vm.ibejis[id] = Dict{Symbol, Any}(:id => id, :twin1 => twin1, :twin2 => twin2)
        return Dict("ibeji" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xb4-0xb8", "success" => false)
    end
end

function handle_orisa(vm::VMState, opcode::UInt8, args)::Any
    if opcode in 0xa0:0xa4
        return handle_orisa_1(vm, opcode, args)
    elseif opcode in 0xa5:0xa9
        return handle_orisa_2(vm, opcode, args)
    elseif opcode in 0xaa:0xae
        return handle_orisa_3(vm, opcode, args)
    elseif opcode in 0xaf:0xb3
        return handle_orisa_4(vm, opcode, args)
    elseif opcode in 0xb4:0xb8
        return handle_orisa_5(vm, opcode, args)
    end
end

# Economic Extensions cluster (real stateful tracking, not decorative).
# Split into 4 sub-functions of 5 opcodes each from the start (same
# rationale as the prior three clusters). Real invariant chains:
# COLLATERAL -> LOAN -> REPAYMENT/DEFAULT -> LIQUIDATION, and
# INSURANCE -> PREMIUM/UNDERWRITE -> CLAIM.
function handle_economic_1(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xc0  # MARKET -- trading venue
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "market id required", "success" => false)
        haskey(vm.markets, id) && return Dict("error" => "market already exists: $id", "success" => false)
        vm.markets[id] = Dict{Symbol, Any}(:id => id, :name => get(args, :name, ""))
        return Dict("market" => id, "success" => true)

    elseif opcode == 0xc1  # ORDER -- buy/sell request, requires an existing market
        id = get(args, :id, "order-$(length(vm.orders) + 1)")
        market_id = get(args, :market_id, "")
        haskey(vm.markets, market_id) || return Dict("error" => "unknown market: $market_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount <= 0.0 && return Dict("error" => "order amount must be positive", "success" => false)
        vm.orders[id] = Dict{Symbol, Any}(:id => id, :market_id => market_id, :side => get(args, :side, "buy"), :amount => amount)
        return Dict("order" => id, "success" => true)

    elseif opcode == 0xc2  # LIQUIDITY -- pool depth, requires an existing market
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "liquidity pool id required", "success" => false)
        haskey(vm.liquidity_pools, id) && return Dict("error" => "pool already exists: $id", "success" => false)
        market_id = get(args, :market_id, "")
        haskey(vm.markets, market_id) || return Dict("error" => "unknown market: $market_id", "success" => false)
        depth = Float64(get(args, :depth, 0.0))
        depth <= 0.0 && return Dict("error" => "liquidity depth must be positive", "success" => false)
        vm.liquidity_pools[id] = Dict{Symbol, Any}(:id => id, :market_id => market_id, :depth => depth)
        return Dict("pool" => id, "success" => true)

    elseif opcode == 0xc3  # SWAP -- exchange assets, requires a pool with sufficient depth
        id = get(args, :id, "swap-$(length(vm.swaps) + 1)")
        pool_id = get(args, :pool_id, "")
        haskey(vm.liquidity_pools, pool_id) || return Dict("error" => "unknown pool: $pool_id", "success" => false)
        amount_in = Float64(get(args, :amount_in, 0.0))
        amount_in <= 0.0 && return Dict("error" => "swap amount must be positive", "success" => false)
        pool = vm.liquidity_pools[pool_id]
        amount_in > pool[:depth] && return Dict("error" => "insufficient pool depth", "success" => false)
        pool[:depth] -= amount_in
        vm.swaps[id] = Dict{Symbol, Any}(:id => id, :pool_id => pool_id, :amount_in => amount_in)
        return Dict("swap" => id, "success" => true)

    elseif opcode == 0xc4  # YIELD -- return rate on a real prior source
        id = get(args, :id, "yield-$(length(vm.yields) + 1)")
        source_id = get(args, :source_id, "")
        (haskey(vm.markets, source_id) || haskey(vm.liquidity_pools, source_id) || haskey(vm.bonds, source_id)) ||
            return Dict("error" => "unknown source (market, pool, or bond): $source_id", "success" => false)
        rate = Float64(get(args, :rate, 0.0))
        (rate < 0.0 || rate > 1.0) && return Dict("error" => "rate must be in [0,1]", "success" => false)
        vm.yields[id] = Dict{Symbol, Any}(:id => id, :source_id => source_id, :rate => rate)
        return Dict("yield" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xc0-0xc4", "success" => false)
    end
end

function handle_economic_2(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xc5  # BOND -- debt instrument
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "bond id required", "success" => false)
        haskey(vm.bonds, id) && return Dict("error" => "bond already exists: $id", "success" => false)
        face_value = Float64(get(args, :face_value, 0.0))
        face_value <= 0.0 && return Dict("error" => "bond face_value must be positive", "success" => false)
        vm.bonds[id] = Dict{Symbol, Any}(:id => id, :issuer => vm.current_sender, :face_value => face_value, :maturity => get(args, :maturity, 0))
        return Dict("bond" => id, "success" => true)

    elseif opcode == 0xc6  # EQUITY -- ownership share
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "equity id required", "success" => false)
        haskey(vm.equities, id) && return Dict("error" => "equity already exists: $id", "success" => false)
        shares = get(args, :shares, 0)
        shares <= 0 && return Dict("error" => "equity shares must be positive", "success" => false)
        vm.equities[id] = Dict{Symbol, Any}(:id => id, :company => get(args, :company, ""), :shares => shares)
        return Dict("equity" => id, "success" => true)

    elseif opcode == 0xc7  # DIVIDEND -- profit distribution, requires an existing equity
        id = get(args, :id, "dividend-$(length(vm.dividends) + 1)")
        equity_id = get(args, :equity_id, "")
        haskey(vm.equities, equity_id) || return Dict("error" => "unknown equity: $equity_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount <= 0.0 && return Dict("error" => "dividend amount must be positive", "success" => false)
        vm.dividends[id] = Dict{Symbol, Any}(:id => id, :equity_id => equity_id, :amount => amount)
        return Dict("dividend" => id, "success" => true)

    elseif opcode == 0xc8  # INTEREST -- debt cost, requires an existing loan
        id = get(args, :id, "interest-$(length(vm.interests) + 1)")
        loan_id = get(args, :loan_id, "")
        haskey(vm.loans, loan_id) || return Dict("error" => "unknown loan: $loan_id", "success" => false)
        rate = Float64(get(args, :rate, 0.0))
        rate <= 0.0 && return Dict("error" => "interest rate must be positive", "success" => false)
        vm.interests[id] = Dict{Symbol, Any}(:id => id, :loan_id => loan_id, :rate => rate)
        return Dict("interest" => id, "success" => true)

    elseif opcode == 0xc9  # COLLATERAL -- security deposit
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "collateral id required", "success" => false)
        haskey(vm.collaterals, id) && return Dict("error" => "collateral already exists: $id", "success" => false)
        value = Float64(get(args, :value, 0.0))
        value <= 0.0 && return Dict("error" => "collateral value must be positive", "success" => false)
        vm.collaterals[id] = Dict{Symbol, Any}(:id => id, :owner => vm.current_sender, :asset => get(args, :asset, ""), :value => value, :locked => false)
        return Dict("collateral" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xc5-0xc9", "success" => false)
    end
end

function handle_economic_3(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xca  # LOAN -- borrowed capital, requires unlocked collateral
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "loan id required", "success" => false)
        haskey(vm.loans, id) && return Dict("error" => "loan already exists: $id", "success" => false)
        collateral_id = get(args, :collateral_id, "")
        haskey(vm.collaterals, collateral_id) || return Dict("error" => "unknown collateral: $collateral_id", "success" => false)
        vm.collaterals[collateral_id][:locked] && return Dict("error" => "collateral already locked: $collateral_id", "success" => false)
        principal = Float64(get(args, :principal, 0.0))
        principal <= 0.0 && return Dict("error" => "loan principal must be positive", "success" => false)
        vm.collaterals[collateral_id][:locked] = true
        vm.loans[id] = Dict{Symbol, Any}(:id => id, :borrower => vm.current_sender, :principal => principal, :collateral_id => collateral_id, :status => :active, :repaid => 0.0)
        return Dict("loan" => id, "success" => true)

    elseif opcode == 0xcb  # REPAYMENT -- debt servicing, requires an active loan
        id = get(args, :id, "repayment-$(length(vm.repayments) + 1)")
        loan_id = get(args, :loan_id, "")
        haskey(vm.loans, loan_id) || return Dict("error" => "unknown loan: $loan_id", "success" => false)
        vm.loans[loan_id][:status] != :active && return Dict("error" => "loan not active: $loan_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount <= 0.0 && return Dict("error" => "repayment amount must be positive", "success" => false)
        vm.loans[loan_id][:repaid] += amount
        vm.repayments[id] = Dict{Symbol, Any}(:id => id, :loan_id => loan_id, :amount => amount)
        if vm.loans[loan_id][:repaid] >= vm.loans[loan_id][:principal]
            vm.loans[loan_id][:status] = :repaid
            collateral_id = vm.loans[loan_id][:collateral_id]
            haskey(vm.collaterals, collateral_id) && (vm.collaterals[collateral_id][:locked] = false)
        end
        return Dict("repayment" => id, "loan_status" => string(vm.loans[loan_id][:status]), "success" => true)

    elseif opcode == 0xcc  # DEFAULT -- failed obligation, requires an active loan
        loan_id = get(args, :loan_id, "")
        haskey(vm.loans, loan_id) || return Dict("error" => "unknown loan: $loan_id", "success" => false)
        vm.loans[loan_id][:status] != :active && return Dict("error" => "loan not active: $loan_id", "success" => false)
        vm.loans[loan_id][:status] = :defaulted
        vm.defaults[loan_id] = Dict{Symbol, Any}(:loan_id => loan_id, :reason => get(args, :reason, ""))
        return Dict("loan" => loan_id, "status" => "defaulted", "success" => true)

    elseif opcode == 0xcd  # LIQUIDATION -- forced sale, requires a defaulted loan
        id = get(args, :id, "liquidation-$(length(vm.liquidations) + 1)")
        loan_id = get(args, :loan_id, "")
        haskey(vm.defaults, loan_id) || return Dict("error" => "loan not in default: $loan_id", "success" => false)
        collateral_id = vm.loans[loan_id][:collateral_id]
        vm.liquidations[id] = Dict{Symbol, Any}(:id => id, :loan_id => loan_id, :collateral_id => collateral_id)
        haskey(vm.collaterals, collateral_id) && (vm.collaterals[collateral_id][:locked] = false)
        return Dict("liquidation" => id, "success" => true)

    elseif opcode == 0xce  # AUCTION -- competitive sale
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "auction id required", "success" => false)
        haskey(vm.auctions, id) && return Dict("error" => "auction already exists: $id", "success" => false)
        reserve_price = Float64(get(args, :reserve_price, 0.0))
        reserve_price < 0.0 && return Dict("error" => "reserve_price cannot be negative", "success" => false)
        vm.auctions[id] = Dict{Symbol, Any}(:id => id, :item => get(args, :item, ""), :reserve_price => reserve_price)
        return Dict("auction" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xca-0xce", "success" => false)
    end
end

function handle_economic_4(vm::VMState, opcode::UInt8, args)::Any
    if opcode == 0xcf  # INSURANCE -- risk coverage
        id = get(args, :id, "")
        isempty(id) && return Dict("error" => "insurance id required", "success" => false)
        haskey(vm.insurances, id) && return Dict("error" => "insurance already exists: $id", "success" => false)
        coverage = Float64(get(args, :coverage, 0.0))
        coverage <= 0.0 && return Dict("error" => "coverage must be positive", "success" => false)
        vm.insurances[id] = Dict{Symbol, Any}(:id => id, :holder => vm.current_sender, :coverage => coverage, :underwritten => false)
        return Dict("insurance" => id, "success" => true)

    elseif opcode == 0xd0  # CLAIM -- insurance payout, requires underwritten insurance
        id = get(args, :id, "claim-$(length(vm.claims) + 1)")
        insurance_id = get(args, :insurance_id, "")
        haskey(vm.insurances, insurance_id) || return Dict("error" => "unknown insurance: $insurance_id", "success" => false)
        vm.insurances[insurance_id][:underwritten] || return Dict("error" => "insurance not underwritten: $insurance_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount > vm.insurances[insurance_id][:coverage] && return Dict("error" => "claim exceeds coverage", "success" => false)
        vm.claims[id] = Dict{Symbol, Any}(:id => id, :insurance_id => insurance_id, :amount => amount)
        return Dict("claim" => id, "success" => true)

    elseif opcode == 0xd1  # PREMIUM -- insurance cost, requires an existing insurance
        id = get(args, :id, "premium-$(length(vm.premiums) + 1)")
        insurance_id = get(args, :insurance_id, "")
        haskey(vm.insurances, insurance_id) || return Dict("error" => "unknown insurance: $insurance_id", "success" => false)
        amount = Float64(get(args, :amount, 0.0))
        amount <= 0.0 && return Dict("error" => "premium amount must be positive", "success" => false)
        vm.premiums[id] = Dict{Symbol, Any}(:id => id, :insurance_id => insurance_id, :amount => amount)
        return Dict("premium" => id, "success" => true)

    elseif opcode == 0xd2  # UNDERWRITE -- risk assumption, requires an existing insurance
        insurance_id = get(args, :insurance_id, "")
        haskey(vm.insurances, insurance_id) || return Dict("error" => "unknown insurance: $insurance_id", "success" => false)
        vm.insurances[insurance_id][:underwritten] && return Dict("error" => "already underwritten: $insurance_id", "success" => false)
        vm.insurances[insurance_id][:underwritten] = true
        vm.underwrites[insurance_id] = Dict{Symbol, Any}(:insurance_id => insurance_id, :underwriter => vm.current_sender)
        return Dict("insurance" => insurance_id, "underwritten" => true, "success" => true)

    elseif opcode == 0xd3  # HEDGE -- risk offset against a real prior loan or insurance
        id = get(args, :id, "hedge-$(length(vm.hedges) + 1)")
        target_id = get(args, :target_id, "")
        (haskey(vm.loans, target_id) || haskey(vm.insurances, target_id)) ||
            return Dict("error" => "unknown target (must be a loan or insurance): $target_id", "success" => false)
        vm.hedges[id] = Dict{Symbol, Any}(:id => id, :target_id => target_id, :instrument => get(args, :instrument, ""))
        return Dict("hedge" => id, "success" => true)

    else
        return Dict("error" => "unreachable: opcode not in 0xcf-0xd3", "success" => false)
    end
end

function handle_economic(vm::VMState, opcode::UInt8, args)::Any
    if opcode in 0xc0:0xc4
        return handle_economic_1(vm, opcode, args)
    elseif opcode in 0xc5:0xc9
        return handle_economic_2(vm, opcode, args)
    elseif opcode in 0xca:0xce
        return handle_economic_3(vm, opcode, args)
    elseif opcode in 0xcf:0xd3
        return handle_economic_4(vm, opcode, args)
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

    # TechGnØŞ.EXE Church cluster (real stateful tracking, not decorative)
    elseif opcode in 0x60:0x78  # TechGnØŞ.EXE Church cluster
        return handle_church(vm, opcode, args)

    # SimaaS Hospital cluster (real stateful tracking, not decorative)
    elseif opcode in 0x80:0x93  # SimaaS Hospital cluster
        return handle_hospital(vm, opcode, args)

    # Òrìṣà Spiritual Layer cluster (real stateful tracking, not decorative
    # fixed responses -- ORISA_OBATALA/ORISA_ESU used to always return the
    # same literal Dict regardless of args or state)
    elseif opcode in 0xa0:0xb8  # Òrìṣà Spiritual Layer cluster
        return handle_orisa(vm, opcode, args)

    # Economic Extensions cluster (real stateful tracking, not decorative)
    elseif opcode in 0xc0:0xd3  # Economic Extensions cluster
        return handle_economic(vm, opcode, args)

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
