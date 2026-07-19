"""
    SacredGeometry - Universal sacred and mathematical constants
    
Bridges spiritual geometry with scientific constants.
Foundation for the First Canon (Veils 401-413).
"""

module SacredGeometry

# ============================================================================
# FUNDAMENTAL MATHEMATICAL CONSTANTS
# ============================================================================

"""Golden Ratio (Φ) - The divine proportion"""
const φ = (1 + sqrt(5)) / 2  # ≈ 1.618033988749...

"""Pi (π) - Circle constant"""
const π = Base.π  # ≈ 3.141592653589...

"""Euler's Number (e) - Growth/exponential constant"""
const e = Base.MathConstants.e  # ≈ 2.718281828459...

"""Catalan's Constant (G)"""
const G_catalan = 0.91596559417721901505

"""Euler-Mascheroni Constant (γ) - Harmonic series limit"""
const γ_euler = 0.5772156649015328606

"""Apéry's Constant (ζ(3))"""
const ζ3 = 1.202056903159594

# ============================================================================
# SQUARE ROOTS - FUNDAMENTAL IRRATIONALS
# ============================================================================

"""√2 - Diagonal of unit square"""
const SQRT2 = sqrt(2)  # ≈ 1.414213562373...

"""√3 - Height of equilateral triangle"""
const SQRT3 = sqrt(3)  # ≈ 1.732050807568...

"""√5 - Related to golden ratio"""
const SQRT5 = sqrt(5)  # ≈ 2.236067977499...

"""√φ - Golden ratio square root"""
const SQRT_PHI = sqrt(φ)

"""1/φ - Reciprocal golden ratio"""
const φ_inv = 1 / φ  # ≈ 0.618033988749...

# ============================================================================
# PHYSICAL CONSTANTS (SI Units)
# ============================================================================

"""Speed of light (c) in m/s"""
const c = 299792458.0

"""Gravitational constant (G) in m³/(kg·s²)"""
const G = 6.67430e-11

"""Planck constant (h) in J·s"""
const h = 6.62607015e-34

"""Reduced Planck constant (ℏ) in J·s"""
const ℏ = h / (2 * π)

"""Planck mass (mₚ) in kg"""
const m_planck = sqrt(ℏ * c / G)

"""Planck length (lₚ) in m"""
const l_planck = sqrt(ℏ * G / c^3)

"""Planck time (tₚ) in s"""
const t_planck = sqrt(ℏ * G / c^5)

"""Planck temperature (Tₚ) in K"""
const T_planck = sqrt(ℏ * c^5 / (G * 1.380649e-23^2))

"""Elementary charge (e) in C"""
const e_charge = 1.602176634e-19

"""Electron mass (mₑ) in kg"""
const m_electron = 9.1093837015e-31

"""Fine structure constant (α)"""
const α = 7.2973525693e-3

# ============================================================================
# ASTRONOMICAL & COSMIC CYCLES
# ============================================================================

"""24-hour day cycle in seconds"""
const DAY_SECONDS = 86400

"""Number of seconds in 1440 minutes (cosmic 24×60)"""
const COSMIC_1440 = 1440 * 60  # 86400 seconds = 24h

"""Lunar month in days"""
const LUNAR_MONTH = 29.53059

"""Metonic cycle (lunar-solar alignment) in years"""
const METONIC_CYCLE = 19

"""Saros cycle (eclipse repeat) in years"""
const SAROS_CYCLE = 18.03

"""Cosmic year (galactic year) in years"""
const COSMIC_YEAR = 26000

"""Precession of equinoxes in years"""
const PRECESSION_CYCLE = 25920

"""Solar year (tropical) in days"""
const SOLAR_YEAR = 365.2425

"""Lunar year in days"""
const LUNAR_YEAR = LUNAR_MONTH * 12

"""Venus synodic period (Earth-Venus alignment) in days"""
const VENUS_CYCLE = 584

"""Saturnian year (Saturn orbit) in Earth years"""
const SATURN_YEAR = 29.457

# ============================================================================
# EARTH & GEOPHYSICAL CONSTANTS
# ============================================================================

"""Earth's mean radius in meters"""
const EARTH_RADIUS = 6.371e6

"""Earth's rotation period in seconds"""
const EARTH_DAY = 86164.0905  # sidereal day

"""Earth's orbital period in seconds"""
const EARTH_YEAR = 365.25 * DAY_SECONDS

"""Schumann Resonance (Earth's fundamental frequency) in Hz"""
const SCHUMANN_FREQUENCY = 7.83

"""Earth's vortex angle (Phi angle) in degrees"""
const EARTH_VORTEX_ANGLE = 19.47

"""Earth's vortex angle in radians"""
const EARTH_VORTEX_RADIAN = deg2rad(EARTH_VORTEX_ANGLE)

# ============================================================================
# CHAKRA FREQUENCIES (Hz) - SACRED TUNING
# ============================================================================

"""Root Chakra (Muladhara) frequency"""
const CHAKRA_ROOT = 194.18

"""Sacral Chakra (Svadhisthana) frequency"""
const CHAKRA_SACRAL = 256.87

"""Solar Plexus Chakra (Manipura) frequency"""
const CHAKRA_SOLAR = 384.0

"""Heart Chakra (Anahata) frequency"""
const CHAKRA_HEART = 341.33

"""Throat Chakra (Vishuddha) frequency"""
const CHAKRA_THROAT = 528.0

"""Third Eye Chakra (Ajna) frequency"""
const CHAKRA_AJNA = 639.0

"""Crown Chakra (Sahasrara) frequency"""
const CHAKRA_CROWN = 963.0

"""Complete chakra frequency array"""
const CHAKRA_FREQUENCIES = [
    CHAKRA_ROOT,
    CHAKRA_SACRAL,
    CHAKRA_SOLAR,
    CHAKRA_HEART,
    CHAKRA_THROAT,
    CHAKRA_AJNA,
    CHAKRA_CROWN
]

# ============================================================================
# SACRED FREQUENCIES & MUSICAL TUNING
# ============================================================================

"""Pythagorean tuning base frequency (A4 = 432 Hz)"""
const A4_PYTHAGOREAN = 432.0

"""Standard modern tuning (A4 = 440 Hz)"""
const A4_MODERN = 440.0

"""Solfeggio 528 Hz - Love & Healing frequency"""
const SOLFEGGIO_528 = 528.0

"""Solfeggio 432 Hz - Foundation frequency"""
const SOLFEGGIO_432 = 432.0

"""Solfeggio 864 Hz - Octave above 432 Hz"""
const SOLFEGGIO_864 = 864.0

"""3-6-9 Vortex (Tesla's divine number) - base frequency"""
const TESLA_369_BASE = 3.0  # Fundamental ratio

"""Hertz unit frequency array - all sacred frequencies"""
const SACRED_FREQUENCIES = [
    SCHUMANN_FREQUENCY,      # 7.83 Hz - Earth resonance
    CHAKRA_ROOT,            # 194.18 Hz
    CHAKRA_SACRAL,          # 256.87 Hz
    CHAKRA_SOLAR,           # 384.0 Hz
    CHAKRA_HEART,           # 341.33 Hz
    CHAKRA_THROAT,          # 528.0 Hz
    CHAKRA_AJNA,            # 639.0 Hz
    CHAKRA_CROWN            # 963.0 Hz
]

# ============================================================================
# YORUBA IFÁ BINARY SYSTEM
# ============================================================================

"""Ifá binary computation base sequence"""
const IFA_BINARY = [2, 16, 256, 65536]

"""Ifá binary power: 2¹"""
const IFA_2 = 2

"""Ifá binary power: 2⁴"""
const IFA_16 = 16

"""Ifá binary power: 2⁸"""
const IFA_256 = 256

"""Ifá binary power: 2¹⁶"""
const IFA_65536 = 65536

"""Number of Odù (sacred binary combinations in Ifá)"""
const IFA_ODU_COUNT = 256

# ============================================================================
# PLATONIC SOLIDS & SACRED GEOMETRY
# ============================================================================

"""Number of Platonic solids (perfect symmetry)"""
const PLATONIC_SOLIDS_COUNT = 5

"""Number of Archimedean solids"""
const ARCHIMEDEAN_SOLIDS_COUNT = 13

"""Number of Kepler-Poinsot solids (star polyhedra)"""
const KEPLER_POINSOT_COUNT = 4

"""Total regular polyhedra"""
const REGULAR_POLYHEDRA_COUNT = PLATONIC_SOLIDS_COUNT + KEPLER_POINSOT_COUNT

"""Vesica Piscis ratio (two overlapping circles)"""
const VESICA_PISCIS_RATIO = √3 / 2

"""Sacred cubit in meters (Egyptian)"""
const SACRED_CUBIT = 0.5236  # meters (φ related)

# ============================================================================
# CALENDAR SYSTEMS & COSMIC NUMBERS
# ============================================================================

"""Yoruba calendar: days in full cycle (cosmic 24×60)"""
const YORUBA_CYCLE = 1440

"""Mayan Long Count base"""
const MAYAN_BASE = 260  # tzolkin

"""Mayan vigesimal system"""
const MAYAN_VIGESIMAL = 20

"""Islamic lunar months per year"""
const ISLAMIC_MONTHS = 12

"""Vedic yugas: Satya Yuga (golden age) in years"""
const SATYA_YUGA = 1728000

"""Vedic yugas: Treta Yuga in years"""
const TRETA_YUGA = 1296000

"""Vedic yugas: Dvapara Yuga in years"""
const DVAPARA_YUGA = 864000

"""Vedic yugas: Kali Yuga (dark age) in years"""
const KALI_YUGA = 432000

"""Total Maha Yuga (complete cycle) in years"""
const MAHA_YUGA = SATYA_YUGA + TRETA_YUGA + DVAPARA_YUGA + KALI_YUGA

"""Days of creation (Biblical Genesis): 6 days"""
const GENESIS_DAYS = 6

"""Norse Yggdrasil: 9 realms"""
const YGGDRASIL_REALMS = 9

# ============================================================================
# ADVANCED MATHEMATICAL CONSTANTS
# ============================================================================

"""Feigenbaum constant (δ) - onset of chaos"""
const FEIGENBAUM_δ = 4.66920160910299

"""Feigenbaum constant (α) - bifurcation scaling"""
const FEIGENBAUM_α = 2.50290787509589

"""Khinchin's constant"""
const KHINCHIN = 2.6854520010

"""Glaisher–Kinkelin constant"""
const GLAISHER_KINKELIN = 1.28242712

"""Omega constant (W(1))"""
const OMEGA = 0.56714329040726

# ============================================================================
# E₈ LATTICE & EXCEPTIONAL GROUPS
# ============================================================================

"""E₈ root system dimension"""
const E8_DIMENSION = 8

"""E₈ root count"""
const E8_ROOT_COUNT = 240

"""E₈ reflection hyperplanes"""
const E8_HYPERPLANES = 120

"""Monster group order (largest sporadic group)"""
const MONSTER_ORDER = 808017424794512875886459904961710757005754368000000000

"""Leech lattice dimension"""
const LEECH_DIMENSION = 24

"""Leech lattice kissing number"""
const LEECH_KISSING = 196560

# ============================================================================
# INFORMATION & BIT SYSTEMS
# ============================================================================

"""Binary digit base"""
const BINARY_BASE = 2

"""Hexadecimal digit base"""
const HEX_BASE = 16

"""Quaternary base (2-bit)"""
const QUATERNARY_BASE = 4

"""Octal base"""
const OCTAL_BASE = 8

"""Decimal base"""
const DECIMAL_BASE = 10

"""Duodecimal base (12 - highly composite)"""
const DUODECIMAL_BASE = 12

"""Sexagesimal base (60 - Babylonian)"""
const SEXAGESIMAL_BASE = 60

"""Vigesimal base (20 - Mayan)"""
const VIGESIMAL_BASE = 20

# ============================================================================
# PUBLIC FUNCTIONS
# ============================================================================

"""
    golden_ratio() -> Float64

Return the golden ratio φ.
"""
function golden_ratio()::Float64
    return φ
end

"""
    planck_units() -> Dict

Return dictionary of Planck units.
"""
function planck_units()::Dict
    return Dict(
        "mass" => m_planck,
        "length" => l_planck,
        "time" => t_planck,
        "temperature" => T_planck
    )
end

"""
    chakra_frequencies() -> Vector{Float64}

Return all chakra frequencies.
"""
function chakra_frequencies()::Vector{Float64}
    return copy(CHAKRA_FREQUENCIES)
end

"""
    sacred_cycle_years(cycle::String) -> Float64

Get duration of a sacred cycle in years.
"""
function sacred_cycle_years(cycle::String)::Float64
    cycles = Dict(
        "metonic" => METONIC_CYCLE,
        "saros" => SAROS_CYCLE,
        "cosmic" => COSMIC_YEAR,
        "precession" => PRECESSION_CYCLE,
        "saturn" => SATURN_YEAR,
        "venus" => VENUS_CYCLE / 365.25
    )
    return get(cycles, lowercase(cycle), 0.0)
end

"""
    yuga_cycle() -> Dict

Return Vedic yuga cycle information.
"""
function yuga_cycle()::Dict
    return Dict(
        "satya" => SATYA_YUGA,
        "treta" => TRETA_YUGA,
        "dvapara" => DVAPARA_YUGA,
        "kali" => KALI_YUGA,
        "total" => MAHA_YUGA
    )
end

end # module SacredGeometry
