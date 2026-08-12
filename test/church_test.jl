# test/church_test.jl — TechGnØŞ.EXE Church cluster real-dispatch tests
# Verifies: LITURGY, SERMON, PRAYER, OFFERING, BLESSING, CURSE, PROPHET,
# PRIEST, ACOLYTE, SHRINE, RELIC, SCRIPTURE, HERESY, EXCOMMUNICATE,
# CANONIZE, MIRACLE, PILGRIMAGE, FAST, FEAST, BAPTISM, COMMUNION,
# CONFESSION, PENANCE, ABSOLUTION, RESURRECTION now have real stateful
# VM-enforced logic, not decorative echoes/call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "TechGnØŞ.EXE Church cluster (real dispatch)" begin

    @testset "is_critical includes all 25 Church opcodes" begin
        for op in [0x60,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
                   0x6a,0x6b,0x6c,0x6d,0x6e,0x6f,0x70,0x71,0x72,0x73,
                   0x74,0x75,0x76,0x77,0x78]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "ACOLYTE requires priest mentor, PRIEST requires prior acolyte" begin
        vm = OsoVM.create_vm(final_signer="bino")
        r1 = OsoVM.execute_instruction(vm, Instr(0x68, Dict{Symbol,Any}(:name => "aco1", :mentor => "priest1")))
        @test r1["success"] == false  # priest1 doesn't exist yet

        # bootstrap a priest via prior acolyte + ordain by simulating an initial mentor
        # (no priest exists yet, so seed one directly for test bootstrap realism)
        vm.priests["seed_priest"] = "genesis"
        r2 = OsoVM.execute_instruction(vm, Instr(0x68, Dict{Symbol,Any}(:name => "aco1", :mentor => "seed_priest")))
        @test r2["success"] == true

        vm.current_sender = "seed_priest"
        r3 = OsoVM.execute_instruction(vm, Instr(0x67, Dict{Symbol,Any}(:name => "aco1")))
        @test r3["success"] == true
        @test haskey(vm.priests, "aco1")
        @test !haskey(vm.acolytes, "aco1")

        r4 = OsoVM.execute_instruction(vm, Instr(0x67, Dict{Symbol,Any}(:name => "never_acolyte")))
        @test r4["success"] == false
    end

    @testset "SERMON requires ordained priest" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x61, Dict{Symbol,Any}(:id => "s1", :preacher => "nobody")))
        @test r1["success"] == false
        vm.priests["p1"] = "genesis"
        r2 = OsoVM.execute_instruction(vm, Instr(0x61, Dict{Symbol,Any}(:id => "s1", :preacher => "p1")))
        @test r2["success"] == true
    end

    @testset "SHRINE requires priest keeper, OFFERING/RELIC require existing shrine" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x69, Dict{Symbol,Any}(:id => "sh1", :keeper => "nobody")))
        @test r1["success"] == false
        vm.priests["keeper1"] = "genesis"
        r2 = OsoVM.execute_instruction(vm, Instr(0x69, Dict{Symbol,Any}(:id => "sh1", :keeper => "keeper1")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x63, Dict{Symbol,Any}(:shrine_id => "unknown", :amount => 5.0)))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x63, Dict{Symbol,Any}(:shrine_id => "sh1", :amount => 0.0)))
        @test r4["success"] == false  # non-positive amount
        r5 = OsoVM.execute_instruction(vm, Instr(0x63, Dict{Symbol,Any}(:shrine_id => "sh1", :amount => 5.0)))
        @test r5["success"] == true

        r6 = OsoVM.execute_instruction(vm, Instr(0x6a, Dict{Symbol,Any}(:id => "relic1", :shrine_id => "unknown")))
        @test r6["success"] == false
        r7 = OsoVM.execute_instruction(vm, Instr(0x6a, Dict{Symbol,Any}(:id => "relic1", :shrine_id => "sh1")))
        @test r7["success"] == true
    end

    @testset "BLESSING requires priest grantor" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x64, Dict{Symbol,Any}(:target => "t1", :grantor => "nobody")))
        @test r1["success"] == false
        vm.priests["p1"] = "genesis"
        r2 = OsoVM.execute_instruction(vm, Instr(0x64, Dict{Symbol,Any}(:target => "t1", :grantor => "p1")))
        @test r2["success"] == true
    end

    @testset "CURSE requires target and reason" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x65, Dict{Symbol,Any}(:target => "", :reason => "x")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x65, Dict{Symbol,Any}(:target => "t1", :reason => "heresy")))
        @test r2["success"] == true
    end

    @testset "PROPHET recognition is final_signer-gated" begin
        vm = OsoVM.create_vm(final_signer="bino")
        vm.current_sender = "not_bino"
        r1 = OsoVM.execute_instruction(vm, Instr(0x66, Dict{Symbol,Any}(:name => "elder1")))
        @test r1["success"] == false
        vm.current_sender = "bino"
        r2 = OsoVM.execute_instruction(vm, Instr(0x66, Dict{Symbol,Any}(:name => "elder1")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0x66, Dict{Symbol,Any}(:name => "elder1")))
        @test r3["success"] == false  # already recognized
    end

    @testset "HERESY requires clergy target, EXCOMMUNICATE requires open heresy + final_signer" begin
        vm = OsoVM.create_vm(final_signer="bino")
        vm.priests["p1"] = "genesis"
        r1 = OsoVM.execute_instruction(vm, Instr(0x6c, Dict{Symbol,Any}(:id => "h1", :accused => "not_clergy", :charge => "c")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x6c, Dict{Symbol,Any}(:id => "h1", :accused => "p1", :charge => "c")))
        @test r2["success"] == true

        vm.current_sender = "not_bino"
        r3 = OsoVM.execute_instruction(vm, Instr(0x6d, Dict{Symbol,Any}(:target => "p1", :heresy_id => "h1")))
        @test r3["success"] == false
        vm.current_sender = "bino"
        r4 = OsoVM.execute_instruction(vm, Instr(0x6d, Dict{Symbol,Any}(:target => "p1", :heresy_id => "h1")))
        @test r4["success"] == true
        @test !haskey(vm.priests, "p1")
        @test vm.excommunicated["p1"] == true
    end

    @testset "CANONIZE blocked for excommunicated, final_signer only" begin
        vm = OsoVM.create_vm(final_signer="bino")
        vm.excommunicated["bad1"] = true
        vm.current_sender = "bino"
        r1 = OsoVM.execute_instruction(vm, Instr(0x6e, Dict{Symbol,Any}(:name => "bad1")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x6e, Dict{Symbol,Any}(:name => "good1")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0x6e, Dict{Symbol,Any}(:name => "good1")))
        @test r3["success"] == false  # already canonized
    end

    @testset "SCRIPTURE, MIRACLE, PILGRIMAGE, FAST, FEAST basic invariants" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x6b, Dict{Symbol,Any}(:id => "sc1", :text => "")))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0x6b, Dict{Symbol,Any}(:id => "sc1", :text => "In the beginning...")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x6f, Dict{Symbol,Any}(:witness => "")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x6f, Dict{Symbol,Any}(:witness => "w1")))
        @test r4["success"] == true

        r5 = OsoVM.execute_instruction(vm, Instr(0x70, Dict{Symbol,Any}(:shrine_id => "unknown")))
        @test r5["success"] == false
        vm.priests["keeper1"] = "genesis"
        OsoVM.execute_instruction(vm, Instr(0x69, Dict{Symbol,Any}(:id => "sh1", :keeper => "keeper1")))
        r6 = OsoVM.execute_instruction(vm, Instr(0x70, Dict{Symbol,Any}(:shrine_id => "sh1")))
        @test r6["success"] == true

        r7 = OsoVM.execute_instruction(vm, Instr(0x71, Dict{Symbol,Any}(:id => "f1", :start => 100, :end => 50)))
        @test r7["success"] == false
        r8 = OsoVM.execute_instruction(vm, Instr(0x71, Dict{Symbol,Any}(:id => "f1", :start => 50, :end => 100)))
        @test r8["success"] == true

        r9 = OsoVM.execute_instruction(vm, Instr(0x72, Dict{Symbol,Any}(:id => "feast1", :name => "Harvest")))
        @test r9["success"] == true
    end

    @testset "BAPTISM cannot double-baptize, COMMUNION requires baptism + priest" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0x73, Dict{Symbol,Any}(:name => "believer1")))
        @test r1["success"] == true
        r2 = OsoVM.execute_instruction(vm, Instr(0x73, Dict{Symbol,Any}(:name => "believer1")))
        @test r2["success"] == false

        r3 = OsoVM.execute_instruction(vm, Instr(0x74, Dict{Symbol,Any}(:participant => "unbaptized", :priest => "p1")))
        @test r3["success"] == false
        vm.priests["p1"] = "genesis"
        r4 = OsoVM.execute_instruction(vm, Instr(0x74, Dict{Symbol,Any}(:participant => "believer1", :priest => "p1")))
        @test r4["success"] == true
    end

    @testset "CONFESSION -> PENANCE -> ABSOLUTION lifecycle" begin
        vm = OsoVM.create_vm()
        vm.priests["p1"] = "genesis"
        r1 = OsoVM.execute_instruction(vm, Instr(0x75, Dict{Symbol,Any}(:id => "conf1", :priest => "unknown_priest")))
        @test r1["success"] == false
        vm.current_sender = "sinner1"
        r2 = OsoVM.execute_instruction(vm, Instr(0x75, Dict{Symbol,Any}(:id => "conf1", :priest => "p1", :sin => "pride")))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0x76, Dict{Symbol,Any}(:confession_id => "unknown")))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0x76, Dict{Symbol,Any}(:confession_id => "conf1", :act => "10 prayers")))
        @test r4["success"] == true

        vm.current_sender = "not_p1"
        r5 = OsoVM.execute_instruction(vm, Instr(0x77, Dict{Symbol,Any}(:confession_id => "conf1")))
        @test r5["success"] == false
        vm.current_sender = "p1"
        r6 = OsoVM.execute_instruction(vm, Instr(0x77, Dict{Symbol,Any}(:confession_id => "conf1")))
        @test r6["success"] == true
        r7 = OsoVM.execute_instruction(vm, Instr(0x77, Dict{Symbol,Any}(:confession_id => "conf1")))
        @test r7["success"] == false  # already absolved

        r8 = OsoVM.execute_instruction(vm, Instr(0x76, Dict{Symbol,Any}(:confession_id => "conf1", :act => "more prayers")))
        @test r8["success"] == false  # confession already absolved
    end

    @testset "RESURRECTION final_signer-gated, requires witness" begin
        vm = OsoVM.create_vm(final_signer="bino")
        vm.current_sender = "not_bino"
        r1 = OsoVM.execute_instruction(vm, Instr(0x78, Dict{Symbol,Any}(:id => "res1", :subject => "s1", :witnessed_by => "w1")))
        @test r1["success"] == false
        vm.current_sender = "bino"
        r2 = OsoVM.execute_instruction(vm, Instr(0x78, Dict{Symbol,Any}(:id => "res1", :subject => "s1", :witnessed_by => "")))
        @test r2["success"] == false  # no witness
        r3 = OsoVM.execute_instruction(vm, Instr(0x78, Dict{Symbol,Any}(:id => "res1", :subject => "s1", :witnessed_by => "w1")))
        @test r3["success"] == true
        r4 = OsoVM.execute_instruction(vm, Instr(0x78, Dict{Symbol,Any}(:id => "res1", :subject => "s1", :witnessed_by => "w1")))
        @test r4["success"] == false  # duplicate id
    end

end
