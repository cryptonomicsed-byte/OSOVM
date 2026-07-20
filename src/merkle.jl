# merkle.jl — generic Merkle tree over arbitrary byte-leaves.
#
# Generalizes the proven pairwise-SHA-256 pattern already used in
# glyphindex.jl's merkle_root(vault) (odd-leaf carry-up, no synthetic
# duplication) to work over any Vector{Vector{UInt8}} of leaves, plus
# adds path generation/verification -- glyphindex.jl only ever needed
# the root; the Job → Proof flow additionally needs validators to be
# able to request a Merkle path for one sampled checkpoint and verify
# it without holding every other checkpoint.

module Merkle

using SHA

export merkle_root, merkle_path, verify_merkle_path

"""Root over `leaves` (already-hashed or raw bytes -- caller's choice;
this module never re-hashes a leaf, matching glyphindex.jl's own
convention of hashing content before it arrives here). Same
odd-leaf-carries-up rule as glyphindex.jl: never duplicates a lone leaf,
which would let an attacker who controls a duplicate produce root
collisions."""
function merkle_root(leaves::Vector{Vector{UInt8}})::Vector{UInt8}
    isempty(leaves) && return sha256(Vector{UInt8}(codeunits("MERKLE:empty")))
    level = leaves
    while length(level) > 1
        nxt = Vector{Vector{UInt8}}()
        for i in 1:2:length(level)-1
            push!(nxt, sha256(vcat(level[i], level[i+1])))
        end
        isodd(length(level)) && push!(nxt, level[end])
        level = nxt
    end
    level[1]
end

"""One step of a Merkle inclusion path: the sibling hash and which side
it's on (`:left` or `:right` of the node being folded)."""
struct PathStep
    sibling::Vector{UInt8}
    side::Symbol
end

"""Inclusion path for `leaves[index]` (1-based) -- the sibling hashes a
verifier needs to recompute the root from just that one leaf, without
ever seeing the other leaves. This is the real mechanism behind the
vault design's "validators derive random indices... request Merkle
paths + sampled checkpoints" step: a validator gets this path plus the
one checkpoint, and can verify inclusion in O(log n) without downloading
the whole job."""
function merkle_path(leaves::Vector{Vector{UInt8}}, index::Int)::Vector{PathStep}
    1 <= index <= length(leaves) || error("index $index out of range for $(length(leaves)) leaves")
    path = PathStep[]
    level = leaves
    idx = index
    while length(level) > 1
        nxt = Vector{Vector{UInt8}}()
        n = length(level)
        for i in 1:2:n-1
            if idx == i
                push!(path, PathStep(level[i+1], :right))
            elseif idx == i + 1
                push!(path, PathStep(level[i], :left))
            end
            push!(nxt, sha256(vcat(level[i], level[i+1])))
        end
        isodd(n) && push!(nxt, level[end])

        # Parent index: paired leaves fold to ceil(idx/2); a lone
        # carried-up trailing leaf (idx == n, n odd) keeps its own
        # value by landing in the last slot of nxt, whose position IS
        # length(nxt) -- not the pairing formula, which would be wrong
        # for it (there's no pair to fold).
        idx = (isodd(n) && idx == n) ? length(nxt) : cld(idx, 2)
        level = nxt
    end
    path
end

"""Recompute the root from `leaf` + `path` and compare to `root`. This
is exactly what a sampling validator runs -- no access to any other
checkpoint required."""
function verify_merkle_path(leaf::Vector{UInt8}, path::Vector{PathStep}, root::Vector{UInt8})::Bool
    node = leaf
    for step in path
        node = step.side == :right ? sha256(vcat(node, step.sibling)) : sha256(vcat(step.sibling, node))
    end
    node == root
end

end # module Merkle
