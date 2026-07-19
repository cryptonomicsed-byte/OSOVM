include("../src/veilsim_engine.jl")

using Test
using .VeilSimEngine

@testset "VeilSimEngine deterministic F1" begin
    sim = initialize_simulation(
        "determinism-check",
        Dict[
            Dict("type" => "robot", "mass" => 2.0, "veils" => [1]),
        ],
        Dict{String, Any}("gravity" => [0.0, -9.81, 0.0]),
        0.01
    )

    entity = sim.entities[1]
    entity.velocity = VeilSimEngine.Vec3(0.25, 0.0, 0.0)
    entity.state.health = 0.92
    entity.state.kinetic_energy = 0.15
    entity.state.potential_energy = 0.05
    entity.state.total_force = VeilSimEngine.Vec3(0.1, 0.0, 0.0)
    sim.metrics.throughput_vps = 25.0

    f1_first = compute_f1(sim)
    f1_second = compute_f1(sim)

    @test f1_first == f1_second
    @test compute_metrics(sim).f1_score == f1_first
end
