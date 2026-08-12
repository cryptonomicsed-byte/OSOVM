# test/orisa_test.jl — Òrìṣà Spiritual Layer cluster real-dispatch tests
# Verifies: ORISA_OBATALA, ORISA_OGUN, ORISA_YEMOJA, ORISA_SANGO,
# ORISA_OSHUN, ORISA_OYA, ORISA_ESU, ORISA_ORUNMILA, IFA_DIVINATION, ODU,
# ESE, EBO, ASE_INVOCATION, ANCESTRAL_CALL, LIBATION, INITIATION,
# DIVINER, BABALAWO, IYALAWO, ILE, EGBE, ORI, EGUN, AJOGUN, IBEJI now have
# real stateful VM-enforced logic, not decorative fixed responses or
# call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Òrìṣà Spiritual Layer cluster (real dispatch)" begin

    @testset "is_critical includes all 25 Òrìṣà opcodes" begin
        for op in [0xa0,0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,
                   0xaa,0xab,0xac,0xad,0xae,0xaf,0xb0,0xb1,0xb2,0xb3,
                   0xb4,0xb5,0xb6,0xb7,0xb8]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "ORISA_* invocations are now real state, not a fixed literal" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xa0, Dict{Symbol,Any}(:id => "inv1")))
        @test r1["success"] == true
        @test r1["orisa"] == "Ọbàtálá"
        r2 = OsoVM.execute_instruction(vm, Instr(0xa0, Dict{Symbol,Any}(:id => "inv1")))
        @test r2["success"] == false  # dedup, unlike the old fixed-response version

        r3 = OsoVM.execute_instruction(vm, Instr(0xa6, Dict{Symbol,Any}(:id => "inv2")))
        @test r3["success"] == true
        @test r3["orisa"] == "Èṣù"
        @test haskey(vm.orisa_invocations, "inv1")
        @test haskey(vm.orisa_invocations, "inv2")
    end

    @testset "INITIATION -> DIVINER -> BABALAWO/IYALAWO lineage" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xb0, Dict{Symbol,Any}(:name => "seeker1")))
        @test r1["success"] == false  # not initiated yet
        r2 = OsoVM.execute_instruction(vm, Instr(0xaf, Dict{Symbol,Any}(:name => "seeker1")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0xaf, Dict{Symbol,Any}(:name => "seeker1")))
        @test r3["success"] == false  # already initiated
        r4 = OsoVM.execute_instruction(vm, Instr(0xb0, Dict{Symbol,Any}(:name => "seeker1")))
        @test r4["success"] == true

        r5 = OsoVM.execute_instruction(vm, Instr(0xb1, Dict{Symbol,Any}(:name => "not_diviner")))
        @test r5["success"] == false
        r6 = OsoVM.execute_instruction(vm, Instr(0xb1, Dict{Symbol,Any}(:name => "seeker1")))
        @test r6["success"] == true
        r7 = OsoVM.execute_instruction(vm, Instr(0xb2, Dict{Symbol,Any}(:name => "seeker1")))
        @test r7["success"] == true  # can hold both roles; only diviner status gates it
    end

    @testset "IFA_DIVINATION -> ODU -> ESE divination chain" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xa8, Dict{Symbol,Any}(:id => "d1", :diviner => "nobody")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xaf, Dict{Symbol,Any}(:name => "div1")))
        OsoVM.execute_instruction(vm, Instr(0xb0, Dict{Symbol,Any}(:name => "div1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0xa8, Dict{Symbol,Any}(:id => "d1", :diviner => "div1")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xa9, Dict{Symbol,Any}(:id => "odu1", :divination_id => "unknown")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xa9, Dict{Symbol,Any}(:id => "odu1", :divination_id => "d1")))
        @test r4["success"] == true

        r5 = OsoVM.execute_instruction(vm, Instr(0xaa, Dict{Symbol,Any}(:odu_id => "unknown")))
        @test r5["success"] == false
        r6 = OsoVM.execute_instruction(vm, Instr(0xaa, Dict{Symbol,Any}(:odu_id => "odu1", :proverb => "wisdom")))
        @test r6["success"] == true
    end

    @testset "EBO and ASE_INVOCATION require real prior sources" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xab, Dict{Symbol,Any}(:invocation_id => "unknown")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xa1, Dict{Symbol,Any}(:id => "inv1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0xab, Dict{Symbol,Any}(:invocation_id => "inv1", :offering => "kola nut")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xac, Dict{Symbol,Any}(:source_id => "unknown")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xac, Dict{Symbol,Any}(:source_id => "inv1")))
        @test r4["success"] == true
    end

    @testset "EGUN registration gates LIBATION" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xae, Dict{Symbol,Any}(:egun_id => "unknown")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xb6, Dict{Symbol,Any}(:id => "egun1", :name => "grandfather")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0xae, Dict{Symbol,Any}(:egun_id => "egun1")))
        @test r3["success"] == true
    end

    @testset "ORI requires initiation, ILE/EGBE/AJOGUN/IBEJI basic invariants" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xb5, Dict{Symbol,Any}(:person => "p1")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xaf, Dict{Symbol,Any}(:name => "p1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0xb5, Dict{Symbol,Any}(:person => "p1", :destiny => "healer")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xb3, Dict{Symbol,Any}(:id => "ile1", :keeper => "")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xb3, Dict{Symbol,Any}(:id => "ile1", :keeper => "k1")))
        @test r4["success"] == true

        r5 = OsoVM.execute_instruction(vm, Instr(0xb4, Dict{Symbol,Any}(:id => "egbe1", :members => String[])))
        @test r5["success"] == false
        r6 = OsoVM.execute_instruction(vm, Instr(0xb4, Dict{Symbol,Any}(:id => "egbe1", :members => ["a","b"])))
        @test r6["success"] == true

        r7 = OsoVM.execute_instruction(vm, Instr(0xb7, Dict{Symbol,Any}(:name => "malice1", :harm => "")))
        @test r7["success"] == false
        r8 = OsoVM.execute_instruction(vm, Instr(0xb7, Dict{Symbol,Any}(:name => "malice1", :harm => "sickness")))
        @test r8["success"] == true

        r9 = OsoVM.execute_instruction(vm, Instr(0xb8, Dict{Symbol,Any}(:id => "ib1", :twin1 => "a", :twin2 => "a")))
        @test r9["success"] == false  # not distinct
        r10 = OsoVM.execute_instruction(vm, Instr(0xb8, Dict{Symbol,Any}(:id => "ib1", :twin1 => "a", :twin2 => "b")))
        @test r10["success"] == true
    end

end
