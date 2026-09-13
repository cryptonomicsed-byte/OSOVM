# Gate 4: Contact/Collision Determinism
#
# Verifies that two separate simulation runs from identical initial conditions
# produce bit-identical final states after collisions occur.
#
# Determinism invariant: entity iteration order in detect_and_resolve_collisions!
# is sorted by entity ID, so insertion order has no effect on outcome.

include("../src/veilsim_engine.jl")

using Test
using SHA
using .VeilSimEngine

function run_collision_sim(seed_label::String)::String
    # Two entities on a collision course (head-on along x-axis)
    sim = initialize_simulation(
        seed_label,
        Dict[
            Dict("type" => "robot", "mass" => 1.0, "veils" => [],
                 "position" => [-2.0, 0.5, 0.0],
                 "velocity" => [3.0,  0.0, 0.0],
                 "target"   => [10.0, 0.5, 0.0]),
            Dict("type" => "robot", "mass" => 1.0, "veils" => [],
                 "position" => [2.0,  0.5, 0.0],
                 "velocity" => [-3.0, 0.0, 0.0],
                 "target"   => [-10.0, 0.5, 0.0]),
        ],
        Dict{String,Any}("gravity" => [0.0, 0.0, 0.0]),  # no gravity — pure contact test
        0.01,
    )

    sim, _ = batch_simulation(sim, 100)

    parts = String[]
    for e in sort(sim.entities, by = e -> e.id)
        push!(parts, string(
            e.position.x, ",", e.position.y, ",", e.position.z, ",",
            e.velocity.x, ",", e.velocity.y, ",", e.velocity.z
        ))
    end
    bytes2hex(sha256(join(parts, ";")))
end

@testset "Gate 4: contact/collision determinism" begin
    hash_a = run_collision_sim("gate4-run-a")
    hash_b = run_collision_sim("gate4-run-b")

    @test hash_a == hash_b
    println("Gate 4 PASS — collision hash: $(hash_a[1:16])...")

    # Verify collisions actually happened (sanity check that we tested something real)
    sim = initialize_simulation(
        "gate4-collision-check",
        Dict[
            Dict("type" => "robot", "mass" => 1.0, "veils" => [],
                 "position" => [-2.0, 0.5, 0.0],
                 "velocity" => [3.0,  0.0, 0.0],
                 "target"   => [10.0, 0.5, 0.0]),
            Dict("type" => "robot", "mass" => 1.0, "veils" => [],
                 "position" => [2.0,  0.5, 0.0],
                 "velocity" => [-3.0, 0.0, 0.0],
                 "target"   => [-10.0, 0.5, 0.0]),
        ],
        Dict{String,Any}("gravity" => [0.0, 0.0, 0.0]),
        0.01,
    )
    sim, _ = batch_simulation(sim, 100)
    @test sim.metrics.collision_count > 0
    println("Gate 4 — collision count: $(sim.metrics.collision_count) (confirmed contacts occurred)")
end
