# glyphindex.jl — GlyphIndex sovereign memory primitive for the Sacred VM
#
# OSOVM executes agent cognition; GlyphIndex is its memory syscall surface.
# This module implements the keyless core of the ecosystem-wide GlyphIndex
# contract (canonical reference: Vantage/backend/glyph_index.py):
#
#   • GIX-FOLD-v1     — SHA-256 content hash → single valid BMP glyph
#   • Odù linkage     — digest[1] → base Odù, (digest[1]<<8)|digest[2] → composed
#   • GIX1 envelope   — structural parsing/audit of sealed blobs
#   • Receipts        — HMAC-SHA256 commitments over sealed blobs
#   • Merkle anchors  — root over the vault, for Sui anchoring
#   • Vault journal   — append-only JSONL metadata journal + in-memory index
#   • VM opcodes      — 0xF0..0xF4 GLYPH_* extension opcodes
#
# Sealing/unsealing (AES-256-GCM under BIPỌ̀N39-derived keys) happens in the
# identity-holding components (BIPON39 Rust crate, Vantage reference, Cloakseed
# vault). The VM deliberately never touches decryption keys: it stores, serves,
# audits, and anchors ciphertext — Zangbeto can replay every step.

module GlyphIndex

using SHA
using JSON

export glyph_fold, content_hash, odu_link, chunk_text,
       GixEnvelope, parse_gix1, GlyphNode, GlyphVault,
       store!, expand_meta, search, merkle_root, receipt, verify_receipt,
       GLYPH_OPCODES, embed

# ── GIX-FOLD-v1 ─────────────────────────────────────────────────────────────

# (start, count) ranges of valid, printable BMP scalars — surrogates,
# controls, and noncharacters excluded. Identical in every ecosystem repo.
const FOLD_RANGES = ((0x0020, 0xD7FF - 0x0020 + 1),
                     (0xE000, 0xFDCF - 0xE000 + 1),
                     (0xFDF0, 0xFFFD - 0xFDF0 + 1))
const FOLD_TOTAL = sum(r[2] for r in FOLD_RANGES)  # 63,422

content_hash(text::AbstractString) = sha256(Vector{UInt8}(codeunits(text)))

"""GIX-FOLD-v1: fold a 32-byte digest onto its display glyph."""
function glyph_fold(digest::Vector{UInt8})
    length(digest) == 32 || error("glyph_fold requires a 32-byte digest")
    rem::UInt64 = 0
    for b in digest
        rem = (rem << 8 | UInt64(b)) % UInt64(FOLD_TOTAL)
    end
    idx = UInt32(rem)
    for (start, count) in FOLD_RANGES
        idx < count && return Char(start + idx)
        idx -= count
    end
    error("unreachable: idx < FOLD_TOTAL by construction")
end

"""(base Odù 0–255, composed Odù 0–65535) for a content digest."""
odu_link(digest::Vector{UInt8}) =
    (Int(digest[1]), Int(digest[1]) << 8 | Int(digest[2]))

# ── chunking ────────────────────────────────────────────────────────────────

"""Semantic split on "User:" turns; oversized chunks split on UTF-8-safe
byte boundaries (never inside a multi-byte character)."""
function chunk_text(text::AbstractString; max_bytes::Int=4096)
    pieces = if occursin("User:", text)
        parts = split(text, "User:")
        [i == 1 ? strip(p) : "User:" * strip(p) for (i, p) in enumerate(parts) if !isempty(strip(p))]
    else
        s = strip(text)
        isempty(s) ? String[] : [s]
    end
    out = String[]
    for piece in pieces
        raw = Vector{UInt8}(codeunits(piece))
        while length(raw) > max_bytes
            cut = max_bytes
            while cut > 0 && (raw[cut + 1] & 0xC0) == 0x80
                cut -= 1
            end
            push!(out, String(raw[1:cut]))
            raw = raw[cut + 1:end]
        end
        isempty(raw) || push!(out, String(raw))
    end
    out
end

# ── GIX1 structural audit (keyless) ─────────────────────────────────────────

const GIX_MAGIC = Vector{UInt8}(codeunits("GIX1"))
const GIX_VERSION = 0x01
const FLAG_ZLIB = 0x01

struct GixEnvelope
    version::UInt8
    flags::UInt8
    nonce::Vector{UInt8}
    ciphertext::Vector{UInt8}
    tag::Vector{UInt8}
end

"""Structurally validate a sealed GIX1 blob without holding any keys."""
function parse_gix1(blob::Vector{UInt8})
    length(blob) >= 4 + 2 + 12 + 16 || error("GIX1 blob too short ($(length(blob)) bytes)")
    blob[1:4] == GIX_MAGIC || error("bad magic — not a GIX1 blob")
    version, flags = blob[5], blob[6]
    version == GIX_VERSION || error("unsupported GIX version $version")
    (flags & ~FLAG_ZLIB) == 0 || error("unknown flag bits set")
    GixEnvelope(version, flags, blob[7:18], blob[19:end-16], blob[end-15:end])
end

# ── embeddings (runtime-local, not a wire format) ───────────────────────────

"""Deterministic hashing 3-gram embedder (SHA-256 buckets, L2-normalized).
A production deployment swaps in a real model; the vault only requires that
`embed` is stable within one runtime."""
function embed(text::AbstractString; dim::Int=256)
    vec = zeros(Float64, dim)
    lowered = lowercase(text)
    chars = collect(lowered)
    n = max(length(chars) - 2, 1)
    for i in 1:n
        gram = String(chars[i:min(i + 2, length(chars))])
        h = sha256(Vector{UInt8}(codeunits(gram)))
        bucket = (Int(h[1]) << 8 | Int(h[2])) % dim + 1
        vec[bucket] += 1.0
    end
    norm = sqrt(sum(abs2, vec))
    norm > 0 ? vec ./ norm : vec
end

cosine(a::Vector{Float64}, b::Vector{Float64}) = sum(a .* b)

# ── vault ───────────────────────────────────────────────────────────────────

struct GlyphNode
    canonical_id::String
    glyph::Char
    odu_base::Int
    odu_composed::Int
    ts::Float64
    blob_sha256::String          # commitment to the sealed blob
    walrus_blob_id::String
    embedding::Vector{Float64}
end

"""Sovereign memory vault: in-memory index + append-only JSONL journal.
Holds ciphertext commitments and metadata only — never plaintext, never keys."""
mutable struct GlyphVault
    owner::String
    journal_path::String
    nodes::Dict{String, GlyphNode}
    blobs::Dict{String, Vector{UInt8}}   # sealed GIX1 blobs by canonical_id
end

function GlyphVault(owner::AbstractString, journal_path::AbstractString)
    vault = GlyphVault(String(owner), String(journal_path),
                       Dict{String, GlyphNode}(), Dict{String, Vector{UInt8}}())
    if isfile(journal_path)
        for line in eachline(journal_path)
            isempty(strip(line)) && continue
            entry = JSON.parse(line)
            node = GlyphNode(entry["canonical_id"], Char(entry["glyph_codepoint"]),
                             entry["odu_base"], entry["odu_composed"], entry["ts"],
                             entry["blob_sha256"], get(entry, "walrus_blob_id", ""),
                             Float64.(get(entry, "embedding", Float64[])))
            vault.nodes[node.canonical_id] = node
        end
    end
    vault
end

"""Journal a chunk: fold plaintext to its glyph identity, commit to the
sealed blob, index the embedding. `sealed_blob` must be a GIX1 envelope
sealed by the identity layer; the vault verifies structure, not content."""
function store!(vault::GlyphVault, chunk::AbstractString, sealed_blob::Vector{UInt8};
                ts::Float64=time(), walrus_blob_id::AbstractString="")
    parse_gix1(sealed_blob)              # refuse malformed ciphertext outright
    digest = content_hash(chunk)
    cid = bytes2hex(digest)
    base, composed = odu_link(digest)
    node = GlyphNode(cid, glyph_fold(digest), base, composed, ts,
                     bytes2hex(sha256(sealed_blob)), String(walrus_blob_id),
                     embed(chunk))
    vault.nodes[cid] = node
    vault.blobs[cid] = sealed_blob
    open(vault.journal_path, "a") do io
        JSON.print(io, Dict(
            "canonical_id" => node.canonical_id,
            "glyph_codepoint" => Int(node.glyph),
            "odu_base" => node.odu_base,
            "odu_composed" => node.odu_composed,
            "ts" => node.ts,
            "blob_sha256" => node.blob_sha256,
            "walrus_blob_id" => node.walrus_blob_id,
            "embedding" => node.embedding,
        ))
        println(io)
    end
    node
end

"""Metadata for a stored glyph (the VM serves ciphertext + metadata; plaintext
expansion happens wherever the keys live)."""
function expand_meta(vault::GlyphVault, canonical_id::AbstractString)
    haskey(vault.nodes, canonical_id) || error("unknown glyph $canonical_id")
    node = vault.nodes[canonical_id]
    blob = get(vault.blobs, canonical_id, UInt8[])
    (node = node, sealed_blob = blob)
end

"""Cosine top-k over the vault's embeddings; ties broken by recency."""
function search(vault::GlyphVault, query::AbstractString; k::Int=3)
    qvec = embed(query)
    scored = [(cosine(qvec, n.embedding), n.ts, n) for n in values(vault.nodes)
              if !isempty(n.embedding)]
    sort!(scored, by = s -> (-s[1], -s[2]))
    [s[3] for s in scored[1:min(k, length(scored))]]
end

# ── receipts + anchoring ────────────────────────────────────────────────────

"""HMAC-SHA256 receipt binding a sealed blob to the owner's MAC key —
field-compatible with the reference implementation and Zangbeto's auditor."""
function receipt(vault::GlyphVault, canonical_id::AbstractString, mac_key::Vector{UInt8})
    node = vault.nodes[canonical_id]
    msg = vcat(Vector{UInt8}(codeunits(node.canonical_id)), hex2bytes(node.blob_sha256))
    Dict("canonical_id" => node.canonical_id,
         "blob_sha256" => node.blob_sha256,
         "owner" => vault.owner,
         "hmac" => bytes2hex(hmac_sha256(mac_key, msg)))
end

function verify_receipt(r::Dict, mac_key::Vector{UInt8})
    msg = vcat(Vector{UInt8}(codeunits(r["canonical_id"])), hex2bytes(r["blob_sha256"]))
    expected = bytes2hex(hmac_sha256(mac_key, msg))
    # constant-time-ish comparison: accumulate over all bytes
    a, b = codeunits(expected), codeunits(r["hmac"])
    length(a) == length(b) && reduce(|, xor.(a, b); init=UInt8(0)) == 0
end

"""Merkle root over the vault (leaf = SHA-256(id_bytes || SHA-256(blob)),
sorted by canonical id, odd leaf promoted) — the Sui anchor value."""
function merkle_root(vault::GlyphVault)
    ids = sort!(collect(keys(vault.blobs)))
    level = [sha256(vcat(hex2bytes(cid), sha256(vault.blobs[cid]))) for cid in ids]
    isempty(level) && return bytes2hex(sha256(Vector{UInt8}(codeunits("GIX1:empty"))))
    while length(level) > 1
        nxt = Vector{Vector{UInt8}}()
        for i in 1:2:length(level)-1
            push!(nxt, sha256(vcat(level[i], level[i+1])))
        end
        isodd(length(level)) && push!(nxt, level[end])
        level = nxt
    end
    bytes2hex(level[1])
end

# ── VM opcode surface ───────────────────────────────────────────────────────

# Extension opcodes in the free 0xF0 block (see opcodes.jl for 0x00–0xE9).
const GLYPH_OPCODES = Dict{Symbol, UInt8}(
    :GLYPH_STORE  => 0xF0,  # @glyphStore  - journal a sealed chunk
    :GLYPH_EXPAND => 0xF1,  # @glyphExpand - serve sealed blob + metadata
    :GLYPH_SEARCH => 0xF2,  # @glyphSearch - semantic top-k over the vault
    :GLYPH_ANCHOR => 0xF3,  # @glyphAnchor - emit merkle root for Sui anchoring
    :GLYPH_AUDIT  => 0xF4,  # @glyphAudit  - Zangbeto receipt/envelope audit
)

end # module GlyphIndex
