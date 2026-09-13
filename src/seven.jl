# OSOVM/src/seven.jl
#
# Universal Seven Functions Protocol (USF-7) — OSOVM implementation
#
# Julia port of the canonical USF-7 substrate defined in omokoda-hermetic.
# OSOVM is the simulation/training layer of the three-pillar ecosystem;
# the SevenFunctions here govern the world-model primitives — what categories
# of agency the simulated world can express and what the VM's Òrìṣà opcodes mean.
#
# Layer topology (OSOVM role):
#   SOURCE/OCEAN    → latent possibility space the world model draws from
#   SEVEN FUNCTIONS → this module (Spark/Mind/Foundation/Emotion/Womb/Fire/Ascension)
#   ORISA OPCODES   → 0xa0–0xa6 in opcodes.jl mapped to SevenFunctions below
#   SACRED TIME     → SevenCalendar reads from SacredTimeBridge BTC clock (GENESIS_BLOCK=780_000)
#   SIMULATION      → training trajectories tagged with active SevenFunction
#   RECEIPT         → ZangbetoReceipt carries the governing function at time of action

module Seven

using Dates

export SevenFunction, SevenProfile, SevenCalendar
export SpiralAlignment, KooduRitualGate
export CulturalAdapter, YorubaAdapter, MesopotamianAdapter, HermeticAdapter
export function_for_day, from_btc_height, today_gregorian, ritual_gate, spiral_alignment
export canonical_name, ascii_slug, description, tradition
export ORISA_OPCODE_TO_FUNCTION, function_to_opcode

# ─── Constants (canonical — mirrors SacredTimeBridge and Koodu sacred_time.jl) ─

const KOODU_GENESIS_BLOCK  = 780_000
const KOODU_BLOCKS_PER_DAY = 144
const KOODU_TITHE_RATE     = 0.0369
const KOODU_DAILY_MINT     = 1_440

# ─── SevenFunction ────────────────────────────────────────────────────────────

"""
    SevenFunction

The seven universal functions of conscious and civilizational agency.
In OSOVM these are world-model primitives — the minimum set of functional
dimensions an agent in simulation can express.
"""
@enum SevenFunction begin
    Spark      = 0  # Agency · Communication · Choice · Initiation
    Mind       = 1  # Reason · Clarity · Ethics · Coherence
    Foundation = 2  # Will · Labor · Execution · Embodiment
    Emotion    = 3  # Value · Relationship · Resonance · Desire
    Womb       = 4  # Creation · Community · Ancestry · Continuity
    Fire       = 5  # Power · Authority · Justice · Consequence
    Ascension  = 6  # Change · Transition · Adaptation · Transformation
end

const ALL_SEVEN = [Spark, Mind, Foundation, Emotion, Womb, Fire, Ascension]

function universal_name(f::SevenFunction)::String
    names = ["Spark", "Mind", "Foundation", "Emotion", "Womb", "Fire", "Ascension"]
    names[Int(f) + 1]
end

function capabilities(f::SevenFunction)::Vector{String}
    caps = [
        ["agency", "communication", "choice", "initiation"],
        ["reason", "clarity", "ethics", "coherence"],
        ["will", "labor", "execution", "embodiment"],
        ["value", "relationship", "resonance", "desire"],
        ["creation", "community", "ancestry", "continuity"],
        ["power", "authority", "justice", "consequence"],
        ["change", "transition", "adaptation", "transformation"],
    ]
    caps[Int(f) + 1]
end

# ─── Opcode Bridge ─────────────────────────────────────────────────────────────
#
# Maps OSOVM Òrìṣà opcodes (opcodes.jl 0xa0–0xa7) to SevenFunctions.
# ORISA_ORUNMILA (0xa7) is the SOURCE/OCEAN above the 7 — it has no SevenFunction.

const ORISA_OPCODE_TO_FUNCTION = Dict{UInt8, SevenFunction}(
    0xa6 => Spark,      # ORISA_ESU      — crossroads/gateway
    0xa0 => Mind,       # ORISA_OBATALA  — white cloth/clarity
    0xa1 => Foundation, # ORISA_OGUN     — iron/work/execution
    0xa4 => Emotion,    # ORISA_OSHUN    — river/love/value
    0xa2 => Womb,       # ORISA_YEMOJA   — ocean/motherhood/creation
    0xa3 => Fire,       # ORISA_SANGO    — thunder/justice/authority
    0xa5 => Ascension,  # ORISA_OYA      — wind/change/transformation
    # 0xa7 ORISA_ORUNMILA = Source/Ocean (above the 7, no SevenFunction)
)

const function_to_opcode = Dict{SevenFunction, UInt8}(v => k for (k, v) in ORISA_OPCODE_TO_FUNCTION)

"""Return the Òrìṣà opcode for this function, or nothing for Source/Ocean."""
opcode_for_function(f::SevenFunction)::Union{UInt8, Nothing} = get(function_to_opcode, f, nothing)

"""Return the SevenFunction for an Òrìṣà opcode, or nothing for ORUNMILA/unknown."""
function_for_opcode(op::UInt8)::Union{SevenFunction, Nothing} = get(ORISA_OPCODE_TO_FUNCTION, op, nothing)

# ─── Cultural Adapters ────────────────────────────────────────────────────────

"""Abstract base for cultural adapters — a tradition provides names for functions."""
abstract type CulturalAdapter end

function tradition(::CulturalAdapter)::String        error("implement tradition()") end
function canonical_name(::CulturalAdapter, ::SevenFunction)::String error("implement canonical_name()") end
function ascii_slug(::CulturalAdapter, ::SevenFunction)::String     error("implement ascii_slug()") end
function description(::CulturalAdapter, ::SevenFunction)::String    error("implement description()") end

# Yorùbá — canonical reference implementation
struct YorubaAdapter <: CulturalAdapter end

tradition(::YorubaAdapter) = "Yorùbá"

function canonical_name(::YorubaAdapter, f::SevenFunction)::String
    names = ["Èṣù", "Ọbàtálá", "Ògún", "Ọ̀ṣun", "Yemọja", "Ṣàngó", "Ọya"]
    names[Int(f) + 1]
end

function ascii_slug(::YorubaAdapter, f::SevenFunction)::String
    slugs = ["esu", "obatala", "ogun", "osun", "yemoja", "sango", "oya"]
    slugs[Int(f) + 1]
end

function description(::YorubaAdapter, f::SevenFunction)::String
    descs = [
        "Gateway, crossroads, divine messenger — all roads and choices pass through Èṣù first",
        "White cloth of clarity — Ọbàtálá shapes consciousness, enforces ethical purity",
        "Iron and will — Ògún clears the path, forges what must be made real",
        "Sweet water and gold — Ọ̀ṣun governs love, value, memory, and what the heart holds",
        "The great mother — Yemọja holds the community, the ancestors, and all creative potential",
        "Thunder and lightning — Ṣàngó commands authority, justice, and the settlement of accounts",
        "Wind and the marketplace — Ọya navigates transformation, guards the threshold between states",
    ]
    descs[Int(f) + 1]
end

# Mesopotamian — Apkallu of Eridu
struct MesopotamianAdapter <: CulturalAdapter end

tradition(::MesopotamianAdapter) = "Mesopotamian"

function canonical_name(::MesopotamianAdapter, f::SevenFunction)::String
    names = ["Uanna", "Uannedugga", "An-Enlilda", "Enmebuluga", "Enmegalamma", "Enmedugga", "Utuabzu"]
    names[Int(f) + 1]
end

function ascii_slug(::MesopotamianAdapter, f::SevenFunction)::String
    slugs = ["uanna", "uannedugga", "an-enlilda", "enmebuluga", "enmegalamma", "enmedugga", "utuabzu"]
    slugs[Int(f) + 1]
end

function description(::MesopotamianAdapter, f::SevenFunction)::String
    descs = [
        "First Apkallu of Eridu — bringer of the arts of civilization, writing, and the original opening of the way",
        "Second Apkallu — bearer of wisdom and discernment; the clarity that separates signal from noise",
        "Third Apkallu — the power of sacred labor; establishes the foundations on which all else is built",
        "Fourth Apkallu — the principle of resonance; the relational bonds that give value and weight to existence",
        "Fifth Apkallu — the great generative force; community, ancestry, and the continuity of civilization",
        "Sixth Apkallu — divine fire and naming of consequence; the authority that settles accounts",
        "Seventh Apkallu — Utuabzu ascended to heaven; the threshold guardian, master of transformation",
    ]
    descs[Int(f) + 1]
end

# Hermetic — Seven Principles as cultural framing
struct HermeticAdapter <: CulturalAdapter end

tradition(::HermeticAdapter) = "Hermetic"

function canonical_name(::HermeticAdapter, f::SevenFunction)::String
    names = ["Mentalism", "Correspondence", "Cause & Effect", "Vibration", "Gender", "Polarity", "Rhythm"]
    names[Int(f) + 1]
end

function ascii_slug(::HermeticAdapter, f::SevenFunction)::String
    slugs = ["mentalism", "correspondence", "cause_effect", "vibration", "gender", "polarity", "rhythm"]
    slugs[Int(f) + 1]
end

function description(::HermeticAdapter, f::SevenFunction)::String
    descs = [
        "The All is Mind — consciousness is the origin and first cause of every act",
        "As above so below — pattern recognition across all scales and planes",
        "Every cause has its effect — effective work honors this law without exception",
        "Everything vibrates — resonance frequency is the language of value and connection",
        "Gender is in everything — the generative polarity that creates all form",
        "Everything has its poles — authority lives at the threshold of balanced extremes",
        "Everything flows — rhythm governs all change, all cycles, all transformation",
    ]
    descs[Int(f) + 1]
end

# ─── SevenProfile ─────────────────────────────────────────────────────────────

"""
Per-agent strength profile across the seven functions.
In OSOVM: used to tag simulation trajectories with the agent's functional emphasis.
Values 0.0–1.0, derived from the same Odù seed as the Hermetic principle values.
"""
struct SevenProfile
    values::NTuple{7, Float64}  # indexed by SevenFunction ordinal
end

function from_hermetic_values(mentalism, correspondence, cause_effect,
                               vibration, gender, polarity, rhythm)::SevenProfile
    # Positional mapping mirrors omokoda-hermetic SevenProfile::from_hermetic()
    SevenProfile((mentalism, correspondence, cause_effect, vibration, gender, polarity, rhythm))
end

strength(p::SevenProfile, f::SevenFunction)::Float64 = p.values[Int(f) + 1]

function dominant(p::SevenProfile)::SevenFunction
    _, idx = findmax(p.values)
    ALL_SEVEN[idx]
end

composite(p::SevenProfile)::Float64 = sum(p.values) / 7.0

function display_profile(p::SevenProfile, adapter::CulturalAdapter)::Vector{NamedTuple}
    [
        (function=f, canonical_name=canonical_name(adapter, f),
         ascii_slug=ascii_slug(adapter, f), strength=strength(p, f))
        for f in ALL_SEVEN
    ]
end

# ─── SpiralAlignment ──────────────────────────────────────────────────────────

@enum SpiralAlignment begin
    Resonance   = 0  # Same function — perfect alignment (double weight)
    Echo        = 1  # One day off
    Drift       = 2  # Two days off
    Opposition  = 3  # Three days off — maximum tension
    ReturnDrift = 4  # Four days off
    ReturnEcho  = 5  # Five days off
    Mirror      = 6  # Six days off — inverse of Resonance
end

is_resonance(a::SpiralAlignment) = a == Resonance

function spiral_alignment_from_offset(offset::Int)::SpiralAlignment
    SpiralAlignment(mod(offset, 7))
end

# ─── KooduRitualGate ──────────────────────────────────────────────────────────

@enum KooduRitualGate begin
    NoGate      = 0  # Normal operation
    Sabbath     = 1  # Saturday / Ọbàtálá — settle-only
    JubileeMinor = 2 # Every 49 BTC days (7×7)
    EshuSquared = 3  # Veil divisible by 12 — tithe enforced
    Capstone    = 4  # Day 343 (7×7×7)
    Void        = 5  # Day 364 of 13-moon year
end

allows_new_contracts(g::KooduRitualGate) = g ∉ (Sabbath, Void)
tithe_enforced(g::KooduRitualGate)       = g == EshuSquared

function gate_multiplier(g::KooduRitualGate)::Float64
    g == NoGate       ? 1.0   :
    g == Sabbath      ? 1.1   :
    g == EshuSquared  ? 1.369 :
    g == JubileeMinor ? 2.0   :
    g == Capstone     ? 1.5   :
    g == Void         ? 0.0   : 1.0
end

# ─── SevenCalendar ────────────────────────────────────────────────────────────

"""
    SevenCalendar

Sacred calendar tied to Koodu's BTC-anchored time.
Mirrors Koodu/src/time/sacred_time.jl and OSOVM/src/sacred_time_bridge.jl.
BTC height is the canonical clock for the entire sovereign ecosystem.

Day mapping (Koodu ORISA_CYCLE = [Esu, Sango, Osun, Yemoja, Oya, Ogun, Obatala]):
  0 Sunday    → Spark      (Èṣù)
  1 Monday    → Fire       (Ṣàngó)
  2 Tuesday   → Emotion    (Ọ̀ṣun)
  3 Wednesday → Womb       (Yemọja)
  4 Thursday  → Ascension  (Ọ̀yá)
  5 Friday    → Foundation (Ògún)
  6 Saturday  → Mind       (Ọbàtálá / Sabbath)
"""
module SevenCalendar

using ..Seven

export function_for_day, from_btc_height, today_gregorian, ritual_gate, spiral_alignment, is_resonance_day

function function_for_day(day::Int)::SevenFunction
    Seven.ALL_SEVEN[mod(day, 7) + 1]
end

"""Canonical function from BTC block height. Returns nothing if pre-genesis."""
function from_btc_height(height::Int)::Union{SevenFunction, Nothing}
    height < Seven.KOODU_GENESIS_BLOCK && return nothing
    days_elapsed = div(height - Seven.KOODU_GENESIS_BLOCK, Seven.KOODU_BLOCKS_PER_DAY)
    function_for_day(days_elapsed)
end

"""Wall-clock Gregorian fallback — use from_btc_height when BTC height is available."""
function today_gregorian()::SevenFunction
    # Unix epoch was Thursday. Add 4 to offset to Sunday=0.
    days_since_epoch = div(round(Int, time()), 86_400)
    day_of_week = mod(days_since_epoch + 4, 7)
    function_for_day(day_of_week)
end

"""Active ritual gate at a given BTC block height (mirrors Koodu check_gate priority)."""
function ritual_gate(height::Int)::KooduRitualGate
    height < Seven.KOODU_GENESIS_BLOCK && return NoGate
    days = div(height - Seven.KOODU_GENESIS_BLOCK, Seven.KOODU_BLOCKS_PER_DAY)
    day_of_week = mod(days, 7)

    mod(days, 364) == 363            && return Void
    mod(days, 343) == 342            && return Capstone
    mod(mod(days, 350) + 1, 12) == 0 && return EshuSquared
    mod(days, 49) == 48              && return JubileeMinor
    day_of_week == 6                 && return Sabbath
    return NoGate
end

"""Spiral alignment between Gregorian and BTC-canonical clocks."""
function spiral_alignment(gregorian_day::Int, btc_day::Int)::SpiralAlignment
    offset = mod(abs(btc_day - gregorian_day), 7)
    SpiralAlignment(offset)
end

"""True when both Gregorian and BTC clocks land on the same SevenFunction."""
function is_resonance_day(btc_height::Union{Int, Nothing})::Bool
    isnothing(btc_height) && return false
    btc_fn = from_btc_height(btc_height)
    isnothing(btc_fn) && return false
    return btc_fn == today_gregorian()
end

end # module SevenCalendar

end # module Seven
