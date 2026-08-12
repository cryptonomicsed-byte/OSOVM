# test/hospital_test.jl — SimaaS Hospital cluster real-dispatch tests
# Verifies: PATIENT, DIAGNOSIS, TREATMENT, PRESCRIPTION, SURGERY, THERAPY,
# VITALS, ADMISSION, DISCHARGE, EMERGENCY, TRIAGE, WARD, ICU, MORGUE,
# AUTOPSY, QUARANTINE, VACCINE, PANDEMIC, RECOVERY, RELAPSE now have real
# stateful VM-enforced logic, not decorative echoes/call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "SimaaS Hospital cluster (real dispatch)" begin

    @testset "is_critical includes all 20 Hospital opcodes" begin
        for op in [0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
                   0x8a,0x8b,0x8c,0x8d,0x8e,0x8f,0x90,0x91,0x92,0x93]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "PATIENT register + dedup" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1", :name => "Ada")))
        @test r1["success"] == true
        r2 = OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        @test r2["success"] == false
    end

    @testset "DIAGNOSIS -> TREATMENT chain requires real predecessors" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x81, Dict{Symbol,Any}(:patient_id => "unknown", :condition => "flu")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0x81, Dict{Symbol,Any}(:id => "d1", :patient_id => "p1", :condition => "flu")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x82, Dict{Symbol,Any}(:diagnosis_id => "unknown")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x82, Dict{Symbol,Any}(:diagnosis_id => "d1", :plan => "rest")))
        @test r4["success"] == true
    end

    @testset "PRESCRIPTION and SURGERY require known patient" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x83, Dict{Symbol,Any}(:patient_id => "unknown", :medicine => "m")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0x83, Dict{Symbol,Any}(:patient_id => "p1", :medicine => "aspirin")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x84, Dict{Symbol,Any}(:patient_id => "p1", :surgeon => "")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x84, Dict{Symbol,Any}(:patient_id => "p1", :surgeon => "dr_x")))
        @test r4["success"] == true
    end

    @testset "VITALS accumulates readings for a known patient" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x86, Dict{Symbol,Any}(:patient_id => "unknown")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        OsoVM.execute_instruction(vm, Instr(0x86, Dict{Symbol,Any}(:patient_id => "p1", :hr => 72)))
        r2 = OsoVM.execute_instruction(vm, Instr(0x86, Dict{Symbol,Any}(:patient_id => "p1", :hr => 75)))
        @test r2["success"] == true
        @test r2["readings"] == 2
    end

    @testset "WARD capacity + ADMISSION/DISCHARGE lifecycle" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r1 = OsoVM.execute_instruction(vm, Instr(0x87, Dict{Symbol,Any}(:patient_id => "p1", :ward_id => "unknown")))
        @test r1["success"] == false

        r2 = OsoVM.execute_instruction(vm, Instr(0x8b, Dict{Symbol,Any}(:id => "w1", :capacity => 1)))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0x87, Dict{Symbol,Any}(:patient_id => "p1", :ward_id => "w1")))
        @test r3["success"] == true
        r4 = OsoVM.execute_instruction(vm, Instr(0x87, Dict{Symbol,Any}(:patient_id => "p1", :ward_id => "w1")))
        @test r4["success"] == false  # already admitted

        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p2")))
        r5 = OsoVM.execute_instruction(vm, Instr(0x87, Dict{Symbol,Any}(:patient_id => "p2", :ward_id => "w1")))
        @test r5["success"] == false  # ward at capacity

        r6 = OsoVM.execute_instruction(vm, Instr(0x88, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r6["success"] == true
        @test isempty(vm.wards["w1"][:occupants])
        r7 = OsoVM.execute_instruction(vm, Instr(0x88, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r7["success"] == false  # not admitted anymore

        r8 = OsoVM.execute_instruction(vm, Instr(0x87, Dict{Symbol,Any}(:patient_id => "p2", :ward_id => "w1")))
        @test r8["success"] == true  # freed capacity after discharge
    end

    @testset "ICU creation mirrors WARD capacity rules" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x8c, Dict{Symbol,Any}(:id => "icu1", :capacity => 0)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x8c, Dict{Symbol,Any}(:id => "icu1", :capacity => 2)))
        @test r2["success"] == true
    end

    @testset "EMERGENCY and TRIAGE require known patient" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x89, Dict{Symbol,Any}(:patient_id => "unknown")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0x89, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x8a, Dict{Symbol,Any}(:patient_id => "p1", :priority => 9)))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x8a, Dict{Symbol,Any}(:patient_id => "p1", :priority => 1)))
        @test r4["success"] == true
    end

    @testset "MORGUE -> AUTOPSY chain" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x8e, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r1["success"] == false  # not in morgue
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0x8d, Dict{Symbol,Any}(:patient_id => "p1", :cause => "unknown")))
        @test r2["success"] == true
        @test vm.patients["p1"][:status] == :deceased
        r3 = OsoVM.execute_instruction(vm, Instr(0x8d, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r3["success"] == false  # already in morgue
        r4 = OsoVM.execute_instruction(vm, Instr(0x8e, Dict{Symbol,Any}(:patient_id => "p1", :findings => "cardiac")))
        @test r4["success"] == true
    end

    @testset "QUARANTINE and VACCINE (no double-vaccination)" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r1 = OsoVM.execute_instruction(vm, Instr(0x8f, Dict{Symbol,Any}(:patient_id => "p1", :reason => "exposure")))
        @test r1["success"] == true

        r2 = OsoVM.execute_instruction(vm, Instr(0x90, Dict{Symbol,Any}(:patient_id => "p1", :vaccine => "flu-shot")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0x90, Dict{Symbol,Any}(:patient_id => "p1", :vaccine => "flu-shot")))
        @test r3["success"] == false
    end

    @testset "PANDEMIC declare + dedupe" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x91, Dict{Symbol,Any}(:id => "outbreak1", :name => "Flu-X")))
        @test r1["success"] == true
        r2 = OsoVM.execute_instruction(vm, Instr(0x91, Dict{Symbol,Any}(:id => "outbreak1")))
        @test r2["success"] == false
    end

    @testset "RECOVERY -> RELAPSE requires prior recovery" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x80, Dict{Symbol,Any}(:id => "p1")))
        r1 = OsoVM.execute_instruction(vm, Instr(0x93, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r1["success"] == false  # no recovery yet
        r2 = OsoVM.execute_instruction(vm, Instr(0x92, Dict{Symbol,Any}(:patient_id => "p1", :condition => "flu")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0x93, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r3["success"] == true
        r4 = OsoVM.execute_instruction(vm, Instr(0x93, Dict{Symbol,Any}(:patient_id => "p1")))
        @test r4["success"] == false  # recovery was consumed by the relapse
    end

end
