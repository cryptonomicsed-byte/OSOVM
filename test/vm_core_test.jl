#!/usr/bin/env julia
# vm_core_test.jl — Deterministic VM Core Tests
# Verifies: determinism, rounding, genesis flaw, halt, stake/unstake conservation

include("../src/vm_core.jl")
using .VMCore
using Test

# Helper: build a single-tx block
function make_block(block_no::Int, timestamp::Int, sender::String,
                    instructions::Vector{VMCore.OsoCompiler.Instruction};
                    tx_id::String = "tx-1")
    tx = VMCore.Transaction(tx_id, sender, instructions, Dict{Symbol,Any}())
    VMCore.Block(block_no, timestamp, [tx], Dict{Symbol,Any}())
end

Instr = VMCore.OsoCompiler.Instruction

@testset "VMCore Hardened Tests" begin

    @testset "Determinism: same input → same output" begin
        s0 = initial_state()
        instrs = [Instr(0x11, Dict{Symbol,Any}(:ase => 5.0, :quorum => 5))]
        blk = make_block(1, 1000000, "alice", instrs)

        s1, r1 = apply_block(s0, blk)
        s2, r2 = apply_block(s0, blk)

        @test s1.balances == s2.balances
        @test s1.block_number == s2.block_number
        @test length(r1) == length(r2)
        @test r1[1].data == r2[1].data
    end

    @testset "IMPACT minting with rounding" begin
        s0 = initial_state()
        instrs = [Instr(0x11, Dict{Symbol,Any}(:ase => 5.0, :quorum => 5))]
        blk = make_block(1, 1000000, "alice", instrs)

        s1, receipts = apply_block(s0, blk)

        # gross = 1.0 * 5 * 5.0 = 25.0
        # tithe = 25.0 * 0.0369 = 0.9225
        # net   = 25.0 - 0.9225 = 24.0775
        @test s1.balances["alice"] ≈ 24.0775 atol=1e-6
        @test receipts[1].data[:gross] ≈ 25.0
        @test receipts[1].data[:tithe] ≈ 0.9225 atol=1e-6
        @test receipts[1].status == :ok
    end

    @testset "TRANSFER" begin
        s0 = initial_state()
        s0 = VMCore.copy_state(s0; balances = Dict("alice" => 100.0))

        instrs = [Instr(0x22, Dict{Symbol,Any}(:to => "bob", :amount => 30.0))]
        blk = make_block(1, 1000000, "alice", instrs)

        s1, receipts = apply_block(s0, blk)

        @test s1.balances["alice"] ≈ 70.0
        @test s1.balances["bob"] ≈ 30.0
        @test receipts[1].data[:success] == true
    end

    @testset "TRANSFER insufficient balance" begin
        s0 = initial_state()
        s0 = VMCore.copy_state(s0; balances = Dict("alice" => 10.0))

        instrs = [Instr(0x22, Dict{Symbol,Any}(:to => "bob", :amount => 50.0))]
        blk = make_block(1, 1000000, "alice", instrs)

        s1, receipts = apply_block(s0, blk)

        @test s1.balances["alice"] ≈ 10.0
        @test !haskey(s1.balances, "bob")
        @test receipts[1].data[:success] == false
    end

    @testset "STAKE and UNSTAKE conservation" begin
        s0 = initial_state()
        s0 = VMCore.copy_state(s0; balances = Dict("alice" => 100.0))

        # Stake 40
        instrs1 = [Instr(0x20, Dict{Symbol,Any}(:amount => 40.0))]
        blk1 = make_block(1, 1000000, "alice", instrs1)
        s1, _ = apply_block(s0, blk1)

        @test s1.balances["alice"] ≈ 60.0
        staked = s1.metadata[:staked]::Dict{String,Float64}
        @test staked["alice"] ≈ 40.0

        # Unstake 15
        instrs2 = [Instr(0x21, Dict{Symbol,Any}(:amount => 15.0))]
        blk2 = make_block(2, 1000100, "alice", instrs2)
        s2, _ = apply_block(s1, blk2)

        @test s2.balances["alice"] ≈ 75.0
        staked2 = s2.metadata[:staked]::Dict{String,Float64}
        @test staked2["alice"] ≈ 25.0

        # Total conserved: 75 + 25 = 100
        @test s2.balances["alice"] + staked2["alice"] ≈ 100.0
    end

    @testset "TITHE split rounding" begin
        s0 = initial_state()
        instrs = [Instr(0x27, Dict{Symbol,Any}(:amount => 100.0, :rate => 0.0369))]
        blk = make_block(1, 1000000, "alice", instrs)

        s1, receipts = apply_block(s0, blk)

        data = receipts[1].data
        @test data[:tithe] ≈ 3.69 atol=1e-6
        splits = data[:splits]
        @test splits["shrine"] ≈ 1.845 atol=1e-6
        @test splits["inheritance"] ≈ 0.9225 atol=1e-6
        @test splits["aio"] ≈ 0.5535 atol=1e-6
        @test splits["burn"] ≈ 0.369 atol=1e-6
    end

    @testset "GENESIS FLAW: block 0 mints, block 1 rejects" begin
        s0 = initial_state()

        # Block 1 (block_number=0+1=1, but genesis flaw checks args[:block_number])
        # We need block_number=1 for sequential, but genesis flaw needs block 0
        # The flaw checks args[:block_number] which comes from the block
        instrs_genesis = [Instr(0x2b, Dict{Symbol,Any}(:token => "ASHE", :amount => 1.0))]
        tx = VMCore.Transaction("tx-gen", "genesis", instrs_genesis, Dict{Symbol,Any}())
        blk0 = VMCore.Block(1, 0, [tx], Dict{Symbol,Any}())

        s1, r1 = apply_block(s0, blk0)
        # block.block_number is 1, so genesis flaw should deny (block_num != 0)
        @test r1[1].data[:genesis] == false

        # To test block 0 minting, start state at block_number=-1... 
        # or test the handler directly
        s_pre = VMCore.copy_state(s0; block_number = -1)
        blk_zero = VMCore.Block(0, 0, [tx], Dict{Symbol,Any}())
        s_post, r_zero = apply_block(s_pre, blk_zero)

        @test r_zero[1].data[:genesis] == true
        @test r_zero[1].data[:token_minted] == "Àṣẹ"
        @test s_post.balances["genesis"] ≈ 1.0
        @test s_post.metadata[:genesis_flaw_used] == true

        # Second attempt on block 1 — flaw already used
        instrs2 = [Instr(0x2b, Dict{Symbol,Any}(:token => "ASHE", :amount => 1.0))]
        tx2 = VMCore.Transaction("tx-gen2", "genesis", instrs2, Dict{Symbol,Any}())
        blk1 = VMCore.Block(1, 100, [tx2], Dict{Symbol,Any}())
        s_post2, r_post = apply_block(s_post, blk1)

        @test r_post[1].data[:genesis] == false
    end

    @testset "HALT stops execution" begin
        s0 = initial_state()
        s0 = VMCore.copy_state(s0; balances = Dict("alice" => 100.0))

        instrs = [
            Instr(0x00, Dict{Symbol,Any}()),                                    # HALT
            Instr(0x22, Dict{Symbol,Any}(:to => "bob", :amount => 50.0)),       # TRANSFER (should not run)
        ]
        blk = make_block(1, 1000000, "alice", instrs)
        s1, receipts = apply_block(s0, blk)

        @test length(receipts) == 1          # only HALT receipt
        @test receipts[1].status == :halted
        @test s1.balances["alice"] ≈ 100.0   # no transfer happened
        @test !haskey(s1.balances, "bob")
    end

    @testset "SABBATH freeze (Saturday)" begin
        s0 = initial_state()
        # Thursday Jan 1 1970 = day 0, Saturday = day 2 → ts = 2*86400 = 172800
        saturday_ts = 172800
        instrs = [Instr(0x27, Dict{Symbol,Any}(:amount => 100.0))]

        # We don't have a SABBATH opcode in registry, but test the helper
        @test VMCore.is_sabbath(saturday_ts) == true
        @test VMCore.is_sabbath(saturday_ts + 86400) == false  # Sunday
    end

    @testset "Non-sequential block rejected" begin
        s0 = initial_state()
        blk = VMCore.Block(5, 1000, VMCore.Transaction[], Dict{Symbol,Any}())
        @test_throws ArgumentError apply_block(s0, blk)
    end

    @testset "BALANCE read-only" begin
        s0 = initial_state()
        s0 = VMCore.copy_state(s0; balances = Dict("alice" => 42.123456))

        instrs = [Instr(0x23, Dict{Symbol,Any}(:wallet => "alice"))]
        blk = make_block(1, 1000000, "alice", instrs)
        s1, receipts = apply_block(s0, blk)

        @test receipts[1].data[:balance] ≈ 42.123456
        @test s1.balances == s0.balances  # no mutation
    end

    @testset "Unknown opcode returns error receipt" begin
        s0 = initial_state()
        instrs = [Instr(0xFF, Dict{Symbol,Any}())]
        blk = make_block(1, 1000000, "alice", instrs)
        s1, receipts = apply_block(s0, blk)

        @test receipts[1].status == :error
        @test receipts[1].data[:status] == "unknown_opcode"
    end

    @testset "Receipt IDs are deterministic" begin
        id1 = VMCore.make_receipt_id(1, 2, 3, 0x11)
        id2 = VMCore.make_receipt_id(1, 2, 3, 0x11)
        @test id1 == id2
        @test id1 == "b1-t2-i3-0x11"
    end

end

println("\n✅ All VMCore hardened tests passed. Àṣẹ. 🤍")
