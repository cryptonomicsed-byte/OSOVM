# Real determinism check: run a full sim from scratch, hash the final state.
# Run this in TWO separate Julia processes and compare DETERMINISM_HASH.
# Same hash across processes => cross-process reproducibility (the PoSim gate).
include(joinpath(@__DIR__, "..", "src", "veilsim_engine.jl"))
using .VeilSimEngine
using SHA

sim = initialize_simulation(
    "determinism-real",
    Dict[ Dict("type" => "robot", "mass" => 2.0, "veils" => [1]) ],
    Dict{String, Any}("gravity" => [0.0, -9.81, 0.0]),
    0.01,
)
sim.entities[1].velocity = VeilSimEngine.Vec3(0.25, 0.0, 0.0)

sim, _ = batch_simulation(sim, 200)

parts = String[]
for e in sim.entities
    push!(parts, string(e.position.x, ",", e.position.y, ",", e.position.z, ",",
                        e.velocity.x, ",", e.velocity.y, ",", e.velocity.z))
end
digest = bytes2hex(sha256(join(parts, ";")))
println("DETERMINISM_HASH=", digest)
