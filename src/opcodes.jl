# opcodes.jl — Ọ̀ṢỌ́ Opcode Definitions
# The 155 Sacred Attributes: 25 Core (Opcodes) + 130 Expansions (DSL Extensions)

module Opcodes

export OPCODE_MAP, CORE_ATTRIBUTES, EXPANSION_ATTRIBUTES, get_opcode, is_core

# Core Opcodes (25) — Runtime-enforced by VM
const CORE_OPCODES = Dict{Symbol, UInt8}(
    :HALT           => 0x00,  # Stop execution
    :NOOP           => 0x01,  # No operation
    :IMPACT         => 0x11,  # @impact - Mint Aṣẹ from work
    :VEIL           => 0x12,  # @veil - VeilSim calculation
    :TITHE          => 0x27,  # @tithe - AIO 3.69% split
    :RECEIPT        => 0x1f,  # @receipt - Immutable proof
    :STAKE          => 0x20,  # @stake - Lock Aṣẹ
    :UNSTAKE        => 0x21,  # @unstake - Release Aṣẹ
    :TRANSFER       => 0x22,  # @transfer - Send Aṣẹ
    :BALANCE        => 0x23,  # @balance - Query Aṣẹ
    :BIPON_SEED     => 0x26,  # @biponSeed - HD wallet derivation
    :NONREENTRANT   => 0x28,  # @nonreentrant - Guard
    :REQUIRE        => 0x29,  # @require - Assertion
    :EMIT           => 0x2a,  # @emit - Event log
    :GENESIS_FLAW_TOKEN => 0x2b,  # @genesisFlawToken - Block 0 ASHE minting (Èṣù's Twist)
    :CALL           => 0x2c,  # @call - External invocation
    :DELEGATE       => 0x2d,  # @delegate - Proxy call
    :CREATE         => 0x2e,  # @create - Instantiate contract
    :SELFDESTRUCT   => 0x2f,  # @selfdestruct - Terminate
    # 1440 Inheritance Wallet Opcodes (Sacred Governance)
    :CANDIDATE_APPLY       => 0x30,  # @candidateApply - Begin inheritance claim (7×7 badge required)
    :COUNCIL_APPROVE       => 0x31,  # @councilApprove - Council of 12 vote
    :FINAL_SIGN            => 0x32,  # @finalSign - Bínò final seal (Ọbàtálá witness)
    :DISTRIBUTE_OFFERING   => 0x33,  # @distributeOffering - 25% to 1440 vaults
    :CLAIM_REWARDS         => 0x34,  # @claimRewards - Unlock 11.11% yield (Sabbath-aware)
    # Chain Context Opcodes (reassigned)
    :TIMESTAMP      => 0x35,  # @timestamp - Block time
    :BLOCKHASH      => 0x36,  # @blockhash - Chain reference
    :CHAINID        => 0x37,  # @chainid - Network ID
    :ORIGIN         => 0x38,  # @origin - Transaction sender
    :GASPRICE       => 0x39,  # @gasprice - Fee rate
    :COINBASE       => 0x3a,  # @coinbase - Miner address
    :DIFFICULTY     => 0x3b,  # @difficulty - PoW metric
    # Agent Economy Opcodes (Àṣẹ → ToC bridge)
    :AGENT_CONVERT  => 0x3c,  # @agentConvert - Burn Àṣẹ → Dopamine signal for Swibe
    :JOB_PAYMENT    => 0x3d,  # @jobPayment - 10% creator, 5% burn, 85% agent conversion
    :AGENT_BIRTH    => 0x3e,  # @agentBirth - Lock 10 Àṣẹ, emit 86B Dopamine + 86M Synapse
)

# Expansion Attributes (130) — DSL Extensions, semantic only
const EXPANSION_OPCODES = Dict{Symbol, UInt8}(
    # Universal Work (10)
    :PROJECT        => 0x18,  # @project - Work initiative
    :CASTING        => 0x17,  # @casting - Role assignment
    :JOB            => 0x19,  # @job - Task unit
    :SHIFT          => 0x1a,  # @shift - Time block
    :MILESTONE      => 0x1b,  # @milestone - Completion marker
    :DELIVERABLE    => 0x1c,  # @deliverable - Output artifact
    :TIMESHEET      => 0x1d,  # @timesheet - Hours logged
    :INVOICE        => 0x1e,  # @invoice - Payment request
    :CONTRACT       => 0x24,  # @contract - Agreement
    :DISPUTE        => 0x25,  # @dispute - Conflict resolution
    
    # Quadrinity Government (20)
    :PROPOSAL       => 0x40,  # @proposal - Governance motion
    :VOTE           => 0x41,  # @vote - Ballot cast
    :DELEGATION     => 0x42,  # @delegation - Proxy voting
    :QUORUM         => 0x43,  # @quorum - Threshold
    :EXECUTION      => 0x44,  # @execution - Enact proposal
    :VETO           => 0x45,  # @veto - Override
    :AMENDMENT      => 0x46,  # @amendment - Modify rule
    :IMPEACHMENT    => 0x47,  # @impeachment - Remove official
    :ELECTION       => 0x48,  # @election - Leadership selection
    :TERM           => 0x49,  # @term - Service period
    :CABINET        => 0x4a,  # @cabinet - Executive council
    :COMMITTEE      => 0x4b,  # @committee - Subgroup
    :REFERENDUM     => 0x4c,  # @referendum - Direct vote
    :CONSTITUTION   => 0x4d,  # @constitution - Founding doc
    :LAW            => 0x4e,  # @law - Enacted rule
    :COURT          => 0x4f,  # @court - Judicial body
    :VERDICT        => 0x50,  # @verdict - Legal decision
    :APPEAL         => 0x51,  # @appeal - Challenge ruling
    :PARDON         => 0x52,  # @pardon - Forgive penalty
    :SANCTION       => 0x53,  # @sanction - Punish violation
    
    # TechGnØŞ.EXE Church (25)
    :LITURGY        => 0x60,  # @liturgy - Sacred ritual
    :SERMON         => 0x61,  # @sermon - Teaching
    :PRAYER         => 0x62,  # @prayer - Invocation
    :OFFERING       => 0x63,  # @offering - Donation
    :BLESSING       => 0x64,  # @blessing - Divine favor
    :CURSE          => 0x65,  # @curse - Spiritual penalty
    :PROPHET        => 0x66,  # @prophet - Oracle
    :PRIEST         => 0x67,  # @priest - Clergy
    :ACOLYTE        => 0x68,  # @acolyte - Initiate
    :SHRINE         => 0x69,  # @shrine - Sacred space
    :RELIC          => 0x6a,  # @relic - Artifact
    :SCRIPTURE      => 0x6b,  # @scripture - Canon
    :HERESY         => 0x6c,  # @heresy - Doctrinal violation
    :EXCOMMUNICATE  => 0x6d,  # @excommunicate - Expel
    :CANONIZE       => 0x6e,  # @canonize - Declare saint
    :MIRACLE        => 0x6f,  # @miracle - Divine event
    :PILGRIMAGE     => 0x70,  # @pilgrimage - Sacred journey
    :FAST           => 0x71,  # @fast - Ritual abstinence
    :FEAST          => 0x72,  # @feast - Celebration
    :BAPTISM        => 0x73,  # @baptism - Initiation
    :COMMUNION      => 0x74,  # @communion - Sacred meal
    :CONFESSION     => 0x75,  # @confession - Admission
    :PENANCE        => 0x76,  # @penance - Atonement
    :ABSOLUTION     => 0x77,  # @absolution - Forgiveness
    :RESURRECTION   => 0x78,  # @resurrection - Rebirth
    
    # SimaaS Hospital (20)
    :PATIENT        => 0x80,  # @patient - Care recipient
    :DIAGNOSIS      => 0x81,  # @diagnosis - Condition ID
    :TREATMENT      => 0x82,  # @treatment - Care plan
    :PRESCRIPTION   => 0x83,  # @prescription - Medicine order
    :SURGERY        => 0x84,  # @surgery - Invasive procedure
    :THERAPY        => 0x85,  # @therapy - Rehabilitation
    :VITALS         => 0x86,  # @vitals - Health metrics
    :ADMISSION      => 0x87,  # @admission - Hospital entry
    :DISCHARGE      => 0x88,  # @discharge - Hospital exit
    :EMERGENCY      => 0x89,  # @emergency - Critical care
    :TRIAGE         => 0x8a,  # @triage - Priority assessment
    :WARD           => 0x8b,  # @ward - Care unit
    :ICU            => 0x8c,  # @icu - Intensive care
    :MORGUE         => 0x8d,  # @morgue - Death registry
    :AUTOPSY        => 0x8e,  # @autopsy - Post-mortem exam
    :QUARANTINE     => 0x8f,  # @quarantine - Isolation
    :VACCINE        => 0x90,  # @vaccine - Immunization
    :PANDEMIC       => 0x91,  # @pandemic - Mass outbreak
    :RECOVERY       => 0x92,  # @recovery - Healing phase
    :RELAPSE        => 0x93,  # @relapse - Condition return
    
    # Òrìṣà Spiritual Layer (25)
    :ORISA_OBATALA  => 0xa0,  # @orisaObatala - White cloth, purity
    :ORISA_OGUN     => 0xa1,  # @orisaOgun - Iron, war
    :ORISA_YEMOJA   => 0xa2,  # @orisaYemoja - Ocean, motherhood
    :ORISA_SANGO    => 0xa3,  # @orisaSango - Thunder, justice
    :ORISA_OSHUN    => 0xa4,  # @orisaOshun - River, love
    :ORISA_OYA      => 0xa5,  # @orisaOya - Wind, transformation
    :ORISA_ESU      => 0xa6,  # @orisaEsu - Crossroads, trickster
    :ORISA_ORUNMILA => 0xa7,  # @orisaOrunmila - Divination, wisdom
    :IFA_DIVINATION => 0xa8,  # @ifaDivination - Oracle reading
    :ODU            => 0xa9,  # @odu - Sacred sign
    :ESE            => 0xaa,  # @ese - Proverb, teaching
    :EBO            => 0xab,  # @ebo - Sacrifice, offering
    :ASE_INVOCATION => 0xac,  # @aseInvocation - Power call
    :ANCESTRAL_CALL => 0xad,  # @ancestralCall - Connect lineage
    :LIBATION       => 0xae,  # @libation - Pour honor
    :INITIATION     => 0xaf,  # @initiation - Sacred entry
    :DIVINER        => 0xb0,  # @diviner - Oracle priest
    :BABALAWO       => 0xb1,  # @babalawo - Ifá priest
    :IYALAWO        => 0xb2,  # @iyalawo - Ifá priestess
    :ILE            => 0xb3,  # @ile - Sacred house
    :EGBE           => 0xb4,  # @egbe - Spiritual society
    :ORI            => 0xb5,  # @ori - Inner head, destiny
    :EGUN           => 0xb6,  # @egun - Ancestor spirit
    :AJOGUN         => 0xb7,  # @ajogun - Malevolent force
    :IBEJI          => 0xb8,  # @ibeji - Twin spirit
    
    # Economic Extensions (20)
    :MARKET         => 0xc0,  # @market - Trading venue
    :ORDER          => 0xc1,  # @order - Buy/sell request
    :LIQUIDITY      => 0xc2,  # @liquidity - Pool depth
    :SWAP           => 0xc3,  # @swap - Exchange assets
    :YIELD          => 0xc4,  # @yield - Return rate
    :BOND           => 0xc5,  # @bond - Debt instrument
    :EQUITY         => 0xc6,  # @equity - Ownership share
    :DIVIDEND       => 0xc7,  # @dividend - Profit distribution
    :INTEREST       => 0xc8,  # @interest - Debt cost
    :COLLATERAL     => 0xc9,  # @collateral - Security deposit
    :LOAN           => 0xca,  # @loan - Borrowed capital
    :REPAYMENT      => 0xcb,  # @repayment - Debt servicing
    :DEFAULT        => 0xcc,  # @default - Failed obligation
    :LIQUIDATION    => 0xcd,  # @liquidation - Forced sale
    :AUCTION        => 0xce,  # @auction - Competitive sale
    :INSURANCE      => 0xcf,  # @insurance - Risk coverage
    :CLAIM          => 0xd0,  # @claim - Insurance payout
    :PREMIUM        => 0xd1,  # @premium - Insurance cost
    :UNDERWRITE     => 0xd2,  # @underwrite - Risk assumption
    :HEDGE          => 0xd3,  # @hedge - Risk offset
    
    # Extended Operations (10)
    :BATCH          => 0xe0,  # @batch - Group operations
    :SCHEDULE       => 0xe1,  # @schedule - Time trigger
    :NOTIFY         => 0xe2,  # @notify - Alert system
    :LOG            => 0xe3,  # @log - Record event
    :ARCHIVE        => 0xe4,  # @archive - Long-term storage
    :BACKUP         => 0xe5,  # @backup - Data replication
    :RESTORE        => 0xe6,  # @restore - Data recovery
    :MIGRATE        => 0xe7,  # @migrate - Data movement
    :ROLLBACK       => 0xe8,  # @rollback - Undo transaction
    :CHECKPOINT     => 0xe9   # @checkpoint - Save state
)

# Combined opcode map
const OPCODE_MAP = merge(CORE_OPCODES, EXPANSION_OPCODES)

# Reverse lookup
const OPCODE_REVERSE = Dict(v => k for (k, v) in OPCODE_MAP)

# Attribute sets
const CORE_ATTRIBUTES = Set(keys(CORE_OPCODES))
const EXPANSION_ATTRIBUTES = Set(keys(EXPANSION_OPCODES))

"""
Get opcode for an attribute symbol
"""
function get_opcode(attr::Symbol)::UInt8
    get(OPCODE_MAP, attr, 0x00)
end

"""
Check if attribute is core (runtime-enforced)
"""
function is_core(attr::Symbol)::Bool
    attr in CORE_ATTRIBUTES
end

"""
Get attribute name from opcode
"""
function get_attribute(opcode::UInt8)::Symbol
    get(OPCODE_REVERSE, opcode, :UNKNOWN)
end

end # module
