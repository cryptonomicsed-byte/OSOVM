#!/usr/bin/env julia
# verify_merkle_path.jl — offline receipt-proof verifier.
#
# A validator (or any agent) that fetched a proof from
# GET /v1/receipt/{job_id}/proof/{leaf} can verify, without the OSOVM
# server and without downloading any other checkpoint, that a single
# sampled checkpoint is included in the receipt's Merkle root.
#
# Usage:
#   julia --project=. scripts/verify_merkle_path.jl \
#       <root_hex> <leaf_hex> '[{"sibling_hex":"...","side":"left"}, ...]'
#
# Exits 0 on VERIFIED, 1 on FAILED, 2 on usage error.

include(joinpath(@__DIR__, "..", "src", "merkle.jl"))
using .Merkle
using JSON

function main()
    length(ARGS) == 3 || (println(stderr, "usage: verify_merkle_path.jl <root_hex> <leaf_hex> <path_json>"); exit(2))

    root_hex = ARGS[1]
    leaf_hex = ARGS[2]
    path_json = ARGS[3]

    try
        path_raw = JSON.parse(path_json)
        path = Merkle.PathStep[
            Merkle.PathStep(hex2bytes(String(step["sibling_hex"])), Symbol(String(step["side"])))
            for step in path_raw
        ]
        root = hex2bytes(root_hex)
        leaf = hex2bytes(leaf_hex)
        ok = Merkle.verify_merkle_path(leaf, path, root)
        println(ok ? "VERIFIED" : "FAILED")
        exit(ok ? 0 : 1)
    catch e
        println(stderr, "error: $(sprint(showerror, e))")
        exit(2)
    end
end

main()
