# test/universal_work_test.jl — Universal Work cluster real-dispatch tests
# Verifies: PROJECT, CASTING, JOB, SHIFT, MILESTONE, DELIVERABLE, TIMESHEET,
# INVOICE, CONTRACT, DISPUTE now have real stateful VM-enforced logic,
# not decorative echoes/stubs.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Universal Work cluster (real dispatch)" begin

    @testset "is_critical includes all 10 Universal Work opcodes" begin
        for op in [0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x24, 0x25]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "PROJECT: create, dedup, negative budget rejected" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :sector => "sim", :budget => 100.0)))
        @test r1["success"] == true
        @test haskey(vm.projects, "p1")

        r2 = OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 1.0)))
        @test r2["success"] == false  # duplicate

        r3 = OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p2", :budget => -5.0)))
        @test r3["success"] == false  # negative budget
    end

    @testset "CASTING: requires existing project, no double-cast" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))

        bad = OsoVM.execute_instruction(vm, Instr(0x17, Dict{Symbol,Any}(:project_id => "nope", :wallet => "alice", :role => "lead")))
        @test bad["success"] == false

        ok = OsoVM.execute_instruction(vm, Instr(0x17, Dict{Symbol,Any}(:project_id => "p1", :wallet => "alice", :role => "lead")))
        @test ok["success"] == true

        dup = OsoVM.execute_instruction(vm, Instr(0x17, Dict{Symbol,Any}(:project_id => "p1", :wallet => "alice", :role => "lead")))
        @test dup["success"] == false
    end

    @testset "JOB: requires open project" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))

        r = OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j1", :project_id => "p1", :reward => 5.0)))
        @test r["success"] == true
        @test vm.jobs["j1"][:status] == :open

        bad = OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j2", :project_id => "ghost", :reward => 5.0)))
        @test bad["success"] == false
    end

    @testset "SHIFT -> TIMESHEET -> INVOICE full chain, real hours math" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))
        OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j1", :project_id => "p1", :reward => 5.0)))

        s1 = OsoVM.execute_instruction(vm, Instr(0x1a, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob", :start => 0, :end => 3600)))
        @test s1["success"] == true
        @test s1["hours"] == 1.0

        bad_shift = OsoVM.execute_instruction(vm, Instr(0x1a, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob", :start => 100, :end => 50)))
        @test bad_shift["success"] == false  # end before start

        s2 = OsoVM.execute_instruction(vm, Instr(0x1a, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob", :start => 3600, :end => 10800)))
        @test s2["hours"] == 2.0

        ts = OsoVM.execute_instruction(vm, Instr(0x1d, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob")))
        @test ts["success"] == true
        @test ts["hours"] == 3.0  # 1.0 + 2.0 aggregated from real shifts

        no_shifts = OsoVM.execute_instruction(vm, Instr(0x1d, Dict{Symbol,Any}(:job_id => "j1", :worker => "nobody")))
        @test no_shifts["success"] == false

        timesheet_id = ts["timesheet"]
        inv = OsoVM.execute_instruction(vm, Instr(0x1e, Dict{Symbol,Any}(:timesheet_id => timesheet_id, :rate => 10.0)))
        @test inv["success"] == true
        @test inv["amount"] == 30.0  # 3.0 hours * 10.0 rate, derived not asserted

        bad_inv = OsoVM.execute_instruction(vm, Instr(0x1e, Dict{Symbol,Any}(:timesheet_id => "ghost", :rate => 10.0)))
        @test bad_inv["success"] == false
    end

    @testset "MILESTONE: monotonic 0..100, closes project at 100" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))

        m1 = OsoVM.execute_instruction(vm, Instr(0x1b, Dict{Symbol,Any}(:project_id => "p1", :percent => 50.0)))
        @test m1["success"] == true

        regress = OsoVM.execute_instruction(vm, Instr(0x1b, Dict{Symbol,Any}(:project_id => "p1", :percent => 30.0)))
        @test regress["success"] == false  # cannot regress

        m2 = OsoVM.execute_instruction(vm, Instr(0x1b, Dict{Symbol,Any}(:project_id => "p1", :percent => 100.0)))
        @test m2["success"] == true
        @test vm.projects["p1"][:status] == :closed

        # New job cannot open against a closed project
        j = OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j-late", :project_id => "p1", :reward => 1.0)))
        @test j["success"] == false
    end

    @testset "DELIVERABLE: requires real job, marks it delivered" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))
        OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j1", :project_id => "p1", :reward => 5.0)))

        d = OsoVM.execute_instruction(vm, Instr(0x1c, Dict{Symbol,Any}(:job_id => "j1", :hash => "0xdead")))
        @test d["success"] == true
        @test vm.jobs["j1"][:status] == :delivered

        bad = OsoVM.execute_instruction(vm, Instr(0x1c, Dict{Symbol,Any}(:job_id => "ghost", :hash => "0xdead")))
        @test bad["success"] == false
    end

    @testset "CONTRACT + DISPUTE: dispute freezes the real invoice, not a stub" begin
        vm = OsoVM.create_vm()
        c = OsoVM.execute_instruction(vm, Instr(0x24, Dict{Symbol,Any}(:party_b => "carol", :terms => "50/50")))
        @test c["success"] == true
        contract_id = c["contract"]

        dup = OsoVM.execute_instruction(vm, Instr(0x24, Dict{Symbol,Any}(:id => contract_id, :party_b => "carol")))
        @test dup["success"] == false

        d = OsoVM.execute_instruction(vm, Instr(0x25, Dict{Symbol,Any}(:target_type => "contract", :target_id => contract_id, :reason => "scope creep")))
        @test d["success"] == true
        @test vm.contracts[contract_id][:status] == :disputed

        bad_target = OsoVM.execute_instruction(vm, Instr(0x25, Dict{Symbol,Any}(:target_type => "contract", :target_id => "ghost")))
        @test bad_target["success"] == false

        # Dispute against a real invoice actually flips its disputed flag
        OsoVM.execute_instruction(vm, Instr(0x18, Dict{Symbol,Any}(:id => "p1", :budget => 10.0)))
        OsoVM.execute_instruction(vm, Instr(0x19, Dict{Symbol,Any}(:id => "j1", :project_id => "p1", :reward => 5.0)))
        OsoVM.execute_instruction(vm, Instr(0x1a, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob", :start => 0, :end => 3600)))
        ts = OsoVM.execute_instruction(vm, Instr(0x1d, Dict{Symbol,Any}(:job_id => "j1", :worker => "bob")))
        inv = OsoVM.execute_instruction(vm, Instr(0x1e, Dict{Symbol,Any}(:timesheet_id => ts["timesheet"], :rate => 10.0)))
        invoice_id = inv["invoice"]
        @test vm.invoices[invoice_id][:disputed] == false

        OsoVM.execute_instruction(vm, Instr(0x25, Dict{Symbol,Any}(:target_type => "invoice", :target_id => invoice_id, :reason => "hours inflated")))
        @test vm.invoices[invoice_id][:disputed] == true
    end
end
