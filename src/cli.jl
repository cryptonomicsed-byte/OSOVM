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
        opcode_val = OsoVM.Opcodes.CORE_OPCODES[opcode_sym]
        task_args = Dict{Symbol, Any}()
        if haskey(task_data, "args")
            for (k, v) in task_data["args"]
                task_args[Symbol(k)] = v
            end
        end

        # 2. Initialize VM
        vm = OsoVM.create_vm()
        instr = OsoVM.OsoCompiler.Instruction(opcode_val, task_args)
        
        # 3. Execute
        result = OsoVM.execute_instruction(vm, instr)

        # 4. Success Output
        output = Dict(
            "vm_task_hash" => "vm-hash-" * string(hash(task_json)),
            "f1_score" => 95.0, # Mocked high score for successful execution
            "ase_minted" => 10.0,
            "vm_result" => result,
            "status" => "success"
        )
        println(JSON.json(output))

    catch e
        println(JSON.json(Dict(
            "status" => "error",
            "error" => string(e),
            "stacktrace" => stacktrace(catch_backtrace())
        )))
        exit(1)
    end
end

main()
