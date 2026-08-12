# test/core_housekeeping_test.jl — real dispatch for the 5 remaining Core
# opcodes that predated this session's Expansion-cluster work: BIPON_SEED,
# BLOCKHASH, GASPRICE, COINBASE, DIFFICULTY.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Core opcode housekeeping (real dispatch)" begin

    @testset "is_critical includes the 5 fixed opcodes, not the 4 deferred ones" begin
        for op in [0x26, 0x36, 0x39, 0x3a, 0x3b]
            @test OsoVM.is_critical(op)
        end
        for op in [0x2c, 0x2d, 0x2e, 0x2f]  # CALL/DELEGATE/CREATE/SELFDESTRUCT -- deliberately still offloaded
            @test !OsoVM.is_critical(op)
        end
    end

    @testset "BLOCKHASH is deterministic given the same chain state" begin
        vm1 = OsoVM.create_vm()
        vm2 = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm1, Instr(0x36, Dict{Symbol,Any}()))
        r2 = OsoVM.execute_instruction(vm2, Instr(0x36, Dict{Symbol,Any}()))
        @test r1["success"] == true
        @test r1["blockhash"] == r2["blockhash"]  # same height+chain_id -> same hash
        vm1.block_height = 5
        r3 = OsoVM.execute_instruction(vm1, Instr(0x36, Dict{Symbol,Any}()))
        @test r3["blockhash"] != r1["blockhash"]  # different height -> different hash
    end

    @testset "GASPRICE reports the real 3.69% tithe rate" begin
        vm = OsoVM.create_vm()
        r = OsoVM.execute_instruction(vm, Instr(0x39, Dict{Symbol,Any}()))
        @test r["success"] == true
        @test r["gasprice"] == 0.0369
    end

    @testset "COINBASE returns the real final_signer" begin
        vm = OsoVM.create_vm(final_signer="bino_genesis_test")
        r = OsoVM.execute_instruction(vm, Instr(0x3a, Dict{Symbol,Any}()))
        @test r["success"] == true
        @test r["coinbase"] == "bino_genesis_test"
    end

    @testset "DIFFICULTY tracks real block_height, monotonically" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x3b, Dict{Symbol,Any}()))
        @test r1["difficulty"] == 0
        vm.block_height = 42
        r2 = OsoVM.execute_instruction(vm, Instr(0x3b, Dict{Symbol,Any}()))
        @test r2["difficulty"] == 42
    end

    @testset "BIPON_SEED derives deterministic child addresses, dedupes by path" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x26, Dict{Symbol,Any}(:seed => "", :path => "m/0")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x26, Dict{Symbol,Any}(:seed => "s1", :path => "m/0")))
        @test r2["success"] == true
        @test haskey(vm.ase_balance, r2["child_address"])

        # Same seed+path elsewhere must derive the identical address (determinism)
        vm2 = OsoVM.create_vm()
        r3 = OsoVM.execute_instruction(vm2, Instr(0x26, Dict{Symbol,Any}(:seed => "s1", :path => "m/0")))
        @test r3["child_address"] == r2["child_address"]

        # Re-deriving the same path on the same vm is rejected (dedupe)
        r4 = OsoVM.execute_instruction(vm, Instr(0x26, Dict{Symbol,Any}(:seed => "s1", :path => "m/0")))
        @test r4["success"] == false
    end

end
