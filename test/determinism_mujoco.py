#!/usr/bin/env python3
"""
MuJoCo cross-machine determinism test — same methodology as
determinism_real.jl (fixed timestep, deterministic integrator, SHA256
the downsampled trajectory, compare hashes across machines).

A pendulum under gravity, no contacts (contacts are MuJoCo's biggest
determinism risk — solver iteration order can vary), RK4 integrator,
fixed dt, fixed number of steps, no randomness anywhere.

Confirmed identical hash on macOS x86_64 (Python 3.9.6) and Linux
x86_64 (Python 3.12.3), mujoco==3.3.7 pinned on both:
  5d731393877eaa77ab054ee43f6cd2edaf99ac29c17eda004737abf2968b20f6

ARM64 cross-arch comparison in progress — see OSOVM_CODEX.md §24/§42a.
"""
import hashlib
import json
import platform
import mujoco
import numpy as np

XML = """
<mujoco>
  <option timestep="0.002" integrator="RK4" gravity="0 0 -9.81"/>
  <worldbody>
    <light diffuse=".5 .5 .5" pos="0 0 3" dir="0 0 -1"/>
    <body name="pendulum" pos="0 0 1">
      <joint name="hinge" type="hinge" axis="0 1 0" pos="0 0 0.5"/>
      <geom type="capsule" fromto="0 0 0.5 0 0 -0.5" size="0.02" mass="1.0"/>
    </body>
  </worldbody>
</mujoco>
"""

def run_sim(n_steps=5000):
    model = mujoco.MjModel.from_xml_string(XML)
    data = mujoco.MjData(model)
    # Deterministic initial condition: start at 45 degrees, zero velocity.
    data.qpos[0] = np.pi / 4
    data.qvel[0] = 0.0

    checkpoints = []
    for step in range(n_steps):
        mujoco.mj_step(model, data)
        if step % 50 == 0:  # downsample, same pattern as validator.jl
            checkpoints.append({
                "t": round(float(data.time), 10),
                "qpos": round(float(data.qpos[0]), 10),
                "qvel": round(float(data.qvel[0]), 10),
            })
    return checkpoints

def trajectory_hash(checkpoints):
    payload = json.dumps(checkpoints, sort_keys=True).encode()
    return hashlib.sha256(payload).hexdigest()

if __name__ == "__main__":
    checkpoints = run_sim()
    h = trajectory_hash(checkpoints)
    print(f"platform: {platform.platform()}")
    print(f"machine: {platform.machine()}")
    print(f"python: {platform.python_version()}")
    print(f"mujoco: {mujoco.__version__}")
    print(f"checkpoints: {len(checkpoints)}")
    print(f"checkpoint[0] qpos (expect ~0.7853981634, pi/4): {checkpoints[0]['qpos']}")
    print(f"final qpos: {checkpoints[-1]['qpos']}")
    print(f"DETERMINISM_HASH={h}")
