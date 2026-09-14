# OSOVM / UCX receipt adapter
#
# Responsibility: translate a completed UCX ComputeReceipt into a canonical
# Zàngbétò receipt that OSOVM records on-chain / in the sovereign ledger.
#
# Dependency direction: OSOVM does NOT import UCX types directly.
# This module speaks plain JSON on both sides — the bridge lives here.
#
# Called by: ucx-broker (ucx-osovm integration crate, future) via HTTP or IPC.

module UcxReceiptAdapter

using JSON3, Dates

export ucx_to_zangbeto, ZangbetoReceipt, check_mint_allowlist

struct ZangbetoReceipt
    job_id         :: String
    provider_id    :: String
    execution_hash :: Union{String, Nothing}
    artifact_hash  :: Union{String, Nothing}
    gpu_seconds    :: Float64
    cpu_seconds    :: Float64
    amount_cents   :: Int
    currency       :: String
    anchored_at    :: DateTime
end

"""
    ucx_to_zangbeto(ucx_receipt_json) -> ZangbetoReceipt

Translate the raw UCX ComputeReceipt JSON (from ucx-broker) into the
canonical Zàngbétò receipt that OSOVM records.

The returned struct should be passed to `ZangbetoReceipts.record()`.
"""
function ucx_to_zangbeto(raw::AbstractString)::ZangbetoReceipt
    r = JSON3.read(raw)
    ZangbetoReceipt(
        string(r.job_id),
        string(r.provider_id),
        get(r.verification, :execution_hash, nothing),
        get(r.verification, :artifact_hash,  nothing),
        Float64(r.resources.gpu_seconds),
        Float64(r.resources.cpu_seconds),
        Int(r.billing.amount_cents),
        string(r.billing.currency),
        now(UTC),
    )
end

"""
    check_mint_allowlist(ucx_receipt::Dict) -> Bool

Validate that a UCX receipt is eligible to trigger a Dopamine/Synapse mint.
Returns true only when ALL of the following hold:

  1. provider_id is present and non-empty
  2. agent_id is present and non-empty
  3. workload_hash is present (proof of actual work, not idle billing)
  4. completed_at timestamp is within the last 1 hour (prevents replayed receipts)

Fail-closed: any missing or expired field returns false.
"""
function check_mint_allowlist(ucx_receipt::Dict)::Bool
    provider_id  = string(get(ucx_receipt, "provider_id",
                              get(ucx_receipt, :provider_id, "")))
    agent_id     = string(get(ucx_receipt, "agent_id",
                              get(ucx_receipt, :agent_id, "")))
    workload_hash = string(get(ucx_receipt, "workload_hash",
                               get(ucx_receipt, :workload_hash, "")))

    isempty(provider_id)   && return false
    isempty(agent_id)      && return false
    isempty(workload_hash) && return false

    completed_at = get(ucx_receipt, "completed_at",
                       get(ucx_receipt, :completed_at, 0))
    now_ts = round(Int, datetime2unix(now(UTC)))
    (now_ts - Int(completed_at)) > 3600 && return false

    return true
end

end # module
