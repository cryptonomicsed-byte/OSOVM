include("../src/checkpoint_export.jl")
using .CheckpointExport
using Test, SHA

@testset "CheckpointExport" begin
    @testset "canonical bytes are independent of Dict key insertion order" begin
        cp1 = Checkpoint(1, Dict("pos" => [1.0, 2.0, 3.0], "vel" => 0.5),
                          Dict("f1" => 0.95, "energy" => 1.2345678901234567))
        cp2 = Checkpoint(1, Dict("vel" => 0.5, "pos" => [1.0, 2.0, 3.0]),
                          Dict("energy" => 1.2345678901234567, "f1" => 0.95))
        @test canonical_checkpoint_bytes(cp1) == canonical_checkpoint_bytes(cp2)
    end

    @testset "checkpoint_leaves sorts by step, not insertion order" begin
        cpA = Checkpoint(2, Dict("x" => 1.0), Dict("m" => 1.0))
        cpB = Checkpoint(1, Dict("x" => 2.0), Dict("m" => 2.0))
        @test checkpoint_leaves([cpA, cpB]) == checkpoint_leaves([cpB, cpA])
    end

    @testset "full float precision preserved, not rounded" begin
        cp = Checkpoint(1, Dict("x" => 0.1 + 0.2), Dict("m" => 1.0))  # classic float-fuzz value
        s = String(canonical_checkpoint_bytes(cp))
        @test occursin("0.30000000000000004", s)  # must not silently round to 0.3
    end

    @testset "checkpoint_leaves produces real SHA-256 digests, deterministic" begin
        cps = [Checkpoint(i, Dict("v" => Float64(i)), Dict("m" => Float64(i) * 2)) for i in 1:5]
        l1 = checkpoint_leaves(cps)
        l2 = checkpoint_leaves(cps)
        @test l1 == l2
        @test all(length(l) == 32 for l in l1)
        @test length(unique(l1)) == 5  # distinct checkpoints produce distinct leaves
    end
end

println("CheckpointExport tests complete.")
