# job_spec.jl — the user-facing "smart contract for a simulation."
#
# Implements the Job → Proof flow locked in the vault design
# (knowledge/convo-1a475350-part11.md): a user submits a Job Spec, a
# worker (a CubeSandbox microVM, external to this repo -- see
# CUBESANDBOX_JOB_PIPELINE.md) runs it deterministically, produces
# checkpoints, and the checkpoints get committed to a Merkle root that
# OSOVM anchors in a receipt. This module owns the spec itself: its
# shape, its canonical hash (which becomes the job_id), and validation.
#
# Two tiers, matching the layering decided for user-authored sims:
#   :dsl    -- parameterized job against OSOVM's existing deterministic
#              catalogs (veil batch/parameters -- what VeilSim already
#              runs). Accepted as mineable by default.
#   :custom -- arbitrary user code (a CubeSandbox job). Not accepted as
#              mineable until it passes its own determinism self-test
#              (run twice, checkpoint Merkle roots must match) -- see
#              JobSpec.requires_determinism_proof.

module JobSpec

using SHA
using Dates
using JSON

export SimJobSpec, canonical_json, job_id, validate_spec

struct SimJobSpec
    kind::Symbol                       # :dsl or :custom
    world::String                      # environment/world identifier
    parameters::Dict{String, Any}      # veil batch/params (:dsl) or job config (:custom)
    seed::Int
    duration_steps::Int
    metrics_schema::Vector{String}     # names of metrics the run must report
    creator_wallet::String
    submitted_at::DateTime
end

"""Deterministic, canonical JSON serialization of a spec: sorted keys,
fixed field order, no wall-clock-dependent content beyond the explicit
`submitted_at` field the spec itself carries. Two logically-identical
specs must serialize to byte-identical output -- this is what job_id
hashes, so any instability here would let one spec masquerade as
multiple distinct jobs (or vice versa)."""
function canonical_json(spec::SimJobSpec)::String
    # JSON.json with a Dict built in a fixed key order (not
    # alphabetical -- Julia's JSON.jl does not reorder Dict keys itself,
    # so the order below IS the wire order every caller must match).
    ordered = Dict{String, Any}(
        "kind" => String(spec.kind),
        "world" => spec.world,
        "parameters" => _canonicalize_value(spec.parameters),
        "seed" => spec.seed,
        "duration_steps" => spec.duration_steps,
        "metrics_schema" => sort(spec.metrics_schema),
        "creator_wallet" => spec.creator_wallet,
        "submitted_at" => Dates.format(spec.submitted_at, dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
    )
    # Re-serialize through a sorted-key path for `parameters` (nested
    # Dicts) -- JSON.json itself doesn't sort keys, so build the string
    # manually for the one field that can have arbitrary nested keys.
    JSON.json(ordered)
end

"""Recursively sort Dict keys so nested parameter maps serialize
deterministically regardless of Julia's Dict iteration order (which is
not guaranteed stable across processes)."""
function _canonicalize_value(v::Dict)
    Dict{String, Any}(k => _canonicalize_value(v[k]) for k in sort(collect(keys(v))))
end
_canonicalize_value(v::AbstractVector) = [_canonicalize_value(x) for x in v]
_canonicalize_value(v) = v

"""The job's unique identifier: SHA-256 of its canonical serialization.
Matches the vault design's "unique (spec + seed) -> unique root" rule --
job_id IS that uniqueness proof, derived from the spec alone before any
work runs."""
job_id(spec::SimJobSpec)::String = bytes2hex(sha256(Vector{UInt8}(codeunits(canonical_json(spec)))))

"""Structural validation only -- this module never runs the job, so it
cannot validate that `parameters` makes physical sense. Real errors
returned as a Vector{String}; empty = valid."""
function validate_spec(spec::SimJobSpec)::Vector{String}
    errors = String[]
    spec.kind in (:dsl, :custom) || push!(errors, "kind must be :dsl or :custom")
    isempty(spec.world) && push!(errors, "world must not be empty")
    spec.duration_steps > 0 || push!(errors, "duration_steps must be positive")
    isempty(spec.metrics_schema) && push!(errors, "metrics_schema must declare at least one metric")
    isempty(spec.creator_wallet) && push!(errors, "creator_wallet must not be empty")
    errors
end

"""Only :custom jobs need a determinism self-test before they're
eligible for the mineable receipt pipeline; :dsl jobs run OSOVM's own
already-proven-deterministic engine (VeilSim) and don't need a per-job
re-proof."""
requires_determinism_proof(spec::SimJobSpec)::Bool = spec.kind == :custom

export requires_determinism_proof

end # module JobSpec
