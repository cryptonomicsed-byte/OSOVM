# nautilus_attestation.jl — verifiable off-chain compute attestation for
# OSOVM, for the real use case flagged in SEAL_WALRUS_NAUTILUS_MIGRATION.md:
# VeilSim's F1/PoSim scoring happens off-chain (in this Julia process); an
# attestation lets a downstream verifier (Zangbeto witnesses, an on-chain
# consumer) trust that a specific, known build of the scoring engine
# produced a given score, without re-running the simulation itself.
#
# Direct port of Omo-Koda2's real nautilus_integration::attestation
# pattern (same honesty level): checks a TEE quote's code measurement
# against an expected value and derives a key from the quote's own
# fields. Honest about what this verifies -- it checks that the code
# measurement matches (and thus binds the attestation to a specific,
# named build of the engine), but it does NOT verify a real hardware
# attestation signature (SGX/TDX/AWS Nitro) yet, since no real enclave is
# deployed anywhere in this ecosystem. Once one is, TeeQuote's fields come
# from that hardware and this module's call sites do not need to change --
# the seam is already correct, only the quote's provenance upgrades.

module NautilusAttestation

using SHA
using Dates

export TeeQuote, AttestationResult, F1Attestation
export verify_quote, code_measurement_of_engine, attest_f1_score

struct TeeQuote
    enclave_id::Vector{UInt8}        # 32 bytes
    code_measurement::Vector{UInt8}  # 32 bytes
    nonce::Vector{UInt8}             # 16 bytes
    signature::Vector{UInt8}
end

struct AttestationResult
    enclave_id::Vector{UInt8}
    seal_key::Vector{UInt8}
end

"""Verify a TEE quote's code measurement against `expected_measurement`
and derive a key from the quote's own fields. Throws on mismatch --
callers must not treat a caught error as a passing attestation.

Honest limitation (see module docstring): does not verify a real hardware
signature, since no real enclave is deployed. The measurement check and
key derivation are real and meaningful on their own -- they bind the
result to a specific claimed build -- but this is not yet cryptographic
proof of having run inside real trusted hardware."""
function verify_quote(tee_quote::TeeQuote, expected_measurement::Vector{UInt8})::AttestationResult
    tee_quote.code_measurement == expected_measurement ||
        error("code measurement mismatch: expected $(bytes2hex(expected_measurement)), got $(bytes2hex(tee_quote.code_measurement))")

    prefix = Vector{UInt8}(codeunits("osovm:nautilus:seal_key_v1"))
    seal_key = sha256(vcat(prefix, tee_quote.enclave_id, tee_quote.code_measurement))
    AttestationResult(tee_quote.enclave_id, seal_key)
end

"""SHA-256 of this module's own sibling file `veilsim_engine.jl` -- a real,
meaningful "code measurement" of the scoring engine that actually ran.
Recomputed at call time (not cached) so it always reflects the file
currently on disk, matching the whole point of a measurement: prove which
code produced the result."""
function code_measurement_of_engine(; engine_path::AbstractString=joinpath(@__DIR__, "veilsim_engine.jl"))::Vector{UInt8}
    isfile(engine_path) || error("veilsim_engine.jl not found at $engine_path")
    sha256(read(engine_path))
end

struct F1Attestation
    sim_id::String
    f1_score::Float64
    code_measurement::String   # hex
    enclave_id::String         # hex
    verified::Bool
    attested_at::DateTime
end

"""Attest that `f1_score` for `sim_id` was produced by the engine build
`quote.code_measurement` claims to be. `verified=false` (never thrown)
when the quote's measurement doesn't match the real, current engine file
-- callers get an honest, inspectable result rather than an exception to
route around."""
function attest_f1_score(sim_id::AbstractString, f1_score::Float64, tee_quote::TeeQuote)::F1Attestation
    expected = code_measurement_of_engine()
    verified = try
        verify_quote(tee_quote, expected)
        true
    catch
        false
    end
    F1Attestation(String(sim_id), f1_score, bytes2hex(tee_quote.code_measurement),
                  bytes2hex(tee_quote.enclave_id), verified, now())
end

end # module NautilusAttestation
