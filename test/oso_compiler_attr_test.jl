include("/opt/ares/OSOVM/src/oso_compiler.jl")
using .OsoCompiler
using Test

# Every multi-word camelCase attribute from opcodes.jl's comments, paired
# with the opcode it must resolve to (not NOOP 0x01).
camel_cases = [
    ("@biponSeed(x=1);",          0x26),
    ("@genesisFlawToken(x=1);",   0x2b),
    ("@candidateApply(x=1);",     0x30),
    ("@councilApprove(x=1);",     0x31),
    ("@finalSign(x=1);",          0x32),
    ("@distributeOffering(x=1);", 0x33),
    ("@claimRewards(x=1);",       0x34),
    ("@agentConvert(x=1);",       0x3c),
    ("@jobPayment(x=1);",         0x3d),
    ("@agentBirth(x=1);",         0x3e),
    ("@orisaObatala(x=1);",       0xa0),
    ("@orisaOgun(x=1);",          0xa1),
    ("@orisaYemoja(x=1);",        0xa2),
    ("@orisaSango(x=1);",         0xa3),
    ("@orisaOshun(x=1);",         0xa4),
    ("@orisaOya(x=1);",           0xa5),
    ("@orisaEsu(x=1);",           0xa6),
    ("@orisaOrunmila(x=1);",      0xa7),
    ("@ifaDivination(x=1);",      0xa8),
    ("@aseInvocation(x=1);",      0xac),
    ("@ancestralCall(x=1);",      0xad),
    # single-word, must still work (regression guard)
    ("@impact(x=1);",             0x11),
    ("@halt;",                    0x00),
]

@testset "camelCase attribute normalization" begin
    for (src, expected_opcode) in camel_cases
        ir = compile_oso(src)
        @test length(ir) == 1
        @test ir[1].opcode == expected_opcode
    end
end

println("ALL PASSED")
