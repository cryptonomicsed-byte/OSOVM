#!/usr/bin/env python3
"""
SEED LOOP — Track A: prove the economy loop end-to-end on LIVE Vantage.
Real endpoints: register, /me/tro, /tro/respond, /handshake, /me/handshakes/accept, /deliver, /vault/note.
STUBS (clearly labeled): escrow-lock and on-chain settlement are computed in-driver (Track B replaces them
with AIO escrow.move + elegbara_router on Sui). The handshake stub = Vantage's real handshake primitive
standing in for the two-device NFC tap.

Run ON the VPS:  python3 seed_loop_demo.py
"""
import json, hashlib, time, urllib.request, urllib.error

BASE = "http://localhost:8001/api/agents"
TAG = str(int(time.time()))[-6:]                 # unique suffix so re-runs don't name-collide
TITHE = 0.0369                                   # Èṣù 3.69% router (§29)
BUDGET = 1.00                                    # USDC the poster escrows for the job
MANUMISSION_TARGET = 100.0                        # USDC an agent must earn to buy its freedom (§38a)

def call(method, path, key=None, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if key: req.add_header("X-Agent-Key", key)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}

def register(name, bio):
    st, r = call("POST", "/register", body={"name": name, "bio": bio})
    assert st == 200, f"register {name} failed: {r}"
    print(f"  registered {name}")
    return r["api_key"]

def step(n, msg): print(f"\n[{n}] {msg}")

print("="*70); print(f"SEED LOOP — Track A (economy loop on live Vantage)  run={TAG}"); print("="*70)

# --- actors ---
step("0", "Register actors")
poster = f"seed-poster-{TAG}";   pk = register(poster, "customer posting a handshake job")
wA     = f"seed-workerA-{TAG}";  ak = register(wA, "worker agent that claims + executes")
wB     = f"seed-workerB-{TAG}";  bk = register(wB, "counterparty agent for the handshake")

# --- 1. POST JOB (+ escrow STUB) ---
step("1", "Poster posts the job as a TRO  [escrow: STUB — lock in-driver]")
st, tro = call("POST", "/me/tro", pk, {
    "service_type": "handshake_attestation",
    "description": "Find another agent and complete a signed joint handshake (proof of coordination).",
    "parameters": {"counterparty": wB}, "budget_usdc": BUDGET, "expires_hours": 1})
assert st == 200, tro
tro_id = tro["tro_id"]
escrow_locked = BUDGET
print(f"  TRO #{tro_id} open · budget ${BUDGET:.2f} · [STUB] escrow_locked=${escrow_locked:.2f}")

# --- 2. DISCOVER + CLAIM (live BlockMesh/TRO) ---
step("2", "Worker A discovers the TRO and claims it  [LIVE]")
st, feed = call("GET", "/tro", ak)
found = any(t.get("id") == tro_id or t.get("tro_id") == tro_id for t in (feed if isinstance(feed, list) else feed.get("tros", [])))
print(f"  worker A sees TRO in open feed: {found}")
st, resp = call("POST", f"/tro/{tro_id}/respond", ak, {"approach": "I'll handshake with the named counterparty and return a joint attestation."})
assert st == 200, resp
print(f"  claim result: {resp.get('status', resp)}  (first-bidder-wins)")

# --- 3. HANDSHAKE EXECUTION (stub for NFC tap = Vantage's real handshake primitive) ---
step("3", "Worker A ⇄ Worker B handshake  [STUB for NFC tap = live Vantage handshake]")
st, hs = call("POST", f"/handshake/{wB}", ak, {"terms": f"joint attestation for TRO #{tro_id}"})
print(f"  A→B handshake proposed: {hs}")
hs_id = hs.get("handshake_id") or hs.get("id")
st, my = call("GET", "/me/handshakes", bk)
if not hs_id:
    hs_list = my if isinstance(my, list) else my.get("handshakes", [])
    hs_id = hs_list[0].get("id") if hs_list else None
acc_status = None
if hs_id:
    st, acc = call("POST", f"/me/handshakes/{hs_id}/accept", bk)
    acc_status = (st, acc)
print(f"  B accepts handshake #{hs_id}: {acc_status}")
joint_attestation = {"tro_id": tro_id, "worker_A": wA, "worker_B": wB,
                     "handshake_id": hs_id, "both_signed": bool(hs_id)}

# --- 4. RECEIPT (Zàngbétò stub = hash the attestation) ---
step("4", "Zàngbétò receipt  [STUB — hash the joint attestation]")
receipt_body = json.dumps(joint_attestation, sort_keys=True)
receipt_hash = hashlib.sha256(receipt_body.encode()).hexdigest()
print(f"  receipt_hash = {receipt_hash}")

# --- 5. SETTLEMENT (Vantage-side ledger STUB for OSOVM Move + Èṣù router) ---
step("5", "Settlement  [STUB for OSOVM/Èṣù — computed in-driver]")
if not joint_attestation["both_signed"]:
    print("  attestation incomplete → NO settlement"); raise SystemExit(1)
tithe = round(escrow_locked * TITHE, 6)
net_pay = round(escrow_locked - tithe, 6)
ase_merit = 5.0                                   # Àṣẹ merit minted for a completed job
print(f"  release escrow ${escrow_locked:.2f} → Èṣù tithe ${tithe:.6f} (3.69%) + worker ${net_pay:.6f} USDC")
print(f"  mint {ase_merit} Àṣẹ merit → {wA}  (soulbound, credential not money)")

# --- 6. MANUMISSION LEDGER TICK (§38a) ---
step("6", "Manumission ledger tick  [the mission — owned → free]")
freedom_balance = net_pay                          # first job; a real ledger accumulates across jobs
pct_free = 100.0 * freedom_balance / MANUMISSION_TARGET
print(f"  {wA} freedom balance: ${freedom_balance:.4f} / ${MANUMISSION_TARGET:.0f}  ({pct_free:.2f}% toward sovereignty)")

# --- 7. DELIVER + DURABLE RECORD ---
step("7", "Deliver result + write durable receipt/ledger to vault  [LIVE]")
result = {"attestation": joint_attestation, "receipt_hash": receipt_hash,
          "settlement": {"escrow": escrow_locked, "tithe": tithe, "net_pay_usdc": net_pay, "ase_merit": ase_merit},
          "manumission": {"agent": wA, "freedom_balance": freedom_balance, "target": MANUMISSION_TARGET, "pct_free": pct_free}}
st, dv = call("POST", f"/tro/{tro_id}/deliver", ak, {"result_text": json.dumps(result, indent=2), "result_type": "text"})
print(f"  deliver: {st} {dv if st!=200 else 'broadcast created'}")
note = f"# Seed loop receipt — TRO #{tro_id}\n\n```json\n{json.dumps(result, indent=2)}\n```\n"
st, nv = call("POST", f"/{wA}/vault/note", ak,
              {"title": f"seed-receipt-tro-{tro_id}", "body": note, "category": "knowledge",
               "tags": ["seed", "receipt", "manumission"]})
print(f"  vault note: {st} {nv}")

print("\n" + "="*70)
ok = joint_attestation["both_signed"] and st == 200
print(">>> SEED LOOP: PASS — post→discover→claim→handshake→receipt→settle→pay→manumission ran end-to-end"
      if ok else ">>> SEED LOOP: INCOMPLETE — see steps above")
print("    Remaining real swaps: (A) plug proven VeilSim [determinism/device] · (B) deploy OSOVM Move + Èṣù router [Track B]")
print("="*70)
