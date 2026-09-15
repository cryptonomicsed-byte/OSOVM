# OSOVM / UCX resource meter
#
# Responsibility: accumulate per-agent GPU seconds from UCX ComputeReceipts,
# determine when a ToC mint threshold is reached, and expose the accumulated
# balance for GPU_CONTRIBUTION (0x3f) → TOC_MINT (0x54) eligibility checks.
#
# Mint rate: 1000 Synapse / GPU-hour  (per OSOVM_TOC spec)
# Mint floor: 0.001 GPU-hours (3.6 s) — anything below is deferred to next cycle
# Decay rate: 1%/day applied by TOC_DECAY (0x55), called by OSOVM scheduler
#
# This module is STATEFUL: uses an in-process Dict protected by a ReentrantLock.
# For multi-process setups wire it to the OSOVM persistent state store instead.

module ResourceMeter

using JSON3, Dates, Logging

export record_contribution, get_balance, mint_eligible_amount,
       drain_for_mint, apply_decay, provider_leaderboard

const _SYNAPSE_PER_GPU_HOUR = 1000
const _MINT_FLOOR_GPU_HOURS = 0.001   # 3.6 seconds — below this, defer

# ── state ────────────────────────────────────────────────────────────────────

struct AgentBalance
    agent_id        :: String
    gpu_seconds     :: Float64    # accumulated, not yet minted
    pending_synapse :: Int        # synapse_estimate already sent to TOC_MINT queue
    last_updated    :: Float64    # unix seconds
    contribution_count :: Int
end

const _lock     = ReentrantLock()
const _balances = Dict{String, AgentBalance}()  # agent_id → balance

# ── public API ───────────────────────────────────────────────────────────────

"""
    record_contribution(agent_id, gpu_seconds, job_id) -> AgentBalance

Add `gpu_seconds` to the agent's accumulator. Returns updated balance.
"""
function record_contribution(
    agent_id    :: AbstractString,
    gpu_seconds :: Float64,
    job_id      :: AbstractString = "",
)::AgentBalance
    if gpu_seconds <= 0.0
        @warn "record_contribution: non-positive gpu_seconds ignored" agent_id gpu_seconds
        return get_balance(agent_id)
    end

    lock(_lock) do
        existing = get(_balances, agent_id, nothing)
        new_bal = if existing === nothing
            AgentBalance(agent_id, gpu_seconds, 0, _now(), 1)
        else
            AgentBalance(
                agent_id,
                existing.gpu_seconds + gpu_seconds,
                existing.pending_synapse,
                _now(),
                existing.contribution_count + 1,
            )
        end
        _balances[agent_id] = new_bal
        @info "resource_meter: contribution recorded" agent_id gpu_seconds job_id total=new_bal.gpu_seconds
        return new_bal
    end
end

"""
    get_balance(agent_id) -> AgentBalance

Return current accumulated balance for an agent (zero-valued if unknown).
"""
function get_balance(agent_id::AbstractString)::AgentBalance
    lock(_lock) do
        get(_balances, agent_id, AgentBalance(agent_id, 0.0, 0, _now(), 0))
    end
end

"""
    mint_eligible_amount(agent_id) -> (gpu_hours, synapse_estimate)

Return how many GPU-hours are eligible for minting and the estimated Synapse.
Returns (0.0, 0) if below the mint floor.
"""
function mint_eligible_amount(agent_id::AbstractString)::Tuple{Float64, Int}
    bal = get_balance(agent_id)
    gpu_hours = bal.gpu_seconds / 3600.0
    if gpu_hours < _MINT_FLOOR_GPU_HOURS
        return (0.0, 0)
    end
    synapse = floor(Int, gpu_hours * _SYNAPSE_PER_GPU_HOUR)
    return (gpu_hours, synapse)
end

"""
    drain_for_mint(agent_id) -> (gpu_seconds_drained, synapse_estimate)

Atomically consume the agent's accumulated GPU seconds for minting.
Caller must subsequently execute TOC_MINT (0x54). Returns (0.0, 0) if below floor.
"""
function drain_for_mint(agent_id::AbstractString)::Tuple{Float64, Int}
    lock(_lock) do
        existing = get(_balances, agent_id, nothing)
        if existing === nothing
            return (0.0, 0)
        end

        gpu_hours = existing.gpu_seconds / 3600.0
        if gpu_hours < _MINT_FLOOR_GPU_HOURS
            return (0.0, 0)
        end

        synapse = floor(Int, gpu_hours * _SYNAPSE_PER_GPU_HOUR)
        _balances[agent_id] = AgentBalance(
            agent_id,
            0.0,  # drained
            existing.pending_synapse + synapse,
            _now(),
            existing.contribution_count,
        )
        @info "resource_meter: drained for mint" agent_id gpu_seconds=existing.gpu_seconds synapse_estimate=synapse
        return (existing.gpu_seconds, synapse)
    end
end

"""
    apply_decay(agent_id) -> Float64

Apply 1%/day decay to the agent's pending_synapse balance.
Called daily by OSOVM scheduler via TOC_DECAY (0x55).
Returns the new pending_synapse balance (as Float64 for precision).
"""
function apply_decay(agent_id::AbstractString)::Float64
    lock(_lock) do
        existing = get(_balances, agent_id, nothing)
        if existing === nothing || existing.pending_synapse == 0
            return 0.0
        end
        decayed = floor(Int, existing.pending_synapse * 0.99)
        _balances[agent_id] = AgentBalance(
            agent_id,
            existing.gpu_seconds,
            decayed,
            _now(),
            existing.contribution_count,
        )
        @info "resource_meter: decay applied" agent_id before=existing.pending_synapse after=decayed
        return Float64(decayed)
    end
end

"""
    provider_leaderboard(n) -> Vector{Dict}

Return top-n agents by accumulated gpu_seconds (unminted).
Used by OSOVM dashboard / VantageDiscovery scoring.
"""
function provider_leaderboard(n::Int = 10)::Vector{Dict}
    lock(_lock) do
        sorted = sort(collect(values(_balances)); by=b -> b.gpu_seconds, rev=true)
        map(first(sorted, n)) do b
            Dict(
                "agent_id"           => b.agent_id,
                "gpu_seconds"        => b.gpu_seconds,
                "gpu_hours"          => b.gpu_seconds / 3600.0,
                "pending_synapse"    => b.pending_synapse,
                "contribution_count" => b.contribution_count,
                "last_updated"       => b.last_updated,
            )
        end
    end
end

# ── JSON interface (called by OSOVM HTTP API handlers) ───────────────────────

"""
    handle_record_json(json_str) -> String

HTTP handler wrapper: parse JSON body, call record_contribution, return JSON.
"""
function handle_record_json(json_str::AbstractString)::String
    r = JSON3.read(json_str)
    bal = record_contribution(
        string(r.agent_id),
        Float64(get(r, :gpu_seconds, 0.0)),
        string(get(r, :job_id, "")),
    )
    JSON3.write(Dict(
        "agent_id"    => bal.agent_id,
        "gpu_seconds" => bal.gpu_seconds,
        "updated_at"  => bal.last_updated,
    ))
end

"""
    handle_drain_json(json_str) -> String

HTTP handler wrapper for TOC_MINT drain step.
"""
function handle_drain_json(json_str::AbstractString)::String
    r = JSON3.read(json_str)
    (drained, synapse) = drain_for_mint(string(r.agent_id))
    JSON3.write(Dict(
        "agent_id"         => string(r.agent_id),
        "gpu_seconds_used" => drained,
        "synapse_estimate" => synapse,
        "eligible"         => drained > 0.0,
    ))
end

# ── internal ─────────────────────────────────────────────────────────────────

_now()::Float64 = Dates.datetime2unix(now(UTC))

end # module ResourceMeter

# ─────────────────────────────────────────────────────────────────────────────
# UcxJobMeter — live resource tracking during a single UCX job execution
#
# Tracks GPU-seconds elapsed, peak memory, and accrued Synapse cost in
# real-time during a job.  The final reading feeds into UcxPreflight.settle()
# as `actual_synapse` and `gpu_seconds`.
#
# Lifecycle:
#   session_id = UcxJobMeter.start(job_id, agent_id)
#   UcxJobMeter.sample(session_id; gpu_utilization=..., memory_mb=..., synapse_per_second=...)
#   reading    = UcxJobMeter.stop(session_id)   # → Dict for settle()
#
# Thread safety: each session is protected by a per-session ReentrantLock
# stored alongside the MeterSession.
# ─────────────────────────────────────────────────────────────────────────────

module UcxJobMeter

using Dates, Logging

export start_session, record_sample, stop_session, current_reading

# ── Types ─────────────────────────────────────────────────────────────────────

mutable struct MeterSession
    job_id              :: String
    agent_id            :: String
    started_at          :: Float64
    last_sample_at      :: Float64
    gpu_seconds_elapsed :: Float64
    memory_mb_peak      :: Float64
    synapse_cost_accrued:: Int
    sample_count        :: Int
    active              :: Bool
end

# ── Module-level session registry ─────────────────────────────────────────────

const _registry_mutex = ReentrantLock()
# session_id → (MeterSession, per-session ReentrantLock)
const _registry = Dict{String, Tuple{MeterSession, ReentrantLock}}()

# ── Public API ────────────────────────────────────────────────────────────────

"""
    start_session(job_id, agent_id) -> session_id

Begin metering for a job. Returns a session_id string.
Call this immediately before the UCX job launches (after preflight succeeds).
"""
function start_session(job_id::AbstractString, agent_id::AbstractString)::String
    session_id = "meter:$(job_id)"
    now_ts = _now()
    session = MeterSession(
        string(job_id), string(agent_id),
        now_ts, now_ts,
        0.0, 0.0, 0, 0, true,
    )
    lock(_registry_mutex) do
        _registry[session_id] = (session, ReentrantLock())
    end
    @info "ucx_job_meter: session started" session_id job_id agent_id
    return session_id
end

"""
    record_sample(session_id; gpu_utilization, memory_mb, synapse_per_second)

Record a resource snapshot. Call periodically (e.g. every 5–30 s) while the
job is running.

- `gpu_utilization` — fraction of one GPU in use (0.0–1.0, default 1.0)
- `memory_mb`       — current GPU memory in MB (default 0.0)
- `synapse_per_second` — Synapse units consumed per wall-second (default 0.0)
"""
function record_sample(
    session_id        :: AbstractString;
    gpu_utilization   :: Float64 = 1.0,
    memory_mb         :: Float64 = 0.0,
    synapse_per_second:: Float64 = 0.0,
)
    entry = lock(_registry_mutex) do
        get(_registry, session_id, nothing)
    end
    entry === nothing && (@warn "ucx_job_meter: record_sample on unknown session" session_id; return)

    (session, session_lock) = entry
    lock(session_lock) do
        !session.active && return

        now_ts     = _now()
        delta_secs = now_ts - session.last_sample_at

        session.gpu_seconds_elapsed  += delta_secs * clamp(gpu_utilization, 0.0, 1.0)
        session.memory_mb_peak        = max(session.memory_mb_peak, memory_mb)
        session.synapse_cost_accrued += round(Int, delta_secs * max(0.0, synapse_per_second))
        session.last_sample_at        = now_ts
        session.sample_count         += 1
    end
end

"""
    stop_session(session_id) -> Dict

Stop metering and return the final resource readings.
Removes the session from the registry.

Return keys:
- `session_id`, `job_id`, `agent_id`
- `gpu_seconds`        — billable GPU-seconds (utilization-weighted)
- `wall_seconds`       — total elapsed wall time
- `memory_mb_peak`     — peak GPU memory observed
- `synapse_cost_accrued` — Synapse units to charge (use as `actual_synapse` in settle())
- `sample_count`
"""
function stop_session(session_id::AbstractString)::Dict
    entry = lock(_registry_mutex) do
        e = get(_registry, session_id, nothing)
        e !== nothing && delete!(_registry, session_id)
        e
    end

    if entry === nothing
        @warn "ucx_job_meter: stop_session on unknown session" session_id
        return Dict("error" => "session not found: $(session_id)")
    end

    (session, session_lock) = entry
    lock(session_lock) do
        session.active = false
        now_ts = _now()
        # Final delta — counts wall time since last sample as full utilization
        session.gpu_seconds_elapsed += now_ts - session.last_sample_at
        wall_secs = now_ts - session.started_at

        @info "ucx_job_meter: session stopped" session_id=session_id job_id=session.job_id gpu_seconds=session.gpu_seconds_elapsed samples=session.sample_count

        return Dict(
            "session_id"            => string(session_id),
            "job_id"                => session.job_id,
            "agent_id"              => session.agent_id,
            "gpu_seconds"           => session.gpu_seconds_elapsed,
            "wall_seconds"          => wall_secs,
            "memory_mb_peak"        => session.memory_mb_peak,
            "synapse_cost_accrued"  => session.synapse_cost_accrued,
            "sample_count"          => session.sample_count,
        )
    end
end

"""
    current_reading(session_id) -> Dict

Non-destructive snapshot of current meter state. Does not stop the session.
"""
function current_reading(session_id::AbstractString)::Dict
    entry = lock(_registry_mutex) do
        get(_registry, session_id, nothing)
    end
    if entry === nothing
        return Dict("error" => "session not found: $(session_id)")
    end

    (session, session_lock) = entry
    lock(session_lock) do
        projected_gpu_secs = session.gpu_seconds_elapsed + (_now() - session.last_sample_at)
        Dict(
            "session_id"            => string(session_id),
            "gpu_seconds"           => projected_gpu_secs,
            "memory_mb_peak"        => session.memory_mb_peak,
            "synapse_cost_accrued"  => session.synapse_cost_accrued,
            "sample_count"          => session.sample_count,
            "active"                => session.active,
        )
    end
end

# ── internal ──────────────────────────────────────────────────────────────────

_now()::Float64 = Dates.datetime2unix(Dates.now(Dates.UTC))

end # module UcxJobMeter
