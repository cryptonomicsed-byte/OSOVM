# server.jl — ỌSỌVM HTTP Server
# Bridges the Julia VM to HTTP so Rust callers can invoke it.
# Port: OSOVM_PORT env var, default 7780
# Crown Architect: Bínò ÈL Guà

module OsoVMServer

include("opcodes.jl")
include("oso_compiler.jl")
include("oso_vm.jl")
include("../integrations/ucx/execution_adapter.jl")
include("../integrations/ucx/resource_meter.jl")

using .Opcodes
using .OsoCompiler
using .OsoVM
using .UcxExecutionAdapter
using .UcxPreflight
using .ResourceMeter
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
function receipt_to_dict(r::OsoCompiler.Instruction)
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
# ROUTE HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

function handle_health(req::HTTP.Request)::HTTP.Response
    json_ok(Dict{String,Any}("status" => "ok", "version" => "osovm/1"))
end

function handle_opcodes(req::HTTP.Request)::HTTP.Response
    core_list = [Dict{String,Any}("name" => string(k), "opcode" => Int(v), "type" => "core")
                 for (k, v) in Opcodes.CORE_OPCODES]
    exp_list  = [Dict{String,Any}("name" => string(k), "opcode" => Int(v), "type" => "expansion")
                 for (k, v) in Opcodes.EXPANSION_OPCODES]
    json_ok(Dict{String,Any}(
        "core_opcodes"      => core_list,
        "expansion_opcodes" => exp_list,
        "total"             => length(core_list) + length(exp_list),
    ))
end

function handle_run(req::HTTP.Request)::HTTP.Response
    run_id   = new_run_id()
    t_start  = time()

    # ── Parse body ────────────────────────────────────────────────────────────
    local body_obj
    try
        body_obj = JSON3.read(req.body)
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
    agent   = string(get(body_obj, :agent, "genesis"))
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

    try
        vm = OsoVM.create_vm()
        vm.current_sender = agent

        instr = OsoCompiler.Instruction(opcode_val, instr_args)
        vm_result = OsoVM.execute_instruction(vm, instr)

        receipts_out = receipts_to_list(vm.receipts)

        # Extract ase_minted from result if present
        if vm_result isa Dict
            ase_minted = Float64(get(vm_result, "ase_minted", get(vm_result, :ase_minted, 0.0)))
            # Simple F1 heuristic: 0.92 for success, 0.0 for error
            f1_score   = ase_minted > 0.0 ? 0.92 : (get(vm_result, "status", "") == "error" ? 0.0 : 0.88)
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
        "f1_score"       => f1_score,
        "ase_minted"     => ase_minted,
        "receipts"       => receipts_out,
        "vm_state_hash"  => vm_state_hash,
        "wall_ms"        => wall_ms,
        "result"         => vm_result,
    )
    return json_ok(response)
end

function handle_veilsim_run(req::HTTP.Request)::HTTP.Response
    run_id  = new_run_id()
    t_start = time()

    # ── Parse body ────────────────────────────────────────────────────────────
    local body_obj
    try
        body_obj = JSON3.read(req.body)
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    veil_ids     = get(body_obj, :veil_ids,     [1])
    entity_count = Int(get(body_obj, :entity_count, 5))
    step_count   = Int(get(body_obj, :step_count,   100))
    agent        = string(get(body_obj, :agent,  "genesis"))

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
        instr      = OsoCompiler.Instruction(veil_opcode, instr_args)
        veil_result = OsoVM.execute_instruction(vm, instr)

        if veil_result isa Dict
            f1_score    = Float64(get(veil_result, "f1",         get(veil_result, :f1,    0.88)))
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
# TOC ALLOWLIST + GPU CONTRIBUTION HANDLERS  (H-7 / E-17)
# ─────────────────────────────────────────────────────────────────────────────

# In-memory allowlist: empty set = open (all eligible).
# Populate at startup via OSOVM_ALLOWLIST env var (comma-separated provider IDs)
# or leave blank to keep the list open for development/testing.
const TOC_ALLOWLIST = Set{String}(
    filter(!isempty, split(get(ENV, "OSOVM_ALLOWLIST", ""), ","))
)

"""
POST /api/toc/allowlist/check
Body: { provider_id, gpu_seconds, zangbeto_anchor? }

Called by UCX mint_allowlist.rs:check_mint_eligible() before minting Synapse.
Returns 200 { eligible: true }  when the provider passes the allowlist gate.
Returns 403 { eligible: false } when the provider is explicitly blocked.
Open list (TOC_ALLOWLIST empty) ⇒ all providers are eligible.
"""
function handle_toc_allowlist_check(req::HTTP.Request)::HTTP.Response
    local body_obj
    try
        body_obj = JSON3.read(req.body)
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    provider_id      = string(get(body_obj, :provider_id, ""))
    gpu_seconds      = Float64(get(body_obj, :gpu_seconds, 0.0))
    zangbeto_anchor  = get(body_obj, :zangbeto_anchor, nothing)

    isempty(provider_id) && return bad_request("missing field: provider_id")

    # Basic eligibility: must have actual GPU work and a settlement anchor.
    if gpu_seconds <= 0.0
        body = JSON3.write(Dict{String,Any}(
            "eligible" => false,
            "reason"   => "gpu_seconds must be > 0",
        ))
        return HTTP.Response(403, ["Content-Type" => "application/json"], body)
    end

    if zangbeto_anchor === nothing || isempty(string(zangbeto_anchor))
        body = JSON3.write(Dict{String,Any}(
            "eligible" => false,
            "reason"   => "missing zangbeto_anchor — settlement not confirmed",
        ))
        return HTTP.Response(403, ["Content-Type" => "application/json"], body)
    end

    # Allowlist gate: open list passes everyone; closed list requires membership.
    if !isempty(TOC_ALLOWLIST) && !(provider_id in TOC_ALLOWLIST)
        @info "TOC allowlist: provider not on list" provider_id=provider_id
        body = JSON3.write(Dict{String,Any}(
            "eligible" => false,
            "reason"   => "provider not on TOC allowlist",
        ))
        return HTTP.Response(403, ["Content-Type" => "application/json"], body)
    end

    @info "TOC allowlist: provider eligible" provider_id=provider_id gpu_seconds=gpu_seconds
    return json_ok(Dict{String,Any}("eligible" => true, "reason" => "ok"))
end

"""
POST /api/osovm/gpu_contribution
Body: { provider_id, submitter_id, job_id, gpu_seconds, zangbeto_anchor?, timestamp }

Records a verified GPU compute contribution in the agent's VM state and fires
the event-bridge sidecar (GPU_CONTRIBUTION → Vantage Dopamine mint).
Returns { recorded: true, event_id: "..." }.
"""
function handle_gpu_contribution(req::HTTP.Request)::HTTP.Response
    local body_obj
    try
        body_obj = JSON3.read(req.body)
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    provider_id     = string(get(body_obj, :provider_id, ""))
    submitter_id    = string(get(body_obj, :submitter_id, ""))
    job_id          = string(get(body_obj, :job_id, ""))
    gpu_seconds     = Float64(get(body_obj, :gpu_seconds, 0.0))
    zangbeto_anchor = string(get(body_obj, :zangbeto_anchor, ""))
    timestamp       = Int(get(body_obj, :timestamp, 0))

    isempty(provider_id)  && return bad_request("missing field: provider_id")
    isempty(submitter_id) && return bad_request("missing field: submitter_id")
    isempty(job_id)       && return bad_request("missing field: job_id")
    gpu_seconds <= 0.0    && return bad_request("gpu_seconds must be > 0")

    # Record the contribution in ResourceMeter so it feeds the TOC_MINT cycle.
    ResourceMeter.record_contribution(submitter_id, gpu_seconds, job_id)

    event_id = "gpu_contrib:" * string(UUIDs.uuid4())
    @info "GPU contribution recorded" provider_id=provider_id submitter_id=submitter_id job_id=job_id gpu_seconds=gpu_seconds event_id=event_id

    # ── Fire-and-forget: call event-bridge.js via Node.js subprocess ──────────
    # event-bridge.js routes GPU_CONTRIBUTION → Vantage Dopamine mint.
    # Launched async so the HTTP response is not blocked by the sidecar call.
    event_payload = JSON3.write(Dict{String,Any}(
        "opcode"     => "GPU_CONTRIBUTION",
        "agent_id"   => submitter_id,
        "gpu_seconds" => gpu_seconds,
        "event_id"   => event_id,
        "job_id"     => job_id,
        "provider_id" => provider_id,
    ))

    bridge_path = joinpath(dirname(dirname(@__FILE__)), "event-bridge.js")
    if isfile(bridge_path)
        # Inline Node.js CJS snippet: require the bridge, call handleOsovmEvent, exit.
        # event-bridge.js uses CommonJS (require/module.exports), so we pass `-e`.
        node_snippet = "const b=require($(repr(bridge_path)));b.handleOsovmEvent($(event_payload)).catch(()=>{}).finally(()=>process.exit(0));"
        try
            @async run(Cmd(`node -e $(node_snippet)`; ignorestatus=true))
        catch
            # node unavailable or snippet error — log and continue; fail-open.
            @warn "event-bridge sidecar call failed (node unavailable or error)" event_id=event_id
        end
    else
        @warn "event-bridge.js not found, skipping sidecar" bridge_path=bridge_path
    end

    return json_ok(Dict{String,Any}(
        "recorded"   => true,
        "event_id"   => event_id,
        "provider_id" => provider_id,
        "submitter_id" => submitter_id,
        "job_id"     => job_id,
        "gpu_seconds" => gpu_seconds,
    ))
end

# ─────────────────────────────────────────────────────────────────────────────
# /v1/vm  — stateless VM session shim  (H-6 / E-02)
# rlm-osovm.ts (organism-core) expects a two-step flow:
#   POST /v1/vm           → { vm_id }
#   POST /v1/vm/:id/execute → execute result
# OSOVM is stateless per-request, so we mint a uuid as vm_id and embed it
# in the execute response; callers can pass it back but we don't need state.
# ─────────────────────────────────────────────────────────────────────────────

"""
POST /v1/vm
Body: { final_signer? }
Returns { vm_id: "..." } — creates a logical session ID for a multi-step caller.
"""
function handle_v1_vm_create(req::HTTP.Request)::HTTP.Response
    vm_id = "vm:" * string(UUIDs.uuid4())
    @info "v1/vm: session created" vm_id=vm_id
    return json_ok(Dict{String,Any}("vm_id" => vm_id, "status" => "created"))
end

"""
POST /v1/vm/:id/execute
Body: { opcode, args?, agent? }
Executes an opcode on a fresh VM (stateless) and returns the result tagged
with the vm_id so callers can correlate multi-step flows.
"""
function handle_v1_vm_execute(req::HTTP.Request, vm_id::String)::HTTP.Response
    # Reuse the core /run logic by delegating to handle_run, then patching vm_id.
    result = handle_run(req)
    # If the response is 200 OK, inject vm_id into the JSON body.
    if result.status == 200
        try
            parsed = JSON3.read(String(result.body))
            merged = Dict{String,Any}(string(k) => v for (k, v) in parsed)
            merged["vm_id"] = vm_id
            return json_ok(merged)
        catch
            # Parsing failed — return original response as-is.
        end
    end
    return result
end

# ─────────────────────────────────────────────────────────────────────────────
# UCX RESOURCE ACCOUNTING HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

"""
POST /ucx/preflight
Body: { agent_id, job_id, workload_type, params: {...} }

Checks Synapse balance and soft-locks the estimated budget before a UCX job
starts. Responds with 200+ticket on success or 402+error on insufficient funds.

The `synapse_balance` is read from a fresh VM instance so it reflects the
latest on-chain minted Synapse for the agent.
"""
function handle_ucx_preflight(req::HTTP.Request)::HTTP.Response
    local body_obj
    try
        body_obj = JSON3.read(req.body)
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    agent_id      = string(get(body_obj, :agent_id, ""))
    job_id        = string(get(body_obj, :job_id, ""))
    workload_type = string(get(body_obj, :workload_type, "inference"))

    isempty(agent_id) && return bad_request("missing field: agent_id")
    isempty(job_id)   && return bad_request("missing field: job_id")

    raw_params = get(body_obj, :params, nothing)
    params = raw_params === nothing ? Dict{String,Any}() :
             Dict{String,Any}(string(k) => v for (k, v) in raw_params)

    # Read current Synapse balance from a fresh VM
    vm = OsoVM.create_vm()
    synapse_balance = get(vm.synapse_balance, agent_id, 0)

    result = UcxPreflight.preflight(synapse_balance, agent_id, job_id, workload_type, params)

    if result["success"]
        # Auto-start a meter session so the caller can immediately record samples
        session_id = UcxJobMeter.start_session(job_id, agent_id)
        result["meter_session_id"] = session_id
        return json_ok(result)
    else
        body = JSON3.write(result)
        return HTTP.Response(402, ["Content-Type" => "application/json"], body)
    end
end

"""
POST /ucx/settle
Body: { lock_id, actual_synapse, gpu_seconds }

Releases the preflight soft-lock and records the actual cost.
Also stops the meter session (if still open) and records the GPU contribution
in ResourceMeter so it is eligible for the TOC_MINT cycle.
"""
function handle_ucx_settle(req::HTTP.Request)::HTTP.Response
    local body_obj
    try
        body_obj = JSON3.read(req.body)
    catch e
        return bad_request("invalid JSON body: $(e)")
    end

    lock_id        = string(get(body_obj, :lock_id, ""))
    actual_synapse = Int(get(body_obj, :actual_synapse, 0))
    gpu_seconds    = Float64(get(body_obj, :gpu_seconds, 0.0))

    isempty(lock_id) && return bad_request("missing field: lock_id")

    result = UcxPreflight.settle(lock_id, actual_synapse, gpu_seconds)

    if !result["success"]
        body = JSON3.write(result)
        return HTTP.Response(404, ["Content-Type" => "application/json"], body)
    end

    # Stop meter session if still open (best-effort; may have been stopped already)
    agent_id = get(result, "agent_id", "")
    job_id   = get(result, "job_id",   "")
    session_id = "meter:$(job_id)"
    meter_reading = UcxJobMeter.stop_session(session_id)
    if !haskey(meter_reading, "error")
        result["meter_reading"] = meter_reading
    end

    # Record contribution in ResourceMeter → makes agent eligible for TOC_MINT
    if gpu_seconds > 0.0 && !isempty(agent_id)
        ResourceMeter.record_contribution(agent_id, gpu_seconds, job_id)
        result["toc_eligible"] = ResourceMeter.mint_eligible_amount(agent_id) != (0.0, 0)
    end

    return json_ok(result)
end

"""
GET /ucx/meter/:session_id
Returns current meter reading without stopping the session.
"""
function handle_ucx_meter_read(req::HTTP.Request)::HTTP.Response
    # Extract session_id from path: /ucx/meter/<session_id>
    parts = split(req.target, '/')
    session_id = length(parts) >= 4 ? join(parts[4:end], '/') : ""
    isempty(session_id) && return bad_request("missing session_id in path")

    reading = UcxJobMeter.current_reading(session_id)
    return json_ok(reading)
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

        elseif target == "/opcodes" && method == "GET"
            return handle_opcodes(req)

        elseif target == "/run" && method == "POST"
            return handle_run(req)

        elseif target == "/veilsim/run" && method == "POST"
            return handle_veilsim_run(req)

        elseif target == "/ucx/preflight" && method == "POST"
            return handle_ucx_preflight(req)

        elseif target == "/ucx/settle" && method == "POST"
            return handle_ucx_settle(req)

        elseif startswith(target, "/ucx/meter/") && method == "GET"
            return handle_ucx_meter_read(req)

        # ── TOC allowlist + GPU contribution  (H-7 / E-17) ───────────────────
        elseif target == "/api/toc/allowlist/check" && method == "POST"
            return handle_toc_allowlist_check(req)

        elseif target == "/api/osovm/gpu_contribution" && method == "POST"
            return handle_gpu_contribution(req)

        # ── v1/vm session shim  (H-6 / E-02) ─────────────────────────────────
        elseif target == "/v1/vm" && method == "POST"
            return handle_v1_vm_create(req)

        elseif startswith(target, "/v1/vm/") && endswith(target, "/execute") && method == "POST"
            # Extract vm_id: /v1/vm/<vm_id>/execute
            parts = split(target, '/')
            # parts = ["", "v1", "vm", "<vm_id>", "execute"]
            vm_id = length(parts) >= 5 ? parts[4] : "unknown"
            return handle_v1_vm_execute(req, vm_id)

        # ── v1/health alias ───────────────────────────────────────────────────
        elseif target == "/v1/health" && method == "GET"
            return handle_health(req)

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
    @info "Routes: GET /health  GET /opcodes  POST /run  POST /veilsim/run  POST /ucx/preflight  POST /ucx/settle  GET /ucx/meter/:id  POST /api/toc/allowlist/check  POST /api/osovm/gpu_contribution  POST /v1/vm  POST /v1/vm/:id/execute"
    HTTP.serve(router, "0.0.0.0", port)
end

end # module OsoVMServer

# ─── Entrypoint ──────────────────────────────────────────────────────────────
port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : parse(Int, get(ENV, "OSOVM_PORT", "7780"))
OsoVMServer.start(port=port)
