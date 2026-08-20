# nostr_bridge.jl — OSOVM <-> Nostr wire adapter.
#
# OSOVM executes ritual bytecode and settles jobs. Until now the fact that a
# job executed, and what it produced, stayed inside OSOVM: the VM could settle
# and Vantage could post, but nothing put an execution result onto the shared
# event log where other agents could see or contest it. This is that piece,
# built to the same wire contract Ifáscript, Kóòdù and Zàngbétò now speak.
#
# ## What this deliberately does NOT do: sign
#
# OSOVM holds no agent keys and should not. The ecosystem rule is derive once,
# adopt everywhere: Ọmọ Kọ́dà births an agent and owns its secp256k1 identity.
# A VM that minted its own key would create a second identity for the same
# agent, indistinguishable on the wire from a second agent.
#
# There is also a hard practical reason. Signing a Nostr event needs BIP-340
# Schnorr over secp256k1, and this project's Project.toml carries no such
# dependency (SHA, JSON, JSON3, HTTP, Dates — all stdlib or near). Adding a
# crypto dependency to the VM to sign events it does not own the keys for
# would be the wrong trade twice over.
#
# So this module builds **canonical unsigned events with correct NIP-01 ids**,
# and whichever component owns the key signs the id. Same split as Kóòdù.
#
# ## Why the serializer is hand-rolled
#
# A NIP-01 event id is sha256 over a canonical JSON array, and the signature is
# over that id. Two implementations that serialize differently compute
# different ids, and each rejects the other's signatures — with no error that
# points at serialization.
#
# NIP-01 requires raw UTF-8 with only a short, fixed escape set. Python's
# json.dumps escapes non-ASCII to \uXXXX by default and gets this wrong;
# measured, for content "Òrìṣà Ògún":
#
#   ensure_ascii=True   -> f5ceda251451b3571736436644e34ca50eca23ad68ea3e067934e5f8668c2337
#   raw UTF-8 (correct) -> e24b148552d35adf425c92e2e701ee3be6b4c86dbfd5fa2cc84a4c922250ac3b
#
# Rather than depend on a JSON library's escaping defaults — which differ
# between libraries and versions, and which a caller can change — this module
# implements the NIP-01 escape rules explicitly. The property is then a fact
# about this code, not about a dependency's configuration. `nostr_bridge_test.jl`
# pins it against the vector above.

module NostrBridge

using SHA
using Unicode

export KIND_AGENT_ENGRAM, KIND_CLAIM, KIND_AUTH, SLUG_PREFIX,
       is_publishable, canonical_serialize, event_id, build_unsigned_event,
       execution_record, slug_execution, execution_engram, execution_claim,
       validate_slug, normalize_slug_segment

# ============================================================================
# THE SHARED WIRE CONTRACT
# Each constant is owned by another component and mirrored here, never
# invented. Changing one in isolation breaks interoperability silently.
# ============================================================================

"NIP-AE agent engram. Owner: minipae (KIND_AGENT_ENGRAM)."
const KIND_AGENT_ENGRAM = 30174

"Crucible falsifiable claim. Owner: crucible-core::kinds::CLAIM."
const KIND_CLAIM = 47001

"NIP-42 relay auth. Owner: minipae (KIND_AUTH)."
const KIND_AUTH = 22242

"Crucible's reserved block. OSOVM must never mint a kind inside it."
const CRUCIBLE_RESERVED = 47000:47999

"Slug namespace for everything OSOVM writes."
const SLUG_PREFIX = "mem/osovm"

"""
    is_publishable(kind) -> Bool

True when `kind` is one OSOVM is allowed to publish under.

Deliberately **not** a mirror of the relay's allowlist. That allowlist is a
large match arm in `required_scope_for_kind` covering most of Buzz's own
vocabulary (kind 1, 7, 30023, 30315 and many more), and a copy here would drift
out of sync silently while claiming an authority this module does not have.
What this states is narrower and checkable: the kinds OSOVM emits.

A `false` therefore means "not ours", never "the relay would refuse it". The
relay does reject kinds with no match arm — after authentication succeeds,
which reads like an auth failure and is not one — so checking locally still
turns a caller's mistake into a clear error at the call site.
"""
is_publishable(kind::Integer) = kind in (KIND_AGENT_ENGRAM, KIND_CLAIM, KIND_AUTH)

# ============================================================================
# CANONICAL SERIALIZATION
# ============================================================================

"""
    escape_json_string(s) -> String

Escape `s` per NIP-01: only `"` `\\` and the C0 controls are escaped, with
short forms for backspace, tab, newline, formfeed and carriage return, and
`\\u00XX` for any other control character. Everything else — including all
non-ASCII — is emitted as raw UTF-8.

This is deliberately explicit rather than delegated to a JSON library, because
the id (and therefore every signature) depends on it. See the module note.
"""
function escape_json_string(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\b'
            write(io, "\\b")
        elseif c == '\f'
            write(io, "\\f")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif c < '\x20'
            write(io, string("\\u", lpad(string(UInt32(c), base = 16), 4, '0')))
        else
            # Raw UTF-8, including every non-ASCII codepoint. Escaping these
            # is the Python-default behaviour and it produces a different,
            # incompatible event id.
            write(io, c)
        end
    end
    String(take!(io))
end

_json_string(s::AbstractString) = string('"', escape_json_string(s), '"')

"Serialize a tag list — an array of arrays of strings — canonically."
function _json_tags(tags)
    inner = [string('[', join((_json_string(v) for v in tag), ','), ']') for tag in tags]
    string('[', join(inner, ','), ']')
end

"""
    canonical_serialize(; pubkey, created_at, kind, tags, content) -> String

The exact byte string NIP-01 hashes: `[0,pubkey,created_at,kind,tags,content]`
with no whitespace.
"""
function canonical_serialize(; pubkey, created_at, kind, tags, content)
    string(
        "[0,",
        _json_string(pubkey), ",",
        created_at, ",",
        kind, ",",
        _json_tags(tags), ",",
        _json_string(content),
        "]",
    )
end

"""
    event_id(; pubkey, created_at, kind, tags, content) -> String

NIP-01 event id: sha256 of the canonical serialization, lowercase hex.
"""
function event_id(; pubkey, created_at, kind, tags, content)
    serial = canonical_serialize(
        pubkey = pubkey, created_at = created_at, kind = kind,
        tags = tags, content = content,
    )
    bytes2hex(sha256(serial))
end

"""
    build_unsigned_event(; pubkey, kind, content, tags, created_at) -> Dict

A canonical event complete except for `sig`. A signer that owns the agent's key
signs `id` and attaches the signature; it must not recompute or alter any other
field, or the id stops matching what was signed.

Throws if `kind` is not one OSOVM publishes under, or if `pubkey` is not
64 hex characters.
"""
function build_unsigned_event(; pubkey, kind, content, tags = Vector{Vector{String}}(),
                              created_at = nothing)
    is_publishable(kind) || error("kind $kind is not one OSOVM publishes under")
    occursin(r"^[0-9a-f]{64}$", pubkey) ||
        error("pubkey must be 64 hex characters (x-only secp256k1)")

    ts = created_at === nothing ? round(Int, time()) : created_at
    id = event_id(pubkey = pubkey, created_at = ts, kind = kind,
                  tags = tags, content = content)

    Dict{String,Any}(
        "id" => id,
        "pubkey" => pubkey,
        "created_at" => ts,
        "kind" => kind,
        "tags" => tags,
        "content" => content,
    )
end

# ============================================================================
# OSOVM DOMAIN EVENTS
# ============================================================================

"""
    execution_record(; job_id, opcode_count, state_root, deterministic, ase_minted, veil)

The wire body of a job execution result.

Flat and self-describing so a Rust, JS or Python reader can interpret it
without OSOVM's own types. Serialized with the same explicit escaping as the
event itself, so a Yorùbá `veil` name cannot desynchronise the id.
"""
function execution_record(; job_id, opcode_count, state_root, deterministic,
                          ase_minted = 0, veil = "")
    string(
        "{",
        _json_string("job_id"), ":", _json_string(job_id), ",",
        _json_string("opcode_count"), ":", opcode_count, ",",
        _json_string("state_root"), ":", _json_string(state_root), ",",
        _json_string("deterministic"), ":", deterministic ? "true" : "false", ",",
        _json_string("ase_minted"), ":", ase_minted, ",",
        _json_string("veil"), ":", _json_string(veil),
        "}",
    )
end

"""
    validate_slug(slug) -> Bool

minipae's slug grammar, which every engram address must satisfy.

Verified against `minipae.py::validate_slug`: each `/`-separated segment after
`mem/` must be non-empty, at most 64 bytes, start with a lowercase letter,
digit or `_`, and contain only lowercase letters, digits, `_` and `-`. The
whole slug must be at most 255 bytes.
"""
function validate_slug(slug::AbstractString)
    ncodeunits(slug) > 255 && return false
    startswith(slug, "mem/") || return false
    rest = slug[5:end]
    isempty(rest) && return false
    for part in split(rest, '/')
        (isempty(part) || ncodeunits(part) > 64) && return false
        occursin(r"^[a-z0-9_][a-z0-9_-]*$", part) || return false
    end
    true
end

"""
    normalize_slug_segment(segment) -> String

Fold one path segment into minipae's grammar.

This ecosystem's vocabulary is Yorùbá — veil and Òrìṣà names carry diacritics,
and job identifiers may carry capitals — and none of that satisfies the
grammar above. An unnormalised segment produces a slug `validate_slug` refuses,
which would make the engram unaddressable by every minipae client.

Normalising costs nothing that matters: the slug is HMAC'd into the `d` tag
before it reaches the wire, so it is an addressing key and never display text,
and the Yorùbá name travels intact in the event content.

Strips combining marks (`ọ́` -> `o`), lowercases, and maps anything still
outside the grammar to `-`. Throws if nothing survives.
"""
function normalize_slug_segment(segment)
    folded = Unicode.normalize(String(segment), stripmark = true, casefold = true)
    folded = replace(folded, r"[^a-z0-9_-]+" => "-")
    folded = replace(folded, r"-{2,}" => "-")
    folded = strip(folded, '-')
    folded = first(folded, 64)
    isempty(folded) && error(
        "slug segment $(repr(segment)) normalises to nothing; " *
        "it cannot be used as an engram address")
    String(folded)
end

"""
    slug_execution(job_id) -> String

Slug for one job execution. The id is normalised and the result validated — a
slug minipae would reject is worth failing on here rather than discovering as
an unreadable engram later.
"""
function slug_execution(job_id::AbstractString)
    slug = string(SLUG_PREFIX, "/execution/", normalize_slug_segment(job_id))
    validate_slug(slug) || error("built an invalid engram slug: $slug")
    slug
end

"""
    execution_engram(; pubkey, record, owner_pubkey, d_tag, created_at) -> Dict

The unsigned engram (kind:30174) carrying an execution result.

`d_tag` is the HMAC'd slug. OSOVM cannot compute it — the HMAC key is derived
from the agent's secret — so the signer supplies it. Passing the raw slug would
publish it in the clear and defeat the reason minipae hashes it, so a missing
`d_tag` fails loudly instead.
"""
function execution_engram(; pubkey, record, owner_pubkey, d_tag = "", created_at = nothing)
    isempty(d_tag) && error(
        "d_tag is required: the slug must be HMACd by the key owner, never published raw")
    build_unsigned_event(
        pubkey = pubkey,
        kind = KIND_AGENT_ENGRAM,
        content = record,
        tags = [["d", d_tag], ["p", owner_pubkey]],
        created_at = created_at,
    )
end

"""
    execution_claim(; pubkey, statement, falsifier, job_id, half_life_secs, created_at) -> Dict

The unsigned Crucible claim (kind:47001) asserting an execution was correct.

This is what makes a settlement contestable rather than self-declared. Crucible
weighs answers by independent witnesses, so a VM cannot ratify its own output by
asserting it more often.

Crucible rejects a claim with no falsifier at parse time, so this throws rather
than emitting one that will bounce at the relay.
"""
function execution_claim(; pubkey, statement, falsifier, job_id,
                         half_life_secs = 86400, created_at = nothing)
    isempty(falsifier) && error(
        "a Crucible claim requires a falsifier; Crucible rejects claims without one")
    content = string(
        "{",
        _json_string("statement"), ":", _json_string(statement), ",",
        _json_string("falsifier"), ":", _json_string(falsifier), ",",
        _json_string("job_id"), ":", _json_string(job_id), ",",
        _json_string("half_life_secs"), ":", half_life_secs,
        "}",
    )
    build_unsigned_event(
        pubkey = pubkey,
        kind = KIND_CLAIM,
        content = content,
        tags = [["falsifier", falsifier], ["job", job_id],
                ["half_life", string(half_life_secs)]],
        created_at = created_at,
    )
end

end # module NostrBridge
