# veil_native.jl — real Julia implementations for the veils the suite asserts.
#
# Before this file FFI_REGISTRY was never populated: every one of the 777 veils
# fell through to a stub that returned status="success" with the literal string
# "stub_output_for_veil_N". That stub is gone (veil_executor.jl now reports
# "no implementation" as an error), and these are the first real ones.
#
# Each implementation is plain, dependency-free math (LinearAlgebra, Random,
# Statistics only). Where the catalog assigns a veil to a Rust or Python backend
# that does not exist, the Julia implementation is registered as the native
# fallback and the output says so ("implementation" => "julia-native"), rather
# than pretending a foreign backend ran.
#
# Contract: impl(params::Dict{String,Any}, input::Dict{String,Any}) -> Dict.
# Missing required input throws ArgumentError, which execute_veil turns into
# status="error" with the message.

module VeilNative

using LinearAlgebra
using Random
using Statistics

export NATIVE_VEILS

_get(d::AbstractDict, k::String, default) = haskey(d, k) ? d[k] : default
function _need(d::AbstractDict, k::String, veil::String)
    haskey(d, k) || throw(ArgumentError("$veil: missing required input \"$k\""))
    return d[k]
end
_vec(x) = Float64.(collect(x))
_mat(x) = x isa AbstractMatrix ? Matrix{Float64}(x) : reshape(Float64.(collect(x)), :, 1)

# ============================================================================
# CLASSICAL CONTROL
# ============================================================================

"""Veil 1 — discrete PID step. State (integral, prev_error) is passed in, never
kept: the executor is stateless, so the caller threads it through."""
function pid(p, x)
    Kp, Ki, Kd = Float64(_get(p, "Kp", 1.0)), Float64(_get(p, "Ki", 0.0)), Float64(_get(p, "Kd", 0.0))
    target, current = Float64(_get(x, "target", 0.0)), Float64(_get(x, "current", 0.0))
    dt = Float64(_get(x, "dt", 0.01))
    dt > 0 || throw(ArgumentError("PID: dt must be > 0"))
    err = target - current
    integral = Float64(_get(x, "integral", 0.0)) + err * dt
    # First step: derivative from prev_error if given, else 0 (no derivative kick).
    prev = Float64(_get(x, "prev_error", err))
    derivative = (err - prev) / dt
    u = Kp * err + Ki * integral + Kd * derivative
    return Dict{String,Any}("output" => u, "error" => err, "integral" => integral,
                            "derivative" => derivative, "prev_error" => err)
end

"""Veil 2 — scalar Kalman filter: one predict (+ update when a measurement z is
given). Random-walk model x_k = x_{k-1} + w, z = x + v."""
function kalman(p, x)
    Q, R = Float64(_get(p, "Q", 1e-3)), Float64(_get(p, "R", 1e-2))
    (Q >= 0 && R > 0) || throw(ArgumentError("Kalman: need Q >= 0 and R > 0"))
    xhat = Float64(_get(x, "x", _get(p, "x0", 0.0)))
    P = Float64(_get(x, "P", _get(p, "P0", 1.0)))
    P += Q                                  # predict
    gain = 0.0
    if haskey(x, "z")
        z = Float64(x["z"])
        gain = P / (P + R)
        xhat += gain * (z - xhat)
        P = (1 - gain) * P
    end
    return Dict{String,Any}("state_estimate" => xhat, "covariance" => P,
                            "kalman_gain" => gain, "updated" => haskey(x, "z"))
end

"""Veil 3 — discrete-time infinite-horizon LQR by Riccati iteration.
Returns K (m x n) such that u = -K x. Defaults: a double integrator."""
function lqr(p, x)
    A = _mat(_get(p, "A", [1.0 0.1; 0.0 1.0]))
    n = size(A, 1)
    size(A, 2) == n || throw(ArgumentError("LQR: A must be square"))
    B = _mat(_get(p, "B", [0.0, 0.1]))
    size(B, 1) == n || throw(ArgumentError("LQR: B must have $n rows"))
    m = size(B, 2)
    Qr = _get(p, "Q", Matrix{Float64}(I, n, n))
    Q = Qr isa UniformScaling ? Matrix{Float64}(Qr, n, n) : Matrix{Float64}(Qr)
    Rr = _get(p, "R", 1.0)
    R = Rr isa Number ? fill(Float64(Rr), m, m) : Matrix{Float64}(Rr)
    P = copy(Q)
    converged, iters = false, 0
    for k in 1:10_000
        iters = k
        BtPB = R + B' * P * B
        Pn = A' * P * A - A' * P * B * (BtPB \ (B' * P * A)) + Q
        if maximum(abs.(Pn - P)) < 1e-10 * max(1.0, maximum(abs.(P)))
            P = Pn; converged = true; break
        end
        P = Pn
    end
    K = (R + B' * P * B) \ (B' * P * A)
    out = Dict{String,Any}("K" => K, "P" => P, "converged" => converged, "iterations" => iters,
                           "closed_loop_spectral_radius" => maximum(abs.(eigvals(A - B * K))))
    haskey(x, "state") && (out["u"] = -K * _vec(x["state"]))
    return out
end

# ============================================================================
# ML
# ============================================================================

_sigmoid(z) = 1 / (1 + exp(-z))

"""Veil 26 — batch gradient descent on logistic regression (with bias)."""
function gradient_descent(p, x)
    X = Matrix{Float64}(_need(x, "X", "GradientDescent"))
    y = _vec(_need(x, "y", "GradientDescent"))
    size(X, 1) == length(y) || throw(ArgumentError("GradientDescent: X rows != length(y)"))
    lr, iters = Float64(_get(p, "lr", 0.1)), Int(_get(p, "iterations", 100))
    Xb = hcat(ones(size(X, 1)), X)
    theta = zeros(size(Xb, 2))
    losses = Float64[]
    eps = 1e-12
    for _ in 1:iters
        h = _sigmoid.(Xb * theta)
        push!(losses, -mean(y .* log.(h .+ eps) .+ (1 .- y) .* log.(1 .- h .+ eps)))
        theta .-= lr .* (Xb' * (h .- y)) ./ length(y)
    end
    return Dict{String,Any}("theta" => theta, "loss_history" => losses, "final_loss" => last(losses))
end

"""Veil 31 — softmax cross-entropy over logits (n x C). Targets are class
indices, 0-based by default (index_base=1 for 1-based)."""
function cross_entropy(p, x)
    L = Matrix{Float64}(_need(x, "predictions", "CrossEntropy"))
    t = Int.(collect(_need(x, "targets", "CrossEntropy")))
    base = Int(_get(p, "index_base", 0))
    n, C = size(L)
    length(t) == n || throw(ArgumentError("CrossEntropy: targets length != rows"))
    idx = t .- base .+ 1
    all(1 .<= idx .<= C) || throw(ArgumentError("CrossEntropy: target out of range for $C classes"))
    per = map(1:n) do i
        row = view(L, i, :); mx = maximum(row)
        (mx + log(sum(exp.(row .- mx)))) - row[idx[i]]
    end
    red = String(_get(p, "reduction", "mean"))
    loss = red == "mean" ? mean(per) : red == "sum" ? sum(per) :
           red == "none" ? per : throw(ArgumentError("CrossEntropy: reduction must be mean|sum|none"))
    return Dict{String,Any}("loss" => loss, "per_sample" => per)
end

"""Veil 34 — precision / recall / F1 for binary labels or scores."""
function prf1(p, x)
    thr = Float64(_get(p, "threshold", 0.5))
    pred = _vec(_need(x, "predictions", "PRF1")) .>= thr
    targ = _vec(_need(x, "targets", "PRF1")) .>= 0.5
    length(pred) == length(targ) || throw(ArgumentError("PRF1: length mismatch"))
    tp = count(pred .& targ); fp = count(pred .& .!targ); fn = count(.!pred .& targ)
    precision = tp + fp == 0 ? 0.0 : tp / (tp + fp)
    recall = tp + fn == 0 ? 0.0 : tp / (tp + fn)
    f1 = precision + recall == 0 ? 0.0 : 2precision * recall / (precision + recall)
    return Dict{String,Any}("precision" => precision, "recall" => recall, "f1_score" => f1,
                            "tp" => tp, "fp" => fp, "fn" => fn)
end

"""Veil 42 — one Adam step. Moments are passed in and returned (stateless)."""
function adam(p, x)
    g = _vec(_need(x, "gradients", "Adam")); w = _vec(_need(x, "weights", "Adam"))
    length(g) == length(w) || throw(ArgumentError("Adam: gradients/weights length mismatch"))
    lr, b1, b2 = Float64(_get(p, "lr", 1e-3)), Float64(_get(p, "beta1", 0.9)), Float64(_get(p, "beta2", 0.999))
    ϵ = Float64(_get(p, "eps", 1e-8))
    t = Int(_get(x, "t", 1)); t >= 1 || throw(ArgumentError("Adam: t must be >= 1"))
    m = b1 .* _vec(_get(x, "m", zeros(length(w)))) .+ (1 - b1) .* g
    v = b2 .* _vec(_get(x, "v", zeros(length(w)))) .+ (1 - b2) .* g .^ 2
    mh = m ./ (1 - b1^t); vh = v ./ (1 - b2^t)
    return Dict{String,Any}("weights" => w .- lr .* mh ./ (sqrt.(vh) .+ ϵ), "m" => m, "v" => v, "t" => t + 1)
end

# ============================================================================
# SIGNAL
# ============================================================================

"""DFT: radix-2 Cooley-Tukey when length is a power of two, direct otherwise."""
function _fft(x::AbstractVector{<:Number})::Vector{ComplexF64}
    N = length(x)
    N <= 1 && return ComplexF64.(x)
    if ispow2(N)
        ev = _fft(x[1:2:end]); od = _fft(x[2:2:end])
        tw = [cis(-2π * (k - 1) / N) * od[k] for k in 1:N÷2]
        return vcat(ev .+ tw, ev .- tw)
    end
    return [sum(x[n] * cis(-2π * (k - 1) * (n - 1) / N) for n in 1:N) for k in 1:N]
end

"""Veil 76 — Fourier transform of a real signal."""
function fourier(p, x)
    s = _vec(_need(x, "signal", "FFT"))
    isempty(s) && throw(ArgumentError("FFT: empty signal"))
    F = _fft(s)
    _get(p, "normalize", false) == true && (F ./= length(s))
    fs = Float64(_get(x, "fs", 1.0))
    freqs = [(k <= cld(length(s), 2) ? k - 1 : k - 1 - length(s)) * fs / length(s) for k in 1:length(s)]
    return Dict{String,Any}("fft" => F, "magnitude" => abs.(F), "phase" => angle.(F),
                            "frequencies" => freqs,
                            "algorithm_used" => ispow2(length(s)) ? "cooley_tukey_radix2" : "direct_dft")
end

"""Veil 78 — one-sided power spectral density, Welch's method (Hann, 50% overlap)."""
function psd_welch(p, x)
    s = _vec(_need(x, "signal", "PSD")); fs = Float64(_get(x, "fs", 1.0))
    nper = min(Int(_get(p, "nperseg", 256)), length(s))
    nper >= 2 || throw(ArgumentError("PSD: need at least 2 samples"))
    step = max(1, nper ÷ 2)
    w = [0.5 - 0.5cos(2π * n / (nper - 1)) for n in 0:nper-1]
    scale = fs * sum(w .^ 2)
    nf = nper ÷ 2 + 1
    acc = zeros(nf); segs = 0
    for start in 1:step:(length(s) - nper + 1)
        seg = s[start:start+nper-1]; seg = (seg .- mean(seg)) .* w
        F = _fft(seg)[1:nf]
        acc .+= abs2.(F) ./ scale; segs += 1
    end
    acc ./= segs
    acc[2:end-(iseven(nper) ? 1 : 0)] .*= 2         # one-sided: fold negative freqs
    return Dict{String,Any}("power_spectrum" => acc, "frequencies" => [(k - 1) * fs / nper for k in 1:nf],
                            "segments" => segs)
end

"""Veil 81 — windowed-sinc FIR (Hamming). critical_freq is normalised to
Nyquist (0,1), as in scipy.signal.firwin. numtaps = order + 1."""
function fir(p, x)
    ntaps = Int(_get(p, "order", 64)) + 1
    fc = Float64(_get(p, "critical_freq", 0.25))
    0 < fc < 1 || throw(ArgumentError("FIR: critical_freq must be in (0, 1) (fraction of Nyquist)"))
    kind = String(_get(p, "filter_type", "lowpass"))
    M = ntaps - 1
    h = [ (n == M / 2 ? fc : sin(π * fc * (n - M / 2)) / (π * (n - M / 2))) *
          (0.54 - 0.46cos(2π * n / M)) for n in 0:M ]
    h ./= sum(h)                                       # unity DC gain
    if kind == "highpass"
        isodd(ntaps) || throw(ArgumentError("FIR: highpass needs an odd number of taps (even order)"))
        h = -h; h[M ÷ 2 + 1] += 1                      # spectral inversion
    elseif kind != "lowpass"
        throw(ArgumentError("FIR: filter_type must be lowpass|highpass"))
    end
    return Dict{String,Any}("coefficients" => h, "numtaps" => ntaps, "filter_type" => kind)
end

"""Veil 86 — continuous wavelet transform, complex Morlet (w0 = 6), by direct
convolution. Returns |scales| x N coefficients and the scale->frequency map."""
function cwt_morlet(p, x)
    s = _vec(_need(x, "signal", "CWT")); fs = Float64(_get(x, "fs", 1.0))
    scales = _vec(_get(p, "scales", 1:32)); w0 = Float64(_get(p, "w0", 6.0))
    all(scales .> 0) || throw(ArgumentError("CWT: scales must be > 0"))
    N = length(s)
    C = zeros(ComplexF64, length(scales), N)
    for (i, a) in enumerate(scales)
        M = min(N, ceil(Int, 4a))
        ks = -M:M
        ψ = [π^-0.25 * cis(w0 * k / a) * exp(-(k / a)^2 / 2) for k in ks] ./ sqrt(a)
        for n in 1:N
            acc = 0.0im
            for (j, k) in enumerate(ks)
                m = n + k
                1 <= m <= N && (acc += s[m] * conj(ψ[j]))
            end
            C[i, n] = acc
        end
    end
    fourier_factor = 4π / (w0 + sqrt(2 + w0^2))
    return Dict{String,Any}("coefficients" => C, "power" => abs2.(C),
                            "frequencies" => fs ./ (fourier_factor .* scales), "scales" => scales)
end

# ============================================================================
# ROBOTICS — standard DH: T_i = Rz(θ) Tz(d) Tx(a) Rx(α)
# ============================================================================

function _dh(a, d, α, θ)
    cθ, sθ, cα, sα = cos(θ), sin(θ), cos(α), sin(α)
    [cθ -sθ*cα  sθ*sα a*cθ;
     sθ  cθ*cα -cθ*sα a*sθ;
     0.0 sα     cα    d;
     0.0 0.0    0.0   1.0]
end

# PUMA 560 (Corke), as (a, d, α, θ_offset) per joint.
const PUMA560 = [(0.0, 0.0, π/2, 0.0), (0.4318, 0.0, 0.0, 0.0), (0.0203, 0.15005, -π/2, 0.0),
                 (0.0, 0.4318, π/2, 0.0), (0.0, 0.0, -π/2, 0.0), (0.0, 0.0, 0.0, 0.0)]

function _frames(dh, q)
    length(dh) == length(q) || throw(ArgumentError("kinematics: $(length(dh)) DH rows but $(length(q)) joint angles"))
    T = Matrix{Float64}(I, 4, 4); frames = [copy(T)]
    for (row, qi) in zip(dh, q)
        a, d, α, off = Float64.(Tuple(row))
        T = T * _dh(a, d, α, qi + off); push!(frames, copy(T))
    end
    return frames
end

"""Veil 106 — forward kinematics. dh_params rows are (a, d, α, θ_offset)."""
function forward_kinematics(p, x)
    dh = _get(p, "dh_params", PUMA560)
    q = _vec(_need(x, "joint_angles", "ForwardKinematics"))
    T = last(_frames(dh, q))
    return Dict{String,Any}("position" => T[1:3, 4], "rotation" => T[1:3, 1:3], "transform" => T)
end

"""Veil 111 — closed-form IK for a 3-DOF anthropomorphic arm (base yaw,
shoulder, elbow) reaching a point. Defaults are PUMA-like link lengths. All
real solutions are returned; an unreachable target returns joint_configs=[] and
reachable=false (the solver ran; there is no solution)."""
function analytical_ik(p, x)
    tgt = _vec(_need(x, "target_pose", "AnalyticalIK"))
    length(tgt) >= 3 || throw(ArgumentError("AnalyticalIK: target_pose needs x, y, z"))
    d1, a2, a3 = Float64(_get(p, "d1", 0.0)), Float64(_get(p, "a2", 0.4318)), Float64(_get(p, "a3", 0.4318))
    px, py, pz = tgt[1:3]
    configs = Vector{Vector{Float64}}()
    for (θ1, rs) in ((atan(py, px), 1.0), (atan(py, px) + π, -1.0))
        r = rs * hypot(px, py); z = pz - d1
        D = (r^2 + z^2 - a2^2 - a3^2) / (2a2 * a3)
        abs(D) <= 1 + 1e-12 || continue
        D = clamp(D, -1.0, 1.0)
        for θ3 in (atan(sqrt(1 - D^2), D), atan(-sqrt(1 - D^2), D))
            θ2 = atan(z, r) - atan(a3 * sin(θ3), a2 + a3 * cos(θ3))
            push!(configs, [rem2pi(θ1, RoundNearest), θ2, θ3])
        end
    end
    configs = unique(c -> round.(c; digits = 10), configs)
    return Dict{String,Any}("joint_configs" => configs, "reachable" => !isempty(configs),
                            "link_lengths" => [d1, a2, a3])
end

"""Veil 116 — geometric Jacobian (6 x n) for an all-revolute DH chain."""
function jacobian(p, x)
    dh = _get(p, "dh_params", PUMA560)
    q = _vec(_need(x, "joint_angles", "Jacobian"))
    F = _frames(dh, q); pe = F[end][1:3, 4]
    J = zeros(6, length(q))
    for i in 1:length(q)
        z = F[i][1:3, 3]; o = F[i][1:3, 4]
        J[1:3, i] = cross(z, pe - o); J[4:6, i] = z
    end
    return Dict{String,Any}("jacobian" => J, "rank" => rank(J), "manipulability" => sqrt(max(0.0, det(J * J'))))
end

"""Veil 121 — point-to-point trajectory with rest-to-rest boundary conditions
(quintic: zero velocity and acceleration at both ends; cubic: zero velocity)."""
function trajectory(p, x)
    q0 = _vec(_need(x, "start", "Trajectory")); q1 = _vec(_need(x, "goal", "Trajectory"))
    length(q0) == length(q1) || throw(ArgumentError("Trajectory: start/goal length mismatch"))
    T = Float64(_get(p, "duration", 1.0)); T > 0 || throw(ArgumentError("Trajectory: duration must be > 0"))
    n = Int(_get(p, "n_points", 50)); n >= 2 || throw(ArgumentError("Trajectory: n_points >= 2"))
    kind = String(_get(p, "trajectory_type", "quintic"))
    s, ds = kind == "quintic" ? ((τ -> 10τ^3 - 15τ^4 + 6τ^5), (τ -> (30τ^2 - 60τ^3 + 30τ^4) / T)) :
            kind == "cubic"   ? ((τ -> 3τ^2 - 2τ^3), (τ -> (6τ - 6τ^2) / T)) :
            throw(ArgumentError("Trajectory: trajectory_type must be quintic|cubic"))
    ts = range(0, T; length = n)
    return Dict{String,Any}("times" => collect(ts),
                            "trajectory" => [q0 .+ (q1 .- q0) .* s(t / T) for t in ts],
                            "velocity" => [(q1 .- q0) .* ds(t / T) for t in ts])
end

# ============================================================================
# FIRST CANON
# ============================================================================

# Same order as src/ifa_compiler_bridge.jl MAJOR_ODU (from IfaScript odu.rs);
# test/veil_native_test.jl asserts the two agree.
const ODU16 = ["Ogbe", "Oyeku", "Iwori", "Odi", "Irosun", "Owonrin", "Obara", "Okanran",
               "Ogunda", "Osa", "Ika", "Oturupon", "Otura", "Irete", "Ose", "Ofun"]

"""Veil 401 — read 8 binary marks as one of the 256 Odù. High nibble is the
right (principal) leg, low nibble the left."""
function ifa_bones(p, x)
    st = Int(_get(p, "binary_state", _get(x, "binary_state", -1)))
    0 <= st <= 255 || throw(ArgumentError("IfaBones: binary_state must be 0..255"))
    r, l = st >> 4, st & 0x0f
    name = r == l ? (r == 0 ? "Eji Ogbe" : "$(ODU16[r+1]) Meji") : "$(ODU16[r+1]) $(ODU16[l+1])"
    return Dict{String,Any}("odù_index" => st, "right" => ODU16[r+1], "left" => ODU16[l+1],
                            "meaning" => name, "is_meji" => r == l,
                            "marks" => string(st, base = 2, pad = 8))
end

const CONSTANTS = Dict("golden_ratio" => Base.MathConstants.golden, "pi" => Float64(π),
                       "e" => Float64(ℯ), "sqrt2" => sqrt(2.0), "tau" => 2π)

"""Veil 403 — mathematical constants by name."""
function constants(p, x)
    k = String(_get(p, "constant_type", "golden_ratio"))
    haskey(CONSTANTS, k) || throw(ArgumentError("Constants: unknown constant_type \"$k\"; known: $(join(sort(collect(keys(CONSTANTS))), ", "))"))
    return Dict{String,Any}("value" => Float64(CONSTANTS[k]), "constant_type" => k)
end

"""Veil 407 — named harmonic series. Schumann: measured Earth-ionosphere cavity
modes (fundamental ≈ 7.83 Hz, then ≈ 14.3, 20.8, 27.3, 33.8 Hz)."""
function harmonics(p, x)
    k = String(_get(p, "frequency_type", "schumann"))
    if k == "schumann"
        modes = [7.83, 14.3, 20.8, 27.3, 33.8]
        return Dict{String,Any}("hz" => modes[1], "modes_hz" => modes, "frequency_type" => k)
    elseif k == "harmonic_series"
        f0 = Float64(_get(p, "fundamental_hz", _get(x, "fundamental_hz", 0.0)))
        f0 > 0 || throw(ArgumentError("Harmonics: harmonic_series needs fundamental_hz > 0"))
        n = Int(_get(p, "n", 8))
        return Dict{String,Any}("hz" => f0, "modes_hz" => f0 .* (1:n), "frequency_type" => k)
    end
    throw(ArgumentError("Harmonics: frequency_type must be schumann|harmonic_series"))
end

# ============================================================================
# QUANTUM (state-vector, exact)
# ============================================================================

const PAULI = Dict("I" => ComplexF64[1 0; 0 1], "X" => ComplexF64[0 1; 1 0],
                   "Y" => ComplexF64[0 -im; im 0], "Z" => ComplexF64[1 0; 0 -1])

"""Veil 501 — n-qubit state initialisation (n <= 20)."""
function qubit_init(p, x)
    n = Int(_get(p, "num_qubits", 1)); 1 <= n <= 20 || throw(ArgumentError("QubitInit: num_qubits must be 1..20"))
    kind = String(_get(p, "initialization_type", "zero_state"))
    ψ = kind == "zero_state" ? (v = zeros(ComplexF64, 2^n); v[1] = 1; v) :
        kind == "plus_state" ? fill(ComplexF64(1 / sqrt(2^n)), 2^n) :
        throw(ArgumentError("QubitInit: initialization_type must be zero_state|plus_state"))
    return Dict{String,Any}("state_vector" => ψ, "num_qubits" => n)
end

_state(x) = haskey(x, "state_vector") ? ComplexF64.(collect(x["state_vector"])) : ComplexF64[1, 0]

"""Veil 503 — projective measurement in the computational (Pauli-Z) basis.
Deterministic: seeded (default seed 0), because a VM must replay."""
function measure(p, x)
    ψ = _state(x); nrm = norm(ψ); nrm > 0 || throw(ArgumentError("Measure: zero state"))
    ψ = ψ ./ nrm
    String(_get(p, "observable", "pauli_z")) == "pauli_z" || throw(ArgumentError("Measure: only pauli_z is implemented"))
    probs = abs2.(ψ); shots = Int(_get(p, "num_shots", 1000)); shots >= 1 || throw(ArgumentError("Measure: num_shots >= 1"))
    rng = Xoshiro(Int(_get(p, "seed", 0)))
    cdf = cumsum(probs); counts = zeros(Int, length(ψ))
    for _ in 1:shots
        counts[min(searchsortedfirst(cdf, rand(rng)), length(ψ))] += 1
    end
    nq = Int(log2(length(ψ)))
    res = Dict(string(i - 1, base = 2, pad = nq) => c for (i, c) in enumerate(counts) if c > 0)
    out = Dict{String,Any}("measurement_results" => res, "probabilities" => probs, "num_shots" => shots)
    nq == 1 && (out["expectation_z"] = probs[1] - probs[2])
    return out
end

"""Veil 511 — apply a sequence of single-qubit Pauli gates."""
function pauli_gates(p, x)
    seq = String.(collect(_get(p, "gate_sequence", String[])))
    ψ = _state(x); length(ψ) == 2 || throw(ArgumentError("PauliGates: single-qubit state required"))
    states = Vector{Vector{ComplexF64}}()
    for g in seq
        haskey(PAULI, g) || throw(ArgumentError("PauliGates: unknown gate \"$g\" (I, X, Y, Z)"))
        ψ = PAULI[g] * ψ; push!(states, copy(ψ))
    end
    return Dict{String,Any}("states_after_gates" => states, "final_state" => ψ)
end

"""Veil 531 — single-qubit VQE: ansatz Ry(θ)|0>, minimise <H> over θ by
golden-section search on [0, 2π) after a coarse grid. COBYLA is not available
here; the optimizer actually used is reported. Default H = (X + Z)/√2, whose
exact ground energy is -1."""
function vqe(p, x)
    H = haskey(p, "hamiltonian") ? Matrix{ComplexF64}(p["hamiltonian"]) : (PAULI["X"] .+ PAULI["Z"]) ./ sqrt(2)
    (size(H) == (2, 2) && H ≈ H') || throw(ArgumentError("VQE: hamiltonian must be a 2x2 Hermitian matrix"))
    energy(θ) = (ψ = ComplexF64[cos(θ / 2), sin(θ / 2)]; real(ψ' * H * ψ))
    iters = Int(_get(p, "max_iterations", 50)); iters >= 1 || throw(ArgumentError("VQE: max_iterations >= 1"))
    grid = range(0, 2π; length = 33)[1:end-1]; θ0 = grid[argmin(energy.(grid))]
    a, b = θ0 - 2π / 32, θ0 + 2π / 32; gr = (sqrt(5) - 1) / 2
    hist = Float64[]
    for _ in 1:iters
        c, d = b - gr * (b - a), a + gr * (b - a)
        energy(c) < energy(d) ? (b = d) : (a = c)
        push!(hist, energy((a + b) / 2))
    end
    θ = (a + b) / 2
    return Dict{String,Any}("optimal_parameters" => [θ], "eigenvalue" => energy(θ),
                            "exact_ground_energy" => minimum(real.(eigvals(Hermitian(H)))),
                            "energy_history" => hist,
                            "optimizer_used" => "grid+golden_section",
                            "optimizer_requested" => String(_get(p, "optimizer", "")))
end

# id => (implementation, human name)
const NATIVE_VEILS = Dict{Int, Function}(
    1 => pid, 2 => kalman, 3 => lqr,
    26 => gradient_descent, 31 => cross_entropy, 34 => prf1, 42 => adam,
    76 => fourier, 78 => psd_welch, 81 => fir, 86 => cwt_morlet,
    106 => forward_kinematics, 111 => analytical_ik, 116 => jacobian, 121 => trajectory,
    401 => ifa_bones, 403 => constants, 407 => harmonics,
    501 => qubit_init, 503 => measure, 511 => pauli_gates, 531 => vqe,
)

end # module VeilNative
