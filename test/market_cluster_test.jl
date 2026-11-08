# market_cluster_test.jl — the 0xc0-0xc3 market cluster must be reachable.
#
# Regression: execute_instruction rejected 0xc0 as "removed" -- a guard written
# for vm_core's deleted ASE_MINT, which used the same byte. In the live table
# 0xc0 is MARKET, which only registers a venue and mints nothing. Because ORDER,
# LIQUIDITY and SWAP all require an existing market, the guard made the entire
# cluster unreachable: no market could ever be created.

using Test
include(joinpath(@__DIR__, "..", "src", "oso_vm.jl"))
using .OsoVM
const I = OsoVM.OsoCompiler.Instruction

run!(vm, op, args) = OsoVM.execute_instruction(vm, I(op, Dict{Symbol,Any}(args)))

@testset "market cluster reachable" begin
    vm = OsoVM.create_vm()
    m = run!(vm, 0xc0, Dict(:id => "mkt-1", :name => "SOL/USDC"))
    @test get(m, "success", false) == true
    @test haskey(vm.markets, "mkt-1")

    o = run!(vm, 0xc1, Dict(:market_id => "mkt-1", :amount => 2.5, :side => "buy"))
    @test get(o, "success", false) == true

    l = run!(vm, 0xc2, Dict(:id => "pool-1", :market_id => "mkt-1", :depth => 100.0))
    @test get(l, "success", false) == true

    # MARKET registers a venue and nothing else: no balance anywhere moves.
    @test all(v == 0 for v in values(vm.ase_balance))
end

@testset "a genuinely deleted mint stays deleted" begin
    vm = OsoVM.create_vm()
    r = run!(vm, 0x11, Dict(:ase => 1.0e6))
    @test get(r, "success", true) == false
    @test occursin("removed", string(get(r, "error", "")))
end
