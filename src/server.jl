# server.jl — ỌSỌVM HTTP Server
# Bridges the Julia VM to HTTP so Rust callers can invoke it.
# Port: OSOVM_PORT env var, default 7780
# Crown Architect: Bínò ÈL Guà

module OsoVMServer

include("opcodes.jl")
include("oso_compiler.jl")
include("oso_vm.jl")
include("../integrations/ucx/resource_meter.jl")   # UcxJobMeter (meter read)

using .Opcodes
using .OsoCompiler
using .OsoVM
using .UcxJobMeter

using HTTP
using JSON3
using SHA
using Dates
using UUIDs

export start

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

"""Return SHA-256 hex digest of any JSON3-serialisable value."""
function sha256hex(val)::String
    bytes = Vector{UInt8}(JSON3.write(val))
    return bytes2hex(SHA.sha256(bytes))
end

"""Generate a unique run_id."""
new_run_id()::String = "run:" * string(UUIDs.uuid4())

"""
Resolve opcode string → UInt8.
Returns (opcode::UInt8, error_msg::Union{Nothing,String}).
"""
function resolve_opcode(opcode_str::String)
    sym = Symbol(uppercase(opcode_str))
    if haskey(Opcodes.CORE_OPCODES, sym)
        return Opcodes.CORE_OPCODES[sym], nothing
    elseif haskey(Opcodes.EXPANSION_OPCODES, sym)
        return Opcodes.EXPANSION_OPCODES[sym], nothing
    else
        return UInt8(0x00), "unknown opcode: $opcode_str"
    end
end

"""
Convert a JSON3 object/value to Dict{Symbol,Any} recursively.
"""
function to_sym_dict(obj)::Dict{Symbol,Any}
    d = Dict{Symbol,Any}()
    for (k, v) in obj
        d[Symbol(k)] = _convert_val(v)
    end
    return d
end

_convert_val(v::JSON3.Object) = to_sym_dict(v)
_convert_val(v::JSON3.Array)  = [_convert_val(x) for x in v]
_convert_val(v)               = v

"""Serialise receipts to plain dicts for JSON response."""
function receipt_to_dict(r::OsoVM.OsoCompiler.Instruction)
    Dict{String,Any}(
        "opcode" => Int(r.opcode),
        "args"   => Dict(string(k) => v for (k, v) in r.args),
    )
end

# OsoVM.VMState receipts are Strings (hashes), not Instruction structs.
receipts_to_list(v::Vector{String}) = v
receipts_to_list(v)                 = collect(string.(v))

"""JSON 500 error helper."""
function error_response(run_id::String, msg::String)
    body = JSON3.write(Dict{String,Any}(
        "status" => "error",
        "error"  => msg,
        "run_id" => run_id,
    ))
    return HTTP.Response(500, ["Content-Type" => "application/json"], body)
end

"""JSON 400 error helper."""
function bad_request(msg::String)
    body = JSON3.write(Dict{String,Any}("status" => "error", "error" => msg))
    return HTTP.Response(400, ["Content-Type" => "application/json"], body)
end

"""JSON 200 helper."""
json_ok(payload) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))

# ─────────────────────────────────────────────────────────────────────────────
# AUTHENTICATION  (I-38 / I-39) — restored after the 8b88bca rewrite deleted it
# ─────────────────────────────────────────────────────────────────────────────

# Shared secret for server-to-server calls.  Set OSOVM_API_KEY in production.
const OSOVM_API_KEY = get(ENV, "OSOVM_API_KEY", "")

"""
Authenticate an incoming request.  Returns `(agent_id, nothing)` on success or
`("", error_string)` on failure.  Fails closed: an unset OSOVM_API_KEY rejects
every request rather than admitting anyone.

Token format (both accepted):
  `Authorization: Bearer <api_key>|<agent_id>`   — explicit identity (preferred)
  `Authorization: Bearer <api_key>`              — bare key (Vantage client
    compat); identity defaults to the X-Agent-Id header, else "vantage".
The verified `agent_id` becomes `vm.current_sender` (I-39 — the caller cannot
choose the credited identity by submitting an :agent body field).
"""
function authenticate(req::HTTP.Request)
    if isempty(OSOVM_API_KEY)
        return "", "OSOVM_API_KEY not configured — authentication required; set OSOVM_API_KEY env var"
    end
    auth_header = HTTP.header(req, "Authorization", "")
    if isempty(auth_header)
        return "", "missing Authorization header (Bearer <api_key>|<agent_id>)"
    end
    if !startswith(lowercase(auth_header), "bearer ")
        return "", "Authorization must be a Bearer token"
    end
    token = strip(SubString(auth_header, 8))
    pipe  = findfirst('|', token)
    if isnothing(pipe)
        # Bare key — Vantage's osovm_client.py sends `Bearer {key}` with no
        # identity suffix; fall back to the X-Agent-Id header, else "vantage".
        key      = token
        agent_id = HTTP.header(req, "X-Agent-Id", "vantage")
    else
        key      = String(SubString(token, 1, pipe - 1))
        agent_id = String(SubString(token, pipe + 1))
    end
    if key != OSOVM_API_KEY
        return "", "invalid API key"
    end
    if isempty(agent_id)
        return "", "agent_id must be non-empty in token"
    end
    return agent_id, nothing
end

"""HTTP 401 helper."""
function unauthorized(msg::String)
    body = JSON3.write(Dict{String,Any}("status" => "error", "error" => msg))
    return HTTP.Response(401, ["Content-Type" => "application/json",
                               "WWW-Authenticate" => "Bearer"], body)
end

# ─────────────────────────────────────────────────────────────────────────────
# ROUTE HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

function handle_health(req::HTTP.Request)::HTTP.Response
    json_ok(Dict{String,Any}("status" => "ok", "version" => "osovm/1"))
end

# handle_opcodes removed (I-42): GET /opcodes enumerated every mint-capable
# opcode name to unauthenticated callers.  The lookup table lives in opcodes.jl
# for internal use; it is not served over HTTP.  (Restored after the 8b88bca
# rewrite re-added it.)

# HTTP.jl hands the handler a BytesBody, not the raw Vector{UInt8}; JSON3.read
# has no method for it, which made every POST fail with a MethodError. Coerce
# once, here, rather than at each call site.
function _req_body_bytes(req::HTTP.Request)
    b = req.body
    return b isa AbstractVector{UInt8} ? b : Vector{UInt8}(b)
end


function handle_run(req::HTTP.Request)::HTTP.Response
    run_id   = new_run_id()
    t_start  = time()

    # ── Authenticate — agent identity comes from the verified token (I-38/I-39) ─
    agent, auth_err = authenticate(req)
    if auth_err !== nothing
        return unauthorized(auth_err)
    end

    # ── Parse body ────────────────────────────────────────────────────────────
    local body_obj
    try
        body_obj = JSON3.read(String(_req_body_bytes(req)))
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    opcode_str = get(body_obj, :opcode, nothing)
    if opcode_str === nothing
        return bad_request("missing field: opcode")
    end
    opcode_str = string(opcode_str)

    # ── Validate opcode ────────────────────────────────────────────────────────
    opcode_val, opcode_err = resolve_opcode(opcode_str)
    if opcode_err !== nothing
        body = JSON3.write(Dict{String,Any}(
            "status" => "error",
            "error"  => opcode_err,
            "run_id" => run_id,
        ))
        return HTTP.Response(400, ["Content-Type" => "application/json"], body)
    end

    # ── Build instruction args ─────────────────────────────────────────────────
    # (:agent body field is ignored — identity comes from the auth token above.)
    raw_args = get(body_obj, :args, nothing)
    instr_args = if raw_args !== nothing
        to_sym_dict(raw_args)
    else
        Dict{Symbol,Any}()
    end

    # ── Execute on fresh VM (stateless per request) ────────────────────────────
    local vm_result
    local receipts_out
    local ase_minted::Float64 = 0.0
    local f1_score::Float64   = 0.0
    local f1_produced::Bool   = false

    try
        vm = OsoVM.create_vm()
        vm.current_sender = agent

        # OsoVM.OsoCompiler is the instance the VM's own method signature
        # binds to; the plain `OsoCompiler` here is a different module
        # instance (server.jl includes oso_compiler.jl independently), and
        # its Instruction is a distinct type -> MethodError on dispatch.
        instr = OsoVM.OsoCompiler.Instruction(opcode_val, instr_args)
        vm_result = OsoVM.execute_instruction(vm, instr)

        receipts_out = receipts_to_list(vm.receipts)

        # Extract ase_minted from result if present. No fabricated f1 (I-44):
        # f1_score is omitted unless the opcode actually produced one.
        if vm_result isa Dict
            ase_minted = Float64(get(vm_result, "ase_minted", get(vm_result, :ase_minted, 0.0)))
            f1_from_result = get(vm_result, "f1_score", get(vm_result, :f1_score, nothing))
            if f1_from_result !== nothing
                f1_score    = Float64(f1_from_result)
                f1_produced = true
            end
        end

    catch e
        @warn "OSOVM /run execution error" opcode=opcode_str agent=agent error=string(e)
        return error_response(run_id, string(e))
    end

    wall_ms = round(Int, (time() - t_start) * 1000)

    # ── State hash ────────────────────────────────────────────────────────────
    vm_state_hash = "sha256:" * sha256hex(vm_result)

    @info "OSOVM /run" opcode=opcode_str agent=agent wall_ms=wall_ms

    response = Dict{String,Any}(
        "status"         => "ok",
        "run_id"         => run_id,
        "opcode"         => opcode_str,
        "ase_minted"     => ase_minted,
        "receipts"       => receipts_out,
        "vm_state_hash"  => vm_state_hash,
        "wall_ms"        => wall_ms,
        "result"         => vm_result,
    )
    # I-44: omit rather than default — a 0.0 would write a measurement-named
    # field with a literal.
    if f1_produced
        response["f1_score"] = f1_score
    end
    return json_ok(response)
end

function handle_veilsim_run(req::HTTP.Request)::HTTP.Response
    run_id  = new_run_id()
    t_start = time()

    # ── Authenticate (I-38/I-39) ──────────────────────────────────────────────
    agent, auth_err = authenticate(req)
    if auth_err !== nothing
        return unauthorized(auth_err)
    end

    # ── Parse body ────────────────────────────────────────────────────────────
    local body_obj
    try
        body_obj = JSON3.read(String(_req_body_bytes(req)))
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    veil_ids     = get(body_obj, :veil_ids,     [1])
    entity_count = Int(get(body_obj, :entity_count, 5))
    step_count   = Int(get(body_obj, :step_count,   100))

    # ── Execute VEIL on fresh VM ───────────────────────────────────────────────
    # Measurements come only from what the VEIL produced (I-44). An absent value
    # is absent -- listed in "unmeasured" -- never a literal. 8b88bca had
    # defaulted robustness to 0.95 and energy_drift to 0.02, so every receipt
    # carried fabricated good measurements.
    local measured = Dict{String,Float64}()
    local receipt_data::Dict{String,Any} = Dict{String,Any}()

    try
        vm  = OsoVM.create_vm()
        vm.current_sender = agent

        veil_opcode = Opcodes.CORE_OPCODES[:VEIL]  # 0x12
        instr_args  = Dict{Symbol,Any}(
            :id           => isempty(veil_ids) ? 1 : Int(first(veil_ids)),
            :entity_count => entity_count,
            :step_count   => step_count,
        )
        instr      = OsoVM.OsoCompiler.Instruction(veil_opcode, instr_args)
        veil_result = OsoVM.execute_instruction(vm, instr)

        if veil_result isa AbstractDict
            for (out, keys) in (("f1_score", ("f1", :f1, "f1_score", :f1_score)),
                                ("energy_drift", ("energy_drift", :energy_drift)),
                                ("robustness", ("robustness", :robustness)))
                for k in keys
                    v = get(veil_result, k, nothing)
                    if v isa Real
                        measured[out] = Float64(v); break
                    end
                end
            end
        end

        receipt_data = Dict{String,Any}(
            "receipt_id"    => "zr:" * string(UUIDs.uuid4()),
            "sim_id"        => run_id,
            "veil_ids"      => collect(Int, veil_ids),
            "entity_count"  => entity_count,
            "step_count"    => step_count,
            "timestamp"     => string(now()),
        )
        merge!(receipt_data, measured)

    catch e
        @warn "OSOVM /veilsim/run error" agent=agent error=string(e)
        return error_response(run_id, string(e))
    end

    wall_ms = round(Int, (time() - t_start) * 1000)
    @info "OSOVM /veilsim/run" agent=agent veil_ids=string(veil_ids) entity_count=entity_count wall_ms=wall_ms

    response = Dict{String,Any}(
        "status"       => "ok",
        "run_id"       => run_id,
        "receipt"      => receipt_data,
        "unmeasured"   => [k for k in ("f1_score", "energy_drift", "robustness") if !haskey(measured, k)],
        "wall_ms"      => wall_ms,
    )
    merge!(response, measured)
    return json_ok(response)
end

# ─────────────────────────────────────────────────────────────────────────────
# RESTORED ROUTES (deleted by 8b88bca, 2026-11-04, in a commit titled as a
# one-line MethodError fix). Vantage calls /v1/tier-sync at startup and
# /v1/tier-update on every tier change (backend/osovm_client.py); both had
# returned 404 since. They had also never worked before that: they called
# parse_json_body, which no version of this file ever defined, so every call
# threw UndefVarError -> 500. test/server_handlers_test.jl covers all of them.
#
# Restored as they were: tier-sync, tier-update, the /v1/vm shim, meter read.
# Restored FAIL-CLOSED: gpu_contribution, ucx/settle, ucx/preflight and the TOC
# allowlist. As written they let an authenticated caller self-report
# gpu_seconds into the Synapse TOC_MINT cycle (and a Dopamine mint via the
# event bridge) against an anchor that was only checked for being non-empty --
# a caller-priced mint (I-12/I-13) -- and the allowlist was open when empty.
# They validate input (400 on bad requests) and then refuse with the reason.
# No live caller uses any of the four.
# ─────────────────────────────────────────────────────────────────────────────

"""Parse a JSON request body; `nothing` when it is not valid JSON."""
function parse_json_body(req::HTTP.Request)
    try
        return JSON3.read(_req_body_bytes(req))
    catch
        return nothing
    end
end

refused(status::Int, msg::String) = HTTP.Response(status, ["Content-Type" => "application/json"],
    JSON3.write(Dict{String,Any}("status" => "refused", "error" => msg)))

const _UNVERIFIED_MINT_INPUT = "self-reported gpu_seconds cannot feed a mint: the zangbeto anchor is not " *
    "verified by any code path (I-12/I-13). Route compute proofs through COMPUTE_PROOF (0x56)."

# Closed by default: an empty list now admits nobody (it used to admit everybody).
const TOC_ALLOWLIST = Set{String}(filter(!isempty, split(get(ENV, "OSOVM_ALLOWLIST", ""), ",")))

"""POST /api/toc/allowlist/check  Body: { provider_id, gpu_seconds, zangbeto_anchor }"""
function handle_toc_allowlist_check(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req); b === nothing && return bad_request("invalid JSON body")
    provider_id = string(get(b, :provider_id, ""))
    isempty(provider_id) && return bad_request("missing field: provider_id")
    no(reason) = HTTP.Response(403, ["Content-Type" => "application/json"],
                               JSON3.write(Dict{String,Any}("eligible" => false, "reason" => reason)))
    isempty(TOC_ALLOWLIST) && return no("allowlist not configured (OSOVM_ALLOWLIST is empty): closed by default")
    provider_id in TOC_ALLOWLIST || return no("provider not on TOC allowlist")
    Float64(get(b, :gpu_seconds, 0.0)) > 0 || return no("gpu_seconds must be > 0")
    isempty(string(something(get(b, :zangbeto_anchor, nothing), ""))) && return no("missing zangbeto_anchor")
    return json_ok(Dict{String,Any}("eligible" => true, "reason" => "ok"))
end

"""POST /api/osovm/gpu_contribution — validates, then refuses (see header)."""
function handle_gpu_contribution(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req); b === nothing && return bad_request("invalid JSON body")
    for f in (:provider_id, :submitter_id, :job_id)
        isempty(string(get(b, f, ""))) && return bad_request("missing field: $f")
    end
    Float64(get(b, :gpu_seconds, 0.0)) > 0 || return bad_request("gpu_seconds must be > 0")
    return refused(501, _UNVERIFIED_MINT_INPUT)
end

"""POST /v1/vm — logical session id for multi-step callers (rlm-osovm.ts).
The VM is stateless per request; the id only correlates responses."""
function handle_v1_vm_create(req::HTTP.Request)::HTTP.Response
    return json_ok(Dict{String,Any}("vm_id" => "vm:" * string(UUIDs.uuid4()), "status" => "created"))
end

"""POST /v1/vm/:id/execute — /run on a fresh VM, tagged with vm_id."""
function handle_v1_vm_execute(req::HTTP.Request, vm_id::String)::HTTP.Response
    result = handle_run(req)
    result.status == 200 || return result
    try
        merged = Dict{String,Any}(string(k) => v for (k, v) in JSON3.read(String(copy(result.body))))
        merged["vm_id"] = vm_id
        return json_ok(merged)
    catch
        return result
    end
end

"""POST /ucx/preflight — validates, then refuses: the Synapse balance it checks
was read from a fresh VM, so it was always 0 and every job got a 402. Needs a
persistent balance store (plan B2)."""
function handle_ucx_preflight(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req); b === nothing && return bad_request("invalid JSON body")
    isempty(string(get(b, :agent_id, ""))) && return bad_request("missing field: agent_id")
    isempty(string(get(b, :job_id, ""))) && return bad_request("missing field: job_id")
    return refused(501, "preflight needs a persistent Synapse balance; a fresh-per-request VM always reads 0 (plan B2)")
end

"""POST /ucx/settle — validates, then refuses (see header)."""
function handle_ucx_settle(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req); b === nothing && return bad_request("invalid JSON body")
    isempty(string(get(b, :lock_id, ""))) && return bad_request("missing field: lock_id")
    return refused(501, _UNVERIFIED_MINT_INPUT)
end

"""GET /ucx/meter/:session_id — read-only."""
function handle_ucx_meter_read(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    parts = split(req.target, '/')
    session_id = length(parts) >= 4 ? join(parts[4:end], '/') : ""
    isempty(session_id) && return bad_request("missing session_id in path")
    return json_ok(UcxJobMeter.current_reading(session_id))
end

_tier_or_nothing(t) = (t isa Integer || (t isa AbstractFloat && isinteger(t))) && 0 <= t <= 5 ? Int(t) : nothing

"""POST /v1/tier-sync  Body: [{agent_id, tier}, ...] or {entries: [...]}, max 10_000.
Replaces the tier registry (stale entries from a previous process are cleared)."""
function handle_tier_sync(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req)
    b === nothing && return bad_request("invalid JSON — expected array [{agent_id,tier}]")
    entries = b isa AbstractVector ? b :
              (b isa AbstractDict && haskey(b, :entries)) ? b[:entries] :
              return bad_request("body must be a JSON array or {\"entries\": [...]}")
    length(entries) > 10_000 && return bad_request("batch too large (max 10,000)")
    new_reg = Dict{String,Int}(); skipped = 0
    for item in entries
        aid = item isa AbstractDict ? get(item, :agent_id, nothing) : nothing
        t = item isa AbstractDict ? _tier_or_nothing(get(item, :tier, nothing)) : nothing
        # (was `aid === nothing || isempty(...) && continue`, which registered a
        # missing agent_id under the key "nothing")
        if aid === nothing || isempty(string(aid)) || t === nothing
            skipped += 1; continue
        end
        new_reg[string(aid)] = t
    end
    lock(OsoVM._TIER_REGISTRY_LOCK) do
        empty!(OsoVM._TIER_REGISTRY_GLOBAL); merge!(OsoVM._TIER_REGISTRY_GLOBAL, new_reg)
    end
    return json_ok(Dict{String,Any}("status" => "ok", "count" => length(new_reg), "skipped" => skipped))
end

"""POST /v1/tier-update  Body: {agent_id, tier (0-5)}"""
function handle_tier_update(req::HTTP.Request)::HTTP.Response
    agent, auth_err = authenticate(req)
    auth_err !== nothing && return unauthorized(auth_err)
    b = parse_json_body(req)
    (b === nothing || !(b isa AbstractDict)) && return bad_request("invalid JSON")
    aid = get(b, :agent_id, nothing)
    (aid === nothing || isempty(string(aid))) && return bad_request("agent_id required")
    haskey(b, :tier) || return bad_request("tier required")
    t = _tier_or_nothing(b[:tier]); t === nothing && return bad_request("tier must be an integer 0–5")
    lock(OsoVM._TIER_REGISTRY_LOCK) do
        OsoVM._TIER_REGISTRY_GLOBAL[string(aid)] = t
    end
    return json_ok(Dict{String,Any}("status" => "ok", "agent_id" => string(aid), "tier" => t))
end

# ─────────────────────────────────────────────────────────────────────────────
# ROUTER
# ─────────────────────────────────────────────────────────────────────────────

function router(req::HTTP.Request)::HTTP.Response
    method = req.method
    target = req.target

    try
        if target == "/health" && method == "GET"
            return handle_health(req)

        elseif target == "/run" && method == "POST"
            return handle_run(req)

        elseif target == "/veilsim/run" && method == "POST"
            return handle_veilsim_run(req)

        elseif target == "/v1/tier-sync" && method == "POST"
            return handle_tier_sync(req)

        elseif target == "/v1/tier-update" && method == "POST"
            return handle_tier_update(req)

        elseif target == "/v1/health" && method == "GET"
            return handle_health(req)

        elseif target == "/v1/vm" && method == "POST"
            return handle_v1_vm_create(req)

        elseif startswith(target, "/v1/vm/") && endswith(target, "/execute") && method == "POST"
            parts = split(target, '/')          # ["", "v1", "vm", "<id>", "execute"]
            return handle_v1_vm_execute(req, length(parts) >= 5 ? String(parts[4]) : "unknown")

        elseif target == "/ucx/preflight" && method == "POST"
            return handle_ucx_preflight(req)

        elseif target == "/ucx/settle" && method == "POST"
            return handle_ucx_settle(req)

        elseif startswith(target, "/ucx/meter/") && method == "GET"
            return handle_ucx_meter_read(req)

        elseif target == "/api/toc/allowlist/check" && method == "POST"
            return handle_toc_allowlist_check(req)

        elseif target == "/api/osovm/gpu_contribution" && method == "POST"
            return handle_gpu_contribution(req)

        else
            body = JSON3.write(Dict{String,Any}(
                "status" => "error",
                "error"  => "not found: $method $target",
            ))
            return HTTP.Response(404, ["Content-Type" => "application/json"], body)
        end
    catch e
        @error "OSOVM unhandled router error" method=method target=target error=string(e)
        body = JSON3.write(Dict{String,Any}(
            "status" => "error",
            "error"  => "internal server error: $(string(e))",
        ))
        return HTTP.Response(500, ["Content-Type" => "application/json"], body)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# START
# ─────────────────────────────────────────────────────────────────────────────

function start(; port::Int = parse(Int, get(ENV, "OSOVM_PORT", "7780")))
    @info "ỌSỌVM HTTP server starting" port=port
    @info "Routes: GET /health  POST /run  POST /veilsim/run"
    HTTP.serve(router, "0.0.0.0", port)
end

end # module OsoVMServer

# ─── Entrypoint ──────────────────────────────────────────────────────────────
# Only when run as the program (`julia --project=. src/server.jl 7780`, which is
# how the osovm unit starts it). Including this file -- the handler tests, or
# src/server_main.jl -- must not bind a port: it used to, so the tests died with
# EADDRINUSE next to the live service and server_main.jl's own start() was
# unreachable behind the blocking serve().
if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : parse(Int, get(ENV, "OSOVM_PORT", "7780"))
    OsoVMServer.start(port=port)
end
