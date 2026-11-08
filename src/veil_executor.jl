"""
    VeilExecutor - Runtime execution engine for veil operations
    
Executes veils via FFI dispatch, handles composition pipelines,
and integrates with osovm instruction dispatch.
"""

module VeilExecutor

include("veils_777.jl")
include("veil_index.jl")
include("opcodes_veil.jl")
include("veil_native.jl")

using .Veils777
using .VeilIndex
using .OpcodeVeil
using .VeilNative

export execute_veil, execute_veil_composition, execute_veil_conditional,
       load_ffi_implementation, veil_execution_context

# ============================================================================
# EXECUTION CONTEXT
# ============================================================================

"""Execution context for veil operations"""
mutable struct VeilExecutionContext
    veil_id::Int
    parameters::Dict{String, Any}
    input_data::Dict{String, Any}
    output::Union{Dict, Nothing}
    execution_time::Float64
    status::String  # "pending", "running", "success", "error"
    error_message::Union{String, Nothing}
    ffi_language::String
    opcode::UInt16
end

"""Create new execution context"""
function VeilExecutionContext(veil_id::Int, parameters::Dict, input_data::Dict)
    veil = lookup_veil(veil_id)
    if isnothing(veil)
        return VeilExecutionContext(veil_id, parameters, input_data, nothing, 0.0, 
                                   "error", "Veil $veil_id not found", "unknown", 0x0000)
    end
    
    return VeilExecutionContext(
        veil_id,
        parameters,
        input_data,
        nothing,
        0.0,
        "pending",
        nothing,
        veil.ffi_language,
        OpcodeVeil.get_veil_opcode(veil_id)
    )
end

# ============================================================================
# FFI IMPLEMENTATION LOADING
# ============================================================================

"""
FFI implementation registry - maps (language, veil_id) to implementation function
"""
const FFI_REGISTRY = Dict{Tuple{String, Int}, Function}()

"""
    register_ffi_implementation(language::String, veil_id::Int, impl::Function)

Register an FFI implementation for a veil.
"""
function register_ffi_implementation(language::String, veil_id::Int, impl::Function)
    FFI_REGISTRY[(language, veil_id)] = impl
end

"""
    load_ffi_implementation(language::String, veil_id::Int) -> Union{Function, Nothing}

Load FFI implementation for a veil.
Returns Julia wrapper function or nothing if not available.
"""
function load_ffi_implementation(language::String, veil_id::Int)::Union{Function, Nothing}
    # Check registry first
    if haskey(FFI_REGISTRY, (language, veil_id))
        return FFI_REGISTRY[(language, veil_id)]
    end
    
    isnothing(lookup_veil(veil_id)) && return nothing
    # Native Julia implementation (src/veil_native.jl). Used whatever backend the
    # catalog names, because no Rust/Python veil backend exists; the output is
    # tagged so callers can see which ran.
    return get(VeilNative.NATIVE_VEILS, veil_id, nothing)
end

# There is deliberately no stub. A veil with no implementation is an error
# ("No implementation available ..."), never status="success" with placeholder
# output -- the old stub did exactly that for all 777 veils.

# ============================================================================
# VEIL EXECUTION
# ============================================================================

"""
    execute_veil(veil_id::Int, parameters::Dict = Dict(), 
                 input_data::Dict = Dict()) -> VeilExecutionContext

Execute a single veil with given parameters and input.
"""
function execute_veil(veil_id::Int, parameters::Dict = Dict(), 
                     input_data::Dict = Dict())::VeilExecutionContext
    
    context = VeilExecutionContext(veil_id, parameters, input_data)
    
    # Validate veil exists
    if isnothing(lookup_veil(veil_id))
        context.status = "error"
        context.error_message = "Veil $veil_id not found in catalog"
        return context
    end
    
    # Mark as running
    context.status = "running"
    start_time = time()
    
    try
        # Load FFI implementation
        impl = load_ffi_implementation(context.ffi_language, veil_id)
        
        if isnothing(impl)
            context.status = "error"
            context.error_message = "No implementation available for veil $veil_id ($(context.ffi_language))"
            context.execution_time = time() - start_time
            return context
        end
        
        # Execute implementation
        result = impl(context.parameters, context.input_data)
        result isa AbstractDict || error("veil $veil_id implementation returned $(typeof(result)), not a Dict")
        result = Dict{String,Any}(result)
        if !haskey(FFI_REGISTRY, (context.ffi_language, veil_id))
            result["implementation"] = "julia-native"
            result["catalog_backend"] = context.ffi_language
        end
        context.output = result
        context.status = "success"
        context.execution_time = time() - start_time
        
        return context
        
    catch err
        context.status = "error"
        context.error_message = err isa ArgumentError ? err.msg : sprint(showerror, err)
        context.execution_time = time() - start_time
        return context
    end
end

"""
    execute_veil_composition(veil_sequence::Vector{Int}, 
                            initial_input::Dict = Dict()) -> Dict

Execute a pipeline of veils, passing output of one as input to next.
"""
execute_veil_composition(veil_sequence::Vector{Int}, initial_input::Dict = Dict())::Dict =
    execute_veil_composition(veil_sequence, Dict{String,Any}(), initial_input)

# `parameters` configure the FIRST veil only; every later veil gets the previous
# veil's output as its input and its own defaults (parameters are per-veil, and
# reusing PID gains as Kalman noise would be meaningless).
function execute_veil_composition(veil_sequence::Vector{Int}, parameters::Dict,
                                  initial_input::Dict)::Dict
    
    if isempty(veil_sequence)
        return Dict("error" => "Empty veil sequence")
    end
    
    # Validate all veils exist
    for veil_id in veil_sequence
        if isnothing(lookup_veil(veil_id))
            return Dict("error" => "Veil $veil_id not found in composition")
        end
    end
    
    # Execute composition
    composition_result = Dict(
        "type" => "veil_composition",
        "veil_sequence" => veil_sequence,
        "steps" => VeilExecutionContext[],
        "total_time" => 0.0,
        "final_output" => nothing,
        "status" => "success"
    )
    
    current_output = initial_input
    start_time = time()
    
    for (idx, veil_id) in enumerate(veil_sequence)
        # Execute veil with previous output as input
        context = execute_veil(veil_id, idx == 1 ? parameters : Dict(), current_output)
        push!(composition_result["steps"], context)
        
        # Check for error
        if context.status == "error"
            composition_result["status"] = "error"
            composition_result["error"] = context.error_message
            break
        end
        
        # Use output as next input
        if !isnothing(context.output)
            current_output = context.output
        end
    end
    
    composition_result["total_time"] = time() - start_time
    composition_result["final_output"] = current_output
    
    return composition_result
end

"""
    execute_veil_conditional(condition::Bool, veil_id_true::Int, 
                            veil_id_false::Union{Int, Nothing} = nothing,
                            parameters::Dict = Dict()) -> VeilExecutionContext

Conditional veil execution based on boolean condition.
"""
function execute_veil_conditional(condition::Bool, veil_id_true::Int, 
                                 veil_id_false::Union{Int, Nothing} = nothing,
                                 parameters::Dict = Dict())::VeilExecutionContext
    
    if condition
        return execute_veil(veil_id_true, parameters)
    elseif !isnothing(veil_id_false)
        return execute_veil(veil_id_false, parameters)
    else
        context = VeilExecutionContext(0, Dict(), Dict())
        context.status = "skipped"
        context.output = Dict("message" => "Condition false, no else veil")
        return context
    end
end

# ============================================================================
# EXECUTION STATISTICS & MONITORING
# ============================================================================

"""Track execution metrics"""
mutable struct ExecutionMetrics
    total_executions::Int
    successful::Int
    failed::Int
    total_execution_time::Float64
    average_execution_time::Float64
    by_veil::Dict{Int, Dict}
    by_language::Dict{String, Dict}
end

"""Global execution metrics"""
const EXECUTION_METRICS = ExecutionMetrics(0, 0, 0, 0.0, 0.0, Dict(), Dict())

"""
    record_execution(context::VeilExecutionContext)

Record execution metrics.
"""
function record_execution(context::VeilExecutionContext)
    EXECUTION_METRICS.total_executions += 1
    
    if context.status == "success"
        EXECUTION_METRICS.successful += 1
    else
        EXECUTION_METRICS.failed += 1
    end
    
    EXECUTION_METRICS.total_execution_time += context.execution_time
    EXECUTION_METRICS.average_execution_time = 
        EXECUTION_METRICS.total_execution_time / EXECUTION_METRICS.total_executions
    
    # Record by veil
    if !haskey(EXECUTION_METRICS.by_veil, context.veil_id)
        EXECUTION_METRICS.by_veil[context.veil_id] = Dict(
            "count" => 0,
            "successful" => 0,
            "total_time" => 0.0
        )
    end
    
    stats = EXECUTION_METRICS.by_veil[context.veil_id]
    stats["count"] += 1
    if context.status == "success"
        stats["successful"] += 1
    end
    stats["total_time"] += context.execution_time
    
    # Record by language
    lang = context.ffi_language
    if !haskey(EXECUTION_METRICS.by_language, lang)
        EXECUTION_METRICS.by_language[lang] = Dict(
            "count" => 0,
            "successful" => 0
        )
    end
    
    EXECUTION_METRICS.by_language[lang]["count"] += 1
    if context.status == "success"
        EXECUTION_METRICS.by_language[lang]["successful"] += 1
    end
end

"""
    get_execution_metrics() -> Dict

Get current execution metrics.
"""
function get_execution_metrics()::Dict
    return Dict(
        "total_executions" => EXECUTION_METRICS.total_executions,
        "successful" => EXECUTION_METRICS.successful,
        "failed" => EXECUTION_METRICS.failed,
        "success_rate" => if EXECUTION_METRICS.total_executions > 0
            EXECUTION_METRICS.successful / EXECUTION_METRICS.total_executions
        else
            0.0
        end,
        "average_time" => EXECUTION_METRICS.average_execution_time,
        "by_veil" => EXECUTION_METRICS.by_veil,
        "by_language" => EXECUTION_METRICS.by_language
    )
end

"""
    reset_execution_metrics()

Reset all execution metrics.
"""
function reset_execution_metrics()
    EXECUTION_METRICS.total_executions = 0
    EXECUTION_METRICS.successful = 0
    EXECUTION_METRICS.failed = 0
    EXECUTION_METRICS.total_execution_time = 0.0
    EXECUTION_METRICS.average_execution_time = 0.0
    empty!(EXECUTION_METRICS.by_veil)
    empty!(EXECUTION_METRICS.by_language)
end

# ============================================================================
# VEIL EXECUTION CONTEXT FUNCTION (for module context)
# ============================================================================

"""
    veil_execution_context(veil_id::Int) -> VeilExecutionContext

Get empty execution context for a veil (for VM integration).
"""
function veil_execution_context(veil_id::Int)::VeilExecutionContext
    return VeilExecutionContext(veil_id, Dict(), Dict())
end

end # module VeilExecutor
