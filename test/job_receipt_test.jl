include("../src/zangbeto_receipts.jl")
using .ZangbetoReceipts
using Test, Dates

const JS = ZangbetoReceipts.JobSpec
const CE = ZangbetoReceipts.CheckpointExport

@testset "create_job_receipt" begin
    spec = JS.SimJobSpec(:dsl, "drone-gate-race", Dict("gain" => 1.5), 42, 1000, ["f1_score"], "0xabc", now())
    checkpoints = [CE.Checkpoint(i, Dict("pos" => Float64(i)), Dict("f1_score" => 0.9)) for i in 1:5]

    @testset "produces a real, well-formed bundle" begin
        delete!(ENV, "SEAL_REQUEST_CMD")
        bundle = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95), "walrus-blob-abc123")
        @test bundle.job_id == JS.job_id(spec)
        @test bundle.checkpoint_count == 5
        @test bundle.status in ("VERIFIED", "QUORUM_FAILED")
        @test length(bundle.checkpoint_merkle_root) == 64  # hex SHA-256
        @test bundle.seal_dek_fingerprint == ""             # fail-open, unconfigured
        @test bundle.walrus_blob_id == "walrus-blob-abc123"
    end

    @testset "Merkle root is reproducible across independent runs" begin
        b1 = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95), "blob-1")
        b2 = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95), "blob-2")
        @test b1.checkpoint_merkle_root == b2.checkpoint_merkle_root
        @test b1.job_id == b2.job_id
    end

    @testset "rejects a spec missing a declared metric" begin
        bad_spec = JS.SimJobSpec(:dsl, "w", Dict(), 1, 100, ["missing_metric"], "0x1", now())
        @test_throws ErrorException create_job_receipt(bad_spec, checkpoints, Dict("f1_score" => 0.9), "blob")
    end

    @testset "rejects zero checkpoints" begin
        @test_throws ErrorException create_job_receipt(spec, CE.Checkpoint[], Dict("f1_score" => 0.9), "blob")
    end

    @testset "rejects an invalid spec" begin
        invalid = JS.SimJobSpec(:dsl, "", Dict(), 1, 0, String[], "", now())
        @test_throws ErrorException create_job_receipt(invalid, checkpoints, Dict{String,Float64}(), "blob")
    end

    @testset "dual seal Layer 2 populates when Seal is configured" begin
        ENV["SEAL_REQUEST_CMD"] = "printf %s testreq"
        ENV["SEAL_FETCH_CMD"] = "printf %s testkeydata"
        ENV["SEAL_KEY_SERVER_IDS"] = "0xserver1"
        bundle = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95), "blob")
        @test length(bundle.seal_dek_fingerprint) == 64
        delete!(ENV, "SEAL_REQUEST_CMD")
        delete!(ENV, "SEAL_FETCH_CMD")
        delete!(ENV, "SEAL_KEY_SERVER_IDS")
    end

    @testset "different checkpoint content produces a different root" begin
        other_checkpoints = [CE.Checkpoint(i, Dict("pos" => Float64(i) * 2), Dict("f1_score" => 0.9)) for i in 1:5]
        b1 = create_job_receipt(spec, checkpoints, Dict("f1_score" => 0.95), "blob")
        b2 = create_job_receipt(spec, other_checkpoints, Dict("f1_score" => 0.95), "blob")
        @test b1.checkpoint_merkle_root != b2.checkpoint_merkle_root
    end
end

println("create_job_receipt tests complete.")
