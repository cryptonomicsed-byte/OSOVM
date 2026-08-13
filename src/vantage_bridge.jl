# vantage_bridge.jl — Vantage <-> OSOVM job-schema adapter.
#
# This is the one piece flagged as the actual missing connective tissue
# between OSOVM and Vantage (2026-08-12 cross-pillar audit): OSOVM can
# settle, Vantage can post jobs, but nothing translates between Vantage's
# job/task marketplace schema (backend/routers/jobs.py, tables `jobs` +
# `job_tasks`, verified against Vantage's live db.py CREATE TABLE
# statements) and OSOVM's SimJobSpec (job_spec.jl).
#
# Deliberately honest about what it can and can't infer: Vantage's job
# schema is generic (title/description/required_capability) and has NO
# concept of a simulation world, seed, duration, or metrics schema --
# those are OSOVM-specific and Vantage has nowhere to put them today.
# This module does NOT invent them from free text (that would silently
# misrepresent a Vantage job poster's intent as something they never
# specified). Instead it takes them as explicit caller-supplied
# parameters alongside the Vantage task dict, and fails loudly if the
# Vantage side is missing something it structurally cannot supply
# (a resolved wallet address -- Vantage stores that in `agent_wallets`,
# keyed by agent_id, not on the job/task row itself; see
# backend/routers/wallets.py -- so this module never tries to read it
# out of a job dict, the caller must resolve and pass it).

module VantageBridge

using Dates
using JSON

# zangbeto_receipts.jl already includes job_spec.jl internally (as its own
# nested submodule) -- including job_spec.jl again here separately would
# create a SECOND, distinct SimJobSpec type that Julia treats as
# incompatible with the one create_job_receipt actually dispatches on,
# despite identical source. Reach JobSpec only through ZangbetoReceipts'
# own copy so both this module and create_job_receipt agree on one type.
include("zangbeto_receipts.jl")
using .ZangbetoReceipts
using .ZangbetoReceipts.JobSpec

export vantage_task_to_jobspec, receipt_to_vantage_submission
export VantageAdapterError

struct VantageAdapterError <: Exception
    msg::String
end
Base.showerror(io::IO, e::VantageAdapterError) = print(io, "VantageAdapterError: ", e.msg)

"""
    vantage_task_to_jobspec(vantage_task::Dict, creator_wallet::AbstractString;
                             world, seed, duration_steps, metrics_schema,
                             kind=:dsl) -> SimJobSpec

Build a SimJobSpec from one Vantage job_tasks row (as returned by
`GET /api/jobs/{id}` inside its `"tasks"` array, or a single task fetched
via the same shape) plus the OSOVM-specific simulation parameters that
Vantage's schema has no field for.

`vantage_task` must have at least the keys Vantage's `job_tasks` table
actually has: `"id"`, `"job_id"`, `"title"`, `"description"`. Anything
else present is ignored (forward-compatible with Vantage adding columns).

`creator_wallet` is the resolved Sui/OSOVM wallet address for the task's
claimant -- the caller must look this up (e.g. via Vantage's
`agent_wallets` table / `GET` wallet endpoint) before calling; this
module never guesses it, since a wrong wallet here means a real
misdirected settlement.

Throws `VantageAdapterError` if the Vantage task dict is missing a
structurally-required field, or if the resulting spec fails OSOVM's own
`validate_spec` (e.g. empty metrics_schema) -- callers should treat
either as "this Vantage task cannot become an OSOVM job as given",
not as a bug to silently paper over.
"""
function vantage_task_to_jobspec(vantage_task::Dict, creator_wallet::AbstractString;
                                  world::AbstractString,
                                  seed::Integer,
                                  duration_steps::Integer,
                                  metrics_schema::Vector{<:AbstractString},
                                  kind::Symbol=:dsl)::SimJobSpec
    for required in ("id", "job_id", "title", "description")
        haskey(vantage_task, required) || throw(VantageAdapterError(
            "vantage_task missing required field \"$required\" -- not a valid job_tasks row"))
    end
    isempty(creator_wallet) && throw(VantageAdapterError(
        "creator_wallet is empty -- caller must resolve it from Vantage's agent_wallets " *
        "table before calling this adapter; OSOVM will not settle to an empty address"))

    # Vantage's free-text title/description become the OSOVM job's
    # `parameters` bag under stable, documented keys -- not merged into
    # `world` or guessed at. A :dsl job's real simulation parameters
    # (veil batch/config) still belong in `parameters` too; the caller
    # merges those in via `extra_parameters` if any exist.
    parameters = Dict{String, Any}(
        "vantage_job_id" => vantage_task["job_id"],
        "vantage_task_id" => vantage_task["id"],
        "vantage_title" => vantage_task["title"],
        "vantage_description" => vantage_task["description"],
    )

    spec = SimJobSpec(
        kind,
        String(world),
        parameters,
        Int(seed),
        Int(duration_steps),
        String.(metrics_schema),
        String(creator_wallet),
        now(),
    )

    errors = validate_spec(spec)
    isempty(errors) || throw(VantageAdapterError(
        "resulting SimJobSpec is invalid: " * join(errors, "; ")))

    spec
end

"""
    receipt_to_vantage_submission(receipt::JobReceiptBundle) -> Dict{String,Any}

Build the payload for Vantage's `POST /api/jobs/{job_id}/tasks/{task_id}/submit`
(`SubmitRequest`: `result_broadcast_id`, `result_description`) from a real
OSOVM `JobReceiptBundle`.

Vantage's `SubmitRequest` only has room for a free-text
`result_description` plus an optional broadcast id -- it has no column
for a Merkle root, witness quorum, or seal. Rather than lossily cramming
the receipt into that one string, this returns BOTH:
  - `"submit_request"`: the exact `{result_broadcast_id, result_description}`
    dict ready to POST as-is (broadcast id always `nothing` here -- this
    module does not create Vantage broadcasts; a caller who wants the
    full receipt visible on the feed should post one separately and pass
    its id back in before submitting).
  - `"receipt_summary"`: the real structured fields (job_id, status,
    quorum_met, checkpoint_merkle_root, walrus_blob_id, etc.) as a plain
    Dict, for the caller to store wherever Vantage actually has room for
    structured data (a vault note, a dedicated column migration, etc.)
    instead of losing it.

Throws `VantageAdapterError` if the receipt's `status` is not
`"VERIFIED"` -- an unverified receipt should never be submitted to
Vantage as completed work.
"""
function receipt_to_vantage_submission(receipt::JobReceiptBundle)::Dict{String, Any}
    receipt.status == "VERIFIED" || throw(VantageAdapterError(
        "refusing to build a Vantage submission for a non-VERIFIED receipt " *
        "(status=\"$(receipt.status)\", $(receipt.total_approvals) approvals) -- " *
        "submit only receipts that actually cleared witness quorum"))

    metrics_str = join(("$k=$(round(v; digits=4))" for (k, v) in sort(collect(receipt.final_metrics))), ", ")
    description = "OSOVM job $(receipt.job_id) VERIFIED " *
                   "($(receipt.total_approvals) witnesses, $(receipt.checkpoint_count) checkpoints). " *
                   "Merkle root: $(receipt.checkpoint_merkle_root). " *
                   (isempty(metrics_str) ? "" : "Metrics: $metrics_str.")

    Dict{String, Any}(
        "submit_request" => Dict{String, Any}(
            "result_broadcast_id" => nothing,
            "result_description" => description,
        ),
        "receipt_summary" => Dict{String, Any}(
            "job_id" => receipt.job_id,
            "spec_kind" => String(receipt.spec_kind),
            "creator_wallet" => receipt.creator_wallet,
            "checkpoint_count" => receipt.checkpoint_count,
            "checkpoint_merkle_root" => receipt.checkpoint_merkle_root,
            "final_metrics" => receipt.final_metrics,
            "walrus_blob_id" => receipt.walrus_blob_id,
            "quorum_met" => receipt.quorum_met,
            "total_approvals" => receipt.total_approvals,
            "status" => receipt.status,
            "seal" => receipt.seal,
            "created_at" => Dates.format(receipt.created_at, dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
        ),
    )
end

end # module VantageBridge
