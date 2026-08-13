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
    HTTP.serve(router, "0.0.0.0", PORT)
end

main()
