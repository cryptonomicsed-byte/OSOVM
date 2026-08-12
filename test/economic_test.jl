# test/economic_test.jl — Economic Extensions cluster real-dispatch tests
# Verifies: MARKET, ORDER, LIQUIDITY, SWAP, YIELD, BOND, EQUITY, DIVIDEND,
# INTEREST, COLLATERAL, LOAN, REPAYMENT, DEFAULT, LIQUIDATION, AUCTION,
# INSURANCE, CLAIM, PREMIUM, UNDERWRITE, HEDGE now have real stateful
# VM-enforced logic, not decorative echoes/call_ase_vault() offload.

using Test

include("../src/oso_vm.jl")

using .OsoVM

Instr = OsoVM.OsoCompiler.Instruction

@testset "Economic Extensions cluster (real dispatch)" begin

    @testset "is_critical includes all 20 Economic opcodes" begin
        for op in [0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,
                   0xca,0xcb,0xcc,0xcd,0xce,0xcf,0xd0,0xd1,0xd2,0xd3]
            @test OsoVM.is_critical(op)
        end
    end

    @testset "MARKET -> ORDER -> LIQUIDITY -> SWAP chain" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xc1, Dict{Symbol,Any}(:market_id => "unknown", :amount => 1.0)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xc0, Dict{Symbol,Any}(:id => "m1")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0xc1, Dict{Symbol,Any}(:market_id => "m1", :amount => 0.0)))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xc1, Dict{Symbol,Any}(:market_id => "m1", :amount => 10.0)))
        @test r4["success"] == true

        r5 = OsoVM.execute_instruction(vm, Instr(0xc2, Dict{Symbol,Any}(:id => "pool1", :market_id => "unknown", :depth => 100.0)))
        @test r5["success"] == false
        r6 = OsoVM.execute_instruction(vm, Instr(0xc2, Dict{Symbol,Any}(:id => "pool1", :market_id => "m1", :depth => 100.0)))
        @test r6["success"] == true

        r7 = OsoVM.execute_instruction(vm, Instr(0xc3, Dict{Symbol,Any}(:pool_id => "pool1", :amount_in => 200.0)))
        @test r7["success"] == false  # exceeds depth
        r8 = OsoVM.execute_instruction(vm, Instr(0xc3, Dict{Symbol,Any}(:pool_id => "pool1", :amount_in => 40.0)))
        @test r8["success"] == true
        @test vm.liquidity_pools["pool1"][:depth] == 60.0
    end

    @testset "YIELD requires a real source" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xc4, Dict{Symbol,Any}(:source_id => "unknown", :rate => 0.1)))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xc0, Dict{Symbol,Any}(:id => "m1")))
        r2 = OsoVM.execute_instruction(vm, Instr(0xc4, Dict{Symbol,Any}(:source_id => "m1", :rate => 1.5)))
        @test r2["success"] == false  # rate out of [0,1]
        r3 = OsoVM.execute_instruction(vm, Instr(0xc4, Dict{Symbol,Any}(:source_id => "m1", :rate => 0.05)))
        @test r3["success"] == true
    end

    @testset "BOND, EQUITY -> DIVIDEND" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xc5, Dict{Symbol,Any}(:id => "b1", :face_value => 0.0)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xc5, Dict{Symbol,Any}(:id => "b1", :face_value => 1000.0)))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xc7, Dict{Symbol,Any}(:equity_id => "unknown", :amount => 1.0)))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xc6, Dict{Symbol,Any}(:id => "eq1", :company => "Acme", :shares => 100)))
        @test r4["success"] == true
        r5 = OsoVM.execute_instruction(vm, Instr(0xc7, Dict{Symbol,Any}(:equity_id => "eq1", :amount => 5.0)))
        @test r5["success"] == true
    end

    @testset "COLLATERAL -> LOAN -> REPAYMENT (full repay unlocks collateral)" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xca, Dict{Symbol,Any}(:id => "l1", :collateral_id => "unknown", :principal => 100.0)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xc9, Dict{Symbol,Any}(:id => "col1", :value => 500.0)))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xca, Dict{Symbol,Any}(:id => "l1", :collateral_id => "col1", :principal => 100.0)))
        @test r3["success"] == true
        @test vm.collaterals["col1"][:locked] == true

        r4 = OsoVM.execute_instruction(vm, Instr(0xca, Dict{Symbol,Any}(:id => "l2", :collateral_id => "col1", :principal => 50.0)))
        @test r4["success"] == false  # collateral already locked

        r5 = OsoVM.execute_instruction(vm, Instr(0xcb, Dict{Symbol,Any}(:loan_id => "l1", :amount => 40.0)))
        @test r5["success"] == true
        @test r5["loan_status"] == "active"
        r6 = OsoVM.execute_instruction(vm, Instr(0xcb, Dict{Symbol,Any}(:loan_id => "l1", :amount => 60.0)))
        @test r6["success"] == true
        @test r6["loan_status"] == "repaid"
        @test vm.collaterals["col1"][:locked] == false

        r7 = OsoVM.execute_instruction(vm, Instr(0xcb, Dict{Symbol,Any}(:loan_id => "l1", :amount => 1.0)))
        @test r7["success"] == false  # no longer active
    end

    @testset "DEFAULT -> LIQUIDATION requires the default first" begin
        vm = OsoVM.create_vm()
        OsoVM.execute_instruction(vm, Instr(0xc9, Dict{Symbol,Any}(:id => "col1", :value => 500.0)))
        OsoVM.execute_instruction(vm, Instr(0xca, Dict{Symbol,Any}(:id => "l1", :collateral_id => "col1", :principal => 100.0)))

        r1 = OsoVM.execute_instruction(vm, Instr(0xcd, Dict{Symbol,Any}(:loan_id => "l1")))
        @test r1["success"] == false  # not defaulted yet
        r2 = OsoVM.execute_instruction(vm, Instr(0xcc, Dict{Symbol,Any}(:loan_id => "l1", :reason => "missed payments")))
        @test r2["success"] == true
        r3 = OsoVM.execute_instruction(vm, Instr(0xcc, Dict{Symbol,Any}(:loan_id => "l1")))
        @test r3["success"] == false  # already defaulted, not active

        r4 = OsoVM.execute_instruction(vm, Instr(0xcd, Dict{Symbol,Any}(:loan_id => "l1")))
        @test r4["success"] == true
        @test vm.collaterals["col1"][:locked] == false
    end

    @testset "INTEREST requires a real loan, AUCTION basic invariant" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xc8, Dict{Symbol,Any}(:loan_id => "unknown", :rate => 0.05)))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xc9, Dict{Symbol,Any}(:id => "col1", :value => 500.0)))
        OsoVM.execute_instruction(vm, Instr(0xca, Dict{Symbol,Any}(:id => "l1", :collateral_id => "col1", :principal => 100.0)))
        r2 = OsoVM.execute_instruction(vm, Instr(0xc8, Dict{Symbol,Any}(:loan_id => "l1", :rate => 0.05)))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xce, Dict{Symbol,Any}(:id => "auc1", :reserve_price => -1.0)))
        @test r3["success"] == false
        r4 = OsoVM.execute_instruction(vm, Instr(0xce, Dict{Symbol,Any}(:id => "auc1", :reserve_price => 50.0)))
        @test r4["success"] == true
    end

    @testset "INSURANCE -> PREMIUM/UNDERWRITE -> CLAIM" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xd0, Dict{Symbol,Any}(:insurance_id => "unknown", :amount => 10.0)))
        @test r1["success"] == false
        r2 = OsoVM.execute_instruction(vm, Instr(0xcf, Dict{Symbol,Any}(:id => "ins1", :coverage => 1000.0)))
        @test r2["success"] == true

        r3 = OsoVM.execute_instruction(vm, Instr(0xd0, Dict{Symbol,Any}(:insurance_id => "ins1", :amount => 10.0)))
        @test r3["success"] == false  # not underwritten yet

        r4 = OsoVM.execute_instruction(vm, Instr(0xd1, Dict{Symbol,Any}(:insurance_id => "ins1", :amount => 20.0)))
        @test r4["success"] == true  # PREMIUM doesn't require underwriting

        r5 = OsoVM.execute_instruction(vm, Instr(0xd2, Dict{Symbol,Any}(:insurance_id => "ins1")))
        @test r5["success"] == true
        r6 = OsoVM.execute_instruction(vm, Instr(0xd2, Dict{Symbol,Any}(:insurance_id => "ins1")))
        @test r6["success"] == false  # already underwritten

        r7 = OsoVM.execute_instruction(vm, Instr(0xd0, Dict{Symbol,Any}(:insurance_id => "ins1", :amount => 5000.0)))
        @test r7["success"] == false  # exceeds coverage
        r8 = OsoVM.execute_instruction(vm, Instr(0xd0, Dict{Symbol,Any}(:insurance_id => "ins1", :amount => 200.0)))
        @test r8["success"] == true
    end

    @testset "HEDGE requires a real loan or insurance target" begin
        vm = OsoVM.create_vm()
        r1 = OsoVM.execute_instruction(vm, Instr(0xd3, Dict{Symbol,Any}(:target_id => "unknown")))
        @test r1["success"] == false
        OsoVM.execute_instruction(vm, Instr(0xcf, Dict{Symbol,Any}(:id => "ins1", :coverage => 1000.0)))
        r2 = OsoVM.execute_instruction(vm, Instr(0xd3, Dict{Symbol,Any}(:target_id => "ins1", :instrument => "put option")))
        @test r2["success"] == true
    end

end
