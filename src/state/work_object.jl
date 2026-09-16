# work_object.jl — Ọ̀ṢỌ́ L1 WorkObject State Machine (Phase 15.3)
# Primary L1 transaction type: every unit of work is a WorkRecord.
# Spec: ~/sovereign-eco-blueprint/specs/OSOVM_L1_SPEC.md
# Constants: ~/sovereign-eco-blueprint/specs/TOC_CONSTANTS.toml

module WorkObject

export WorkRecord, WorkState, advance_work_state
export CREATED, ASSIGNED, ACCEPTED, STARTED, DELEGATED, EXECUTED, VERIFIED, REJECTED, SETTLED

# ─────────────────────────────────────────────────────────────────────────────
# WORK STATE ENUM
# Matches pub enum WorkState in the Rust ABCI app (OSOVM_L1_SPEC.md).
# ─────────────────────────────────────────────────────────────────────────────

@enum WorkState begin
    CREATED    # posted but not yet assigned to an agent
    ASSIGNED   # agent matched; awaiting acceptance
    ACCEPTED   # agent confirmed; pre-work
    STARTED    # work begun
    DELEGATED  # agent sub-delegated capability to another agent
    EXECUTED   # work complete, proof submitted
    VERIFIED   # proof accepted by witnesses
    REJECTED   # proof rejected (terminal)
    SETTLED    # payment released, reputation updated (terminal)
end

# ─────────────────────────────────────────────────────────────────────────────
# PRIMARY WORK RECORD
# ─────────────────────────────────────────────────────────────────────────────

struct WorkRecord
    work_id::String
    principal_id::String                # who posted the job
    agent_id::Union{String, Nothing}    # who accepted it (Nothing until ASSIGNED)
    capability::String                  # what skill is required
    budget_mist::UInt128                # Àṣẹ budget in mist (1 ASE = 1_000_000 mist)
    deadline::UInt64                    # Unix timestamp
    state::WorkState
    receipts::Vector{String}            # Zàngbétò receipt IDs chained during execution
    evidence_submitted::Bool
    proof_hash::Union{Vector{UInt8}, Nothing}  # 32-byte hash once EXECUTED
    created_at::UInt64
    settled_at::Union{UInt64, Nothing}
end

# ─────────────────────────────────────────────────────────────────────────────
# STATE MACHINE TRANSITION TABLE
# Canonical lifecycle: Created → Assigned → Accepted → Started → Executed → Verified → Settled
# Delegated is an optional detour from Started; Rejected is a terminal failure state.
# ─────────────────────────────────────────────────────────────────────────────

const WORK_TRANSITIONS = Dict{WorkState, Vector{WorkState}}(
    CREATED   => [ASSIGNED],
    ASSIGNED  => [ACCEPTED, REJECTED],
    ACCEPTED  => [STARTED],
    STARTED   => [EXECUTED, DELEGATED],
    DELEGATED => [EXECUTED],
    EXECUTED  => [VERIFIED, REJECTED],
    VERIFIED  => [SETTLED],
    REJECTED  => WorkState[],   # terminal
    SETTLED   => WorkState[],   # terminal
)

"""
    advance_work_state(work, to_state; agent_id, receipt_id, proof) -> Union{WorkRecord, String}

Advance a WorkRecord to the next state in the state machine.
Returns the new WorkRecord on success, or an error string on invalid transition.

Keyword args (all optional):
  agent_id   — String: set when transitioning CREATED → ASSIGNED
  receipt_id — String: Zàngbétò receipt ID appended at EXECUTED or VERIFIED
  proof      — Vector{UInt8}: 32-byte proof hash set at EXECUTED
"""
function advance_work_state(
    work::WorkRecord,
    to_state::WorkState;
    agent_id::Union{String, Nothing}    = nothing,
    receipt_id::Union{String, Nothing}  = nothing,
    proof::Union{Vector{UInt8}, Nothing} = nothing,
    settled_at::Union{UInt64, Nothing}  = nothing,
)::Union{WorkRecord, String}
    # Guard: verify the transition is valid
    allowed = WORK_TRANSITIONS[work.state]
    if !(to_state in allowed)
        return "invalid work transition: $(work.state) → $(to_state) " *
               "(allowed from $(work.state): $(allowed))"
    end

    # Resolve fields for the new record
    new_agent_id = (to_state == ASSIGNED && !isnothing(agent_id)) ? agent_id : work.agent_id

    new_receipts = copy(work.receipts)
    if !isnothing(receipt_id) && to_state in [EXECUTED, VERIFIED, SETTLED]
        push!(new_receipts, receipt_id)
    end

    new_proof_hash = (!isnothing(proof) && to_state == EXECUTED) ? proof : work.proof_hash

    new_evidence_submitted = to_state == EXECUTED ? true : work.evidence_submitted

    new_settled_at = (to_state == SETTLED) ? settled_at : work.settled_at

    return WorkRecord(
        work.work_id,
        work.principal_id,
        new_agent_id,
        work.capability,
        work.budget_mist,
        work.deadline,
        to_state,
        new_receipts,
        new_evidence_submitted,
        new_proof_hash,
        work.created_at,
        new_settled_at,
    )
end

end # module WorkObject
