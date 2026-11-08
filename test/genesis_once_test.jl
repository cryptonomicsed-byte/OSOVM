# genesis_once_test.jl — the one-time genesis mint must not be repeatable.
#
# 0x2b GENESIS_FLAW_TOKEN mints 1.0 Àṣẹ "once, at block 0", guarded by
# block_height == 0 and the absence of a GenesisFlawUsed event in vm.events.
# server.jl builds a fresh VM for every /run, so both conditions were true on
# EVERY request: measured, three requests minted three times. Genesis is a
# one-time constitutional event; a VM that forgets everything between requests
# cannot enforce "once", so the live handler must refuse rather than mint.

using Test
include(joinpath(@__DIR__, "..", "src", "oso_vm.jl"))
using .OsoVM
const I = OsoVM.OsoCompiler.Instruction

@testset "genesis cannot be minted per request" begin
    for _ in 1:3                       # three requests, a fresh VM each, like /run
        vm = OsoVM.create_vm(); vm.current_sender = "did:key:probe"
        r = OsoVM.execute_instruction(vm, I(0x2b, Dict{Symbol,Any}(:token => "ASHE")))
        @test get(r, "success", true) == false
        @test get(r, "genesis", false) == false
        @test get(vm.ase_balance, "did:key:probe", 0.0) == 0.0
    end
end
