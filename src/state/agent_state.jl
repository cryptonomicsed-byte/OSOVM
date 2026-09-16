# agent_state.jl — Ọ̀ṢỌ́ L1 AgentState (Phase 15.2)
# Primary L1 blockchain object: every agent on the chain has one of these.
# Spec: ~/sovereign-eco-blueprint/specs/OSOVM_L1_SPEC.md
# Constants: ~/sovereign-eco-blueprint/specs/TOC_CONSTANTS.toml

module AgentState

export AgentStateRecord, apply_transition, hash_state

using SHA

# ─────────────────────────────────────────────────────────────────────────────
# PRIMARY L1 OBJECT
# Every agent on the chain has exactly one AgentStateRecord.
# Fields mirror the Rust AgentState in OSOVM_L1_SPEC.md.
# ─────────────────────────────────────────────────────────────────────────────

struct AgentStateRecord
    # Identity
    agent_id::String
    nostr_pubkey::Vector{UInt8}      # 32-byte Ed25519 pubkey (= the npub)
    bipon39_hash::Vector{UInt8}      # SHA-256 of BIPON39 phrase
    odu_index::UInt8                 # 0-255 cosmic archetype

    # Ownership / status
    principal::String                # who owns this agent
    tier::UInt8
    lifecycle::Symbol                # :embryonic | :active | :dormant | :migrating | :archived

    # Reputation + capabilities
    reputation::Float64
    capabilities::Vector{String}

    # Economy — all balances from TOC_CONSTANTS.toml
    # 1 ASE = 1_000_000 mist (micro-units, see [ase].micro_per_ase)
    ase_balance::UInt128
    dopamine_balance::UInt64         # non-transferable compute signal
    synapse_balance::UInt64          # transferable compute slice
    stake_locked::UInt64             # synapse staked for gate access

    # Work tracking
    active_jobs::Vector{String}
    completed_jobs::UInt64
    evidence_root::Vector{UInt8}     # 32-byte Merkle root of all receipts

    # Memory
    memory_commitment::Vector{UInt8} # 32-byte hash of sealed vault (Walrus/Seal)

    # Chain custody — every transition provable from genesis
    previous_state_hash::Vector{UInt8} # 32-byte hash of previous state
    block_height::UInt64               # block of last update
end

# ─────────────────────────────────────────────────────────────────────────────
# DETERMINISTIC STATE HASH
# hash_state produces the 32-byte fingerprint chained into the next state's
# previous_state_hash field.  Algorithm is stable and cross-language testable.
# ─────────────────────────────────────────────────────────────────────────────

function hash_state(s::AgentStateRecord)::Vector{UInt8}
    buf = IOBuffer()
    write(buf, s.agent_id)
    write(buf, s.nostr_pubkey)
    write(buf, UInt8(s.odu_index))
    write(buf, UInt8(s.tier))
    write(buf, reinterpret(UInt8, [s.reputation]))
    write(buf, reinterpret(UInt8, [s.ase_balance]))
    write(buf, reinterpret(UInt8, [s.dopamine_balance]))
    write(buf, reinterpret(UInt8, [s.synapse_balance]))
    write(buf, reinterpret(UInt8, [s.block_height]))
    write(buf, s.previous_state_hash)
    return sha256(take!(buf))
end

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE TRANSITION TABLE
# Valid (from, to) pairs and the transition kind symbol that triggers them.
# Matches TransitionKind in the Rust ABCI app.
# ─────────────────────────────────────────────────────────────────────────────

# Each entry: (from_lifecycle, to_lifecycle) => transition_kind
const VALID_TRANSITIONS = Dict{Tuple{Symbol,Symbol}, Symbol}(
    (:embryonic, :active)    => :born,
    (:active,    :dormant)   => :hibernate,
    (:dormant,   :active)    => :wake,
    (:active,    :migrating) => :migrate,
    (:migrating, :active)    => :land,
    (:active,    :archived)  => :terminate,
)

"""
    apply_transition(state, transition, new_block_height) -> Union{AgentStateRecord, String}

Apply a lifecycle transition to an AgentStateRecord.  Returns the new state
(with previous_state_hash = hash_state(state)) on success, or an error string
if the transition is invalid.

Transition kinds:
  :born       — Embryonic → Active   (AGENT_ACTIVATED tx)
  :hibernate  — Active    → Dormant  (AGENT_HIBERNATED tx)
  :wake       — Dormant   → Active   (re-activation)
  :migrate    — Active    → Migrating (AGENT_MIGRATED tx, phase 1)
  :land       — Migrating → Active   (AGENT_MIGRATED tx, phase 2)
  :terminate  — Active    → Archived (AGENT_TERMINATED tx)
"""
function apply_transition(
    state::AgentStateRecord,
    transition::Symbol,
    new_block_height::UInt64
)::Union{AgentStateRecord, String}
    new_lifecycle = nothing
    for ((from, to), kind) in VALID_TRANSITIONS
        if from == state.lifecycle && kind == transition
            new_lifecycle = to
            break
        end
    end
    if isnothing(new_lifecycle)
        return "invalid transition: $(transition) from lifecycle=$(state.lifecycle)"
    end

    # Chain the current state hash as previous_state_hash in the new record.
    new_state = AgentStateRecord(
        state.agent_id,
        state.nostr_pubkey,
        state.bipon39_hash,
        state.odu_index,
        state.principal,
        state.tier,
        new_lifecycle,
        state.reputation,
        state.capabilities,
        state.ase_balance,
        state.dopamine_balance,
        state.synapse_balance,
        state.stake_locked,
        state.active_jobs,
        state.completed_jobs,
        state.evidence_root,
        state.memory_commitment,
        hash_state(state),    # ← chain of custody
        new_block_height,
    )
    return new_state
end

end # module AgentState
