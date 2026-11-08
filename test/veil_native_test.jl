# veil_native_test.jl — the native veils are correct, not just well-shaped.
# veil_tests.jl checks output keys; this checks the math against independent
# references (closed forms, a direct DFT, finite differences, the bridge's Odù
# table, exact eigenvalues).
using Test, LinearAlgebra, Statistics
include(joinpath(@__DIR__, "..", "src", "veil_executor.jl"))
using .VeilExecutor
const VN = VeilExecutor.VeilNative
ok(id, p = Dict(), x = Dict()) = (r = execute_veil(id, p, x); @assert r.status == "success" "veil $id: $(r.error_message)"; r.output)

@testset "no stub: an unimplemented veil is an error, never placeholder success" begin
    r = execute_veil(4, Dict(), Dict())
    @test r.status == "error"
    @test occursin("No implementation", something(r.error_message, ""))
    @test r.output === nothing
    # missing required input -> error with a readable message
    r = execute_veil(26, Dict(), Dict())
    @test r.status == "error" && occursin("missing required input \"X\"", r.error_message)
    # native implementation is tagged with the catalog backend it stands in for
    @test ok(3)["implementation"] == "julia-native" && ok(3)["catalog_backend"] == "rust"
end

@testset "control" begin
    o = ok(1, Dict("Kp" => 2.0, "Ki" => 0.5, "Kd" => 0.1), Dict("target" => 10.0, "current" => 4.0, "dt" => 0.1, "prev_error" => 5.0))
    @test o["error"] == 6.0 && o["integral"] ≈ 0.6 && o["derivative"] ≈ 10.0
    @test o["output"] ≈ 2 * 6 + 0.5 * 0.6 + 0.1 * 10
    k = ok(2, Dict("Q" => 0.0, "R" => 1.0, "x0" => 0.0, "P0" => 1.0), Dict("z" => 2.0))
    @test k["kalman_gain"] ≈ 0.5 && k["state_estimate"] ≈ 1.0 && k["covariance"] ≈ 0.5
    A = [1.0 0.1; 0 1.0]; B = reshape([0.0, 1.0], 2, 1); Q = Matrix(1.0I, 2, 2); R = fill(1.0, 1, 1)
    l = ok(3, Dict("A" => A, "B" => [0; 1.0], "Q" => I(2), "R" => 1.0))
    P, K = l["P"], l["K"]
    @test l["converged"] && size(K) == (1, 2)
    @test norm(A' * P * A - A' * P * B * ((R + B' * P * B) \ (B' * P * A)) + Q - P) < 1e-8   # DARE residual
    @test l["closed_loop_spectral_radius"] < 1                                               # stabilising
end

@testset "ml" begin
    X = [1.0 2; 2 1; 3 4; 4 3; -1 -2; -2 -1; -3 -4; -4 -3]; y = [1, 1, 1, 1, 0, 0, 0, 0]
    g = ok(26, Dict("lr" => 0.5, "iterations" => 200), Dict("X" => X, "y" => y))
    @test issorted(g["loss_history"]; rev = true) && g["final_loss"] < 0.05
    c = ok(31, Dict(), Dict("predictions" => zeros(4, 10), "targets" => [0, 3, 9, 5]))
    @test c["loss"] ≈ log(10)                                                     # uniform logits
    f = ok(34, Dict(), Dict("predictions" => [1, 1, 0, 0, 1], "targets" => [1, 0, 0, 1, 1]))
    @test f["precision"] ≈ 2 / 3 && f["recall"] ≈ 2 / 3 && f["f1_score"] ≈ 2 / 3
    a = ok(42, Dict("lr" => 0.1), Dict("gradients" => [1.0, -2.0], "weights" => [0.0, 0.0], "t" => 1))
    @test a["weights"] ≈ [-0.1, 0.1] atol = 1e-6                                  # first Adam step = -lr*sign(g)
end

@testset "signal" begin
    for N in (8, 13)
        x = randn(N)
        direct = [sum(x[n] * cis(-2π * (k - 1) * (n - 1) / N) for n in 1:N) for k in 1:N]
        @test ok(76, Dict(), Dict("signal" => x))["fft"] ≈ direct
    end
    fs = 1000.0; t = (0:2047) ./ fs
    pw = ok(78, Dict("nperseg" => 256), Dict("signal" => sin.(2π * 125 .* t), "fs" => fs))
    @test pw["frequencies"][argmax(pw["power_spectrum"])] ≈ 125.0
    h = ok(81, Dict("order" => 64, "critical_freq" => 0.3))["coefficients"]
    @test sum(h) ≈ 1 && h ≈ reverse(h)                                            # unity DC, linear phase
    @test abs(sum(h .* (-1) .^ (0:length(h)-1))) < 1e-3                           # rejects Nyquist
    hp = ok(81, Dict("order" => 64, "critical_freq" => 0.3, "filter_type" => "highpass"))["coefficients"]
    @test abs(sum(hp)) < 1e-12
    sig = sin.(2π * 5 .* (0:511) ./ 100)
    w = ok(86, Dict("scales" => 1:40), Dict("signal" => sig, "fs" => 100.0))
    @test isapprox(w["frequencies"][argmax(vec(mean(w["power"][:, 100:400]; dims = 2)))], 5.0; rtol = 0.15)
end

@testset "robotics" begin
    dh = [(0.0, 0.3, π / 2, 0.0), (0.3, 0.0, 0.0, 0.0), (0.2, 0.0, π / 2, 0.0)]
    @test ok(106, Dict("dh_params" => dh), Dict("joint_angles" => zeros(3)))["position"] ≈ [0.5, 0.0, 0.3]
    # IK -> FK round trip on the IK's own 3-DOF model
    d1, a2, a3 = 0.0, 0.4318, 0.4318
    model = [(0.0, d1, π / 2, 0.0), (a2, 0.0, 0.0, 0.0), (a3, 0.0, 0.0, 0.0)]
    target = [0.5, 0.5, 0.3]
    ik = ok(111, Dict(), Dict("target_pose" => target))
    @test ik["reachable"] && length(ik["joint_configs"]) >= 2
    for q in ik["joint_configs"]
        @test ok(106, Dict("dh_params" => model), Dict("joint_angles" => q))["position"] ≈ target atol = 1e-9
    end
    @test !ok(111, Dict(), Dict("target_pose" => [5.0, 0, 0]))["reachable"]
    # geometric Jacobian linear part == finite-difference of FK position
    q = [0.1, -0.4, 0.3, 0.2, -0.1, 0.5]
    J = ok(116, Dict(), Dict("joint_angles" => q))["jacobian"]
    fk(q) = ok(106, Dict(), Dict("joint_angles" => q))["position"]
    Jfd = hcat([(fk(q .+ 1e-6 .* (1:6 .== i)) .- fk(q .- 1e-6 .* (1:6 .== i))) ./ 2e-6 for i in 1:6]...)
    @test J[1:3, :] ≈ Jfd atol = 1e-6
    tr = ok(121, Dict("duration" => 2.0), Dict("start" => zeros(2), "goal" => [1.0, -1.0]))
    @test tr["trajectory"][1] ≈ zeros(2) && tr["trajectory"][end] ≈ [1.0, -1.0]
    @test norm(tr["velocity"][1]) < 1e-12 && norm(tr["velocity"][end]) < 1e-12
end

@testset "first canon" begin
    bridge = read(joinpath(@__DIR__, "..", "src", "ifa_compiler_bridge.jl"), String)
    names = [replace(m.captures[1], r"^Eji " => "", r" Meji$" => "") for m in eachmatch(r"^\s+\"([^\"]+)\",\s+# [01]{4}"m, bridge)]
    @test names == VN.ODU16                                                       # same order as the bridge
    o = ok(401, Dict("binary_state" => 0b10100110))
    @test o["right"] == "Ika" && o["left"] == "Obara" && o["meaning"] == "Ika Obara" && o["odù_index"] == 166
    @test ok(401, Dict("binary_state" => 0))["meaning"] == "Eji Ogbe"
    @test ok(401, Dict("binary_state" => 0xff))["meaning"] == "Ofun Meji"
    @test ok(403, Dict("constant_type" => "golden_ratio"))["value"] ≈ (1 + sqrt(5)) / 2
    @test execute_veil(403, Dict("constant_type" => "nope"), Dict()).status == "error"
    @test ok(407)["hz"] == 7.83
end

@testset "quantum" begin
    @test ok(501, Dict("num_qubits" => 3))["state_vector"] == ComplexF64[1, 0, 0, 0, 0, 0, 0, 0]
    pg = ok(511, Dict("gate_sequence" => ["X", "Z", "Y"]))
    X, Y, Z = (VN.PAULI[g] for g in ("X", "Y", "Z"))
    @test pg["states_after_gates"][1] ≈ [0, 1]
    @test pg["final_state"] ≈ Y * Z * X * ComplexF64[1, 0]                      # applied left to right
    plus = ComplexF64[1, 1] ./ sqrt(2)
    m1 = ok(503, Dict("num_shots" => 4000, "seed" => 7), Dict("state_vector" => plus))
    m2 = ok(503, Dict("num_shots" => 4000, "seed" => 7), Dict("state_vector" => plus))
    @test m1["measurement_results"] == m2["measurement_results"]                   # replayable
    @test abs(m1["measurement_results"]["0"] / 4000 - 0.5) < 0.05
    v = ok(531, Dict("max_iterations" => 60))
    @test isapprox(v["eigenvalue"], v["exact_ground_energy"]; atol = 1e-8)
    @test v["exact_ground_energy"] ≈ -1
end

@testset "composition" begin
    c = execute_veil_composition([1, 2, 3], Dict("Kp" => 1.0), Dict("target" => 10.0, "current" => 5.0))
    @test c["status"] == "success" && length(c["steps"]) == 3
    @test execute_veil_composition([1, 4])["status"] == "error"                   # stops at the gap
end
