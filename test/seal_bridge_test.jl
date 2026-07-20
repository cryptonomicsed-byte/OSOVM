# seal_bridge_test.jl — real, subprocess-driven tests for the Seal bridge.
# Mirrors Omo-Koda2's seal_bridge.rs test suite (same architecture family).

include("../src/seal_bridge.jl")
using .SealBridge
using Test

@testset "SealBridge" begin
    @testset "config_from_env fail-open" begin
        for k in ("SEAL_REQUEST_CMD", "SEAL_FETCH_CMD", "SEAL_KEY_SERVER_IDS", "SEAL_THRESHOLD", "SEAL_NETWORK")
            delete!(ENV, k)
        end
        @test config_from_env() === nothing

        ENV["SEAL_REQUEST_CMD"] = "echo test"
        ENV["SEAL_FETCH_CMD"] = "echo test"
        @test config_from_env() === nothing  # still nothing: no key server ids

        delete!(ENV, "SEAL_REQUEST_CMD")
        delete!(ENV, "SEAL_FETCH_CMD")
        @test try_seal_fingerprint() === nothing
    end

    @testset "build_fetch_command substitutes every verified placeholder" begin
        cfg = SealConfig(
            "printf %s deadbeef",
            "seal-cli fetch-keys --request {request_hex} -k {key_server_id} -t {threshold} -n {network}",
            ["0xserver1", "0xserver2"], "2", "testnet",
        )
        cmd = build_fetch_command(cfg, "deadbeef")
        @test occursin("--request deadbeef", cmd)
        @test occursin("-k 0xserver1,0xserver2", cmd)
        @test occursin("-t 2", cmd)
        @test occursin("-n testnet", cmd)
        @test !occursin("{", cmd)
    end

    @testset "fetch_dek_fingerprint is deterministic over the real two-step pipeline" begin
        cfg = SealConfig("printf %s fake-request-hex", "printf %s fixed-key-share-bytes", ["x"], "1", "testnet")
        a = fetch_dek_fingerprint(cfg)
        b = fetch_dek_fingerprint(cfg)
        @test a == b
        @test length(a) == 64  # 32-byte SHA-256, hex-encoded
    end

    @testset "fetch_dek_fingerprint fails when request step produces no output" begin
        cfg = SealConfig("true", "printf %s x", ["x"], "1", "testnet")
        @test_throws ErrorException fetch_dek_fingerprint(cfg)
    end

    @testset "fetch_dek_fingerprint fails when fetch step exits nonzero" begin
        cfg = SealConfig("printf %s x", "exit 1", ["x"], "1", "testnet")
        @test_throws ErrorException fetch_dek_fingerprint(cfg)
    end

    @testset "request_hex from step 1 actually reaches step 2" begin
        cfg = SealConfig(
            "printf %s cafef00d",
            "test \"{request_hex}\" = \"cafef00d\" && echo ok || exit 1",
            ["x"], "1", "testnet",
        )
        @test fetch_dek_fingerprint(cfg) isa String  # succeeds only if wired together
    end
end

println("SealBridge tests complete.")
