# test/quadrinity_gov_test.jl — Quadrinity Government cluster real-dispatch tests
# Verifies: PROPOSAL, VOTE, DELEGATION, QUORUM, EXECUTION, VETO, AMENDMENT,
# IMPEACHMENT, ELECTION, TERM, CABINET, COMMITTEE, REFERENDUM, CONSTITUTION,
# LAW, COURT, VERDICT, APPEAL, PARDON, SANCTION now have real stateful
# VM-enforced logic, not decorative echoes/call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Quadrinity Government cluster (real dispatch)" begin

    @testset "is_critical includes all 20 Quadrinity Government opcodes" begin
        for op in [0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,
                   0x4a,0x4b,0x4c,0x4d,0x4e,0x4f,0x50,0x51,0x52,0x53]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "PROPOSAL: create, dedup, id required" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1", :title => "raise tithe")))
        @test r1["success"] == true
        @test haskey(vm.proposals, "p1")

        r2 = OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1", :title => "dup")))
        @test r2["success"] == false  # duplicate

        r3 = OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:title => "no id")))
        @test r3["success"] == false  # missing id
    end

    @testset "VOTE: requires known ballot, no double-vote, delegated voter blocked" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))

        bad = OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "ghost", :voter => "alice", :choice => "yes")))
        @test bad["success"] == false

        ok = OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "alice", :choice => "yes")))
        @test ok["success"] == true

        dup = OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "alice", :choice => "no")))
        @test dup["success"] == false

        OsoVM.execute_instruction(vm, Instr(0x42, Dict{Symbol,Any}(:delegator => "bob", :delegate => "alice")))
        blocked = OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "bob", :choice => "yes")))
        @test blocked["success"] == false
    end

    @testset "DELEGATION: no self-delegation, no double-delegation" begin
        vm = OsoVM.create_vm()
        selfd = OsoVM.execute_instruction(vm, Instr(0x42, Dict{Symbol,Any}(:delegator => "alice", :delegate => "alice")))
        @test selfd["success"] == false

        ok = OsoVM.execute_instruction(vm, Instr(0x42, Dict{Symbol,Any}(:delegator => "alice", :delegate => "bob")))
        @test ok["success"] == true

        dup = OsoVM.execute_instruction(vm, Instr(0x42, Dict{Symbol,Any}(:delegator => "alice", :delegate => "carol")))
        @test dup["success"] == false
    end

    @testset "QUORUM: reflects real vote count against council size" begin
        vm = OsoVM.create_vm(council = ["c1", "c2", "c3", "c4"])
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))
        r1 = OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p1", :threshold => 0.5)))
        @test r1["quorum_met"] == false  # 0 votes cast

        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c1", :choice => "yes")))
        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c2", :choice => "yes")))
        r2 = OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p1", :threshold => 0.5)))
        @test r2["quorum_met"] == true  # 2 of 4 council meets 0.5 threshold
    end

    @testset "EXECUTION: requires quorum + yes majority, blocks double-execute and vetoed" begin
        vm = OsoVM.create_vm(council = ["c1", "c2"])
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))

        premature = OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p1")))
        @test premature["success"] == false  # no quorum yet

        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c1", :choice => "yes")))
        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c2", :choice => "no")))
        OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p1", :threshold => 0.5)))
        tied = OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p1")))
        @test tied["success"] == false  # yes==no, no majority

        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p2")))
        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p2", :voter => "c1", :choice => "yes")))
        OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p2", :threshold => 0.5)))
        ok = OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p2")))
        @test ok["success"] == true

        again = OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p2")))
        @test again["success"] == false  # already executed
    end

    @testset "VETO: only final_signer, blocks re-execution" begin
        vm = OsoVM.create_vm(final_signer = "bino")
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))

        vm.current_sender = "not_bino"
        denied = OsoVM.execute_instruction(vm, Instr(0x45, Dict{Symbol,Any}(:proposal_id => "p1")))
        @test denied["success"] == false

        vm.current_sender = "bino"
        ok = OsoVM.execute_instruction(vm, Instr(0x45, Dict{Symbol,Any}(:proposal_id => "p1")))
        @test ok["success"] == true
        @test vm.proposals["p1"][:status] == :vetoed
    end

    @testset "AMENDMENT and LAW require an executed proposal" begin
        vm = OsoVM.create_vm(council = ["c1"])
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))

        badlaw = OsoVM.execute_instruction(vm, Instr(0x4e, Dict{Symbol,Any}(:id => "l1", :proposal_id => "p1", :text => "no tithe skip")))
        @test badlaw["success"] == false  # p1 not executed yet

        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c1", :choice => "yes")))
        OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p1", :threshold => 0.5)))
        OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p1")))

        lawok = OsoVM.execute_instruction(vm, Instr(0x4e, Dict{Symbol,Any}(:id => "l1", :proposal_id => "p1", :text => "no tithe skip")))
        @test lawok["success"] == true

        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p2")))  # not executed
        badamend = OsoVM.execute_instruction(vm, Instr(0x46, Dict{Symbol,Any}(:law_id => "l1", :proposal_id => "p2", :text => "amended text")))
        @test badamend["success"] == false

        amendok = OsoVM.execute_instruction(vm, Instr(0x46, Dict{Symbol,Any}(:law_id => "l1", :proposal_id => "p1", :text => "amended text")))
        @test amendok["success"] == true
        @test vm.laws["l1"][:text] == "amended text"
    end

    @testset "CABINET: only final_signer appoints, no duplicates; IMPEACHMENT requires executed proposal" begin
        vm = OsoVM.create_vm(final_signer = "bino", council = ["c1"])
        vm.current_sender = "not_bino"
        denied = OsoVM.execute_instruction(vm, Instr(0x4a, Dict{Symbol,Any}(:official => "alice", :role => "treasurer")))
        @test denied["success"] == false

        vm.current_sender = "bino"
        ok = OsoVM.execute_instruction(vm, Instr(0x4a, Dict{Symbol,Any}(:official => "alice", :role => "treasurer")))
        @test ok["success"] == true

        dup = OsoVM.execute_instruction(vm, Instr(0x4a, Dict{Symbol,Any}(:official => "alice", :role => "other")))
        @test dup["success"] == false

        vm.current_sender = "c1"
        OsoVM.execute_instruction(vm, Instr(0x40, Dict{Symbol,Any}(:id => "p1")))
        badimp = OsoVM.execute_instruction(vm, Instr(0x47, Dict{Symbol,Any}(:official => "alice", :proposal_id => "p1")))
        @test badimp["success"] == false  # not executed

        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "p1", :voter => "c1", :choice => "yes")))
        OsoVM.execute_instruction(vm, Instr(0x43, Dict{Symbol,Any}(:ballot_id => "p1", :threshold => 0.5)))
        OsoVM.execute_instruction(vm, Instr(0x44, Dict{Symbol,Any}(:proposal_id => "p1")))
        impok = OsoVM.execute_instruction(vm, Instr(0x47, Dict{Symbol,Any}(:official => "alice", :proposal_id => "p1")))
        @test impok["success"] == true
        @test !haskey(vm.cabinet, "alice")
    end

    @testset "ELECTION: open, vote, close, winner by real tally" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x48, Dict{Symbol,Any}(:id => "e1", :action => "open", :candidates => ["alice", "bob"])))

        closeearly = OsoVM.execute_instruction(vm, Instr(0x48, Dict{Symbol,Any}(:id => "e1", :action => "close")))
        @test closeearly["success"] == false  # no votes yet

        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "e1", :voter => "v1", :choice => "alice")))
        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "e1", :voter => "v2", :choice => "alice")))
        OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "e1", :voter => "v3", :choice => "bob")))
        closed = OsoVM.execute_instruction(vm, Instr(0x48, Dict{Symbol,Any}(:id => "e1", :action => "close")))
        @test closed["success"] == true
        @test closed["winner"] == "alice"

        recl = OsoVM.execute_instruction(vm, Instr(0x48, Dict{Symbol,Any}(:id => "e1", :action => "close")))
        @test recl["success"] == false  # already closed
    end

    @testset "TERM: end must be after start" begin
        vm = OsoVM.create_vm()
        bad = OsoVM.execute_instruction(vm, Instr(0x49, Dict{Symbol,Any}(:id => "t1", :official => "alice", :start => 100, :end => 50)))
        @test bad["success"] == false
        ok = OsoVM.execute_instruction(vm, Instr(0x49, Dict{Symbol,Any}(:id => "t1", :official => "alice", :start => 0, :end => 100)))
        @test ok["success"] == true
    end

    @testset "COMMITTEE: requires members" begin
        vm = OsoVM.create_vm()
        bad = OsoVM.execute_instruction(vm, Instr(0x4b, Dict{Symbol,Any}(:id => "c1", :members => String[])))
        @test bad["success"] == false
        ok = OsoVM.execute_instruction(vm, Instr(0x4b, Dict{Symbol,Any}(:id => "c1", :members => ["alice", "bob"])))
        @test ok["success"] == true
    end

    @testset "REFERENDUM: opens a votable ballot" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0x4c, Dict{Symbol,Any}(:id => "r1", :question => "raise tithe?")))
        v = OsoVM.execute_instruction(vm, Instr(0x41, Dict{Symbol,Any}(:ballot_id => "r1", :voter => "alice", :choice => "yes")))
        @test v["success"] == true
    end

    @testset "CONSTITUTION: set once, immutable" begin
        vm = OsoVM.create_vm()
        ok = OsoVM.execute_instruction(vm, Instr(0x4d, Dict{Symbol,Any}(:text => "founding doc")))
        @test ok["success"] == true
        again = OsoVM.execute_instruction(vm, Instr(0x4d, Dict{Symbol,Any}(:text => "rewrite")))
        @test again["success"] == false
    end

    @testset "COURT, VERDICT, APPEAL: verdict requires court, appeal once" begin
        vm = OsoVM.create_vm()
        badverdict = OsoVM.execute_instruction(vm, Instr(0x50, Dict{Symbol,Any}(:id => "v1", :court_id => "ghost", :ruling => "guilty")))
        @test badverdict["success"] == false

        OsoVM.execute_instruction(vm, Instr(0x4f, Dict{Symbol,Any}(:id => "court1", :judges => ["j1", "j2"])))
        okverdict = OsoVM.execute_instruction(vm, Instr(0x50, Dict{Symbol,Any}(:id => "v1", :court_id => "court1", :ruling => "guilty")))
        @test okverdict["success"] == true

        appeal1 = OsoVM.execute_instruction(vm, Instr(0x51, Dict{Symbol,Any}(:verdict_id => "v1", :reason => "new evidence")))
        @test appeal1["success"] == true
        appeal2 = OsoVM.execute_instruction(vm, Instr(0x51, Dict{Symbol,Any}(:verdict_id => "v1", :reason => "again")))
        @test appeal2["success"] == false  # not final anymore
    end

    @testset "SANCTION and PARDON: sanction requires verdict, pardon only final_signer" begin
        vm = OsoVM.create_vm(final_signer = "bino")
        OsoVM.execute_instruction(vm, Instr(0x4f, Dict{Symbol,Any}(:id => "court1", :judges => ["j1"])))
        OsoVM.execute_instruction(vm, Instr(0x50, Dict{Symbol,Any}(:id => "v1", :court_id => "court1", :ruling => "guilty")))

        badsanction = OsoVM.execute_instruction(vm, Instr(0x53, Dict{Symbol,Any}(:id => "s1", :verdict_id => "ghost", :target => "alice")))
        @test badsanction["success"] == false

        oksanction = OsoVM.execute_instruction(vm, Instr(0x53, Dict{Symbol,Any}(:id => "s1", :verdict_id => "v1", :target => "alice", :penalty => "fine")))
        @test oksanction["success"] == true

        vm.current_sender = "not_bino"
        denied = OsoVM.execute_instruction(vm, Instr(0x52, Dict{Symbol,Any}(:sanction_id => "s1")))
        @test denied["success"] == false

        vm.current_sender = "bino"
        ok = OsoVM.execute_instruction(vm, Instr(0x52, Dict{Symbol,Any}(:sanction_id => "s1")))
        @test ok["success"] == true
        again = OsoVM.execute_instruction(vm, Instr(0x52, Dict{Symbol,Any}(:sanction_id => "s1")))
        @test again["success"] == false  # not active anymore
    end

end
