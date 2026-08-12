# test/extended_ops_test.jl — Extended Operations cluster real-dispatch tests
# Verifies: BATCH, SCHEDULE, NOTIFY, LOG, ARCHIVE, BACKUP, RESTORE,
# MIGRATE, ROLLBACK, CHECKPOINT now have real stateful VM-enforced logic,
# not decorative echoes/call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Extended Operations cluster (real dispatch)" begin

    @testset "is_critical includes all 10 Extended Operations opcodes" begin
        for op in [0xe0,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "BATCH requires non-empty operations, dedupe by id" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe0, Dict{Symbol,Any}(:id => "b1", :operations => String[])))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe0, Dict{Symbol,Any}(:id => "b1", :operations => ["op1", "op2"])))
        @test r2["success"] == true
        @test r2["count"] == 2
        r3 = OsoVM.execute_instruction(vm, Instr(0xe0, Dict{Symbol,Any}(:id => "b1", :operations => ["op3"])))
        @test r3["success"] == false
    end

    @testset "SCHEDULE requires future trigger_time" begin
        vm = OsoVM.create_vm()
        vm.block_time = 100
        r1 = OsoVM.execute_instruction(vm, Instr(0xe1, Dict{Symbol,Any}(:id => "s1", :target => "t1", :trigger_time => 50)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe1, Dict{Symbol,Any}(:id => "s1", :target => "t1", :trigger_time => 200)))
        @test r2["success"] == true
    end

    @testset "NOTIFY and LOG basic invariants" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe2, Dict{Symbol,Any}(:recipient => "", :message => "hi")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe2, Dict{Symbol,Any}(:recipient => "r1", :message => "hi")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xe3, Dict{Symbol,Any}(:message => "")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xe3, Dict{Symbol,Any}(:message => "event happened")))
        @test r4["success"] == true
        @test r4["count"] == 1
        r5 = OsoVM.execute_instruction(vm, Instr(0xe3, Dict{Symbol,Any}(:message => "another event")))
        @test r5["count"] == 2
    end

    @testset "ARCHIVE requires a named source" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe4, Dict{Symbol,Any}(:source_id => "")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe4, Dict{Symbol,Any}(:source_id => "some-record")))
        @test r2["success"] == true
    end

    @testset "BACKUP -> RESTORE chain" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe6, Dict{Symbol,Any}(:backup_id => "unknown")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe5, Dict{Symbol,Any}(:id => "bk1", :snapshot_of => "")))
        @test r2["success"] == false
        r3 = OsoVM.execute_instruction(vm, Instr(0xe5, Dict{Symbol,Any}(:id => "bk1", :snapshot_of => "vm-state")))
        @test r3["success"] == true
        r4 = OsoVM.execute_instruction(vm, Instr(0xe6, Dict{Symbol,Any}(:backup_id => "bk1")))
        @test r4["success"] == true
    end

    @testset "MIGRATE requires distinct from/to" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe7, Dict{Symbol,Any}(:from => "host1", :to => "host1")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe7, Dict{Symbol,Any}(:from => "hostinger", :to => "contabo")))
        @test r2["success"] == true
    end

    @testset "CHECKPOINT -> ROLLBACK chain" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xe8, Dict{Symbol,Any}(:checkpoint_id => "unknown")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xe9, Dict{Symbol,Any}(:id => "cp1")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0xe9, Dict{Symbol,Any}(:id => "cp1")))
        @test r3["success"] == false  # dedupe
        r4 = OsoVM.execute_instruction(vm, Instr(0xe8, Dict{Symbol,Any}(:checkpoint_id => "cp1")))
        @test r4["success"] == true
    end

end
