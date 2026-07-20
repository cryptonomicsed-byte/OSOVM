# seal_bridge.jl — Sui Seal bridge for OSOVM receipts.
#
# Direct Julia port of Omo-Koda2's real seal_bridge.rs (same repo family,
# same verified `seal-cli fetch-keys` command shape). OSOVM's own
# architecture deliberately never does encryption itself (see
# glyphindex.jl's header comment: "the VM deliberately never touches
# decryption keys: it stores, serves, audits, and anchors ciphertext") --
# so this module's job is narrower than Omo-Koda2's: fetch a real DEK from
# Seal's decentralized key servers and fingerprint it (SHA-256), proving a
# real Seal consultation happened, without OSOVM ever holding or using the
# key to encrypt anything itself. Any actual field-level encryption stays
# the job of the identity-holding component, same division of labor as
# GlyphIndex.
#
# ## `seal-cli fetch-keys`'s real signature (verified against Mysten's
# `crates/seal-cli/src/main.rs` source, same verification Omo-Koda2's
# seal_bridge.rs already did):
#
#   seal-cli fetch-keys --request <HEX> -k <ids> -t <threshold> -n <network> [--rpc-url <url>]
#
# `fetch-keys` takes exactly one identity input: `--request`, a hex-encoded
# BCS-serialized `FetchKeyRequest` -- building that requires a signed
# session-key certificate the bare CLI cannot produce standalone. So, like
# Omo-Koda2's bridge, this is two real, separate, operator-configured
# steps rather than something faked here:
#
#   1. SEAL_REQUEST_CMD -- builds + signs the FetchKeyRequest, prints its
#      hex encoding to stdout.
#   2. SEAL_FETCH_CMD   -- the verified `seal-cli fetch-keys` invocation
#      above, with {request_hex}/{key_server_id}/{threshold}/{network}
#      substituted from step 1's output + config.
#
# Configuration (fail-open -- unset means "Seal not wired", never a crash):
#   SEAL_REQUEST_CMD     shell command that prints a hex-encoded, signed
#                        FetchKeyRequest to stdout
#   SEAL_FETCH_CMD       shell command template with the placeholders above
#   SEAL_KEY_SERVER_IDS  comma-separated key server object ids
#   SEAL_THRESHOLD       e.g. "2" for 2-of-3 (default "1")
#   SEAL_NETWORK         "testnet" | "mainnet" (default "testnet")

module SealBridge

using SHA

export SealConfig, config_from_env, build_fetch_command, fetch_dek_fingerprint, try_seal_fingerprint

struct SealConfig
    request_cmd::String
    fetch_cmd_template::String
    key_server_ids::Vector{String}
    threshold::String
    network::String
end

"""`nothing` = Seal not configured on this runtime; the caller should fall
back to SHA-256-only commitment, not fail."""
function config_from_env()::Union{SealConfig, Nothing}
    request_cmd = get(ENV, "SEAL_REQUEST_CMD", "")
    isempty(request_cmd) && return nothing
    fetch_cmd_template = get(ENV, "SEAL_FETCH_CMD", "")
    isempty(fetch_cmd_template) && return nothing
    key_server_ids = filter(!isempty, strip.(split(get(ENV, "SEAL_KEY_SERVER_IDS", ""), ",")))
    isempty(key_server_ids) && return nothing
    threshold = get(ENV, "SEAL_THRESHOLD", "1")
    network = get(ENV, "SEAL_NETWORK", "testnet")
    SealConfig(request_cmd, fetch_cmd_template, key_server_ids, threshold, network)
end

"""Substitute the verified `fetch-keys` placeholders in the config's
template with this fetch's real values. Pure -- testable without ever
shelling out."""
function build_fetch_command(config::SealConfig, request_hex::AbstractString)::String
    cmd = config.fetch_cmd_template
    cmd = replace(cmd, "{request_hex}" => request_hex)
    cmd = replace(cmd, "{key_server_id}" => join(config.key_server_ids, ","))
    cmd = replace(cmd, "{threshold}" => config.threshold)
    cmd = replace(cmd, "{network}" => config.network)
    cmd
end

"""Run a configured shell command, return its trimmed stdout bytes, or
error on nonzero exit / empty output. Shared by both real steps below."""
function _run_step(command::AbstractString, label::AbstractString)::Vector{UInt8}
    out = IOBuffer()
    proc = try
        run(pipeline(`sh -c $command`, stdout=out, stderr=devnull))
    catch e
        error("seal $label failed to spawn: $e")
    end
    stdout_bytes = take!(out)
    if isempty(stdout_bytes)
        error("seal $label command produced no output")
    end
    stdout_bytes
end

"""Fetch a real DEK from Seal's key servers via the two-step CLI pipeline,
and return its SHA-256 fingerprint (not the key itself -- OSOVM never
holds decryption keys, only proves a real Seal fetch occurred). Throws on
any failure; callers should catch and fall back to SHA-256-only
commitment (fail-open), never fake success."""
function fetch_dek_fingerprint(config::SealConfig)::String
    request_bytes = _run_step(config.request_cmd, "request-build")
    request_hex = strip(String(request_bytes))

    fetch_command = build_fetch_command(config, request_hex)
    fetch_output = _run_step(fetch_command, "fetch-keys")

    prefix = Vector{UInt8}(codeunits("osovm:seal_dek_fingerprint_v1"))
    bytes2hex(sha256(vcat(prefix, fetch_output)))
end

"""High-level entry point: `nothing` if Seal isn't configured (fail-open),
the fingerprint hex string if it is and the fetch succeeded, or throws if
configured-but-failing (a real misconfiguration, not silently swallowed)."""
function try_seal_fingerprint()::Union{String, Nothing}
    config = config_from_env()
    config === nothing && return nothing
    fetch_dek_fingerprint(config)
end

end # module SealBridge
