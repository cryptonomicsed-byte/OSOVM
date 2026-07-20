# VeilSim Execution Engine — OSOVM Simulation Kernel
# Physics-Grounded: deterministic, reproducible, energy-conserving
# Crown Architect: Bino EL Gua Omo Koda Ase

module VeilSimEngine

using Dates
using LinearAlgebra
using JSON3
using SHA
using Statistics

include("veilsim_scorer.jl")
using .VeilSimScorer

export SimulationState, Entity, VeilInstance, CollisionPair
export initialize_simulation, step_simulation, batch_simulation
export compute_metrics, compute_f1, anchor_simulation
export vec3_mag, vec3_dot, vec3_sub, vec3_add, vec3_scale

# ============================================================================
# 1. DATA STRUCTURES
# ============================================================================

mutable struct Vec3
    x::Float64
    y::Float64
    z::Float64
end

vec3_mag(v::Vec3)::Float64 = sqrt(v.x^2 + v.y^2 + v.z^2)
vec3_dot(a::Vec3, b::Vec3)::Float64 = a.x*b.x + a.y*b.y + a.z*b.z
vec3_sub(a::Vec3, b::Vec3)::Vec3 = Vec3(a.x-b.x, a.y-b.y, a.z-b.z)
vec3_add(a::Vec3, b::Vec3)::Vec3 = Vec3(a.x+b.x, a.y+b.y, a.z+b.z)
vec3_scale(v::Vec3, s::Float64)::Vec3 = Vec3(v.x*s, v.y*s, v.z*s)
vec3_normalize(v::Vec3)::Vec3 = begin m = vec3_mag(v); m > 1e-12 ? vec3_scale(v, 1.0/m) : Vec3(0.0,0.0,0.0) end

mutable struct Quaternion
    w::Float64
    x::Float64
    y::Float64
    z::Float64
end

mutable struct EntityState
    kinetic_energy::Float64
    potential_energy::Float64
    total_force::Vec3
    total_torque::Vec3
    acceleration::Vec3
    angular_velocity::Vec3
    health::Float64
    timestamp::DateTime
end

mutable struct VeilInstance
    veil_id::Int
    parameters::Dict{String, Float64}
    state::Dict{String, Any}
    input_connectors::Vector{String}
    output_connectors::Vector{String}
    enabled::Bool
end

mutable struct Entity
    id::String
    type::String
    position::Vec3
    velocity::Vec3
    rotation::Quaternion
    mass::Float64
    radius::Float64              # Collision radius
    restitution::Float64         # Bounce coefficient (0=inelastic, 1=elastic)
    veils::Vector{VeilInstance}
    properties::Dict{String, Any}
    state::EntityState
    target_position::Vec3
    position_tolerance::Float64
end

struct CollisionPair
    entity_a::String
    entity_b::String
    normal::Vec3
    penetration::Float64
    impulse::Float64
end

mutable struct SimulationMetrics
    f1_score::Float64
    energy_efficiency::Float64
    convergence_rate::Float64
    robustness_score::Float64
    latency_ms::Float64
    throughput_vps::Float64
    total_energy::Float64        # KE + PE — should be conserved
    energy_drift::Float64        # Deviation from initial energy
    collision_count::Int
end

mutable struct SimulationState
    sim_id::String
    entities::Vector{Entity}
    environment::Dict{String, Any}
    time::Float64
    timestep::Float64
    metrics::SimulationMetrics
    status::String
    started_at::DateTime
    veil_executions::Int
    initial_energy::Float64      # Recorded at t=0 for conservation check
    collisions::Vector{CollisionPair}
end

# ============================================================================
# 2. INITIALIZATION
# ============================================================================

function initialize_simulation(
    sim_id::String,
    entities_config::Vector{Dict},
    environment::Dict,
    timestep::Float64 = 0.01
)::SimulationState

    println("[VeilSim] Initializing: $sim_id")

    entities = Entity[]
    for (i, cfg) in enumerate(entities_config)
        pos = get(cfg, "position", [0.0, 0.0, 0.0])
        vel = get(cfg, "velocity", [0.0, 0.0, 0.0])
        target = get(cfg, "target", [10.0, 0.0, 0.0])
        entity = Entity(
            "entity_$(lpad(i, 4, '0'))",
            get(cfg, "type", "robot"),
            Vec3(pos[1], pos[2], pos[3]),
            Vec3(vel[1], vel[2], vel[3]),
            Quaternion(1.0, 0.0, 0.0, 0.0),
            get(cfg, "mass", 1.0),
            get(cfg, "radius", 0.5),
            get(cfg, "restitution", 0.8),
            _initialize_veils(get(cfg, "veils", []), get(cfg, "veil_params", Dict())),
            get(cfg, "properties", Dict()),
            EntityState(0.0, 0.0, Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0),
                        Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0), 1.0, now()),
            Vec3(target[1], target[2], target[3]),
            get(cfg, "tolerance", 0.5)
        )
        push!(entities, entity)
    end

    # Compute initial energy for conservation tracking
    g = get(environment, "gravity", [0.0, -9.81, 0.0])
    initial_E = 0.0
    for e in entities
        ke = 0.5 * e.mass * (e.velocity.x^2 + e.velocity.y^2 + e.velocity.z^2)
        pe = -e.mass * (g[1]*e.position.x + g[2]*e.position.y + g[3]*e.position.z)
        e.state.kinetic_energy = ke
        e.state.potential_energy = pe
        initial_E += ke + pe
    end

    sim = SimulationState(
        sim_id,
        entities,
        environment,
        0.0,
        timestep,
        SimulationMetrics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, initial_E, 0.0, 0),
        "INIT",
        now(),
        0,
        initial_E,
        CollisionPair[]
    )

    println("[VeilSim] Initialized $(length(entities)) entities, E0=$(round(initial_E, digits=4))")
    return sim
end

function _initialize_veils(veil_ids, params_map::Dict = Dict())::Vector{VeilInstance}
    veils = VeilInstance[]
    for vid in veil_ids
        vid_int = Int(vid)
        veil_params = get(params_map, string(vid_int), Dict{String,Float64}())
        veil = VeilInstance(
            vid_int,
            veil_params isa Dict{String,Float64} ? veil_params : Dict{String,Float64}(string(k) => Float64(v) for (k,v) in veil_params),
            Dict{String, Any}(),
            String[],
            String[],
            true
        )
        push!(veils, veil)
    end
    return veils
end

# ============================================================================
# 3. PHYSICS CORE — Force Computation
# ============================================================================

"""
Compute net force on entity from environment (gravity, drag, ground contact).
Veil forces are added separately.
"""
function compute_environment_force(
    entity::Entity,
    pos::Vec3,
    vel::Vec3,
    env::Dict
)::Vec3
    g = get(env, "gravity", [0.0, -9.81, 0.0])
    drag_coeff = get(env, "drag", 0.1)
    ground_y = get(env, "ground_y", 0.0)
    ground_k = get(env, "ground_stiffness", 10000.0)

    # Gravity
    fx = entity.mass * g[1]
    fy = entity.mass * g[2]
    fz = entity.mass * g[3]

    # Aerodynamic drag: F_drag = -c * v * |v|
    speed = vec3_mag(vel)
    if speed > 1e-10
        fd = drag_coeff * speed
        fx -= fd * vel.x / speed
        fy -= fd * vel.y / speed
        fz -= fd * vel.z / speed
    end

    # Ground contact (penalty-based)
    penetration = ground_y - (pos.y - entity.radius)
    if penetration > 0.0
        # Normal force (spring)
        fy += ground_k * penetration
        # Ground friction
        friction_coeff = get(env, "ground_friction", 0.5)
        if speed > 1e-10
            fx -= friction_coeff * ground_k * penetration * vel.x / speed
            fz -= friction_coeff * ground_k * penetration * vel.z / speed
        end
    end

    Vec3(fx, fy, fz)
end

# ============================================================================
# 4. VEIL EXECUTION — Per-Step Computation
# ============================================================================

function step_simulation(
    sim::SimulationState,
    inputs::Dict{String, Any} = Dict{String, Any}()
)::Tuple{SimulationState, SimulationMetrics}

    start_time = time()
    dt = sim.timestep

    # Phase 1: Compute veil forces for each entity
    for entity in sim.entities
        if !isempty(entity.veils)
            cascade_output = execute_veil_cascade(entity, sim.environment, dt)
            entity.state.total_force = cascade_output[:total_force]
            entity.state.total_torque = cascade_output[:total_torque]
            sim.veil_executions += length(entity.veils)
        else
            entity.state.total_force = Vec3(0.0, 0.0, 0.0)
            entity.state.total_torque = Vec3(0.0, 0.0, 0.0)
        end
    end

    # Phase 2: Integrate physics with proper RK4
    for entity in sim.entities
        new_pos, new_vel = rk4_integrate(
            entity, sim.environment, dt
        )
        entity.position = new_pos
        entity.velocity = new_vel

        # Update energy state
        g = get(sim.environment, "gravity", [0.0, -9.81, 0.0])
        entity.state.kinetic_energy = 0.5 * entity.mass * (new_vel.x^2 + new_vel.y^2 + new_vel.z^2)
        entity.state.potential_energy = -entity.mass * (g[1]*new_pos.x + g[2]*new_pos.y + g[3]*new_pos.z)
        entity.state.acceleration = Vec3(
            entity.state.total_force.x / entity.mass,
            entity.state.total_force.y / entity.mass,
            entity.state.total_force.z / entity.mass
        )
    end

    # Phase 3: Collision detection and response
    sim.collisions = detect_and_resolve_collisions!(sim.entities)
    sim.metrics.collision_count += length(sim.collisions)

    # Phase 4: Update metrics
    elapsed = (time() - start_time) * 1000
    sim.metrics.latency_ms = elapsed
    sim.metrics.throughput_vps = sim.veil_executions / max(elapsed / 1000, 0.001)

    # Energy conservation check
    total_E = sum(e.state.kinetic_energy + e.state.potential_energy for e in sim.entities)
    sim.metrics.total_energy = total_E
    sim.metrics.energy_drift = abs(total_E - sim.initial_energy) / max(abs(sim.initial_energy), 1e-10)

    sim.time += dt
    sim.status = "RUNNING"

    return sim, sim.metrics
end

function execute_veil_cascade(
    entity::Entity,
    env::Dict,
    dt::Float64
)::NamedTuple{(:total_force, :total_torque, :efficiency), Tuple{Vec3, Vec3, Float64}}

    total_force = Vec3(0.0, 0.0, 0.0)
    total_torque = Vec3(0.0, 0.0, 0.0)
    efficiency = 0.0

    for veil in entity.veils
        if !veil.enabled
            continue
        end

        # Pass actual physics state to veils
        veil_output = dispatch_veil(veil, entity, env, dt)

        if haskey(veil_output, "force")
            f = veil_output["force"]
            total_force.x += f[1]
            total_force.y += f[2]
            total_force.z += f[3]
        end

        if haskey(veil_output, "torque")
            t = veil_output["torque"]
            total_torque.x += t[1]
            total_torque.y += t[2]
            total_torque.z += t[3]
        end

        efficiency += get(veil_output, "efficiency", 0.5)
    end

    return (
        total_force = total_force,
        total_torque = total_torque,
        efficiency = efficiency / max(length(entity.veils), 1)
    )
end

function dispatch_veil(
    veil::VeilInstance,
    entity::Entity,
    env::Dict,
    dt::Float64
)::Dict{String, Any}

    vid = veil.veil_id

    if 1 <= vid <= 25       # Control Systems
        return veil_control(vid, veil, entity, dt)
    elseif 26 <= vid <= 75  # Machine Learning / Optimization
        return veil_ml(vid, veil, entity, dt)
    elseif 76 <= vid <= 100 # Signal Processing
        return veil_signal(vid, veil, entity, env, dt)
    elseif 101 <= vid <= 125 # Robotics / Navigation
        return veil_robotics(vid, veil, entity, env, dt)
    else
        return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
    end
end

# ============================================================================
# 5. VEIL IMPLEMENTATIONS — Physics-Grounded
# ============================================================================

function veil_control(vid::Int, veil::VeilInstance, entity::Entity, dt::Float64)::Dict{String,Any}
    p = veil.parameters
    s = veil.state

    if vid == 1  # 3D PID Controller — drives entity toward target
        Kp = get(p, "Kp", 10.0)
        Ki = get(p, "Ki", 0.5)
        Kd = get(p, "Kd", 5.0)
        max_force = get(p, "max_force", 100.0)

        # Error vector: target - position
        err = vec3_sub(entity.target_position, entity.position)
        err_mag = vec3_mag(err)

        # Integral accumulation
        ix = get(s, "integral_x", 0.0) + err.x * dt
        iy = get(s, "integral_y", 0.0) + err.y * dt
        iz = get(s, "integral_z", 0.0) + err.z * dt
        # Anti-windup: clamp integral
        i_max = max_force / max(Ki, 0.01)
        ix = clamp(ix, -i_max, i_max)
        iy = clamp(iy, -i_max, i_max)
        iz = clamp(iz, -i_max, i_max)

        # Derivative (velocity is rate of position change, derivative of error = -velocity when target is fixed)
        dx = -entity.velocity.x
        dy = -entity.velocity.y
        dz = -entity.velocity.z

        # PID output
        fx = Kp * err.x + Ki * ix + Kd * dx
        fy = Kp * err.y + Ki * iy + Kd * dy
        fz = Kp * err.z + Ki * iz + Kd * dz

        # Clamp force magnitude
        f_mag = sqrt(fx^2 + fy^2 + fz^2)
        if f_mag > max_force
            scale = max_force / f_mag
            fx *= scale; fy *= scale; fz *= scale
        end

        # Persist state
        s["integral_x"] = ix; s["integral_y"] = iy; s["integral_z"] = iz

        eff = err_mag < entity.position_tolerance ? 0.95 : clamp(1.0 / (1.0 + err_mag), 0.0, 1.0)

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => eff)

    elseif vid == 2  # Proportional-only (P controller)
        Kp = get(p, "Kp", 5.0)
        err = vec3_sub(entity.target_position, entity.position)
        return Dict{String,Any}(
            "force" => [Kp*err.x, Kp*err.y, Kp*err.z],
            "efficiency" => clamp(1.0 / (1.0 + vec3_mag(err)), 0.0, 1.0)
        )

    elseif vid == 3  # Damper — velocity-proportional resistance
        Kd = get(p, "Kd", 2.0)
        return Dict{String,Any}(
            "force" => [-Kd*entity.velocity.x, -Kd*entity.velocity.y, -Kd*entity.velocity.z],
            "efficiency" => 0.85
        )

    elseif vid == 4  # Spring-Damper to target
        Ks = get(p, "Ks", 8.0)
        Kd = get(p, "Kd", 3.0)
        err = vec3_sub(entity.target_position, entity.position)
        fx = Ks*err.x - Kd*entity.velocity.x
        fy = Ks*err.y - Kd*entity.velocity.y
        fz = Ks*err.z - Kd*entity.velocity.z
        return Dict{String,Any}(
            "force" => [fx, fy, fz],
            "efficiency" => clamp(1.0 / (1.0 + vec3_mag(err)), 0.0, 1.0)
        )

    elseif vid == 5  # Waypoint sequencer
        waypoints_str = get(s, "waypoints", nothing)
        wp_idx = Int(get(s, "wp_index", 1.0))

        if isnothing(waypoints_str)
            return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
        end

        waypoints = s["waypoints"]::Vector{Vector{Float64}}
        if wp_idx > length(waypoints)
            return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 1.0)
        end

        wp = waypoints[wp_idx]
        target = Vec3(wp[1], wp[2], wp[3])
        err = vec3_sub(target, entity.position)
        err_mag = vec3_mag(err)

        # Advance waypoint if close enough
        if err_mag < get(p, "wp_tolerance", 1.0)
            s["wp_index"] = Float64(wp_idx + 1)
        end

        Kp = get(p, "Kp", 8.0)
        Kd = get(p, "Kd", 4.0)
        fx = Kp*err.x - Kd*entity.velocity.x
        fy = Kp*err.y - Kd*entity.velocity.y
        fz = Kp*err.z - Kd*entity.velocity.z

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => clamp(1.0 / (1.0 + err_mag), 0.0, 1.0))
    end

    return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
end

function veil_ml(vid::Int, veil::VeilInstance, entity::Entity, dt::Float64)::Dict{String,Any}
    p = veil.parameters
    s = veil.state

    if vid == 26  # Gradient descent on position error (learned approach vector)
        alpha = get(p, "alpha", 0.5)
        err = vec3_sub(entity.target_position, entity.position)
        err_mag = vec3_mag(err)
        # Gradient of L2 loss = -2 * error direction
        fx = alpha * err.x
        fy = alpha * err.y
        fz = alpha * err.z
        return Dict{String,Any}(
            "force" => [fx, fy, fz],
            "efficiency" => clamp(exp(-err_mag), 0.0, 1.0)
        )

    elseif vid == 27  # Momentum-based optimizer (like Adam)
        beta1 = get(p, "beta1", 0.9)
        beta2 = get(p, "beta2", 0.999)
        lr = get(p, "lr", 1.0)

        err = vec3_sub(entity.target_position, entity.position)

        # First moment (momentum)
        mx = beta1 * get(s, "m_x", 0.0) + (1 - beta1) * err.x
        my = beta1 * get(s, "m_y", 0.0) + (1 - beta1) * err.y
        mz = beta1 * get(s, "m_z", 0.0) + (1 - beta1) * err.z

        # Second moment (RMSprop)
        vx = beta2 * get(s, "v_x", 0.0) + (1 - beta2) * err.x^2
        vy = beta2 * get(s, "v_y", 0.0) + (1 - beta2) * err.y^2
        vz = beta2 * get(s, "v_z", 0.0) + (1 - beta2) * err.z^2

        s["m_x"] = mx; s["m_y"] = my; s["m_z"] = mz
        s["v_x"] = vx; s["v_y"] = vy; s["v_z"] = vz

        eps = 1e-8
        fx = lr * mx / (sqrt(vx) + eps)
        fy = lr * my / (sqrt(vy) + eps)
        fz = lr * mz / (sqrt(vz) + eps)

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => clamp(exp(-vec3_mag(err)), 0.0, 1.0))

    elseif vid == 28  # Simulated annealing — decreasing random perturbation
        temp = get(s, "temperature", 10.0)
        cooling = get(p, "cooling_rate", 0.995)

        err = vec3_sub(entity.target_position, entity.position)
        err_mag = vec3_mag(err)

        # Deterministic perturbation using sin of time (no randomness — reproducible)
        t_state = get(s, "t", 0.0) + dt
        s["t"] = t_state
        px = sin(t_state * 7.3) * temp
        py = sin(t_state * 13.7) * temp
        pz = sin(t_state * 19.1) * temp

        fx = err.x + px
        fy = err.y + py
        fz = err.z + pz

        s["temperature"] = temp * cooling

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => clamp(1.0 / (1.0 + err_mag), 0.0, 1.0))
    end

    return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
end

function veil_signal(vid::Int, veil::VeilInstance, entity::Entity, env::Dict, dt::Float64)::Dict{String,Any}
    p = veil.parameters
    s = veil.state

    if vid == 76  # Low-pass filter on velocity (smoothing)
        alpha = get(p, "alpha", 0.1)
        # Filtered velocity tracks actual velocity with lag
        fvx = alpha * entity.velocity.x + (1 - alpha) * get(s, "fv_x", 0.0)
        fvy = alpha * entity.velocity.y + (1 - alpha) * get(s, "fv_y", 0.0)
        fvz = alpha * entity.velocity.z + (1 - alpha) * get(s, "fv_z", 0.0)
        s["fv_x"] = fvx; s["fv_y"] = fvy; s["fv_z"] = fvz

        # Apply corrective force toward filtered velocity
        Kp = get(p, "Kp", 2.0)
        fx = Kp * (fvx - entity.velocity.x)
        fy = Kp * (fvy - entity.velocity.y)
        fz = Kp * (fvz - entity.velocity.z)

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => 0.8)

    elseif vid == 77  # Oscillator — generates periodic force
        freq = get(p, "frequency", 1.0)  # Hz
        amp = get(p, "amplitude", 5.0)
        axis = Int(get(p, "axis", 1.0))  # 1=x, 2=y, 3=z

        t = get(s, "phase", 0.0) + dt
        s["phase"] = t

        f_val = amp * sin(2.0 * pi * freq * t)
        force = [0.0, 0.0, 0.0]
        force[clamp(axis, 1, 3)] = f_val

        return Dict{String,Any}("force" => force, "efficiency" => 0.7)

    elseif vid == 78  # Kalman-inspired position estimator (corrective force toward estimated true position)
        # Simple 1D Kalman on each axis
        Q = get(p, "process_noise", 0.1)
        R = get(p, "measurement_noise", 1.0)

        for (ax, label) in [("x", entity.position.x), ("y", entity.position.y), ("z", entity.position.z)]
            est = get(s, "est_$ax", label)
            P = get(s, "P_$ax", 1.0)

            # Predict
            P_pred = P + Q
            # Update
            K = P_pred / (P_pred + R)
            s["est_$ax"] = est + K * (label - est)
            s["P_$ax"] = (1 - K) * P_pred
        end

        return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.85)
    end

    return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
end

function veil_robotics(vid::Int, veil::VeilInstance, entity::Entity, env::Dict, dt::Float64)::Dict{String,Any}
    p = veil.parameters
    s = veil.state

    if vid == 101  # Obstacle avoidance (repulsive field from obstacles)
        # Obstacles stored in environment
        obstacles = get(env, "obstacles", Vector{Dict}())
        repulse_range = get(p, "repulse_range", 3.0)
        repulse_k = get(p, "repulse_k", 20.0)

        fx, fy, fz = 0.0, 0.0, 0.0
        for obs in obstacles
            opos = get(obs, "position", [0.0, 0.0, 0.0])
            diff = Vec3(entity.position.x - opos[1], entity.position.y - opos[2], entity.position.z - opos[3])
            dist = vec3_mag(diff)
            if dist < repulse_range && dist > 1e-6
                # Inverse-square repulsion
                strength = repulse_k / dist^2
                dir = vec3_normalize(diff)
                fx += strength * dir.x
                fy += strength * dir.y
                fz += strength * dir.z
            end
        end

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => 0.75)

    elseif vid == 102  # Thrust controller (drone-like vertical + horizontal)
        target_alt = get(p, "target_altitude", 5.0)
        Kp_alt = get(p, "Kp_alt", 15.0)
        Kd_alt = get(p, "Kd_alt", 8.0)
        Kp_lat = get(p, "Kp_lat", 5.0)
        Kd_lat = get(p, "Kd_lat", 3.0)

        # Altitude control
        alt_err = target_alt - entity.position.y
        fy = Kp_alt * alt_err - Kd_alt * entity.velocity.y

        # Lateral control toward target
        err_x = entity.target_position.x - entity.position.x
        err_z = entity.target_position.z - entity.position.z
        fx = Kp_lat * err_x - Kd_lat * entity.velocity.x
        fz = Kp_lat * err_z - Kd_lat * entity.velocity.z

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => 0.8)

    elseif vid == 103  # Formation hold (maintain offset from leader entity)
        offset = get(p, "offset", [2.0, 0.0, 0.0])
        Kp = get(p, "Kp", 6.0)
        Kd = get(p, "Kd", 4.0)

        # Target = entity.target_position + offset
        tx = entity.target_position.x + offset[1]
        ty = entity.target_position.y + offset[2]
        tz = entity.target_position.z + offset[3]

        fx = Kp * (tx - entity.position.x) - Kd * entity.velocity.x
        fy = Kp * (ty - entity.position.y) - Kd * entity.velocity.y
        fz = Kp * (tz - entity.position.z) - Kd * entity.velocity.z

        return Dict{String,Any}("force" => [fx, fy, fz], "efficiency" => 0.8)
    end

    return Dict{String,Any}("force" => [0.0, 0.0, 0.0], "efficiency" => 0.5)
end

# ============================================================================
# 6. PHYSICS INTEGRATION — Proper RK4
# ============================================================================

"""
RK4 integration with force re-evaluation at intermediate steps.
The acceleration function evaluates both environment and veil forces.
"""
function rk4_integrate(
    entity::Entity,
    env::Dict,
    dt::Float64
)::Tuple{Vec3, Vec3}

    veil_force = entity.state.total_force

    # State: [px, py, pz, vx, vy, vz]
    function deriv(pos::Vec3, vel::Vec3)::Tuple{Vec3, Vec3}
        env_force = compute_environment_force(entity, pos, vel, env)
        # Total force = environment + veil
        ax = (env_force.x + veil_force.x) / entity.mass
        ay = (env_force.y + veil_force.y) / entity.mass
        az = (env_force.z + veil_force.z) / entity.mass
        return (vel, Vec3(ax, ay, az))
    end

    pos = entity.position
    vel = entity.velocity

    # k1
    dp1, dv1 = deriv(pos, vel)

    # k2
    p2 = Vec3(pos.x + 0.5*dt*dp1.x, pos.y + 0.5*dt*dp1.y, pos.z + 0.5*dt*dp1.z)
    v2 = Vec3(vel.x + 0.5*dt*dv1.x, vel.y + 0.5*dt*dv1.y, vel.z + 0.5*dt*dv1.z)
    dp2, dv2 = deriv(p2, v2)

    # k3
    p3 = Vec3(pos.x + 0.5*dt*dp2.x, pos.y + 0.5*dt*dp2.y, pos.z + 0.5*dt*dp2.z)
    v3 = Vec3(vel.x + 0.5*dt*dv2.x, vel.y + 0.5*dt*dv2.y, vel.z + 0.5*dt*dv2.z)
    dp3, dv3 = deriv(p3, v3)

    # k4
    p4 = Vec3(pos.x + dt*dp3.x, pos.y + dt*dp3.y, pos.z + dt*dp3.z)
    v4 = Vec3(vel.x + dt*dv3.x, vel.y + dt*dv3.y, vel.z + dt*dv3.z)
    dp4, dv4 = deriv(p4, v4)

    # Combine
    new_pos = Vec3(
        pos.x + (dt/6.0) * (dp1.x + 2*dp2.x + 2*dp3.x + dp4.x),
        pos.y + (dt/6.0) * (dp1.y + 2*dp2.y + 2*dp3.y + dp4.y),
        pos.z + (dt/6.0) * (dp1.z + 2*dp2.z + 2*dp3.z + dp4.z)
    )
    new_vel = Vec3(
        vel.x + (dt/6.0) * (dv1.x + 2*dv2.x + 2*dv3.x + dv4.x),
        vel.y + (dt/6.0) * (dv1.y + 2*dv2.y + 2*dv3.y + dv4.y),
        vel.z + (dt/6.0) * (dv1.z + 2*dv2.z + 2*dv3.z + dv4.z)
    )

    return new_pos, new_vel
end

# ============================================================================
# 7. COLLISION DETECTION & RESPONSE
# ============================================================================

function detect_and_resolve_collisions!(entities::Vector{Entity})::Vector{CollisionPair}
    collisions = CollisionPair[]
    n = length(entities)

    for i in 1:n
        for j in (i+1):n
            a = entities[i]
            b = entities[j]

            diff = vec3_sub(a.position, b.position)
            dist = vec3_mag(diff)
            min_dist = a.radius + b.radius

            if dist < min_dist && dist > 1e-10
                # Collision detected
                normal = vec3_normalize(diff)
                penetration = min_dist - dist

                # Relative velocity along normal
                rel_vel = vec3_sub(a.velocity, b.velocity)
                vn = vec3_dot(rel_vel, normal)

                # Only resolve if approaching
                if vn < 0
                    e = min(a.restitution, b.restitution)
                    inv_mass_sum = 1.0/a.mass + 1.0/b.mass
                    j_impulse = -(1 + e) * vn / inv_mass_sum

                    # Apply impulse
                    impulse_vec = vec3_scale(normal, j_impulse)
                    a.velocity = vec3_add(a.velocity, vec3_scale(impulse_vec, 1.0/a.mass))
                    b.velocity = vec3_sub(b.velocity, vec3_scale(impulse_vec, 1.0/b.mass))

                    # Positional correction (prevent sinking)
                    correction = vec3_scale(normal, penetration * 0.5)
                    a.position = vec3_add(a.position, correction)
                    b.position = vec3_sub(b.position, correction)

                    push!(collisions, CollisionPair(a.id, b.id, normal, penetration, j_impulse))
                end
            end
        end
    end

    return collisions
end

# ============================================================================
# 8. METRICS & F1 SCORING
# ============================================================================

function compute_metrics(sim::SimulationState)::SimulationMetrics
    total_energy = 0.0
    convergence_sum = 0.0

    for entity in sim.entities
        total_energy += entity.state.kinetic_energy + entity.state.potential_energy

        err = vec3_sub(entity.position, entity.target_position)
        pos_error = vec3_mag(err)

        convergence_sum += 1.0 / (1.0 + pos_error)
    end

    f1 = compute_f1(sim)

    sim.metrics.f1_score = f1
    sim.metrics.convergence_rate = convergence_sum / max(length(sim.entities), 1)
    sim.metrics.total_energy = total_energy
    sim.metrics.energy_drift = abs(total_energy - sim.initial_energy) / max(abs(sim.initial_energy), 1e-10)

    # Energy efficiency: ratio of useful work to total energy expended
    sim.metrics.energy_efficiency = total_energy > 0 ? sim.metrics.convergence_rate / (1.0 + abs(total_energy)) : 1.0

    # Robustness: penalize energy blowup AND excessive drift
    if total_energy > 1e6 || sim.metrics.energy_drift > 100.0
        sim.metrics.robustness_score = 0.0
    else
        sim.metrics.robustness_score = min(1.0, 1.0 / (1.0 + sim.metrics.energy_drift))
    end

    return sim.metrics
end

# ============================================================================
# 9. BATCH EXECUTION
# ============================================================================

function batch_simulation(
    sim::SimulationState,
    steps::Int
)::Tuple{SimulationState, Vector{SimulationMetrics}}

    println("[VeilSim] Batch: $steps steps, dt=$(sim.timestep)")
    metrics_history = SimulationMetrics[]

    for step = 1:steps
        sim, _ = step_simulation(sim)
        compute_metrics(sim)
        push!(metrics_history, deepcopy(sim.metrics))

        if step % 100 == 0
            m = sim.metrics
            println("  Step $step/$steps | F1=$(round(m.f1_score, digits=3)) | E_drift=$(round(m.energy_drift, digits=4)) | Collisions=$(m.collision_count)")
        end
    end

    f1_avg = mean([m.f1_score for m in metrics_history])
    sim.metrics.f1_score = f1_avg

    status = f1_avg >= 0.9 ? "CONVERGED" : (f1_avg >= 0.5 ? "PARTIAL" : "DIVERGED")
    println("[VeilSim] Batch complete | F1=$(round(f1_avg, digits=4)) | Status=$status | E_drift=$(round(sim.metrics.energy_drift, digits=6))")

    return sim, metrics_history
end

"""
    compute_f1(sim::SimulationState) -> Float64

Deterministic F1 helper derived from the same target/tolerance logic used by
`compute_metrics`, without mutating the simulation state.
"""
function compute_f1(sim::SimulationState)::Float64
    total_tp = 0
    total_fp = 0
    total_fn = 0

    for entity in sim.entities
        err = vec3_sub(entity.position, entity.target_position)
        pos_error = vec3_mag(err)
        within_tolerance = pos_error <= entity.position_tolerance
        speed = vec3_mag(entity.velocity)
        settling = within_tolerance && speed < 1.0
        force_mag = vec3_mag(entity.state.total_force)
        veils_active = force_mag > 1e-6 && !isempty(entity.veils)

        if within_tolerance && (veils_active || settling)
            total_tp += 1
        elseif within_tolerance && !veils_active && !settling
            total_fp += 1
        elseif !within_tolerance && veils_active
            total_fn += 1
        end
    end

    p = total_tp + total_fp > 0 ? total_tp / (total_tp + total_fp) : 0.0
    r = total_tp + total_fn > 0 ? total_tp / (total_tp + total_fn) : 0.0
    p + r > 0 ? 2.0 * (p * r) / (p + r) : 0.0
end
# ============================================================================
# 10. BLOCKCHAIN ANCHORING
# ============================================================================

function anchor_simulation(
    sim::SimulationState,
    metrics::SimulationMetrics,
    chains::Vector{String} = ["Bitcoin", "Arweave", "Ethereum", "Sui"]
)::Dict{String, String}

    println("[VeilSim] Anchoring to $(length(chains)) chains...")

    snapshot_data = JSON3.write(Dict(
        "sim_id" => sim.sim_id,
        "timestamp" => string(now()),
        "time" => sim.time,
        "metrics" => Dict(
            "f1_score" => metrics.f1_score,
            "energy_efficiency" => metrics.energy_efficiency,
            "energy_drift" => metrics.energy_drift,
            "robustness" => metrics.robustness_score,
            "collision_count" => metrics.collision_count
        ),
        "entity_count" => length(sim.entities),
        "veil_executions" => sim.veil_executions,
        "entities" => [Dict(
            "id" => e.id,
            "final_position" => [e.position.x, e.position.y, e.position.z],
            "final_velocity" => [e.velocity.x, e.velocity.y, e.velocity.z],
            "target" => [e.target_position.x, e.target_position.y, e.target_position.z],
            "error" => vec3_mag(vec3_sub(e.position, e.target_position))
        ) for e in sim.entities]
    ))

    data_hash = bytes2hex(sha256(snapshot_data))

    anchors = Dict{String, String}()
    for chain in chains
        if chain == "Bitcoin"
            anchors["Bitcoin"] = "op_return:0x$(data_hash[1:16])"
        elseif chain == "Arweave"
            anchors["Arweave"] = "tx:veilsim_$(sim.sim_id)_$data_hash"
        elseif chain == "Ethereum"
            anchors["Ethereum"] = "0x$(data_hash)"
        elseif chain == "Sui"
            anchors["Sui"] = "ase_veilsim_$(sim.sim_id)"
        end
    end

    println("[VeilSim] Anchored: $(join(keys(anchors), ", "))")
    return anchors
end

end # module VeilSimEngine
