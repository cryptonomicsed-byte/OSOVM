include("/opt/ares/OSOVM/src/techgnos_compiler.jl")
using .TechGnosCompiler
using Test

@testset "techgnos unknown attribute no longer silently HALTs" begin
    source = """
    shrine TestShrine {
        @totallyMadeUpNonexistentAttr
        function doThing() {
        }
    }
    """
    ir = compile_tech(source)
    @test length(ir) == 1
    @test ir[1]["opcode"] == 0x01  # NOOP, not 0x00 HALT
end

@testset "real @halt attribute still maps to HALT" begin
    source = """
    shrine TestShrine {
        @halt
        function stopIt() {
        }
    }
    """
    ir = compile_tech(source)
    @test length(ir) == 1
    @test ir[1]["opcode"] == 0x00
end

@testset "known camelCase multi-word attribute still resolves" begin
    source = """
    shrine TestShrine {
        @candidateApply
        function apply() {
        }
    }
    """
    ir = compile_tech(source)
    @test length(ir) == 1
    @test ir[1]["opcode"] == 0x30  # CANDIDATE_APPLY
end
