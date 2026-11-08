# opcode_probe.jl — measure the live opcode table by EXECUTING it.
#
# Every byte 0x00-0xff is run once against a fresh VM through the same
# OsoVM.execute_instruction that server.jl's /run uses, with empty args.
# Each byte lands in exactly one class:
#
#   dispatched  a handler ran (including one that raised on the empty args --
#               raising on missing input is still the handler answering)
#   offloaded   not is_critical(): routed to call_ase_vault(), which fails closed
#   removed     an explicit "has been removed" rejection
#   unknown     reached the end of the dispatch chain ("unknown_opcode")
#
# Reading the source with regexes mis-counts this file (range branches like
# `opcode in 0x45:0x49`, cluster helpers, the is_critical() pre-route), which is
# how earlier counts disagreed. Execution is the measurement.
#
# Output: one JSON document on stdout. Logging goes to stderr.
#
#   julia --project=. tools/opcode_probe.jl > build/opcode_probe.json

using Logging
global_logger(SimpleLogger(stderr, Logging.Error))   # the probe trips @warn by design

include(joinpath(@__DIR__, "..", "src", "oso_vm.jl"))
using .OsoVM
using JSON3

const Instruction = OsoVM.OsoCompiler.Instruction

function classify(opcode::UInt8)
    vm = OsoVM.create_vm()
    local res
    try
        res = OsoVM.execute_instruction(vm, Instruction(opcode, Dict{Symbol,Any}()))
    catch e
        return ("dispatched", "raised: " * first(sprint(showerror, e), 160))
    end
    if res isa AbstractDict
        err = string(get(res, "error", ""))
        st  = string(get(res, "status", ""))
        occursin("has been removed", err)                 && return ("removed", err)
        err == "ase-vault offload not implemented"        && return ("offloaded", err)
        st == "unknown_opcode"                            && return ("unknown", st)
    end
    return ("dispatched", "")
end

names_for(b::UInt8) = [String(s) for s in get(OsoVM.Opcodes.OPCODE_REVERSE_ALL, b, Symbol[])]

rows = Vector{Dict{String,Any}}()
for b in 0x00:0xff
    cls, note = classify(UInt8(b))
    push!(rows, Dict(
        "byte"     => "0x" * string(b, base=16, pad=2),
        "names"    => names_for(UInt8(b)),
        "class"    => cls,
        "critical" => OsoVM.is_critical(UInt8(b)),
        "note"     => note,
    ))
end

JSON3.write(stdout, Dict(
    "source"   => "src/oso_vm.jl execute_instruction (the /run path)",
    "julia"    => string(VERSION),
    "bytes"    => rows,
))
println()
