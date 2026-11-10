# I-2 — the ASE→SYNAPSE scarcity curve, pinned down.
#
# Every assertion here is a property the invariant claims, not a golden
# number: a test that only checks one input/output pair would still pass
# after the curve was quietly replaced with a different one.

using Test
include(joinpath(@__DIR__, "..", "src", "token_guards.jl"))
using .TokenGuards

@testset "I-2 ase_to_synapse scarcity curve" begin
    S = TOC_CONSTANTS[:synapse][:saturation_count]
    rate = Float64(SYNAPSE_PER_ASE)

    @testset "base price preserved for small amounts" begin
        # 1 ASE against a 1e6 ASE saturation scale: within 1 part in 1e5 of
        # the linear base rate, so early conversion is not penalised.
        got = ase_to_synapse(1.0)
        @test isapprox(got, rate, rtol=1e-5)
        @test got <= rate                      # never MORE than base rate
    end

    @testset "monotone increasing" begin
        xs = [0.0, 1.0, 10.0, 1e3, 1e6, 1e9]
        ys = [ase_to_synapse(x) for x in xs]
        @test all(diff(ys) .> 0)
        @test ys[1] == 0.0
    end

    @testset "concave — each further ASE buys less" begin
        first_buy  = ase_to_synapse(1_000.0)
        second_buy = ase_to_synapse(1_000.0)          # from 0 again
        marginal_first  = ase_to_synapse(1_000.0; already_converted=0.0)
        marginal_second = ase_to_synapse(1_000.0; already_converted=1_000.0)
        @test marginal_second < marginal_first
        @test isapprox(first_buy, second_buy)          # purity
    end

    @testset "bounded by the supply cap" begin
        cap = synapse_supply_cap()
        @test isapprox(cap, rate * S)
        # Strictly below the cap at any reachable scale: one saturation
        # scale issues ~63% of the asymptote.
        @test ase_to_synapse(1e6) < cap
        @test isapprox(ase_to_synapse(1e6), (1 - exp(-1.0)) * cap, rtol=1e-12)
        # approaches the cap: within 0.1% after 10 saturation scales
        @test ase_to_synapse(10 * S) > 0.999 * cap
        # At 1e9 ASE the exponential underflows and the result IS the cap in
        # float64 -- the curve cannot be pushed past it, which is the point.
        @test ase_to_synapse(1e9) <= cap
        @test isapprox(ase_to_synapse(1e9), cap, rtol=1e-12)
        @test ase_to_synapse(1e12) <= cap
    end

    @testset "additive — splitting a payment buys no more credit" begin
        for (a, b) in [(1.0, 999.0), (500.0, 500.0), (1e5, 1e5)]
            whole = ase_to_synapse(a + b)
            split = ase_to_synapse(a) + ase_to_synapse(b; already_converted=a)
            @test isapprox(split, whole, rtol=1e-12)
            @test split <= whole * (1 + 1e-12)
        end
    end

    @testset "negative amounts throw" begin
        @test_throws DomainError ase_to_synapse(-1.0)
        @test_throws DomainError ase_to_synapse(1.0; already_converted=-1.0)
    end

    @testset "misconfigured saturation falls back to the base rate" begin
        saved = TOC_CONSTANTS[:synapse][:saturation_count]
        try
            TOC_CONSTANTS[:synapse][:saturation_count] = 0.0
            @test ase_to_synapse(2.0) == 2.0 * rate
        finally
            TOC_CONSTANTS[:synapse][:saturation_count] = saved
        end
    end
end
