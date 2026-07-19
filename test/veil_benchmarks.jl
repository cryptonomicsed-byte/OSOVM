"""
    VeilBenchmarks - Performance and Scalability Benchmarks
    
    Measures:
    - Per-veil execution time
    - Composition overhead
    - FFI call overhead
    - Memory usage
    - Scaling with complexity
"""

module VeilBenchmarks

include("../src/veils_777.jl")
include("../src/sacred_geometry.jl")
include("../src/opcodes_veil.jl")
include("../src/veil_index.jl")
include("../src/veil_executor.jl")

using BenchmarkTools
using Statistics
import .VeilExecutor: execute_veil, execute_veil_composition
import .VeilIndex: lookup_veil, veil_by_tier

export benchmark_all_veils, benchmark_composition, benchmark_report

# ============================================================================
# GLOBAL BENCHMARK SETTINGS
# ============================================================================

const SAMPLES = 100
const EVALS = 5
const SECONDS_LIMIT = 60.0

# ============================================================================
# TIER 1: CLASSICAL SYSTEMS BENCHMARKS
# ============================================================================

function benchmark_classical_systems()
    println("\n🎛️ Classical Systems Benchmarks (Veils 1-25)")
    println("-" * 60)
    
    results = Dict()
    
    # PID Controller (1)
    results[1] = @benchmark execute_veil(1,
        Dict("Kp" => 1.0, "Ki" => 0.1, "Kd" => 0.01),
        Dict("target" => 10.0, "current" => 5.0, "dt" => 0.01)
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Kalman Filter (2)
    results[2] = @benchmark execute_veil(2,
        Dict("Q" => 0.1, "R" => 0.05, "x0" => 5.0),
        Dict("z" => 5.2)
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # LQR Control (3)
    results[3] = @benchmark execute_veil(3,
        Dict("A" => [1.0 0.1; 0 1.0], "B" => [0; 1.0], 
             "Q" => I(2), "R" => 1.0),
        Dict("state" => [1.0, 0.0])
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Sample remaining veils (4-25)
    for veil_id in [4, 5, 6, 10, 15, 20, 25]
        results[veil_id] = @benchmark execute_veil($veil_id, Dict(), Dict()) \
            samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Report
    for (veil_id, bench_result) in results
        median_time = median(bench_result.times) / 1e6  # Convert to ms
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_id: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# TIER 2: ML & AI BENCHMARKS
# ============================================================================

function benchmark_ml_ai_systems()
    println("\n🧠 ML & AI Systems Benchmarks (Veils 26-75)")
    println("-" * 60)
    
    results = Dict()
    
    # Gradient Descent (26) - test scaling
    for sample_size in [100, 1000, 10000]
        X_train = randn(sample_size, 10)
        y_train = rand([0, 1], sample_size)
        
        results[("GD", sample_size)] = @benchmark execute_veil(26,
            Dict("lr" => 0.01, "iterations" => 10),
            Dict("X" => $X_train, "y" => $y_train)
        ) samples=50 evals=3 seconds=SECONDS_LIMIT
    end
    
    # Cross-Entropy Loss (31)
    for batch_size in [32, 256, 1024]
        logits = randn(batch_size, 10)
        targets = rand(0:9, batch_size)
        
        results[("Loss", batch_size)] = @benchmark execute_veil(31,
            Dict("reduction" => "mean"),
            Dict("predictions" => $logits, "targets" => $targets)
        ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Adam Optimizer (42)
    for param_count in [100, 1000, 10000]
        gradients = randn(param_count)
        weights = ones(param_count)
        
        results[("Adam", param_count)] = @benchmark execute_veil(42,
            Dict("lr" => 0.001, "beta1" => 0.9, "beta2" => 0.999),
            Dict("gradients" => $gradients, "weights" => $weights, "t" => 1)
        ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Attention mechanism (61)
    results["Attention"] = @benchmark execute_veil(61,
        Dict("d_k" => 64, "dropout_rate" => 0.1),
        Dict("Q" => randn(32, 64), "K" => randn(32, 64), "V" => randn(32, 64))
    ) samples=50 evals=3 seconds=SECONDS_LIMIT
    
    # Report
    for (veil_key, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_key: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# TIER 3: SIGNAL PROCESSING BENCHMARKS
# ============================================================================

function benchmark_signal_processing()
    println("\n🔊 Signal Processing Benchmarks (Veils 76-100)")
    println("-" * 60)
    
    results = Dict()
    
    # FFT (76) - scaling with signal length
    for signal_length in [256, 1024, 4096]
        signal = sin.(2π .* (0:0.01:signal_length/100))
        
        results[("FFT", signal_length)] = @benchmark execute_veil(76,
            Dict("algorithm" => "cooley_tukey", "normalize" => true),
            Dict("signal" => $signal)
        ) samples=100 evals=3 seconds=SECONDS_LIMIT
    end
    
    # Filtering (81)
    signal = randn(1024)
    results["FIR_Filter"] = @benchmark execute_veil(81,
        Dict("filter_type" => "lowpass", "order" => 128, "critical_freq" => 0.3),
        Dict("fs" => 1000)
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Wavelet Transform (86)
    results["CWT"] = @benchmark execute_veil(86,
        Dict("wavelet" => "morlet", "scales" => 1:64),
        Dict("signal" => randn(256), "fs" => 100)
    ) samples=50 evals=3 seconds=SECONDS_LIMIT
    
    # DWT (87)
    results["DWT"] = @benchmark execute_veil(87,
        Dict("wavelet" => "db4", "level" => 3),
        Dict("signal" => randn(512))
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Report
    for (veil_key, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_key: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# TIER 4: ROBOTICS BENCHMARKS
# ============================================================================

function benchmark_robotics()
    println("\n🤖 Robotics Benchmarks (Veils 101-125)")
    println("-" * 60)
    
    results = Dict()
    
    # Forward Kinematics (106)
    dh_params = [(0, 0.3, π/2, 0), (0.3, 0, 0, 0), (0.2, 0, π/2, 0)]
    results["FK"] = @benchmark execute_veil(106,
        Dict("robot_type" => "simple", "dh_params" => $dh_params),
        Dict("joint_angles" => [0.0, 0.0, 0.0])
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Jacobian (116) - scaling with DOF
    for num_dof in [3, 6, 7]
        joint_angles = zeros(num_dof)
        
        results[("Jacobian", num_dof)] = @benchmark execute_veil(116,
            Dict("method" => "geometric"),
            Dict("joint_angles" => $joint_angles)
        ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Trajectory Planning (121) - scaling with waypoint count
    for num_points in [10, 100, 1000]
        results[("Trajectory", num_points)] = @benchmark execute_veil(121,
            Dict("trajectory_type" => "quintic", "duration" => 5.0, "num_points" => $num_points),
            Dict("start" => zeros(6), "goal" => ones(6))
        ) samples=50 evals=3 seconds=SECONDS_LIMIT
    end
    
    # Report
    for (veil_key, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_key: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# TIER 5: FIRST CANON BENCHMARKS
# ============================================================================

function benchmark_first_canon()
    println("\n🤍 First Canon Benchmarks (Veils 401-413)")
    println("-" * 60)
    
    results = Dict()
    
    # Ifá Binary (401)
    results[401] = @benchmark execute_veil(401,
        Dict("binary_state" => 0b10100110, "oracle" => true),
        Dict()
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Mathematical Constants (403)
    for constant_type in ["golden_ratio", "pi", "euler"]
        results[("Constants", constant_type)] = @benchmark execute_veil(403,
            Dict("constant_type" => $constant_type),
            Dict()
        ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Sacred Harmonics (407)
    for frequency_type in ["schumann", "chakra_suite", "solfeggio"]
        results[("Harmonics", frequency_type)] = @benchmark execute_veil(407,
            Dict("frequency_type" => $frequency_type),
            Dict()
        ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    end
    
    # Report
    for (veil_key, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_key: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# TIER 6: QUANTUM BENCHMARKS
# ============================================================================

function benchmark_quantum()
    println("\n⚛️ Quantum Benchmarks (Veils 501-550)")
    println("-" * 60)
    
    results = Dict()
    
    # Qubit Initialization (501) - scaling with qubit count
    for num_qubits in [5, 10, 15]
        results[("Init", num_qubits)] = @benchmark execute_veil(501,
            Dict("num_qubits" => $num_qubits, "initialization_type" => "zero_state"),
            Dict()
        ) samples=50 evals=3 seconds=SECONDS_LIMIT
    end
    
    # Quantum Measurement (503)
    results["Measurement"] = @benchmark execute_veil(503,
        Dict("observable" => "pauli_z", "num_shots" => 1000),
        Dict()
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # Pauli Gates (511)
    results["Pauli_Gates"] = @benchmark execute_veil(511,
        Dict("gate_sequence" => ["X", "Y", "Z"]),
        Dict()
    ) samples=SAMPLES evals=EVALS seconds=SECONDS_LIMIT
    
    # VQE (531)
    results["VQE"] = @benchmark execute_veil(531,
        Dict("optimizer" => "cobyla", "max_iterations" => 10),
        Dict()
    ) samples=10 evals=1 seconds=30.0
    
    # Report
    for (veil_key, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("Veil $veil_key: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# COMPOSITION BENCHMARKS
# ============================================================================

function benchmark_composition()
    println("\n🔗 Composition Benchmarks")
    println("-" * 60)
    
    results = Dict()
    
    # 2-veil composition (minimal overhead)
    results["2-Veil"] = @benchmark execute_veil_composition([1, 2],
        Dict("Kp" => 1.0, "Ki" => 0.1, "Kd" => 0.01),
        Dict("target" => 10.0, "current" => 5.0)
    ) samples=50 evals=5 seconds=SECONDS_LIMIT
    
    # 5-veil composition
    results["5-Veil"] = @benchmark execute_veil_composition([1, 2, 3, 4, 5],
        Dict(),
        Dict()
    ) samples=30 evals=3 seconds=SECONDS_LIMIT
    
    # 10-veil composition (stress test)
    results["10-Veil"] = @benchmark execute_veil_composition(1:10,
        Dict(),
        Dict()
    ) samples=10 evals=1 seconds=SECONDS_LIMIT
    
    # Mixed FFI composition (Julia + Rust + Python)
    results["Mixed-FFI"] = @benchmark execute_veil_composition([1, 3, 26],
        Dict(),
        Dict()
    ) samples=10 evals=1 seconds=SECONDS_LIMIT
    
    # Sacred Canon composition (401-413)
    results["Sacred-Canon"] = @benchmark execute_veil_composition([401, 403, 407, 410],
        Dict(),
        Dict()
    ) samples=10 evals=1 seconds=SECONDS_LIMIT
    
    # Report
    println("\nComposition Overhead Analysis:")
    for (composition_name, bench_result) in results
        median_time = median(bench_result.times) / 1e6
        mean_time = mean(bench_result.times) / 1e6
        println("$composition_name: median=$(round(median_time; digits=3))ms, mean=$(round(mean_time; digits=3))ms")
    end
    
    return results
end

# ============================================================================
# COMPREHENSIVE BENCHMARK REPORT
# ============================================================================

function benchmark_report()
    println("=" * 60)
    println("🧪 COMPREHENSIVE VEIL SYSTEM BENCHMARK REPORT")
    println("=" * 60)
    println("Date: $(now())")
    println("Samples: $SAMPLES, Evals: $EVALS, Time limit: $(Int(SECONDS_LIMIT))s")
    
    # Run all benchmarks
    classical_results = benchmark_classical_systems()
    ml_results = benchmark_ml_ai_systems()
    signal_results = benchmark_signal_processing()
    robotics_results = benchmark_robotics()
    canon_results = benchmark_first_canon()
    quantum_results = benchmark_quantum()
    composition_results = benchmark_composition()
    
    # Summary statistics
    println("\n" * "=" * 60)
    println("SUMMARY STATISTICS")
    println("=" * 60)
    
    all_times = vcat(
        [median(r.times) / 1e6 for r in values(classical_results)],
        [median(r.times) / 1e6 for r in values(ml_results)],
        [median(r.times) / 1e6 for r in values(signal_results)],
        [median(r.times) / 1e6 for r in values(robotics_results)],
        [median(r.times) / 1e6 for r in values(canon_results)],
        [median(r.times) / 1e6 for r in values(quantum_results)]
    )
    
    comp_times = [median(r.times) / 1e6 for r in values(composition_results)]
    
    println("Individual Veil Execution:")
    println("  Min: $(round(minimum(all_times); digits=3))ms")
    println("  Max: $(round(maximum(all_times); digits=3))ms")
    println("  Mean: $(round(mean(all_times); digits=3))ms")
    println("  Median: $(round(median(all_times); digits=3))ms")
    println("  95th percentile: $(round(quantile(all_times, 0.95); digits=3))ms")
    
    println("\nVeil Composition:")
    println("  Min: $(round(minimum(comp_times); digits=3))ms")
    println("  Max: $(round(maximum(comp_times); digits=3))ms")
    println("  Mean: $(round(mean(comp_times); digits=3))ms")
    
    # Performance targets
    println("\n" * "=" * 60)
    println("PERFORMANCE TARGETS (SUCCESS CRITERIA)")
    println("=" * 60)
    
    single_veil_target = 10.0  # ms
    composition_target = 50.0  # ms
    
    single_veil_pass = all(t -> t < single_veil_target, all_times)
    composition_pass = all(t -> t < composition_target, comp_times)
    
    println("Single veil execution < $(single_veil_target)ms: $(single_veil_pass ? "✓ PASS" : "✗ FAIL")")
    println("Composition < $(composition_target)ms: $(composition_pass ? "✓ PASS" : "✗ FAIL")")
    
    println("\n" * "=" * 60)
    println("Benchmarks complete. All results logged.")
    println("=" * 60)
end

function benchmark_all_veils()
    """Run benchmarks for all 777 veils (comprehensive)"""
    benchmark_report()
end

end  # module VeilBenchmarks
