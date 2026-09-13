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

export ucx_to_zangbeto, ZangbetoReceipt

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

end # module
