# job_pipeline_test.jl — end-to-end: submit → execute → prove → verify
#
# Exercises the exact chain the HTTP server now exposes (POST /v1/job,
# POST /v1/job/{id}/run, POST /v1/job/{id}/receipt, GET /v1/receipt/{id}/proof/{leaf})
# directly against the underlying modules, so the "no missing links" property
# is locked by a test rather than by prose.
#
# Runs the :dsl tier (VeilSim). :custom requires CubeSandbox (task #24) and is
# deliberately out of scope here.

include("../src/veilsim_engine.jl")
using .VeilSimEngine
include("../src/zangbeto_receipts.jl")
using .ZangbetoReceipts
using Test, Dates

const JS = ZangbetoReceipts.JobSpec
const CE = ZangbetoReceipts.CheckpointExport
const Merkle = ZangbetoReceipts.Merkle

# Mirror the metric set VeilSim's SimulationMetrics can actually produce.
const VEILSIM_METRICS = [
    "f1_score", "energy_efficiency", "convergence_rate", "robustness_score",
    "latency_ms", "throughput_vps", "total_energy", "energy_drift", "collision_count",
]

function sim_metrics_to_dict(m::VeilSimEngine.SimulationMetrics)::Dict{String, Float64}
    Dict{String, Float64}(
        "f1_score" => m.f1_score,
        "energy_efficiency" => m.energy_efficiency,
        "convergence_rate" => m.convergence_rate,
        "robustness_score" => m.robustness_score,
        "latency_ms" => m.latency_ms,
        "throughput_vps" => m.throughput_vps,
        "total_energy" => m.total_energy,
        "energy_drift" => m.energy_drift,
        "collision_count" => Float64(m.collision_count),
    )
end

@testset "job pipeline end-to-end (submit → execute → prove → verify)" begin
    # ── 1. SUBMIT ─────────────────────────────────────────────────────
    spec = JS.SimJobSpec(:dsl, "drone-gate-race", Dict("timestep" => 0.01), 42, 50,
                         ["f1_score", "energy_drift"], "0xabc", now())
    @test isempty(JS.validate_spec(spec))
    jid = JS.job_id(spec)
    @test length(jid) == 64  # hex SHA-256

    # ── 2. EXECUTE (:dsl → VeilSim) ───────────────────────────────────
    sim = VeilSimEngine.initialize_simulation(
        spec.world,
        Dict[Dict("type" => "robot", "position" => [0.0, 0.0, 0.0],
                  "target" => [10.0, 0.0, 0.0], "veils" => [1, 2, 3])],
        Dict("gravity" => [0.0, -9.81, 0.0]),
        0.01,
    )
    final_sim, metrics_history = VeilSimEngine.batch_simulation(sim, spec.duration_steps)
    @test length(metrics_history) == spec.duration_steps

    checkpoints = CE.Checkpoint[
        CE.Checkpoint(i, Dict("time" => Float64(i) * 0.01, "entities" => length(final_sim.entities)),
                      sim_metrics_to_dict(metrics_history[i]))
        for i in 1:length(metrics_history)
    ]
    @test length(checkpoints) == spec.duration_steps

    all_metrics = sim_metrics_to_dict(final_sim.metrics)
    final_metrics = Dict{String, Float64}(m => all_metrics[m] for m in spec.metrics_schema)
    @test all(haskey(final_metrics, m) for m in spec.metrics_schema)

    # ── 3. PROVE (receipt) ────────────────────────────────────────────
    bundle = ZangbetoReceipts.create_job_receipt(spec, checkpoints, final_metrics, "")
    @test bundle.job_id == jid
    @test bundle.checkpoint_count == spec.duration_steps
    @test length(bundle.checkpoint_merkle_root) == 64
    @test bundle.status in ("VERIFIED", "QUORUM_FAILED")
    @test startswith(bundle.seal, "job-")      # Layer 1 seal always present

    # ── 4. VERIFY (Merkle inclusion, sampled checkpoint) ─────────────
    leaves = CE.checkpoint_leaves(checkpoints)
    root = Merkle.merkle_root(leaves)
    @test bytes2hex(root) == bundle.checkpoint_merkle_root

    # A validator can verify ANY single sampled checkpoint without the rest.
    for idx in (1, length(leaves) ÷ 2, length(leaves))
        path = Merkle.merkle_path(leaves, idx)
        @test Merkle.verify_merkle_path(leaves[idx], path, root)
    end

    # ── 5. Determinism: same spec + same run → same job_id + same root ─
    bundle2 = ZangbetoReceipts.create_job_receipt(spec, checkpoints, final_metrics, "")
    @test bundle2.job_id == bundle.job_id
    @test bundle2.checkpoint_merkle_root == bundle.checkpoint_merkle_root
end

println("job pipeline end-to-end tests complete.")
