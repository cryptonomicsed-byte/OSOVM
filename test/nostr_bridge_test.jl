# Tests for the OSOVM <-> Nostr wire adapter.
#
# Run: julia --project=. test/nostr_bridge_test.jl
#
# The first test is the load-bearing one. A NIP-01 id is sha256 over canonical
# JSON and the signature is over that id, so if this module's escaping drifts
# from every other implementation's, OSOVM's events are rejected everywhere and
# nothing else in this file would notice.

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using Test

include(joinpath(@__DIR__, "..", "src", "nostr_bridge.jl"))

using .NostrBridge

const PUBKEY = repeat("a", 64)

@testset "NostrBridge" begin

    @testset "canonical serialization agrees across languages" begin
        # Pinned against the value independently computed in Rust, in
        # JavaScript, and in Python with ensure_ascii=False. Python's DEFAULT
        # (ensure_ascii=True) yields
        # f5ceda251451b3571736436644e34ca50eca23ad68ea3e067934e5f8668c2337
        # instead -- that is the bug this vector exists to catch.
        id = event_id(
            pubkey = PUBKEY,
            created_at = 1700000000,
            kind = 30174,
            tags = Vector{Vector{String}}(),
            content = "Òrìṣà Ògún",
        )
        @test id == "e24b148552d35adf425c92e2e701ee3be6b4c86dbfd5fa2cc84a4c922250ac3b"
    end

    @testset "non-ASCII is emitted raw, never \\u-escaped" begin
        serial = canonical_serialize(
            pubkey = PUBKEY, created_at = 1700000000, kind = 30174,
            tags = Vector{Vector{String}}(), content = "Òrìṣà Ògún",
        )
        @test occursin("Òrìṣà Ògún", serial)
        @test !occursin("\\u00", serial)
    end

    @testset "canonical form has NIP-01 field order and no whitespace" begin
        serial = canonical_serialize(
            pubkey = PUBKEY, created_at = 1700000000, kind = 30174,
            tags = [["d", "abc"]], content = "x",
        )
        @test serial == "[0,\"$PUBKEY\",1700000000,30174,[[\"d\",\"abc\"]],\"x\"]"
    end

    @testset "the required escapes are applied" begin
        serial = canonical_serialize(
            pubkey = PUBKEY, created_at = 1, kind = 30174,
            tags = Vector{Vector{String}}(), content = "a\"b\\c\nd\te",
        )
        @test occursin("a\\\"b\\\\c\\nd\\te", serial)
    end

    @testset "control characters below 0x20 use \\u00XX" begin
        serial = canonical_serialize(
            pubkey = PUBKEY, created_at = 1, kind = 30174,
            tags = Vector{Vector{String}}(), content = "a\x01b",
        )
        @test occursin("\\u0001", serial)
    end

    @testset "id changes when any signed field changes" begin
        base = (pubkey = PUBKEY, created_at = 1700000000, kind = 30174,
                tags = Vector{Vector{String}}(), content = "x")
        id = event_id(; base...)
        @test id != event_id(; base..., content = "y")
        @test id != event_id(; base..., created_at = 1700000001)
        @test id != event_id(; base..., kind = 47001)
        @test id != event_id(; base..., tags = [["d", "a"]])
    end

    @testset "every kind OSOVM emits is publishable" begin
        @test is_publishable(KIND_AGENT_ENGRAM)
        @test is_publishable(KIND_CLAIM)
        @test is_publishable(KIND_AUTH)
        # The failure this guard exists to prevent: a plausible custom kind
        # the relay drops after auth succeeds, which reads as an auth problem.
        @test !is_publishable(31337)
    end

    @testset "is_publishable does not claim the relay rejects other kinds" begin
        # The relay accepts far more than OSOVM emits -- kind 1, 7, 30023,
        # 30315 and much of Buzz's vocabulary. false here means "not ours",
        # never "refused". Conflating the two sent an earlier draft of this
        # module into over-restricting, so this pins the distinction.
        @test !is_publishable(7)
        @test !is_publishable(1)
    end

    @testset "an unadmitted kind is refused before an event is built" begin
        @test_throws ErrorException build_unsigned_event(
            pubkey = PUBKEY, kind = 31337, content = "{}")
    end

    @testset "a malformed pubkey is refused" begin
        @test_throws ErrorException build_unsigned_event(
            pubkey = "nope", kind = KIND_CLAIM, content = "{}")
        @test_throws ErrorException build_unsigned_event(
            pubkey = repeat("z", 64), kind = KIND_CLAIM, content = "{}")
    end

    @testset "an unsigned event is complete except for sig" begin
        ev = build_unsigned_event(
            pubkey = PUBKEY, kind = KIND_CLAIM, content = "{}", created_at = 1700000000)
        for f in ("id", "pubkey", "created_at", "kind", "tags", "content")
            @test haskey(ev, f)
        end
        # OSOVM holds no keys and must not fabricate a signature.
        @test !haskey(ev, "sig")
        @test ev["id"] == event_id(
            pubkey = ev["pubkey"], created_at = ev["created_at"], kind = ev["kind"],
            tags = ev["tags"], content = ev["content"])
    end

    @testset "an execution engram carries the d and p tags NIP-AE requires" begin
        record = execution_record(
            job_id = "job-1", opcode_count = 42,
            state_root = repeat("f", 64), deterministic = true,
            ase_minted = 7, veil = "Ògún")
        ev = execution_engram(
            pubkey = PUBKEY, record = record, owner_pubkey = PUBKEY,
            d_tag = "deadbeef", created_at = 1700000000)

        names = [t[1] for t in ev["tags"]]
        @test "d" in names
        @test "p" in names
        @test ev["kind"] == KIND_AGENT_ENGRAM
        @test occursin("\"job_id\":\"job-1\"", ev["content"])
        @test occursin("\"deterministic\":true", ev["content"])
    end

    @testset "an engram refuses a raw slug in place of an HMACd d tag" begin
        # minipae hashes the slug so a relay operator cannot enumerate what an
        # agent stores. OSOVM has no key to compute the HMAC, so omitting it
        # must fail loudly rather than silently leak.
        record = execution_record(
            job_id = "j", opcode_count = 1, state_root = "x", deterministic = true)
        @test_throws ErrorException execution_engram(
            pubkey = PUBKEY, record = record, owner_pubkey = PUBKEY)
    end

    @testset "slug is namespaced to osovm" begin
        @test startswith(slug_execution("job-1"), "mem/osovm/")
    end

    @testset "a claim without a falsifier is refused rather than emitted" begin
        # Crucible rejects such a claim at parse time; failing here gives a
        # clear error instead of a silent bounce at the relay.
        @test_throws ErrorException execution_claim(
            pubkey = PUBKEY, statement = "s", falsifier = "", job_id = "j")
    end

    @testset "an execution claim is a Crucible claim carrying its falsifier" begin
        ev = execution_claim(
            pubkey = PUBKEY,
            statement = "job-1 executed deterministically",
            falsifier = "sha256:abc",
            job_id = "job-1",
            created_at = 1700000000)
        @test ev["kind"] == KIND_CLAIM
        @test any(t -> t[1] == "falsifier" && t[2] == "sha256:abc", ev["tags"])
        @test occursin("\"half_life_secs\":86400", ev["content"])
    end

    @testset "a Yoruba veil name does not desynchronise the id" begin
        # The record body goes through the same explicit escaping as the event,
        # so diacritics in domain data cannot produce an id other readers
        # disagree with.
        record = execution_record(
            job_id = "j", opcode_count = 1, state_root = "x",
            deterministic = true, veil = "Ọ̀rúnmìlà")
        ev = execution_engram(
            pubkey = PUBKEY, record = record, owner_pubkey = PUBKEY,
            d_tag = "abc", created_at = 1700000000)
        @test occursin("Ọ̀rúnmìlà", ev["content"])
        @test !occursin("\\u", ev["content"])
        @test ev["id"] == event_id(
            pubkey = ev["pubkey"], created_at = ev["created_at"], kind = ev["kind"],
            tags = ev["tags"], content = ev["content"])
    end
end
