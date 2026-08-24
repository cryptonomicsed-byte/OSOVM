# glyphindex_dispatch_test.jl — opcode-dispatch tests for GLYPH_* 0xF0-0xF4
#
# glyphindex_test.jl already covers GlyphIndex's internal functions
# (fold/Odù vectors, envelope parsing, etc.) directly against the module.
# This file covers the other half: that the 5 opcodes are actually
# reachable through OsoVM.execute_instruction, not just defined dead code.

using Test
using SHA

include(joinpath(@__DIR__, "..", "src", "oso_vm.jl"))
using .OsoVM

function seal_gix1(plaintext_len::Int)
    # Minimal structurally-valid GIX1 envelope: magic+version+flags+nonce(12)+ciphertext+tag(16).
    vcat(Vector{UInt8}(codeunits("GIX1")), UInt8[0x01, 0x00],
         rand(UInt8, 12), rand(UInt8, plaintext_len), rand(UInt8, 16))
end

@testset "GlyphIndex opcode dispatch" begin
    vm = OsoVM.create_vm(glyph_journal_path = tempname())

    @test OsoVM.is_critical(0xf0) && OsoVM.is_critical(0xf1) && OsoVM.is_critical(0xf2) &&
          OsoVM.is_critical(0xf3) && OsoVM.is_critical(0xf4)

    blob = seal_gix1(64)
    store_instr = OsoVM.OsoCompiler.Instruction(0xf0,
        Dict(:chunk => "hello glyph world", :sealed_blob_hex => bytes2hex(blob)))
    store_res = OsoVM.execute_instruction(vm, store_instr)
    @test store_res["status"] == "stored"
    cid = store_res["canonical_id"]

    expand_res = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf1, Dict(:canonical_id => cid)))
    @test expand_res["status"] == "expanded"
    @test hex2bytes(expand_res["sealed_blob_hex"]) == blob

    search_res = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf2, Dict(:query => "glyph", :k => 3)))
    @test search_res["status"] == "searched"
    @test any(r -> r["canonical_id"] == cid, search_res["results"])

    anchor_res = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf3, Dict()))
    @test anchor_res["status"] == "anchored"
    @test length(anchor_res["merkle_root"]) == 64

    mac_key = bytes2hex(rand(UInt8, 32))
    audit_res = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf4, Dict(:canonical_id => cid, :mac_key_hex => mac_key)))
    @test audit_res["status"] == "audited"
    @test audit_res["receipt_verified"] == true
    @test audit_res["envelope_valid"] == true
    issued_receipt = audit_res["receipt"]

    # Re-auditing the SAME previously-issued receipt against the correct
    # key must still verify true.
    reaudit = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf4,
            Dict(:canonical_id => cid, :mac_key_hex => mac_key, :receipt => issued_receipt)))
    @test reaudit["receipt_verified"] == true

    # Auditing that same issued receipt against the WRONG key must fail --
    # this is the real tamper-detection path (regenerating a fresh receipt
    # from the wrong key would be tautologically self-consistent and never
    # catch this).
    bad_audit = OsoVM.execute_instruction(vm,
        OsoVM.OsoCompiler.Instruction(0xf4,
            Dict(:canonical_id => cid, :mac_key_hex => bytes2hex(rand(UInt8, 32)),
                 :receipt => issued_receipt)))
    @test bad_audit["receipt_verified"] == false
end
