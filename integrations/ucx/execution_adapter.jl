# OSOVM / UCX execution adapter
#
# Responsibility: translate an OSOVM VM execution result (opcode 0x3f / 0x54 chain)
# back into a UCX-compatible RunResult so ucx-broker can produce a ComputeReceipt.
#
# Dependency direction: OSOVM → UCX (OSOVM pushes results; UCX pulls on job completion).
# This module speaks plain JSON on both sides.
#
# Called by: OSOVM vm/executor.jl after GPU_CONTRIBUTION (0x3f) executes.

module UcxExecutionAdapter

using JSON3, Dates, SHA

export osovm_result_to_ucx, UcxRunResult, ExecutionStatus

@enum ExecutionStatus begin
    SUCCESS   = 1
    FAILED    = 2
    CANCELLED = 3
    TIMEOUT   = 4
end

struct UcxRunResult
    job_id          :: String
    provider_id     :: String
    status          :: ExecutionStatus
    exit_code       :: Int
    stdout_digest   :: String     # SHA-256 of stdout bytes
    stderr_digest   :: String     # SHA-256 of stderr bytes
    execution_hash  :: String     # deterministic: sha256(job_id + provider_id + exit_code)
    artifact_hash   :: Union{String, Nothing}
    gpu_seconds     :: Float64
    cpu_seconds     :: Float64
    started_at      :: Float64    # unix seconds
    completed_at    :: Float64
    osovm_opcode    :: UInt8      # the triggering opcode (0x3f = GPU_CONTRIBUTION)
    osovm_tx_id     :: Union{String, Nothing}
end

"""
    osovm_result_to_ucx(osovm_json) -> UcxRunResult

Translate a raw OSOVM execution result JSON into a UCX RunResult.

Expected OSOVM JSON shape:
```json
{
  "job_id": "...",
  "provider_id": "...",
  "opcode": "0x3f",
  "tx_id": "...",
  "exit_code": 0,
  "stdout_digest": "sha256:...",
  "stderr_digest": "sha256:...",
  "artifact_hash": "sha256:...",
  "resources": { "gpu_seconds": 3600.0, "cpu_seconds": 120.0 },
  "started_at": 1700000000.0,
  "completed_at": 1700003600.0
}
```
"""
function osovm_result_to_ucx(raw::AbstractString)::UcxRunResult
    r = JSON3.read(raw)

    job_id      = string(get(r, :job_id, ""))
    provider_id = string(get(r, :provider_id, ""))
    exit_code   = Int(get(r, :exit_code, 0))

    status = if exit_code == 0
        SUCCESS
    elseif get(r, :cancelled, false)
        CANCELLED
    elseif get(r, :timed_out, false)
        TIMEOUT
    else
        FAILED
    end

    stdout_digest  = string(get(r, :stdout_digest, _empty_sha256()))
    stderr_digest  = string(get(r, :stderr_digest, _empty_sha256()))
    artifact_hash  = get(r, :artifact_hash, nothing)
    execution_hash = _compute_execution_hash(job_id, provider_id, exit_code)

    resources    = get(r, :resources, JSON3.read("{}"))
    gpu_seconds  = Float64(get(resources, :gpu_seconds, 0.0))
    cpu_seconds  = Float64(get(resources, :cpu_seconds, 0.0))

    opcode_str = string(get(r, :opcode, "0x3f"))
    opcode_val = try parse(UInt8, replace(opcode_str, "0x" => ""); base=16) catch; 0x3f end

    UcxRunResult(
        job_id,
        provider_id,
        status,
        exit_code,
        stdout_digest,
        stderr_digest,
        execution_hash,
        artifact_hash isa Nothing ? nothing : string(artifact_hash),
        gpu_seconds,
        cpu_seconds,
        Float64(get(r, :started_at,   0.0)),
        Float64(get(r, :completed_at, 0.0)),
        opcode_val,
        get(r, :tx_id, nothing) isa Nothing ? nothing : string(get(r, :tx_id, "")),
    )
end

"""
    ucx_run_result_to_json(result) -> String

Serialize a UcxRunResult to JSON for the ucx-broker HTTP response.
"""
function ucx_run_result_to_json(result::UcxRunResult)::String
    d = Dict(
        "job_id"         => result.job_id,
        "provider_id"    => result.provider_id,
        "status"         => string(result.status),
        "exit_code"      => result.exit_code,
        "execution_hash" => result.execution_hash,
        "artifact_hash"  => result.artifact_hash,
        "resources"      => Dict(
            "gpu_seconds" => result.gpu_seconds,
            "cpu_seconds" => result.cpu_seconds,
        ),
        "started_at"    => result.started_at,
        "completed_at"  => result.completed_at,
        "osovm_opcode"  => string("0x", string(result.osovm_opcode, base=16)),
        "osovm_tx_id"   => result.osovm_tx_id,
    )
    JSON3.write(d)
end

# ── internal helpers ─────────────────────────────────────────────────────────

function _empty_sha256()::String
    "sha256:" * bytes2hex(sha256(UInt8[]))
end

function _compute_execution_hash(job_id::String, provider_id::String, exit_code::Int)::String
    payload = "$(job_id):$(provider_id):$(exit_code)"
    "sha256:" * bytes2hex(sha256(Vector{UInt8}(payload)))
end

end # module UcxExecutionAdapter

# ─────────────────────────────────────────────────────────────────────────────
# UcxPreflight — pre-flight resource accounting for UCX job execution
#
# Called BEFORE a job starts:
#   1. Verify agent has sufficient Synapse balance for estimated cost
#   2. Soft-lock the estimated budget (prevents double-spend across concurrent jobs)
#   3. Return an ExecutionTicket with lock_id
#
# Called AFTER a job completes (via settle/):
#   1. Release the soft lock
#   2. Charge actual cost (may be less than estimate)
#   3. Return SettlementResult for event_bridge to post Dopamine credit
#
# Synapse balance source: vm.synapse_balance[agent_id] (from OsoVM.VMState)
# Synapse staked (in-flight) tracked here in _synapse_locked, not in VMState,
# because the server is stateless per-request.
# ─────────────────────────────────────────────────────────────────────────────

module UcxPreflight

using Dates

export preflight, settle, estimate_synapse_cost, ExecutionTicket, SettlementResult

# ── Cost table (Synapse units per workload unit) ──────────────────────────────

"""Synapse cost for a mid-range LLM inference call."""
const COST_PER_INFERENCE_CALL = 50

"""Synapse cost per second of VeilSim/MuJoCo simulation."""
const COST_PER_SIMULATION_SECOND = 10

"""Synapse cost per gradient step of fine-tuning."""
const COST_PER_TRAINING_STEP = 100

"""Buffer multiplier applied to all estimates (20% headroom)."""
const COST_ESTIMATION_BUFFER = 1.20

# ── Types ─────────────────────────────────────────────────────────────────────

struct ExecutionTicket
    ticket_id         :: String
    agent_id          :: String
    job_id            :: String
    estimated_synapse :: Int
    lock_id           :: String
    locked_at         :: Float64    # unix seconds
    workload_type     :: String
end

struct SettlementResult
    ticket_id         :: String
    actual_synapse    :: Int
    released_surplus  :: Int
    dopamine_earned   :: Int        # credited via event_bridge → Dopamine mint path
    gpu_seconds       :: Float64
    settled_at        :: Float64
end

# ── Module-level soft-lock table ──────────────────────────────────────────────
# Keyed by lock_id; holds in-flight reservations that have not yet settled.
# The server is per-request stateless for VMState, but preflight locks live
# across the request boundary (preflight → job runs → settle), so they must
# live here at module scope.

const _lock_table_mutex = ReentrantLock()
const _lock_table = Dict{String, ExecutionTicket}()

# ── Public API ────────────────────────────────────────────────────────────────

"""
    estimate_synapse_cost(workload_type, params) -> Int

Estimate Synapse cost with a 20% buffer.

Supported workload_type values:
- `"inference"` — params["estimated_calls"] (default 1)
- `"simulation"` — params["estimated_seconds"] (default 60.0)
- `"training"`   — params["estimated_steps"] (default 100)
- anything else  — 500 Synapse default
"""
function estimate_synapse_cost(workload_type::AbstractString, params::Dict)::Int
    base = if workload_type == "inference"
        calls = Int(get(params, "estimated_calls", get(params, :estimated_calls, 1)))
        calls * COST_PER_INFERENCE_CALL
    elseif workload_type == "simulation"
        secs = Float64(get(params, "estimated_seconds", get(params, :estimated_seconds, 60.0)))
        round(Int, secs * COST_PER_SIMULATION_SECOND)
    elseif workload_type == "training"
        steps = Int(get(params, "estimated_steps", get(params, :estimated_steps, 100)))
        steps * COST_PER_TRAINING_STEP
    else
        500  # conservative default for unknown workload type
    end
    ceil(Int, base * COST_ESTIMATION_BUFFER)
end

"""
    preflight(synapse_balance, agent_id, job_id, workload_type, params) -> Dict

Pre-flight check: verify Synapse balance and soft-lock the estimated budget.

`synapse_balance` is the current minted Synapse for this agent, read from
`vm.synapse_balance[agent_id]` by the caller.

Returns:
- `{"success": true,  "ticket_id": ..., "lock_id": ..., "estimated_synapse": ...}`
- `{"success": false, "error": ..., "agent_id": ...}`
"""
function preflight(
    synapse_balance :: Int,
    agent_id        :: AbstractString,
    job_id          :: AbstractString,
    workload_type   :: AbstractString,
    params          :: Dict,
)::Dict
    estimated = estimate_synapse_cost(workload_type, params)

    # Account for already-locked (in-flight) reservations for this agent
    already_locked = lock(_lock_table_mutex) do
        sum(t.estimated_synapse for t in values(_lock_table)
            if t.agent_id == agent_id; init=0)
    end
    available = synapse_balance - already_locked

    if available < estimated
        return Dict(
            "success"   => false,
            "error"     => "insufficient synapse: available=$(available) (balance=$(synapse_balance) locked=$(already_locked)), need=$(estimated)",
            "agent_id"  => string(agent_id),
        )
    end

    ts_ns   = time_ns()
    lock_id = "lock:$(agent_id):$(job_id):$(ts_ns)"
    ticket  = ExecutionTicket(
        "ticket:$(job_id):$(ts_ns)",
        string(agent_id),
        string(job_id),
        estimated,
        lock_id,
        _now(),
        string(workload_type),
    )

    lock(_lock_table_mutex) do
        _lock_table[lock_id] = ticket
    end

    return Dict(
        "success"           => true,
        "ticket_id"         => ticket.ticket_id,
        "lock_id"           => lock_id,
        "estimated_synapse" => estimated,
        "workload_type"     => string(workload_type),
    )
end

"""
    settle(lock_id, actual_synapse, gpu_seconds) -> Dict

Post-execution settlement: release the soft lock and return a SettlementResult.

The caller (server route handler or event_bridge) is responsible for:
  - Debiting `actual_synapse` from `vm.synapse_balance[agent_id]`
  - Crediting `dopamine_earned` via `UcxEventBridge.handle_gpu_contribution`

Returns:
- `{"success": true, "ticket_id": ..., "actual_synapse": ..., "dopamine_earned": ..., ...}`
- `{"success": false, "error": ...}`
"""
function settle(lock_id::AbstractString, actual_synapse::Int, gpu_seconds::Float64)::Dict
    ticket = lock(_lock_table_mutex) do
        t = get(_lock_table, lock_id, nothing)
        t !== nothing && delete!(_lock_table, lock_id)
        t
    end

    if ticket === nothing
        return Dict("success" => false, "error" => "lock $(lock_id) not found or already settled")
    end

    surplus = max(0, ticket.estimated_synapse - actual_synapse)

    # Dopamine earned: 86B pool / 86,400 s/day = ~994,213 Dopamine per GPU-second
    # Matches AGENT_DOPAMINE_ENDOWMENT (86B) / seconds-per-day constant.
    dopamine_earned = round(Int, gpu_seconds * (86_000_000_000.0 / 86_400.0))

    return Dict(
        "success"          => true,
        "ticket_id"        => ticket.ticket_id,
        "agent_id"         => ticket.agent_id,
        "job_id"           => ticket.job_id,
        "actual_synapse"   => actual_synapse,
        "released_surplus" => surplus,
        "dopamine_earned"  => dopamine_earned,
        "gpu_seconds"      => gpu_seconds,
        "settled_at"       => _now(),
    )
end

"""
    active_locks(agent_id) -> Int

Return the total Synapse currently soft-locked for an agent across all in-flight jobs.
Useful for dashboard / balance queries.
"""
function active_locks(agent_id::AbstractString)::Int
    lock(_lock_table_mutex) do
        sum(t.estimated_synapse for t in values(_lock_table)
            if t.agent_id == agent_id; init=0)
    end
end

# ── internal ──────────────────────────────────────────────────────────────────

_now()::Float64 = Dates.datetime2unix(Dates.now(Dates.UTC))

end # module UcxPreflight
