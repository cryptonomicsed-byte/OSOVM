#!/usr/bin/env julia
# cli.jl — CLI wrapper for Ọ̀ṢỌ́ VM
# Usage: julia cli.jl --task '{"opcode": "COUNCIL_APPROVE", "args": {"agent": "0x123"}}' --agent "shrine-01"

using JSON
include("oso_vm.jl")
using .OsoVM

function main()
    args = ARGS
    task_json = ""
    agent_pubkey = "genesis"

    # Simple arg parsing
    for i in 1:length(args)
        if args[i] == "--task" && i < length(args)
            task_json = args[i+1]
        elseif args[i] == "--agent" && i < length(args)
            agent_pubkey = args[i+1]
        end
    end

    if isempty(task_json)
        println(JSON.json(Dict("error" => "No task provided via --task")))
        exit(1)
    end

    try
        # 1. Parse task
        task_data = JSON.parse(task_json)
        opcode_sym = Symbol(task_data["opcode"])
        # OPCODE_MAP is CORE_OPCODES merged with EXPANSION_OPCODES -- looking
        # up CORE_OPCODES alone (the previous bug) silently threw KeyError
        # for every opcode defined only in EXPANSION_OPCODES (PROJECT, JOB,
        # CASTING, VOTE, PROPOSAL, etc. -- the whole work-economy and
        # governance opcode clusters).
        opcode_val = OsoVM.Opcodes.OPCODE_MAP[opcode_sym]
        task_args = Dict{Symbol, Any}()
        if haskey(task_data, "args")
            for (k, v) in task_data["args"]
                task_args[Symbol(k)] = v
            end
        end

        # 2. Initialize VM
        vm = OsoVM.create_vm()
        vm.current_sender = agent_pubkey
        instr = OsoVM.OsoCompiler.Instruction(opcode_val, task_args)

        # 3. Execute
        result = OsoVM.execute_instruction(vm, instr)

        # 4. Derive a real status from the actual result, instead of
        # unconditionally reporting success. Most real handlers signal
        # failure via a truthy "error" key or an explicit "success"=>false;
        # opcodes with neither (HALT, NOOP, EMIT, ...) succeed by nature.
        ok = true
        if result isa AbstractDict
            if haskey(result, "success") && result["success"] == false
                ok = false
            elseif haskey(result, "error") && !isempty(string(get(result, "error", "")))
                ok = false
            end
        end

        # f1_score/ase_minted were previously hardcoded to 95.0/10.0 on
        # every call regardless of what actually happened -- dropped in
        # favor of vm_result (the real per-opcode outcome) plus the
        # sender's real post-execution balance, which is honest and
        # meaningful across all opcodes rather than fabricated for most.
        output = Dict(
            "vm_task_hash" => "vm-hash-" * string(hash(task_json)),
            "status" => ok ? "success" : "failed",
            "vm_result" => result,
            "sender_balance" => get(vm.ase_balance, agent_pubkey, 0.0),
        )
        println(JSON.json(output))
        exit(ok ? 0 : 1)

    catch e
        # Previously included the raw exception + a Vector{StackFrame} in
        # the error Dict -- both contain non-JSON-serializable Julia
        # internals (Module/Method/MethodInstance objects), so a real
        # error (e.g. the KeyError this was masking) crashed a SECOND time
        # inside the error handler itself with an unrelated, more
        # confusing "cannot serialize Module Base as JSON" error.
        println(JSON.json(Dict(
            "status" => "error",
            "error" => sprint(showerror, e),
            "stacktrace" => [string(frame) for frame in stacktrace(catch_backtrace())],
        )))
        exit(1)
    end
end

main()
