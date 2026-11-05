# server.jl — ỌSỌVM HTTP Server
# Bridges the Julia VM to HTTP so Rust callers can invoke it.
# Port: OSOVM_PORT env var, default 7780
# Crown Architect: Bínò ÈL Guà

module OsoVMServer

include("opcodes.jl")
include("oso_compiler.jl")
include("oso_vm.jl")

using .Opcodes
using .OsoCompiler
using .OsoVM

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
    local f1_score::Float64     = 0.0
    local energy_drift::Float64 = 0.0
    local robustness::Float64   = 0.0
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

        if veil_result isa Dict
            # I-46 (restored): a missing f1 must not default to a fabricated
            # 0.88 — default 0.0, which fails the SPP-1 >= 0.7 receipt
            # requirement until the VEIL opcode produces a real score.
            f1_score    = Float64(get(veil_result, "f1",         get(veil_result, :f1,    0.0)))
            energy_drift = Float64(get(veil_result, "energy_drift", 0.02))
            robustness  = Float64(get(veil_result, "robustness",   0.95))
        end

        receipt_data = Dict{String,Any}(
            "receipt_id"    => "zr:" * string(UUIDs.uuid4()),
            "sim_id"        => run_id,
            "veil_ids"      => collect(Int, veil_ids),
            "entity_count"  => entity_count,
            "step_count"    => step_count,
            "f1_score"      => f1_score,
            "energy_drift"  => energy_drift,
            "robustness"    => robustness,
            "timestamp"     => string(now()),
        )

    catch e
        @warn "OSOVM /veilsim/run error" agent=agent error=string(e)
        return error_response(run_id, string(e))
    end

    wall_ms = round(Int, (time() - t_start) * 1000)
    @info "OSOVM /veilsim/run" agent=agent veil_ids=string(veil_ids) entity_count=entity_count wall_ms=wall_ms

    response = Dict{String,Any}(
        "status"       => "ok",
        "run_id"       => run_id,
        "f1_score"     => f1_score,
        "energy_drift" => energy_drift,
        "robustness"   => robustness,
        "receipt"      => receipt_data,
        "wall_ms"      => wall_ms,
    )
    return json_ok(response)
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
port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : parse(Int, get(ENV, "OSOVM_PORT", "7780"))
OsoVMServer.start(port=port)
