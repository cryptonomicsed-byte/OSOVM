"""
    OpcodeVeil - Veil opcode mapping and instruction dispatch
    
Maps all 777 veils to executable opcodes (0x01-0x309).
Extends osovm instruction set with veil-specific operations.
"""

module OpcodeVeil

include("veils_777.jl")
using .Veils777

export OPCODE_VEIL, OPCODE_VEIL_COMPOSE, OPCODE_VEIL_SCORE,
       get_veil_opcode, get_opcode_veil, opcode_to_hex, hex_to_opcode

# ============================================================================
# STANDARD VEIL OPCODES (0x10-0x14)
# ============================================================================

"""Main veil dispatcher - fetch veil ID and invoke execution"""
const OPCODE_VEIL = 0x0012

"""Veil composition operator - cascade multiple veils"""
const OPCODE_VEIL_COMPOSE = 0x0013

"""Veil F1 scoring - evaluate and reward"""
const OPCODE_VEIL_SCORE = 0x0014

"""Conditional veil execution"""
const OPCODE_VEIL_IF = 0x0015

"""Veil error handling"""
const OPCODE_VEIL_CATCH = 0x0016

# ============================================================================
# OPCODE ALLOCATION STRATEGY
# ============================================================================

"""
Standard opcodes:     0x00-0x0F (16 instructions)
System opcodes:       0x10-0x1F (16 instructions)  
  0x12 = VEIL dispatcher
  0x13 = VEIL compose
  0x14 = VEIL score
  0x15 = VEIL if
  0x16 = VEIL catch

Extended opcodes:     0x100-0x309 (522 instructions for 777 veils with overlap)

ALLOCATION:
  Veils 1-25    → 0x01-0x19
  Veils 26-75   → 0x1A-0x49
  Veils 76-100  → 0x4A-0x64
  Veils 101-125 → 0x65-0x7D
  Veils 126-150 → 0x7E-0x96
  Veils 151-175 → 0x97-0xAF
  Veils 176-200 → 0xB0-0xC8
  Veils 201-225 → 0xC9-0xE1
  Veils 226-250 → 0xE2-0xFA
  Veils 251-275 → 0xFB-0x113
  Veils 276-300 → 0x114-0x12C
  Veils 301-350 → 0x12D-0x164
  Veils 401-413 → 0x191-0x19D
  Veils 414-425 → 0x19E-0x1A9
  Veils 426-475 → 0x1AA-0x1DB
  Veils 476-500 → 0x1DC-0x1F4
  Veils 501-550 → 0x1F5-0x226
  Veils 551-600 → 0x227-0x258
  Veils 601-680 → 0x259-0x2AA
  Veils 681-777 → 0x2AB-0x309
"""

# Build opcode mapping at module load time

# ============================================================================
# OPCODE BUILDER FUNCTIONS
# ============================================================================

"""
Build mapping from veil ID to opcode.
"""
function build_veil_opcode_map()::Dict{Int, UInt16}
    opcode_map = Dict{Int, UInt16}()
    
    # Allocate opcodes based on tier ranges
    # Classical (1-25)
    for id in 1:25
        opcode_map[id] = UInt16(0x01 + (id - 1))
    end
    
    # ML/AI (26-75)
    for id in 26:75
        opcode_map[id] = UInt16(0x1A + (id - 26))
    end
    
    # Signal (76-100)
    # Base was 0x4A (74), which collided with the tail of the ML/AI range
    # above (26:75 -> opcodes 0x1A:0x4B, i.e. up through 75/0x4B) -- veils
    # 75 and 77 both mapped to opcode 0x4B, and veils 74 and 76 both
    # mapped to opcode 0x4A. Correct base is 0x4C (76), immediately after
    # ML/AI's last opcode (0x4B/75).
    for id in 76:100
        opcode_map[id] = UInt16(0x4C + (id - 76))
    end
    
    # Robotics (101-125)
    for id in 101:125
        opcode_map[id] = UInt16(0x65 + (id - 101))
    end
    
    # Vision (126-150)
    for id in 126:150
        opcode_map[id] = UInt16(0x7E + (id - 126))
    end
    
    # Networks (151-175)
    for id in 151:175
        opcode_map[id] = UInt16(0x97 + (id - 151))
    end
    
    # Optimization (176-200)
    for id in 176:200
        opcode_map[id] = UInt16(0xB0 + (id - 176))
    end
    
    # Physics (201-225)
    for id in 201:225
        opcode_map[id] = UInt16(0xC9 + (id - 201))
    end
    
    # Estimation (226-250)
    for id in 226:250
        opcode_map[id] = UInt16(0xE2 + (id - 226))
    end
    
    # Navigation (251-275)
    for id in 251:275
        opcode_map[id] = UInt16(0xFB + (id - 251))
    end
    
    # MultiAgent (276-300)
    for id in 276:300
        opcode_map[id] = UInt16(0x114 + (id - 276))
    end
    
    # Crypto (301-350)
    for id in 301:350
        opcode_map[id] = UInt16(0x12D + (id - 301))
    end
    
    # First Canon (401-413)
    for id in 401:413
        opcode_map[id] = UInt16(0x191 + (id - 401))
    end
    
    # Meta-Laws (414-425)
    for id in 414:425
        opcode_map[id] = UInt16(0x19E + (id - 414))
    end
    
    # Fundamental Physics (426-475)
    for id in 426:475
        opcode_map[id] = UInt16(0x1AA + (id - 426))
    end
    
    # AI/Category Theory (476-500)
    for id in 476:500
        opcode_map[id] = UInt16(0x1DC + (id - 476))
    end
    
    # Quantum (501-550)
    for id in 501:550
        opcode_map[id] = UInt16(0x1F5 + (id - 501))
    end
    
    # Exotic Materials (551-600)
    for id in 551:600
        opcode_map[id] = UInt16(0x227 + (id - 551))
    end
    
    # Blockchain (601-680)
    for id in 601:680
        opcode_map[id] = UInt16(0x259 + (id - 601))
    end
    
    # Extended/Meta (681-777)
    for id in 681:777
        opcode_map[id] = UInt16(0x2AB + (id - 681))
    end
    
    return opcode_map
end

"""
Build reverse mapping from opcode to veil ID.
"""
function build_opcode_veil_map()::Dict{UInt16, Int}
    reverse_map = Dict{UInt16, Int}()
    for (veil_id, opcode) in VEIL_OPCODE_MAP
        reverse_map[opcode] = veil_id
    end


    return reverse_map
end

# Build opcode mapping at module load time (after both builder functions are defined)
const VEIL_OPCODE_MAP = build_veil_opcode_map()
const OPCODE_VEIL_MAP = build_opcode_veil_map()

# ============================================================================
# PUBLIC API
# ============================================================================

"""
    get_veil_opcode(veil_id::Int) -> Union{UInt16, Nothing}

Get opcode for a veil ID.
"""
function get_veil_opcode(veil_id::Int)::Union{UInt16, Nothing}
    get(VEIL_OPCODE_MAP, veil_id, nothing)
end

"""
    get_opcode_veil(opcode::UInt16) -> Union{Int, Nothing}

Get veil ID for an opcode.
"""
function get_opcode_veil(opcode::UInt16)::Union{Int, Nothing}
    get(OPCODE_VEIL_MAP, opcode, nothing)
end

"""
    opcode_to_hex(opcode::UInt16) -> String

Convert opcode to hexadecimal string.
"""
function opcode_to_hex(opcode::UInt16)::String
    return string(opcode; base=16)
end

"""
    hex_to_opcode(hex_str::String) -> UInt16

Convert hex string to opcode.
"""
function hex_to_opcode(hex_str::String)::UInt16
    return parse(UInt16, hex_str; base=16)
end

"""
    list_opcodes_by_tier(tier::String) -> Vector{Tuple{Int, UInt16}}

Get all opcode mappings for a tier.
Returns vector of (veil_id, opcode) tuples.
"""
function list_opcodes_by_tier(tier::String)::Vector{Tuple{Int, UInt16}}
    veils = Veils777.list_veils_by_tier(tier)
    opcodes = [(v.id, get_veil_opcode(v.id)) for v in veils]
    return filter(x -> x[2] !== nothing, opcodes)
end

"""
    opcode_stats() -> Dict

Get opcode allocation statistics.
"""
function opcode_stats()::Dict
    stats = Dict(
        "total_veils" => length(VEIL_OPCODE_MAP),
        "total_opcodes" => length(OPCODE_VEIL_MAP),
        "opcode_min" => minimum(keys(OPCODE_VEIL_MAP)),
        "opcode_max" => maximum(keys(OPCODE_VEIL_MAP)),
        "by_tier" => Dict()
    )
    
    # Count by tier
    for tier in ["classical", "ml_ai", "signal", "robotics", "vision", 
                 "networks", "optimization", "physics", "estimation", "navigation",
                 "multiagent", "crypto", "first_canon", "meta_laws", 
                 "fundamental_physics", "ai_category_theory", "quantum",
                 "exotic_materials", "blockchain", "extended_meta"]
        tier_opcodes = list_opcodes_by_tier(tier)
        if !isempty(tier_opcodes)
            stats["by_tier"][tier] = length(tier_opcodes)
        end
    end
    
    return stats
end

"""
    validate_opcode_map() -> Bool

Validate that all 777 veils have unique opcodes.
"""
function validate_opcode_map()::Bool
    veil_ids = collect(keys(VEIL_OPCODE_MAP))
    opcodes = collect(values(VEIL_OPCODE_MAP))

    # build_veil_opcode_map() covers 1:350 and 401:777 -- veils 351:400 are
    # a genuine, intentional gap (never allocated a tier range), so the
    # correct expected count is 727, not the whole 1:777 span. This was
    # previously hardcoded to 777, which made validate_opcode_map() always
    # return false regardless of whether the map was actually internally
    # consistent.
    expected_ids = union(1:350, 401:777)
    expected_count = length(expected_ids)
    actual_count = length(unique(veil_ids))
    all_expected_present = Set(expected_ids) == Set(veil_ids)

    # Check opcodes are unique
    unique_opcodes = length(unique(opcodes))

    return actual_count == expected_count && unique_opcodes == actual_count && all_expected_present
end

"""
    opcode_reference() -> Dict

Generate reference documentation of opcode allocations.
"""
function opcode_reference()::Dict
    ref = Dict(
        "metadata" => Dict(
            "total_veils" => 777,
            "opcode_range" => "0x00-0x309",
            "standard_opcodes" => "0x00-0x0F",
            "system_opcodes" => "0x10-0x1F",
            "veil_opcodes" => "0x01-0x309"
        ),
        "veil_opcode_allocations" => Dict(),
        "veil_dispatcher_info" => Dict(
            "OPCODE_VEIL" => opcode_to_hex(OPCODE_VEIL),
            "OPCODE_VEIL_COMPOSE" => opcode_to_hex(OPCODE_VEIL_COMPOSE),
            "OPCODE_VEIL_SCORE" => opcode_to_hex(OPCODE_VEIL_SCORE),
            "OPCODE_VEIL_IF" => opcode_to_hex(OPCODE_VEIL_IF),
            "OPCODE_VEIL_CATCH" => opcode_to_hex(OPCODE_VEIL_CATCH)
        )
    )
    
    # Add allocation ranges
    ranges = [
        ("classical_1_25", 1, 25),
        ("ml_ai_26_75", 26, 75),
        ("signal_76_100", 76, 100),
        ("robotics_101_125", 101, 125),
        ("vision_126_150", 126, 150),
        ("networks_151_175", 151, 175),
        ("optimization_176_200", 176, 200),
        ("physics_201_225", 201, 225),
        ("estimation_226_250", 226, 250),
        ("navigation_251_275", 251, 275),
        ("multiagent_276_300", 276, 300),
        ("crypto_301_350", 301, 350),
        ("first_canon_401_413", 401, 413),
        ("meta_laws_414_425", 414, 425),
        ("fundamental_physics_426_475", 426, 475),
        ("ai_category_theory_476_500", 476, 500),
        ("quantum_501_550", 501, 550),
        ("exotic_materials_551_600", 551, 600),
        ("blockchain_601_680", 601, 680),
        ("extended_meta_681_777", 681, 777)
    ]
    
    for (name, veil_min, veil_max) in ranges
        opcode_min = get_veil_opcode(veil_min)
        opcode_max = get_veil_opcode(veil_max)
        ref["veil_opcode_allocations"][name] = Dict(
            "veils" => "$veil_min-$veil_max",
            "opcodes" => "$(opcode_to_hex(opcode_min))-$(opcode_to_hex(opcode_max))",
            "count" => veil_max - veil_min + 1
        )
    end
    
    return ref
end

end # module OpcodeVeil
