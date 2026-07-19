"""
    VeilIndex - Comprehensive veil lookup and search system
    
Provides efficient indexing and querying across all 777 veils.
"""

module VeilIndex

using JSON
include("veils_777.jl")
using .Veils777

export lookup_veil, search_veils, veil_by_tier, veil_by_opcode, 
       export_veil_json, veil_by_tag, count_veils_in_tier

# ============================================================================
# INDEXING STRUCTURES
# ============================================================================

# Build indices at module load time
const VEIL_ID_INDEX = Dict(v.id => v for v in Veils777.get_all_veils())
const VEIL_OPCODE_INDEX = Dict(v.opcode => v for v in Veils777.get_all_veils())
const VEIL_TIER_INDEX = let
    idx = Dict{String, Vector{VeilDefinition}}()
    for tier in keys(Veils777.VEIL_TIER_RANGES)
        idx[tier] = Veils777.list_veils_by_tier(tier)
    end
    idx
end

# ============================================================================
# LOOKUP FUNCTIONS
# ============================================================================

"""
    lookup_veil(veil_id::Int) -> Union{VeilDefinition, Nothing}

Lookup a single veil by ID.
Returns nothing if veil not found.
"""
function lookup_veil(veil_id::Int)::Union{VeilDefinition, Nothing}
    get(VEIL_ID_INDEX, veil_id, nothing)
end

"""
    veil_by_opcode(opcode::UInt16) -> Union{VeilDefinition, Nothing}

Lookup a veil by its opcode.
"""
function veil_by_opcode(opcode::UInt16)::Union{VeilDefinition, Nothing}
    get(VEIL_OPCODE_INDEX, opcode, nothing)
end

"""
    veil_by_tier(tier::String) -> Vector{VeilDefinition}

Get all veils in a specified tier.
"""
function veil_by_tier(tier::String)::Vector{VeilDefinition}
    get(VEIL_TIER_INDEX, tier, VeilDefinition[])
end

"""
    search_veils(query::String) -> Vector{VeilDefinition}

Search for veils by name, description, or tags.
Returns all matching veils.
"""
function search_veils(query::String)::Vector{VeilDefinition}
    query_lower = lowercase(query)
    results = VeilDefinition[]
    
    for veil in Veils777.get_all_veils()
        # Search in name
        if contains(lowercase(veil.name), query_lower)
            push!(results, veil)
            continue
        end
        
        # Search in description
        if contains(lowercase(veil.description), query_lower)
            push!(results, veil)
            continue
        end
        
        # Search in tags
        for tag in veil.tags
            if contains(lowercase(tag), query_lower)
                push!(results, veil)
                break
            end
        end
    end
    
    return results
end

"""
    veil_by_tag(tag::String) -> Vector{VeilDefinition}

Get all veils with a specific tag.
"""
function veil_by_tag(tag::String)::Vector{VeilDefinition}
    tag_lower = lowercase(tag)
    filter(v -> any(lowercase(t) == tag_lower for t in v.tags), 
           Veils777.get_all_veils())
end

# ============================================================================
# STATISTICAL FUNCTIONS
# ============================================================================

"""
    count_veils_in_tier(tier::String) -> Int

Count the number of veils in a tier.
"""
function count_veils_in_tier(tier::String)::Int
    length(veil_by_tier(tier))
end

"""
    total_veil_count() -> Int

Get total number of veils (should always be 777).
"""
function total_veil_count()::Int
    length(Veils777.get_all_veils())
end

"""
    get_veil_categories() -> Vector{String}

Get all tier/category names.
"""
function get_veil_categories()::Vector{String}
    collect(keys(Veils777.VEIL_TIER_RANGES))
end

# ============================================================================
# EXPORT FUNCTIONS
# ============================================================================

"""
    export_veil_json(filename::String = "veils_777.json") -> String

Export all 777 veils to JSON file.
Returns the JSON string.
"""
function export_veil_json(filename::String = "veils_777.json")::String
    veils_data = Dict[]
    
    for veil in Veils777.get_all_veils()
        veil_dict = Dict(
            "id" => veil.id,
            "name" => veil.name,
            "tier" => veil.tier,
            "description" => veil.description,
            "equation" => veil.equation,
            "category" => veil.category,
            "opcode" => string(veil.opcode; base=16),
            "ffi_language" => veil.ffi_language,
            "parameters" => veil.parameters,
            "output_type" => veil.output_type,
            "implementation_file" => veil.implementation_file,
            "tags" => veil.tags,
            "references" => veil.references
        )
        
        if !isnothing(veil.sacred_mapping)
            veil_dict["sacred_mapping"] = veil.sacred_mapping
        end
        
        push!(veils_data, veil_dict)
    end
    
    # Create export structure
    export_dict = Dict(
        "metadata" => Dict(
            "total_veils" => total_veil_count(),
            "tiers" => length(get_veil_categories()),
            "exported_at" => string(now()),
            "description" => "The 777 Sacred-Scientific Veils of Ọbàtálá"
        ),
        "veils" => veils_data
    )
    
    # Convert to JSON
    json_str = JSON.json(export_dict)
    
    # Write to file
    open(filename, "w") do f
        write(f, json_str)
    end
    
    return json_str
end

"""
    export_veil_summary() -> Dict

Export summary statistics of all veils.
"""
function export_veil_summary()::Dict
    summary = Dict(
        "total_veils" => total_veil_count(),
        "categories" => Dict(),
        "ffi_languages" => Dict(),
        "sample_veils" => Dict()
    )
    
    # Count by tier
    for tier in get_veil_categories()
        summary["categories"][tier] = count_veils_in_tier(tier)
    end
    
    # Count by FFI language
    lang_count = Dict{String, Int}()
    for veil in Veils777.get_all_veils()
        lang_count[veil.ffi_language] = get(lang_count, veil.ffi_language, 0) + 1
    end
    summary["ffi_languages"] = lang_count
    
    # Sample veils from each tier
    for tier in get_veil_categories()
        tier_veils = veil_by_tier(tier)
        if !isempty(tier_veils)
            sample = first(tier_veils)
            summary["sample_veils"][tier] = Dict(
                "id" => sample.id,
                "name" => sample.name
            )
        end
    end
    
    return summary
end

end # module VeilIndex
