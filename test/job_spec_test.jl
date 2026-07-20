include("../src/job_spec.jl")
using .JobSpec
using Test, Dates

@testset "JobSpec" begin
    @testset "job_id is deterministic regardless of Dict/Vector key insertion order" begin
        spec1 = SimJobSpec(:dsl, "drone-gate-race", Dict("veil_batch" => [1, 2, 3], "gain" => 1.5),
                            42, 1000, ["f1_score", "energy_drift"], "0xabc", DateTime(2026, 7, 20, 12, 0, 0))
        spec2 = SimJobSpec(:dsl, "drone-gate-race", Dict("gain" => 1.5, "veil_batch" => [1, 2, 3]),
                            42, 1000, ["energy_drift", "f1_score"], "0xabc", DateTime(2026, 7, 20, 12, 0, 0))
        @test job_id(spec1) == job_id(spec2)
    end

    @testset "job_id changes when the spec actually changes" begin
        base = SimJobSpec(:dsl, "w", Dict("a" => 1), 1, 100, ["m"], "0x1", DateTime(2026, 1, 1))
        changed_seed = SimJobSpec(:dsl, "w", Dict("a" => 1), 2, 100, ["m"], "0x1", DateTime(2026, 1, 1))
        @test job_id(base) != job_id(changed_seed)
    end

    @testset "validate_spec catches every real violation" begin
        bad = SimJobSpec(:dsl, "", Dict(), 1, 0, String[], "", now())
        errs = validate_spec(bad)
        @test length(errs) == 4
        @test any(occursin("world", e) for e in errs)
        @test any(occursin("duration_steps", e) for e in errs)
        @test any(occursin("metrics_schema", e) for e in errs)
        @test any(occursin("creator_wallet", e) for e in errs)
    end

    @testset "validate_spec passes a well-formed spec" begin
        good = SimJobSpec(:dsl, "world", Dict("a" => 1), 1, 100, ["f1"], "0xabc", now())
        @test isempty(validate_spec(good))
    end

    @testset "requires_determinism_proof gates by tier" begin
        dsl_spec = SimJobSpec(:dsl, "w", Dict(), 1, 1, ["m"], "0x1", now())
        custom_spec = SimJobSpec(:custom, "w", Dict(), 1, 1, ["m"], "0x1", now())
        @test !requires_determinism_proof(dsl_spec)
        @test requires_determinism_proof(custom_spec)
    end
end

println("JobSpec tests complete.")
