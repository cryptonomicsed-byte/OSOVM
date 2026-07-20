include("../src/merkle.jl")
using .Merkle
using Test, SHA

@testset "Merkle" begin
    @testset "root determinism" begin
        leaves = [sha256(Vector{UInt8}("leaf-$i")) for i in 1:7]
        @test merkle_root(leaves) == merkle_root(leaves)
    end

    @testset "empty leaves gets a defined, non-crashing root" begin
        @test length(merkle_root(Vector{Vector{UInt8}}())) == 32
    end

    @testset "every leaf's path verifies against the root, for every leaf count 1..13" begin
        for n in 1:13
            leaves = [sha256(Vector{UInt8}("leaf-$i")) for i in 1:n]
            root = merkle_root(leaves)
            for idx in 1:n
                path = merkle_path(leaves, idx)
                @test verify_merkle_path(leaves[idx], path, root)
            end
        end
    end

    @testset "tampered leaf fails verification" begin
        leaves = [sha256(Vector{UInt8}("leaf-$i")) for i in 1:5]
        root = merkle_root(leaves)
        path = merkle_path(leaves, 3)
        wrong_leaf = sha256(Vector{UInt8}("tampered"))
        @test !verify_merkle_path(wrong_leaf, path, root)
    end

    @testset "tampered path step fails verification" begin
        leaves = [sha256(Vector{UInt8}("leaf-$i")) for i in 1:6]
        root = merkle_root(leaves)
        path = merkle_path(leaves, 4)
        tampered_path = copy(path)
        if !isempty(tampered_path)
            tampered_path[1] = Merkle.PathStep(sha256(Vector{UInt8}("evil")), tampered_path[1].side)
        end
        @test !verify_merkle_path(leaves[4], tampered_path, root)
    end

    @testset "out-of-range index errors, not silently wrong" begin
        leaves = [sha256(Vector{UInt8}("x"))]
        @test_throws ErrorException merkle_path(leaves, 0)
        @test_throws ErrorException merkle_path(leaves, 2)
    end
end

println("Merkle tests complete.")
