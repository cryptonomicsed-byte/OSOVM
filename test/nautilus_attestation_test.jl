# nautilus_attestation_test.jl — mirrors Omo-Koda2's real attestation.rs
# test suite (same architecture family, same honesty level).

include("../src/nautilus_attestation.jl")
using .NautilusAttestation
using Test

@testset "NautilusAttestation" begin
    @testset "code_measurement_of_engine is real and deterministic" begin
        m1 = code_measurement_of_engine()
        m2 = code_measurement_of_engine()
        @test m1 == m2
        @test length(m1) == 32  # real SHA-256 digest, not a placeholder
    end

    @testset "verify_quote accepts a matching measurement" begin
        measurement = code_measurement_of_engine()
        tee_quote = TeeQuote(fill(0x09, 32), measurement, fill(0x02, 16), fill(0x03, 8))
        result = verify_quote(tee_quote, measurement)
        @test result.enclave_id == tee_quote.enclave_id
        @test length(result.seal_key) == 32
    end

    @testset "verify_quote rejects a measurement mismatch" begin
        real_measurement = code_measurement_of_engine()
        wrong_measurement = fill(0x08, 32)
        tee_quote = TeeQuote(fill(0x01, 32), wrong_measurement, fill(0x02, 16), fill(0x03, 8))
        @test_throws ErrorException verify_quote(tee_quote, real_measurement)
    end

    @testset "attest_f1_score reports verified=true for the real engine build" begin
        measurement = code_measurement_of_engine()
        tee_quote = TeeQuote(fill(0x09, 32), measurement, fill(0x02, 16), fill(0x03, 8))
        att = attest_f1_score("sim-42", 0.95, tee_quote)
        @test att.verified
        @test att.f1_score == 0.95
        @test att.sim_id == "sim-42"
    end

    @testset "attest_f1_score reports verified=false, never throws, on a stale/wrong quote" begin
        tee_quote = TeeQuote(fill(0x09, 32), fill(0xFF, 32), fill(0x02, 16), fill(0x03, 8))
        att = attest_f1_score("sim-43", 0.95, tee_quote)
        @test !att.verified
    end
end

println("NautilusAttestation tests complete.")
