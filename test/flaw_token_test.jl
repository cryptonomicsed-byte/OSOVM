# flaw_token_test.jl — proves the 1440 Genesis Flaw Token system:
# uniqueness, determinism, soulbound entitlement, and that no flaw token
# ever collides with the true spelling of Àṣẹ.

using Test

include(joinpath(@__DIR__, "..", "src", "flaw_tokens.jl"))
using .FlawTokens

include(joinpath(@__DIR__, "..", "src", "inheritance.jl"))
using .Inheritance

@testset "Genesis Flaw Tokens (1440)" begin

    @testset "generation is deterministic and total" begin
        # Same wallet_id always produces the same token.
        for id in (1, 42, 720, 1440)
            @test generate_flaw_token(id) == generate_flaw_token(id)
        end
        # Out-of-range wallet_id is rejected, not silently wrapped.
        @test_throws ArgumentError generate_flaw_token(0)
        @test_throws ArgumentError generate_flaw_token(1441)
    end

    @testset "all 1440 tokens are unique" begin
        tokens = mint_all_flaw_tokens()
        @test length(tokens) == 1440
        @test length(Set(tokens)) == 1440  # no collisions across the whole set
    end

    @testset "no flaw token ever equals the true spelling" begin
        tokens = mint_all_flaw_tokens()
        @test !(TRUE_SPELLING in tokens)
        @test all(t -> t != "Àṣẹ", tokens)
    end

    @testset "verify_flaw_token is the entitlement check" begin
        token_7 = generate_flaw_token(7)
        @test verify_flaw_token(7, token_7) == true
        @test verify_flaw_token(8, token_7) == false   # wrong wallet
        @test verify_flaw_token(7, "wrong") == false   # wrong token
        @test verify_flaw_token(0, token_7) == false   # out of range, fails closed
    end

    @testset "wallets are soulbound to their token at genesis" begin
        wallets = init_1440_wallets(1000)
        @test wallets[1].flaw_token == generate_flaw_token(1)
        @test wallets[1440].flaw_token == generate_flaw_token(1440)
        @test wallets[500].flaw_token != wallets[501].flaw_token
    end

    @testset "candidate_apply requires the correct flaw token" begin
        wallets = init_1440_wallets(0)
        has_inherited = Dict{String,Bool}()
        correct_token = wallets[5].flaw_token
        wrong_token = wallets[6].flaw_token

        # Wrong token for this wallet -> rejected, even with 7x7 badge.
        r_wrong = candidate_apply(5, "shrine_addr", wallets, has_inherited, 0, true, wrong_token)
        @test r_wrong[:success] == false
        @test r_wrong[:error] == "wrong flaw token for this wallet"

        # Correct token -> accepted.
        r_right = candidate_apply(5, "shrine_addr", wallets, has_inherited, 0, true, correct_token)
        @test r_right[:success] == true
        @test r_right[:event] == "CandidateApplied"
    end

end

println("🤍 1440 Genesis Flaw Tokens — soulbound, unique, verified.")
