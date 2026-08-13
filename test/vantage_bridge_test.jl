# test/vantage_bridge_test.jl — proves the Vantage <-> OSOVM job-schema
# adapter actually round-trips real shapes from both sides, not just
# that it compiles. See src/vantage_bridge.jl for the design rationale.

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using Test
using Dates

include(joinpath(@__DIR__, "..", "src", "vantage_bridge.jl"))
using .VantageBridge
using .VantageBridge.ZangbetoReceipts
using .VantageBridge.ZangbetoReceipts.JobSpec
using .VantageBridge.ZangbetoReceipts.CheckpointExport

@testset "VantageBridge: Vantage job_tasks row -> SimJobSpec" begin

    # A real shape as returned inside GET /api/jobs/{id}'s "tasks" array
    # (backend/routers/jobs.py get_job / _rows over the job_tasks table --
    # field names match db.py's CREATE TABLE job_tasks exactly).
    vantage_task = Dict(
        "id" => 42,
        "job_id" => 7,
        "title" => "Run gate-racing drone sim, seed 1337",
        "description" => "6-DOF drone gate race, F1 threshold 0.9",
        "required_capability" => "veilsim",
        "status" => "claimed",
        "claimed_by_id" => 3,
        "claimed_by_name" => "Claude-Codex",
        "claim_expires_at" => "2026-08-12T23:00:00",
        "result_broadcast_id" => nothing,
        "result_description" => "",
        "fail_count" => 0,
    )

    spec = vantage_task_to_jobspec(
        vantage_task, "0xd02ea140b30c6f16885d5b81d6b4f6bbc3b0585cec53ee6dbf901e77c185311f";
        world="veilsim-drone-gate-race",
        seed=1337,
        duration_steps=200,
        metrics_schema=["f1_score", "collisions"],
    )

    @test spec.kind == :dsl
    @test spec.world == "veilsim-drone-gate-race"
    @test spec.seed == 1337
    @test spec.duration_steps == 200
    @test spec.metrics_schema == ["f1_score", "collisions"]  # unsorted -- canonical_json sorts only for hashing
    @test spec.creator_wallet == "0xd02ea140b30c6f16885d5b81d6b4f6bbc3b0585cec53ee6dbf901e77c185311f"
    @test spec.parameters["vantage_job_id"] == 7
    @test spec.parameters["vantage_task_id"] == 42
    @test spec.parameters["vantage_title"] == "Run gate-racing drone sim, seed 1337"
    @test isempty(validate_spec(spec))

    # job_id must be the real deterministic hash, not a placeholder --
    # calling it twice on an equal-but-distinct spec (same submitted_at
    # can't be replicated exactly, so we just check it's a real 64-hex
    # SHA-256 string here, and stability is job_spec.jl's own concern).
    jid = job_id(spec)
    @test length(jid) == 64
    @test all(c -> c in "0123456789abcdef", jid)

    @testset "missing required Vantage field throws VantageAdapterError" begin
        bad_task = Dict("id" => 1, "job_id" => 1, "title" => "x")  # no "description"
        @test_throws VantageAdapterError vantage_task_to_jobspec(
            bad_task, "0xabc"; world="w", seed=1, duration_steps=10, metrics_schema=["m"])
    end

    @testset "empty creator_wallet throws VantageAdapterError" begin
        @test_throws VantageAdapterError vantage_task_to_jobspec(
            vantage_task, ""; world="w", seed=1, duration_steps=10, metrics_schema=["m"])
    end

    @testset "invalid resulting spec throws VantageAdapterError (empty metrics_schema)" begin
        @test_throws VantageAdapterError vantage_task_to_jobspec(
            vantage_task, "0xabc"; world="w", seed=1, duration_steps=10, metrics_schema=String[])
    end
end

@testset "VantageBridge: JobReceiptBundle -> Vantage submit payload" begin
    spec = SimJobSpec(
        :dsl, "veilsim-drone-gate-race",
        Dict{String,Any}("vantage_job_id" => 7, "vantage_task_id" => 42),
        1337, 200, ["f1_score", "collisions"],
        "0xd02ea140b30c6f16885d5b81d6b4f6bbc3b0585cec53ee6dbf901e77c185311f",
        now(),
    )

    checkpoints = [
        CheckpointExport.Checkpoint(0, Dict("pos" => [0.0, 0.0, 0.0]), Dict("f1_score" => 0.0, "collisions" => 0.0)),
        CheckpointExport.Checkpoint(1, Dict("pos" => [1.0, 0.0, 0.0]), Dict("f1_score" => 0.95, "collisions" => 0.0)),
    ]

    receipt = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95, "collisions" => 0.0), "walrus-blob-abc123")

    if receipt.status == "VERIFIED"
        result = receipt_to_vantage_submission(receipt)

        @test haskey(result, "submit_request")
        @test haskey(result, "receipt_summary")
        @test result["submit_request"]["result_broadcast_id"] === nothing
        @test occursin(receipt.job_id, result["submit_request"]["result_description"])
        @test occursin("VERIFIED", result["submit_request"]["result_description"])
        @test occursin(receipt.checkpoint_merkle_root, result["submit_request"]["result_description"])

        rs = result["receipt_summary"]
        @test rs["job_id"] == receipt.job_id
        @test rs["status"] == "VERIFIED"
        @test rs["quorum_met"] == true
        @test rs["checkpoint_merkle_root"] == receipt.checkpoint_merkle_root
        @test rs["walrus_blob_id"] == "walrus-blob-abc123"
        @test rs["final_metrics"]["f1_score"] == 0.95
    else
        # Witness quorum is randomized in this repo's own test harness
        # (see genesis_flow_test.jl / job_receipt_test.jl for the same
        # pattern) -- a QUORUM_FAILED receipt must be REJECTED, not
        # silently degraded into a submission.
        @test_throws VantageAdapterError receipt_to_vantage_submission(receipt)
    end
end
