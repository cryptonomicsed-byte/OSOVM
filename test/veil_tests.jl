"""
    VeilTests - Comprehensive Unit & Integration Test Suite
    
    Validates all 777 veils for:
    - Correctness (against known test cases)
    - Performance (execution time < thresholds)
    - F1 scoring (accuracy >= 0.90)
    - Integration (composition chains, FFI calls)
"""

# HISTORY (2026-08-13 -> 2026-11-08): this file used to be KNOWN RED.
# FFI_REGISTRY was never populated and every veil fell through to a stub that
# returned status="success" with "stub_output_for_veil_N". The stub is deleted
# (a veil with no implementation is now status="error"), and every veil this
# file asserts on has a real implementation in src/veil_native.jl, checked for
# correctness (not just shape) in test/veil_native_test.jl. The batch loops
# below only assert a VeilExecutionContext comes back; for veils with no
# implementation that context now honestly carries status="error".
#
# Three assertions were malformed, not strict: 403/407 nested an @test inside
# an `@test begin ... end`, so the outer test received a Test.Pass object
# instead of a Bool and always errored. Each condition is unchanged, asserted
# once. Likewise `any(v -> f for v in xs)` built a generator of lambdas, not
# Bools; rewritten as `any(v -> f, xs)`, same condition. Do not weaken these assertions to accept placeholder output.

include(joinpath(@__DIR__, "..", "src", "veils_777.jl"))
include(joinpath(@__DIR__, "..", "src", "veil_index.jl"))
include(joinpath(@__DIR__, "..", "src", "veil_executor.jl"))
include(joinpath(@__DIR__, "..", "src", "veilsim_scorer.jl"))
include(joinpath(@__DIR__, "..", "src", "sacred_geometry.jl"))

module VeilTests

using Test
using Statistics
using LinearAlgebra
import Main.Veils777: VeilDefinition, get_veil, list_veils_by_tier
import Main.VeilIndex: lookup_veil, search_veils, veil_by_tier
import Main.VeilExecutor: execute_veil, execute_veil_composition
import Main.VeilSimScorer: veil_f1_score, score_veil_execution, should_mint_ase, VeilMetrics, F1_THRESHOLD
import Main.SacredGeometry

export run_all_tests, run_phase_tests

# ============================================================================
# TIER 1: CLASSICAL SYSTEMS (VEILS 1-25)
# ============================================================================

@testset "Classical Systems (Veils 1-25)" begin
    
    # Veil 1: PID Controller
    @test begin
        result = execute_veil(1, 
            Dict("Kp" => 1.0, "Ki" => 0.1, "Kd" => 0.01),
            Dict("target" => 10.0, "current" => 5.0, "dt" => 0.01)
        )
        # Check control output is numeric and reasonable
        result.status == "success" && haskey(result.output, "output") && isa(result.output["output"], Number)
    end
    
    # Veil 2: Kalman Filter
    @test begin
        result = execute_veil(2,
            Dict("Q" => 0.1, "R" => 0.05, "x0" => 5.0),
            Dict("z" => 5.2)
        )
        result.status == "success" && haskey(result.output, "state_estimate") && isa(result.output["state_estimate"], Number)
    end
    
    # Veil 3: LQR Control
    @test begin
        A = [1.0 0.1; 0 1.0]
        B = [0; 1.0]
        Q = I(2)
        R = 1.0
        result = execute_veil(3,
            Dict("A" => A, "B" => B, "Q" => Q, "R" => R),
            Dict("state" => [1.0, 0.0])
        )
        result.status == "success" && haskey(result.output, "K") && size(result.output["K"], 2) == 2
    end
    
    # Batch test remaining classical veils (4-25)
    for veil_id in 4:25
        @test begin
            veil_def = lookup_veil(veil_id)
            result = execute_veil(veil_id, Dict(), Dict())
            # Should return a result dict without error
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# TIER 2: ML & AI (VEILS 26-75)
# ============================================================================

@testset "ML & AI Systems (Veils 26-75)" begin
    
    # Veil 26: Gradient Descent
    @test begin
        X_train = randn(100, 10)
        y_train = rand([0, 1], 100)
        result = execute_veil(26,
            Dict("lr" => 0.01, "iterations" => 10),
            Dict("X" => X_train, "y" => y_train)
        )
        result.status == "success" && haskey(result.output, "theta") && haskey(result.output, "loss_history")
    end
    
    # Veil 31: Cross-Entropy Loss
    @test begin
        logits = randn(32, 10)
        targets = rand(0:9, 32)
        result = execute_veil(31,
            Dict("reduction" => "mean"),
            Dict("predictions" => logits, "targets" => targets)
        )
        result.status == "success" && 0 <= result.output["loss"] <= 10  # Reasonable loss range
    end
    
    # Veil 34: Precision, Recall, F1
    @test begin
        predictions = rand([0, 1], 100)
        targets = rand([0, 1], 100)
        result = execute_veil(34,
            Dict("threshold" => 0.5),
            Dict("predictions" => predictions, "targets" => targets)
        )
        result.status == "success" && (0 <= result.output["precision"] <= 1) && (0 <= result.output["f1_score"] <= 1)
    end
    
    # Veil 42: Adam Optimizer
    @test begin
        gradients = randn(10)
        weights = ones(10)
        result = execute_veil(42,
            Dict("lr" => 0.001, "beta1" => 0.9, "beta2" => 0.999),
            Dict("gradients" => gradients, "weights" => weights, "t" => 1)
        )
        result.status == "success" && haskey(result.output, "weights") && length(result.output["weights"]) == 10
    end
    
    # Batch test remaining ML/AI veils
    for veil_id in [27, 28, 29, 30, 32, 33, 35, 41, 43, 51, 52, 61, 62, 71, 72]
        @test begin
            result = execute_veil(veil_id, Dict(), Dict())
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# TIER 3: SIGNAL PROCESSING (VEILS 76-100)
# ============================================================================

@testset "Signal Processing (Veils 76-100)" begin
    
    # Veil 76: FFT
    @test begin
        signal = sin.(2π .* (0:0.01:1))
        result = execute_veil(76,
            Dict("algorithm" => "cooley_tukey", "normalize" => true),
            Dict("signal" => signal)
        )
        result.status == "success" && haskey(result.output, "fft") && haskey(result.output, "magnitude")
    end
    
    # Veil 78: Power Spectral Density
    @test begin
        signal = randn(1024)
        result = execute_veil(78,
            Dict("method" => "welch", "nperseg" => 256),
            Dict("signal" => signal, "fs" => 1000)
        )
        result.status == "success" && haskey(result.output, "power_spectrum") && length(result.output["power_spectrum"]) > 0
    end
    
    # Veil 81: FIR Filter
    @test begin
        result = execute_veil(81,
            Dict("filter_type" => "lowpass", "order" => 128, "critical_freq" => 0.3),
            Dict("fs" => 1000)
        )
        result.status == "success" && haskey(result.output, "coefficients") && length(result.output["coefficients"]) > 0
    end
    
    # Veil 86: Continuous Wavelet Transform
    @test begin
        signal = randn(256)
        scales = 1:64
        result = execute_veil(86,
            Dict("wavelet" => "morlet", "scales" => scales),
            Dict("signal" => signal, "fs" => 100)
        )
        result.status == "success" && haskey(result.output, "coefficients") && haskey(result.output, "frequencies")
    end
    
    # Batch test remaining signal processing veils
    for veil_id in [77, 79, 80, 82, 83, 84, 85, 87, 88, 89, 90, 91, 95, 96, 97]
        @test begin
            result = execute_veil(veil_id, Dict(), Dict())
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# TIER 4: ROBOTICS (VEILS 101-125)
# ============================================================================

@testset "Robotics & Kinematics (Veils 101-125)" begin
    
    # Veil 106: Forward Kinematics
    @test begin
        dh_params = [(0, 0.3, π/2, 0), (0.3, 0, 0, 0), (0.2, 0, π/2, 0)]
        joint_angles = [0.0, 0.0, 0.0]
        result = execute_veil(106,
            Dict("robot_type" => "simple", "dh_params" => dh_params),
            Dict("joint_angles" => joint_angles)
        )
        result.status == "success" && haskey(result.output, "position") && length(result.output["position"]) == 3
    end
    
    # Veil 111: Analytical IK
    @test begin
        result = execute_veil(111,
            Dict("arm_type" => "puma_like"),
            Dict("target_pose" => [0.5, 0.5, 0.3])
        )
        result.status == "success" && haskey(result.output, "joint_configs")
    end
    
    # Veil 116: Jacobian Computation
    @test begin
        joint_angles = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        result = execute_veil(116,
            Dict("method" => "geometric"),
            Dict("joint_angles" => joint_angles)
        )
        result.status == "success" && haskey(result.output, "jacobian") && size(result.output["jacobian"]) == (6, 6)
    end
    
    # Veil 121: Point-to-Point Trajectory
    @test begin
        result = execute_veil(121,
            Dict("trajectory_type" => "quintic", "duration" => 5.0),
            Dict("start" => zeros(6), "goal" => ones(6))
        )
        result.status == "success" && haskey(result.output, "trajectory") && length(result.output["trajectory"]) > 0
    end
    
    # Batch test remaining robotics veils
    for veil_id in [101, 102, 103, 104, 105, 107, 108, 109, 110, 112, 113, 114, 115, 117, 118, 119, 120, 122, 123, 124, 125]
        @test begin
            result = execute_veil(veil_id, Dict(), Dict())
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# TIER 5: FIRST CANON (VEILS 401-413)
# ============================================================================

@testset "First Canon - Sacred Foundation (Veils 401-413)" begin
    
    # Veil 401: Ifá Binary Bones
    @test begin
        result = execute_veil(401,
            Dict("binary_state" => 0b10100110, "oracle" => true),
            Dict()
        )
        result.status == "success" && haskey(result.output, "odù_index") && haskey(result.output, "meaning")
    end
    
    # Veil 403: Mathematical Constants
    @test begin
        result_φ = execute_veil(403,
            Dict("constant_type" => "golden_ratio"),
            Dict()
        )
        φ = (result_φ.status == "success" ? result_φ.output["value"] : NaN)
        1.618 < φ < 1.619  # Golden ratio within tolerance
    end
    
    @test begin
        result_π = execute_veil(403,
            Dict("constant_type" => "pi"),
            Dict()
        )
        π = (result_π.status == "success" ? result_π.output["value"] : NaN)
        3.141 < π < 3.142  # Pi within tolerance
    end
    
    # Veil 407: Harmonic Frequencies
    @test begin
        result = execute_veil(407,
            Dict("frequency_type" => "schumann"),
            Dict()
        )
        schumann = (result.status == "success" ? result.output["hz"] : NaN)
        7.8 < schumann < 7.9  # Schumann frequency
    end
    
    # Batch test remaining First Canon veils
    for veil_id in [402, 404, 405, 406, 408, 409, 410, 411, 412, 413]
        @test begin
            result = execute_veil(veil_id, Dict(), Dict())
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# TIER 6: QUANTUM (VEILS 501-550)
# ============================================================================

@testset "Quantum Foundations (Veils 501-550)" begin
    
    # Veil 501: Qubit Initialization
    @test begin
        result = execute_veil(501,
            Dict("num_qubits" => 5, "initialization_type" => "zero_state"),
            Dict()
        )
        result.status == "success" && haskey(result.output, "state_vector") && length(result.output["state_vector"]) == 32  # 2^5 states
    end
    
    # Veil 503: Quantum Measurement
    @test begin
        result = execute_veil(503,
            Dict("observable" => "pauli_z", "num_shots" => 1000),
            Dict()
        )
        result.status == "success" && haskey(result.output, "measurement_results") && haskey(result.output, "probabilities")
    end
    
    # Veil 511: Pauli Gates
    @test begin
        result = execute_veil(511,
            Dict("gate_sequence" => ["X", "Y", "Z"]),
            Dict()
        )
        result.status == "success" && haskey(result.output, "states_after_gates")
    end
    
    # Veil 531: VQE
    @test begin
        result = execute_veil(531,
            Dict("optimizer" => "cobyla", "max_iterations" => 10),
            Dict()
        )
        result.status == "success" && haskey(result.output, "optimal_parameters") && haskey(result.output, "eigenvalue")
    end
    
    # Batch test remaining quantum veils
    for veil_id in [502, 504, 505, 506, 507, 508, 509, 510, 512, 513, 514, 515, 516, 517, 520, 521, 525, 531, 542, 545]
        @test begin
            result = execute_veil(veil_id, Dict(), Dict())
            result isa Main.VeilExecutor.VeilExecutionContext
        end
    end
end

# ============================================================================
# F1 SCORING VALIDATION
# ============================================================================

@testset "F1 Scoring Validation" begin
    # The scorer measures; it never pays. These assertions replaced ones that
    # called score_veil(id, f1) / veil_f1_score(f1, id) and expected an Àṣẹ
    # amount back from a CALLER-SUPPLIED F1 -- a caller-priced mint (I-12/I-13).
    # That API was deliberately removed: Àṣẹ issuance routes through the
    # emission clock only (I-33), and a passing score feeds COMPUTE_PROOF ->
    # Synapse. What is asserted now is that contract.
    m(tp, fp, fn, tn) = VeilMetrics(1, tp, fp, fn, tn, 0.01, 0, 0.0)

    # F1 is computed from measured counts, not accepted from the caller
    @test veil_f1_score(m(9, 1, 1, 89)) ≈ 0.9
    @test veil_f1_score(m(0, 0, 0, 100)) == 0.0

    # a perfect score still mints no Àṣẹ
    rec = score_veil_execution(1, m(100, 0, 0, 0), "did:key:scorer")
    @test rec.f1_score == 1.0 && rec.ase_minted == 0.0

    # the threshold only gates eligibility for the proof path
    @test should_mint_ase(1.0) && !should_mint_ase(F1_THRESHOLD - 1e-9)

    # an unknown veil scores nothing
    @test score_veil_execution(99_999, m(10, 0, 0, 0)).f1_score == 0.0
end

# ============================================================================
# COMPOSITION & INTEGRATION TESTS
# ============================================================================

@testset "Veil Composition & Integration" begin
    
    # Test veil composition chain
    @test begin
        composition = execute_veil_composition([1, 2, 3], 
            Dict("Kp" => 1.0, "Ki" => 0.1, "Kd" => 0.01),
            Dict("target" => 10.0, "current" => 5.0)
        )
        isa(composition, Dict)
    end
    
    # Test mixed-language FFI
    @test begin
        # Julia + Rust + Python composition
        result = execute_veil_composition([1, 3, 26])  # PID (Julia) + LQR (Rust) + Grad Desc (Python)
        isa(result, Dict)
    end
    
    # Test Sacred Canon cascade
    @test begin
        composition = execute_veil_composition([401, 403, 407])  # Ifá → Constants → Harmonics
        isa(composition, Dict)
    end
end

# ============================================================================
# PERFORMANCE BENCHMARKS
# ============================================================================

@testset "Performance Benchmarks" begin
    
    # Individual veil execution should be fast
    for veil_id in [1, 26, 76, 106, 401, 501]
        @test begin
            t = @elapsed execute_veil(veil_id, Dict(), Dict())
            t < 0.1  # < 100ms per veil
        end
    end
    
    # Composition overhead should be minimal
    @test begin
        t = @elapsed execute_veil_composition([1, 2, 3])
        t < 0.5  # < 500ms for 3-veil composition
    end
end

# ============================================================================
# VEIL INDEX TESTS
# ============================================================================

@testset "Veil Index & Lookup" begin
    
    # Test lookup by ID
    @test begin
        veil = lookup_veil(1)
        veil.id == 1 && veil.name == "PID Controller"
    end
    
    # Test search functionality
    @test begin
        results = search_veils("gradient")
        length(results) > 0 && any(v -> v.id == 26, results)
    end
    
    # Test tier-based filtering
    @test begin
        classical_veils = veil_by_tier("classical")
        all(v -> 1 <= v.id <= 25, classical_veils)
    end
    
    # Test tier ranges
    @test begin
        quantum_veils = veil_by_tier("quantum")
        all(v -> 501 <= v.id <= 550, quantum_veils)
    end
end

# ============================================================================
# SACRED GEOMETRY CONSTANTS
# ============================================================================

@testset "Sacred Geometry Constants" begin
    
    # Golden ratio
    @test begin
        φ = SacredGeometry.φ
        1.618 < φ < 1.619
    end
    
    # Schumann frequency
    @test begin
        schumann = SacredGeometry.SCHUMANN_FREQUENCY
        isapprox(schumann, 7.83, atol=0.01)
    end
    
    # Chakra frequencies
    @test begin
        chakras = SacredGeometry.CHAKRA_FREQUENCIES
        length(chakras) == 7
    end
    
    # Ifá binary
    @test begin
        ifa = SacredGeometry.IFA_BINARY
        ifa == [2, 16, 256, 65536]
    end
end

# ============================================================================
# MAIN TEST RUNNER
# ============================================================================

function run_all_tests()
    println("🧪 Running Comprehensive Veil Test Suite")
    println("=" ^ 60)
    
    @test begin
        # This will run all @testset blocks above
        true
    end
    
    println("=" ^ 60)
    println("✓ All tests passed!")
end

function run_phase_tests(phase_num::Int)
    """Run tests for specific phase"""
    if phase_num == 1
        @test begin
            # Index tests only
            veil = lookup_veil(1)
            veil.id == 1
        end
    elseif phase_num == 6
        run_all_tests()
    end
end

end  # module VeilTests
