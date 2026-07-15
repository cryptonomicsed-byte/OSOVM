# glyphindex_test.jl — GlyphIndex memory primitive tests
#
# The fold/Odù vectors below are the frozen cross-language vectors generated
# by the canonical Python reference implementation (Vantage). Every ecosystem
# repo embeds the same values — do not regenerate casually.

using Test
using SHA

include(joinpath(@__DIR__, "..", "src", "glyphindex.jl"))
using .GlyphIndex

@testset "GIX-FOLD-v1 canonical vectors" begin
    vectors = [
        ("Àṣẹ", "e32866670f27c0ccaeda5facc74fcfc3f8c17b18bcae2fb9dc150d91c601db1b", 21841, 227, 58152),
        ("hello", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", 23636, 44, 11506),
        ("GlyphIndex", "44bb6336e45b2f5daf764930ac1d1f2798ad92c34048f0395686ac4509a0a7ec", 13726, 68, 17595),
        ("😊🚀 Unicode test", "bdf299182a61f04e31c6445f96a6a68d927d7e6cd9c56f883c8f1cc7cfac8683", 64591, 189, 48626),
        ("Ọ̀rúnmìlà", "cca6a38cbd2874b7f2b4809ba11ee5177660c4ad5fb4851991414722729fd523", 17963, 204, 52390),
    ]
    for (text, cid, codepoint, base, composed) in vectors
        digest = content_hash(text)
        @test bytes2hex(digest) == cid
        @test Int(glyph_fold(digest)) == codepoint
        @test odu_link(digest) == (base, composed)
    end
end

@testset "fold never emits invalid scalars" begin
    for i in 1:2000
        cp = Int(glyph_fold(content_hash("probe-$i")))
        @test 0x20 <= cp <= 0xFFFD
        @test !(0xD800 <= cp <= 0xDFFF)
        @test !(0xFDD0 <= cp <= 0xFDEF)
    end
end

@testset "chunking" begin
    chunks = chunk_text("Intro. User: hi AI: hello User: bye")
    @test length(chunks) == 3
    @test chunks[1] == "Intro."
    @test startswith(chunks[2], "User:")
    # UTF-8 safe hard split: no mojibake, lossless
    big = repeat("😊", 3000)
    parts = chunk_text(big; max_bytes=4096)
    @test length(parts) > 1
    @test join(parts) == big
end

# A structurally valid (contents fake) GIX1 envelope for vault tests.
function fake_blob(seed::UInt8)
    vcat(Vector{UInt8}(codeunits("GIX1")), UInt8[0x01, 0x00],
         fill(seed, 12), Vector{UInt8}(codeunits("ciphertext-bytes")), fill(seed, 16))
end

@testset "GIX1 structural audit" begin
    env = parse_gix1(fake_blob(0x07))
    @test env.version == 0x01
    @test env.nonce == fill(0x07, 12)
    @test_throws Exception parse_gix1(UInt8[0x00, 0x01])
    bad = fake_blob(0x07); bad[1] = UInt8('X')
    @test_throws Exception parse_gix1(bad)
    badflags = fake_blob(0x07); badflags[6] = 0x80
    @test_throws Exception parse_gix1(badflags)
end

@testset "vault journal, search, receipts, merkle" begin
    mktempdir() do dir
        journal = joinpath(dir, "vault.jsonl")
        vault = GlyphVault("0xabc123", journal)

        @test merkle_root(vault) ==
              "58cc47f0d238cea8bb764f7a927a54b398c8baf5de0a2332c03008038c3fd9a8"

        n1 = store!(vault, "User: What's the weather? AI: Sunny and clear.", fake_blob(0x01))
        n2 = store!(vault, "Code: print('Hello, world!') # Python example", fake_blob(0x02))
        root = merkle_root(vault)
        @test length(root) == 64 && root != merkle_root(GlyphVault("x", joinpath(dir, "e.jsonl")))

        hits = search(vault, "weather sunny rain"; k=1)
        @test length(hits) == 1
        @test hits[1].canonical_id == n1.canonical_id

        meta = expand_meta(vault, n1.canonical_id)
        @test meta.node.glyph == n1.glyph
        @test parse_gix1(meta.sealed_blob).version == 0x01

        mac_key = fill(0x03, 32)
        r = receipt(vault, n1.canonical_id, mac_key)
        @test verify_receipt(r, mac_key)
        @test !verify_receipt(r, fill(0x04, 32))
        forged = copy(r); forged["blob_sha256"] = bytes2hex(sha256(UInt8[0xEE]))
        @test !verify_receipt(forged, mac_key)

        # journal replay restores the index
        reloaded = GlyphVault("0xabc123", journal)
        @test length(reloaded.nodes) == 2
        @test haskey(reloaded.nodes, n2.canonical_id)
    end
end

@testset "opcode block stays in free space" begin
    for (_, code) in GLYPH_OPCODES
        @test code >= 0xF0   # 0x00–0xE9 belong to the existing opcode map
    end
    @test length(unique(values(GLYPH_OPCODES))) == length(GLYPH_OPCODES)
end
