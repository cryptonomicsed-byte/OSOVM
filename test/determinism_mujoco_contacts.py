#!/usr/bin/env python3
"""
MuJoCo contact-resolution determinism test — the real risk case flagged
in determinism_mujoco.py. That test deliberately avoided contacts (a
free pendulum); this one is a box dropped onto a floor, hits, bounces,
and settles under friction. Contact solving is iterative (MuJoCo's
default is a Newton/CG-based solver over active constraints), and
solver *iteration order* is exactly the kind of thing that can legally
differ across platforms without being a "bug" anywhere -- which is
why this, not the free-fall/pendulum case, is the real determinism
bar for anything that touches the ground.

Same methodology as determinism_mujoco.py: fixed timestep, no
randomness, downsampled trajectory, SHA256, DETERMINISM_HASH= line
for CI grep.
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
    <geom name="floor" type="plane" size="5 5 0.1" friction="0.8 0.02 0.001"/>
    <body name="box" pos="0.3 0 1.0" euler="10 20 5">
      <freejoint/>
      <geom name="box_geom" type="box" size="0.15 0.15 0.15" mass="1.0"
            friction="0.8 0.02 0.001" solref="0.02 1" solimp="0.9 0.95 0.001"/>
    </body>
  </worldbody>
</mujoco>
"""

def run_sim(n_steps=5000):
    model = mujoco.MjModel.from_xml_string(XML)
    data = mujoco.MjData(model)
    # No velocity, no randomness -- position/orientation set in the XML
    # itself (tilted box, off-center start) so it tumbles and bounces
    # before settling, exercising real contact transitions.

    checkpoints = []
    for step in range(n_steps):
        mujoco.mj_step(model, data)
        if step % 50 == 0:  # downsample, same pattern as determinism_mujoco.py
            checkpoints.append({
                "t": round(float(data.time), 10),
                "pos": [round(float(x), 10) for x in data.qpos[0:3]],
                "quat": [round(float(x), 10) for x in data.qpos[3:7]],
                "ncon": int(data.ncon),  # active contact count -- the solver-sensitive part
            })
    return checkpoints

def trajectory_hash(checkpoints):
    payload = json.dumps(checkpoints, sort_keys=True).encode()
    return hashlib.sha256(payload).hexdigest()

if __name__ == "__main__":
    checkpoints = run_sim()
    h = trajectory_hash(checkpoints)
    settled = checkpoints[-1]
    print(f"platform: {platform.platform()}")
    print(f"machine: {platform.machine()}")
    print(f"python: {platform.python_version()}")
    print(f"mujoco: {mujoco.__version__}")
    print(f"checkpoints: {len(checkpoints)}")
    print(f"max ncon seen: {max(c['ncon'] for c in checkpoints)}")
    print(f"final pos (expect resting near z~0.15, box half-height): {settled['pos']}")
    print(f"DETERMINISM_HASH={h}")
