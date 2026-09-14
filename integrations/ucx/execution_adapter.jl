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
