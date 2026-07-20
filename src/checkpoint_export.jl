# checkpoint_export.jl — canonical, deterministic checkpoint serialization.
#
# The whole Job → Proof flow's soundness rests on one thing: hashing the
# SAME bytes for the SAME logical checkpoint, every time, on every
# machine. Explicitly does NOT hash a raw SQLite/PocketBase file --
# on-disk DB layout (page order, VACUUM state, WAL artifacts) can differ
# between two logically-identical runs, which would manufacture false
# "nondeterminism" failures (the same class of bug already found and
# fixed in this session's determinism work: JSON int-vs-float, Dict
# iteration order). PocketBase/any local DB stays a live-telemetry
# convenience during the run; THIS module's canonical export is the only
# thing that ever gets hashed into the Merkle tree.

module CheckpointExport

using SHA
using JSON
using Printf: @sprintf

export Checkpoint, canonical_checkpoint_bytes, checkpoint_leaves

struct Checkpoint
    step::Int
    state::Dict{String, Any}      # position/velocity/whatever the sim tracks
    metrics::Dict{String, Float64} # must cover the job spec's metrics_schema
end

"""Fixed-precision string for a Float64 -- 17 significant digits (the
minimum that round-trips any Float64 exactly per Steele & White/Grisu),
so two machines with different default `string(::Float64)` formatting
still agree byte-for-byte."""
_fixed_float(x::Float64)::String = @sprintf("%.17g", x)

function _canonicalize(v::Dict)
    Dict{String, Any}(k => _canonicalize(v[k]) for k in sort(collect(keys(v))))
end
_canonicalize(v::AbstractVector) = [_canonicalize(x) for x in v]
_canonicalize(v::Float64) = _fixed_float(v)
_canonicalize(v) = v

"""Canonical byte serialization of one checkpoint: sorted keys
(recursively), fixed-precision floats, fixed field order. This is what
gets hashed into a Merkle leaf -- never the raw struct, never a DB file."""
function canonical_checkpoint_bytes(cp::Checkpoint)::Vector{UInt8}
    ordered = Dict{String, Any}(
        "step" => cp.step,
        "state" => _canonicalize(cp.state),
        "metrics" => Dict{String, Any}(k => _fixed_float(cp.metrics[k]) for k in sort(collect(keys(cp.metrics)))),
    )
    Vector{UInt8}(codeunits(JSON.json(ordered)))
end

"""SHA-256 leaves, in step order, ready for `Merkle.merkle_root`. Step
order (not insertion order) is enforced here so a worker can't
manufacture a different root from the same checkpoint set by reordering
writes."""
function checkpoint_leaves(checkpoints::Vector{Checkpoint})::Vector{Vector{UInt8}}
    ordered = sort(checkpoints, by = cp -> cp.step)
    [sha256(canonical_checkpoint_bytes(cp)) for cp in ordered]
end

end # module CheckpointExport
