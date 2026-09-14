# OSOVM / UCX event bridge
#
# Responsibility: when a UCX ComputeReceipt arrives with a verified GPU
# contribution, execute the GPU_CONTRIBUTION (0x3f) opcode in the OSOVM VM
# to record eligibility, then call TOC_MINT (0x54) to emit Synapse tokens.
#
# Called by: ucx-broker via HTTP POST /api/osovm/gpu_contribution
# or by the receipt_adapter after a ZangbetoReceipt is produced.

module UcxEventBridge

using JSON3, HTTP, Dates

export handle_gpu_contribution, request_toc_mint, handle_toc_decay

const OSOVM_BASE = get(ENV, "OSOVM_URL", "http://127.0.0.1:7780")

"""
    handle_gpu_contribution(receipt_json) -> Bool

Parse a UCX ComputeReceipt JSON and POST a GPU_CONTRIBUTION opcode execution
to OSOVM. Returns true if OSOVM accepted the contribution.

The contribution records:
  - provider_id (the agent that contributed GPU work)
  - gpu_seconds
  - job_id (for audit)
  - zangbeto_anchor (for settlement verification)
"""
function handle_gpu_contribution(receipt_json::AbstractString)::Bool
    try
        r = JSON3.read(receipt_json)
        gpu_seconds = Float64(get(r, :gpu_seconds, 0.0))
        if gpu_seconds <= 0.0
            @warn "handle_gpu_contribution: zero gpu_seconds, skipping"
            return false
        end

        payload = Dict(
            "opcode"       => "0x3f",
            "opcode_name"  => "GPU_CONTRIBUTION",
            "provider_id"  => get(r, :provider_id, "unknown"),
            "agent_id"     => get(r, :submitter_id, "unknown"),
            "gpu_seconds"  => gpu_seconds,
            "job_id"       => get(r, :job_id, ""),
            "zangbeto_anchor" => get(r, :zangbeto_anchor, nothing),
            "timestamp"    => Dates.datetime2unix(now(UTC)),
        )

        resp = HTTP.post(
            "$OSOVM_BASE/api/vm/execute",
            ["Content-Type" => "application/json"],
            JSON3.write(payload);
            readtimeout = 10,
            status_exception = false,
        )

        if resp.status in 200:299
            @info "gpu_contribution recorded" provider=payload["provider_id"] gpu_seconds=gpu_seconds
            return true
        else
            @warn "OSOVM rejected gpu_contribution" status=resp.status
            return false
        end
    catch e
        @warn "handle_gpu_contribution error" exception=e
        return false
    end
end

"""
    request_toc_mint(agent_id, accumulated_gpu_seconds) -> Union{Dict, Nothing}

Execute TOC_MINT (0x54) in OSOVM to convert accumulated GPU seconds
into Synapse tokens. Returns the mint result dict or nothing on failure.

Mint rate: 1000 Synapse / GPU-hour (per OSOVM_TOC spec).
Gate: OSOVM validates is_fully_verified() before minting.
"""
function request_toc_mint(agent_id::AbstractString, accumulated_gpu_seconds::Float64)::Union{Dict, Nothing}
    try
        synapse_estimate = floor(Int, accumulated_gpu_seconds / 3600.0 * 1000)
        if synapse_estimate <= 0
            @info "toc_mint: insufficient gpu_seconds for mint" agent_id=agent_id gpu_seconds=accumulated_gpu_seconds
            return nothing
        end

        payload = Dict(
            "opcode"           => "0x54",
            "opcode_name"      => "TOC_MINT",
            "agent_id"         => agent_id,
            "gpu_seconds"      => accumulated_gpu_seconds,
            "synapse_estimate" => synapse_estimate,
            "timestamp"        => Dates.datetime2unix(now(UTC)),
        )

        resp = HTTP.post(
            "$OSOVM_BASE/api/vm/execute",
            ["Content-Type" => "application/json"],
            JSON3.write(payload);
            readtimeout = 15,
            status_exception = false,
        )

        if resp.status in 200:299
            result = JSON3.read(String(resp.body), Dict)
            @info "toc_mint executed" agent_id=agent_id minted=get(result, "minted_synapse", 0)
            return result
        else
            @warn "OSOVM rejected toc_mint" status=resp.status agent_id=agent_id
            return nothing
        end
    catch e
        @warn "request_toc_mint error" exception=e
        return nothing
    end
end

"""
    handle_toc_decay(agent_id) -> Bool

Execute TOC_DECAY (0x55) in OSOVM to apply the 1%/day Synapse balance decay
for the given agent. Called daily by the OSOVM scheduler.
"""
function handle_toc_decay(agent_id::AbstractString)::Bool
    try
        payload = Dict(
            "opcode"      => "0x55",
            "opcode_name" => "TOC_DECAY",
            "agent_id"    => agent_id,
            "timestamp"   => Dates.datetime2unix(now(UTC)),
        )

        resp = HTTP.post(
            "$OSOVM_BASE/api/vm/execute",
            ["Content-Type" => "application/json"],
            JSON3.write(payload);
            readtimeout = 10,
            status_exception = false,
        )

        return resp.status in 200:299
    catch e
        @warn "handle_toc_decay error" exception=e
        return false
    end
end

end # module UcxEventBridge
