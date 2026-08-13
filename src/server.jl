#!/usr/bin/env julia
# server.jl — Real HTTP server for Ọ̀ṢỌ́ VM
#
# Closes the gap flagged in the ecosystem-alignment orchestration:
# "OSOVM has no server. It's a CLI, not a service." Every other pillar
# (Omo-Koda2 :7777, Vantage :8001, Zàngbétò :8787) is a running daemon
# with an HTTP surface; OSOVM's only prior door was organism-core's
# rlm-osovm.ts shelling out locally to `julia cli.jl` on the same box.
# This is the network-reachable endpoint that didn't exist.
#
# Unlike cli.jl (which creates a brand-new, single-instruction VM per
# process invocation and then discards it), this server holds VM
# instances IN MEMORY across calls, keyed by vm_id. That's a deliberate,
# necessary difference: almost every opcode cluster built this session
# (Quadrinity Government's PROPOSAL->VOTE->EXECUTION, Economic
# Extensions' COLLATERAL->LOAN->REPAYMENT, etc.) depends on sequential
# calls against the SAME VM state. A stateless one-shot-per-request
# server would be unable to run any of those real invariant chains --
# a caller couldn't vote on a proposal it created in a prior call.
#
# Usage: julia --project=. src/server.jl [port]
# Default port 7778 (adjacent to Omo-Koda2's kernel on 7777).

using HTTP
using JSON
using SHA

include("oso_vm.jl")
using .OsoVM

const PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 7778

# vm_id => VMState. Guarded by VM_LOCK since HTTP.jl serves requests on
# multiple tasks; without a lock, two concurrent requests against the
# same vm_id could race on the underlying Dict mutations inside
# execute_instruction (a real, not hypothetical, concern -- Julia's
# Dicts are not thread-safe for concurrent writes).
const VM_REGISTRY = Dict{String, OsoVM.VMState}()
const VM_LOCK = ReentrantLock()

# ============ Identity Registry ============
# Closes gap #3 from the ecosystem-alignment orchestration (round 3):
# "No shared identity registry across the four pillars." After this
# session's work, there are FOUR separate keypair spaces with zero
# cross-reference: Witness-firmware nodes (secp256k1 NIP-shaped + RNS
# Ed25519), Omo-Koda2 agents (BIPON39-seed-derived), Vantage accounts
# (its own registration), and OSOVM/Sui wallets. There was no table,
# contract, or service anywhere that answered "given this Witness
# node's pubkey, which Omo-Koda2 agent does it vouch for, and which Sui
# wallet gets paid." This is that table.
#
# One canonical identity, N pillar-native IDs linked to it. The
# canonical ID is derived the same way BIPON_SEED (opcode 0x26) already
# derives child addresses -- sha256(seed:path) -- so a canonical
# identity here is the SAME kind of deterministic derivation already
# real elsewhere in this VM, not a new ad hoc ID scheme.
#
# canonical_id => {seed, path, pillars: {pillar_name => pillar_native_id}}
const IDENTITY_REGISTRY = Dict{String, Dict{String, Any}}()
# "pillar:pillar_id" => canonical_id, for O(1) reverse lookup and to
# enforce the real invariant that a given pillar-native ID can only
# ever be linked to ONE canonical identity (prevents identity confusion
# / hijack -- without this, two different canonical identities could
# both claim to speak for the same Witness node's pubkey).
const IDENTITY_REVERSE = Dict{String, String}()
const IDENTITY_LOCK = ReentrantLock()

function json_response(status::Int, body::Dict)
    return HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(body))
end

function error_response(status::Int, message::String)
    return json_response(status, Dict("status" => "error", "error" => message))
end

# ============ Handlers ============

function handle_health(req::HTTP.Request)
    return json_response(200, Dict(
        "status" => "ok",
        "service" => "OSOVM",
        "active_vms" => length(VM_REGISTRY),
    ))
end

function handle_create_vm(req::HTTP.Request)
    body = Dict{String, Any}()
    if !isempty(req.body)
        try
            body = JSON.parse(String(req.body))
        catch e
            return error_response(400, "invalid JSON body: $(sprint(showerror, e))")
        end
    end

    council = get(body, "council", String[])
    final_signer = get(body, "final_signer", "genesis")

    vm = OsoVM.create_vm(council=Vector{String}(council), final_signer=final_signer)

    # vm_id derived from a real random source (Julia's default RNG,
    # OS-entropy-seeded) + current time, hashed -- not sequential/
    # guessable, matching the same "don't hand out predictable IDs"
    # principle used for wallet/agent addressing elsewhere in the VM.
    vm_id = bytes2hex(sha256("$(rand(UInt64)):$(time_ns())"))[1:32]

    lock(VM_LOCK) do
        VM_REGISTRY[vm_id] = vm
    end

    return json_response(201, Dict("vm_id" => vm_id, "final_signer" => final_signer, "council" => council))
end

function handle_execute(req::HTTP.Request, vm_id::String)
    local vm
    lock(VM_LOCK) do
        if !haskey(VM_REGISTRY, vm_id)
            vm = nothing
        else
            vm = VM_REGISTRY[vm_id]
        end
    end
    if vm === nothing
        return error_response(404, "unknown vm_id: $vm_id")
    end

    local task_data
    try
        task_data = JSON.parse(String(req.body))
    catch e
        return error_response(400, "invalid JSON body: $(sprint(showerror, e))")
    end

    if !haskey(task_data, "opcode")
        return error_response(400, "missing required field: opcode")
    end

    agent_pubkey = get(task_data, "agent", "genesis")

    try
        opcode_sym = Symbol(task_data["opcode"])
        if !haskey(OsoVM.Opcodes.OPCODE_MAP, opcode_sym)
            return error_response(400, "unknown opcode: $(task_data["opcode"])")
        end
        opcode_val = OsoVM.Opcodes.OPCODE_MAP[opcode_sym]

        task_args = Dict{Symbol, Any}()
        if haskey(task_data, "args")
            for (k, v) in task_data["args"]
                task_args[Symbol(k)] = v
            end
        end

        # Same success/failure derivation as cli.jl -- kept identical so
        # a caller migrating from the CLI to this server sees the same
        # contract, not a different one to relearn.
        result = lock(VM_LOCK) do
            vm.current_sender = agent_pubkey
            instr = OsoVM.OsoCompiler.Instruction(opcode_val, task_args)
            OsoVM.execute_instruction(vm, instr)
        end

        ok = true
        if result isa AbstractDict
            if haskey(result, "success") && result["success"] == false
                ok = false
            elseif haskey(result, "error") && !isempty(string(get(result, "error", "")))
                ok = false
            end
        end

        output = Dict(
            "vm_id" => vm_id,
            "vm_task_hash" => "vm-hash-" * string(hash(String(req.body))),
            "status" => ok ? "success" : "failed",
            "vm_result" => result,
            "sender_balance" => get(vm.ase_balance, agent_pubkey, 0.0),
        )
        return json_response(ok ? 200 : 422, output)

    catch e
        # Same JSON-serialization safety as cli.jl's catch block: never
        # put the raw exception or a Vector{StackFrame} in the response
        # body -- both contain non-JSON-serializable Julia internals and
        # would crash a second time inside this handler.
        return json_response(500, Dict(
            "status" => "error",
            "error" => sprint(showerror, e),
            "stacktrace" => [string(frame) for frame in stacktrace(catch_backtrace())],
        ))
    end
end

function handle_get_vm(req::HTTP.Request, vm_id::String)
    local vm
    lock(VM_LOCK) do
        vm = get(VM_REGISTRY, vm_id, nothing)
    end
    if vm === nothing
        return error_response(404, "unknown vm_id: $vm_id")
    end
    return json_response(200, Dict(
        "vm_id" => vm_id,
        "final_signer" => vm.final_signer,
        "block_height" => vm.block_height,
        "block_time" => vm.block_time,
        "chain_id" => vm.chain_id,
        "halted" => vm.halted,
        "ase_balances" => vm.ase_balance,
    ))
end

# ============ Identity Registry handlers ============

function handle_create_identity(req::HTTP.Request)
    body = Dict{String, Any}()
    if !isempty(req.body)
        try
            body = JSON.parse(String(req.body))
        catch e
            return error_response(400, "invalid JSON body: $(sprint(showerror, e))")
        end
    end

    seed = get(body, "seed", "")
    path = get(body, "path", "")
    (isempty(seed) || isempty(path)) && return error_response(400, "seed and path required")

    # Same derivation as BIPON_SEED (opcode 0x26): sha256(seed:path).
    # Deterministic on purpose -- registering the same seed+path twice
    # returns the SAME canonical_id rather than minting a duplicate
    # identity, matching BIPON_SEED's own dedupe-by-path invariant.
    canonical_id = bytes2hex(sha256("$seed:$path"))

    lock(IDENTITY_LOCK) do
        if !haskey(IDENTITY_REGISTRY, canonical_id)
            IDENTITY_REGISTRY[canonical_id] = Dict{String, Any}(
                "seed" => seed, "path" => path, "pillars" => Dict{String, String}(),
            )
        end
    end

    return json_response(201, Dict("canonical_id" => canonical_id))
end

function handle_link_identity(req::HTTP.Request, canonical_id::String)
    local entry
    lock(IDENTITY_LOCK) do
        entry = get(IDENTITY_REGISTRY, canonical_id, nothing)
    end
    if entry === nothing
        return error_response(404, "unknown canonical_id: $canonical_id")
    end

    local body
    try
        body = JSON.parse(String(req.body))
    catch e
        return error_response(400, "invalid JSON body: $(sprint(showerror, e))")
    end

    pillar = get(body, "pillar", "")
    pillar_id = get(body, "pillar_id", "")
    (isempty(pillar) || isempty(pillar_id)) && return error_response(400, "pillar and pillar_id required")

    reverse_key = "$pillar:$pillar_id"

    result = lock(IDENTITY_LOCK) do
        # The real invariant: this pillar-native ID must not already be
        # linked to a DIFFERENT canonical identity. Without this check,
        # two agents could both claim the same Witness node's pubkey (or
        # the same Sui wallet), which is exactly the identity-confusion
        # failure mode this registry exists to prevent.
        if haskey(IDENTITY_REVERSE, reverse_key) && IDENTITY_REVERSE[reverse_key] != canonical_id
            return Dict("error" => "already linked to a different canonical_id: $(IDENTITY_REVERSE[reverse_key])", "success" => false)
        end
        existing_pillar_id = get(entry["pillars"], pillar, "")
        if !isempty(existing_pillar_id) && existing_pillar_id != pillar_id
            return Dict("error" => "canonical_id already has a different $pillar link: $existing_pillar_id", "success" => false)
        end
        entry["pillars"][pillar] = pillar_id
        IDENTITY_REVERSE[reverse_key] = canonical_id
        return Dict("canonical_id" => canonical_id, "pillar" => pillar, "pillar_id" => pillar_id, "success" => true)
    end

    ok = get(result, "success", false)
    return json_response(ok ? 200 : 409, result)
end

function handle_get_identity(req::HTTP.Request, canonical_id::String)
    local entry
    lock(IDENTITY_LOCK) do
        entry = get(IDENTITY_REGISTRY, canonical_id, nothing)
    end
    if entry === nothing
        return error_response(404, "unknown canonical_id: $canonical_id")
    end
    return json_response(200, Dict(
        "canonical_id" => canonical_id,
        "pillars" => entry["pillars"],
    ))
end

function handle_lookup_identity(req::HTTP.Request)
    query = HTTP.URIs.queryparams(HTTP.URI(req.target))
    pillar = get(query, "pillar", "")
    pillar_id = get(query, "pillar_id", "")
    (isempty(pillar) || isempty(pillar_id)) && return error_response(400, "pillar and pillar_id query params required")

    reverse_key = "$pillar:$pillar_id"
    local canonical_id, entry
    lock(IDENTITY_LOCK) do
        canonical_id = get(IDENTITY_REVERSE, reverse_key, nothing)
        entry = canonical_id === nothing ? nothing : IDENTITY_REGISTRY[canonical_id]
    end
    if canonical_id === nothing
        return error_response(404, "no canonical identity linked to $pillar:$pillar_id")
    end
    return json_response(200, Dict(
        "canonical_id" => canonical_id,
        "pillars" => entry["pillars"],
    ))
end

# ============ Router ============

function router(req::HTTP.Request)
    method = req.method
    path = HTTP.URI(req.target).path
    parts = split(strip(path, '/'), '/')

    try
        if method == "GET" && path == "/v1/health"
            return handle_health(req)
        elseif method == "POST" && path == "/v1/vm"
            return handle_create_vm(req)
        elseif method == "GET" && length(parts) == 3 && parts[1] == "v1" && parts[2] == "vm"
            return handle_get_vm(req, String(parts[3]))
        elseif method == "POST" && length(parts) == 4 && parts[1] == "v1" && parts[2] == "vm" && parts[4] == "execute"
            return handle_execute(req, String(parts[3]))
        elseif method == "POST" && path == "/v1/identity"
            return handle_create_identity(req)
        elseif method == "GET" && path == "/v1/identity/lookup"
            return handle_lookup_identity(req)
        elseif method == "GET" && length(parts) == 3 && parts[1] == "v1" && parts[2] == "identity"
            return handle_get_identity(req, String(parts[3]))
        elseif method == "POST" && length(parts) == 4 && parts[1] == "v1" && parts[2] == "identity" && parts[4] == "link"
            return handle_link_identity(req, String(parts[3]))
        else
            return error_response(404, "no such route: $method $path")
        end
    catch e
        return json_response(500, Dict(
            "status" => "error",
            "error" => "unhandled server error: $(sprint(showerror, e))",
        ))
    end
end

function main()
    println("[OSOVM Server] Starting on 0.0.0.0:$PORT")
    println("[OSOVM Server] Routes:")
    println("  GET  /v1/health")
    println("  POST /v1/vm                    -- create a persistent VM instance")
    println("  GET  /v1/vm/{vm_id}             -- inspect VM state")
    println("  POST /v1/vm/{vm_id}/execute     -- execute one instruction against it")
    println("  POST /v1/identity               -- create/derive a canonical identity (seed+path)")
    println("  GET  /v1/identity/lookup         -- reverse lookup by pillar+pillar_id")
    println("  GET  /v1/identity/{canonical_id} -- get all pillar links for a canonical identity")
    println("  POST /v1/identity/{canonical_id}/link -- link a pillar-native ID to it")
    HTTP.serve(router, "0.0.0.0", PORT)
end

main()
