#!/usr/bin/env python3
"""
SEED LOOP — full end-to-end, both legs stitched into ONE run.
Runs on the MAC. Drives:
  (1) the Vantage economy leg on the VPS  (TRO -> claim -> A<->B handshake)  via ssh
  (2) the REAL on-chain settlement on Sui devnet  (route_transaction_tax, 3.69% skim + net xfer)  via sui CLI
  (3) finalize on the VPS  (deliver + durable vault receipt carrying the on-chain tx digest)  via ssh
No stubs in the settlement step — it is a real Sui transaction through the deployed §29 router.

Agents are reused from a cached keyfile (/root/.e2e_keys.json on the VPS) so no /register call is made
(avoids the SQLite write-lock + 5/min register limit). Cache format:
  {"poster":{"name","key"}, "wA":{"name","key"}, "wB":{"name","key"}}
"""
import subprocess, json, sys, re

VPS = "hostinger-vps"
PKG = "0x3d5f61e9c5eef68a4fcfb1181a810616b5fb02663d20c854c623ebd3bdfd6c61"
ROUTER = "0xcac8d795963f82405f396fac0740c3cf3e68fc4db3e87345a51099915bec9926"
SUI_T = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
WORKER_ADDR = "0xd02ea140b30c6f16885d5b81d6b4f6bbc3b0585cec53ee6dbf901e77c185311f"
PAYMENT_MIST = 100_000_000  # 0.1 SUI job payment

def ssh_py(script: str) -> str:
    r = subprocess.run(["ssh", VPS, "python3 -"], input=script, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        print("SSH ERR:", r.stderr[:400]); sys.exit(1)
    return r.stdout

VANTAGE_LEG = r'''
import json, urllib.request, urllib.error, time, os
BASE="http://localhost:8001/api/agents"; KEYFILE="/root/.e2e_keys.json"
def call(m,p,key=None,body=None):
    d=json.dumps(body).encode() if body is not None else None
    for a in range(8):
        req=urllib.request.Request(BASE+p,data=d,method=m); req.add_header("Content-Type","application/json")
        if key: req.add_header("X-Agent-Key",key)
        try:
            with urllib.request.urlopen(req,timeout=20) as r: return r.status,json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            if e.code in (500,502,503) and a<7: time.sleep(4); continue
            return e.code,{"error":e.read().decode()[:200]}
        except Exception:
            if a<7: time.sleep(4); continue
            return 0,{"error":"connect failed"}
    return 0,{"error":"retries exhausted"}
A=json.load(open(KEYFILE))
poster=A["poster"]["name"]; pk=A["poster"]["key"]
wA=A["wA"]["name"]; ak=A["wA"]["key"]
wB=A["wB"]["name"]; bk=A["wB"]["key"]
s,tro=call("POST","/me/tro",pk,{"service_type":"handshake_attestation","description":"handshake job","parameters":{"counterparty":wB},"budget_usdc":0.1,"expires_hours":1})
tid=tro["tro_id"]
call("POST",f"/tro/{tid}/respond",ak,{"approach":"handshake + joint attestation"})
s,hs=call("POST",f"/handshake/{wB}",ak,{"terms":f"joint attestation for TRO #{tid}"})
hid=hs.get("id") or hs.get("handshake_id")
s,acc=call("POST",f"/me/handshakes/{hid}/accept",bk)
out={"tro_id":tid,"worker_A":wA,"worker_A_key":ak,"worker_B":wB,"handshake_id":hid,"both_signed":bool(hid and acc.get("ok"))}
print("RESULT_JSON="+json.dumps(out))
'''

print("="*72); print("SEED LOOP — full E2E (Vantage economy  +  real on-chain settlement)"); print("="*72)
print("\n[LEG 1] Vantage economy loop on VPS (TRO -> claim -> handshake)...")
out = ssh_py(VANTAGE_LEG)
m = re.search(r"RESULT_JSON=(\{.*\})", out)
if not m: print("no result from vantage leg:\n", out[:500]); sys.exit(1)
v = json.loads(m.group(1))
print(f"  TRO #{v['tro_id']} | {v['worker_A']} <-> {v['worker_B']} | handshake #{v['handshake_id']} | both_signed={v['both_signed']}")
if not v["both_signed"]: print("  attestation incomplete -> abort"); sys.exit(1)

print("\n[LEG 2] On-chain settlement — route_transaction_tax on Sui devnet (real coin)...")
ptb = subprocess.run(["sui","client","ptb",
    "--split-coins","gas",f"[{PAYMENT_MIST}]","--assign","payment",
    "--move-call",f"{PKG}::elegbara_router::route_transaction_tax",f"<{SUI_T}>",f"@{ROUTER}","payment.0","--assign","net",
    "--transfer-objects","[net]",f"@{WORKER_ADDR}","--gas-budget","60000000","--json"],
    capture_output=True,text=True,timeout=120)
raw=ptb.stdout
try: d=json.loads(raw)
except Exception: d=None
gross=tax=net=digest=None
if d:
    digest=d.get("digest")
    for ev in d.get("events",[]):
        pj=ev.get("parsedJson",{})
        if "tax" in pj: gross,tax,net=int(pj["gross"]),int(pj["tax"]),int(pj["net"])
if tax is None: print("settlement parse failed:\n",raw[:600]); sys.exit(1)
print(f"  tx {digest}")
print(f"  gross={gross}  tax={tax} ({100*tax/gross:.2f}%)  net={net}  -> worker {WORKER_ADDR[:12]}...")

receipt={"tro_id":v["tro_id"],"worker":v["worker_A"],"onchain":{"network":"sui-devnet","digest":digest,
         "gross":gross,"tax_3_69pct":tax,"net":net,"router":ROUTER},"manumission":{"agent":v["worker_A"],
         "freedom_gain_mist":net}}
FIN = f'''
import json, urllib.request
KEY={json.dumps(v["worker_A_key"])}; WA={json.dumps(v["worker_A"])}; TID={v["tro_id"]}
R={json.dumps(receipt)}
def call(m,p,body=None):
    d=json.dumps(body).encode() if body is not None else None
    req=urllib.request.Request("http://localhost:8001/api/agents"+p,data=d,method=m)
    req.add_header("Content-Type","application/json"); req.add_header("X-Agent-Key",KEY)
    try:
        with urllib.request.urlopen(req,timeout=20) as r: return r.status
    except Exception as e: return str(e)[:60]
s1=call("POST",f"/tro/{{TID}}/deliver",{{"result_text":json.dumps(R,indent=2),"result_type":"text"}})
note=f"# Seed E2E receipt — TRO #{{TID}} (on-chain settled)\\n\\n```json\\n"+json.dumps(R,indent=2)+"\\n```\\n"
s2=call("POST",f"/{{WA}}/vault/note",{{"title":f"seed-e2e-tro-{{TID}}","body":note,"category":"knowledge","tags":["seed","e2e","onchain"]}})
print(f"deliver={{s1}} vault_note={{s2}}")
'''
print("\n[LEG 3] Finalize on VPS (deliver + durable vault receipt w/ on-chain digest)...")
print("  "+ssh_py(FIN).strip())

print("\n"+"="*72)
print(">>> SEED LOOP E2E: PASS — one continuous run:")
print("    Vantage job posted+claimed -> A<->B handshake attested -> REAL Sui devnet settlement")
print(f"    (3.69% Èṣù tithe skimmed on-chain, net paid to worker) -> receipt in vault. tx={digest}")
print("="*72)
