#!/usr/bin/env python3
"""
test/openapi_schema_test.py -- proves OSOVM's published OpenAPI schema
(GET /v1/openapi.json) actually matches what the live server returns,
not just that the schema document is well-formed. A schema that looks
right but drifts from reality is worse than no schema -- consumers
would trust a contract the server doesn't actually honor.

Requires: OSOVM server running and reachable (default localhost:7778),
the `jsonschema` package (pip install jsonschema).
"""
import json
import subprocess
import sys
import urllib.request

from jsonschema import validate as js_validate

BASE = "http://localhost:7778"


def curl(method: str, path: str, data: dict | None = None) -> dict:
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())


def main() -> int:
    spec = curl("GET", "/v1/openapi.json")
    schemas = spec["components"]["schemas"]

    fails = 0

    def check(desc: str, schema_name: str, response: dict) -> None:
        nonlocal fails
        try:
            js_validate(instance=response, schema=schemas[schema_name])
            print(f"VALID  {desc} matches {schema_name}")
        except Exception as e:
            print(f"INVALID {desc} does NOT match {schema_name}: {e}")
            fails += 1

    check("GET /v1/health", "HealthResponse", curl("GET", "/v1/health"))

    vm = curl("POST", "/v1/vm", {"final_signer": "schema-test"})
    check("POST /v1/vm", "CreateVmResponse", vm)
    vm_id = vm["vm_id"]

    check("GET /v1/vm/{id}", "VmStateResponse", curl("GET", f"/v1/vm/{vm_id}"))

    exec_res = curl("POST", f"/v1/vm/{vm_id}/execute", {"opcode": "BALANCE", "agent": "x", "args": {}})
    check("POST /v1/vm/{id}/execute (success)", "ExecuteResponse", exec_res)

    check("GET /v1/vm/{unknown} (404)", "ErrorResponse", curl("GET", "/v1/vm/nonexistent"))

    ident = curl("POST", "/v1/identity", {"seed": "schema-test-seed", "path": "v1"})
    check("POST /v1/identity", "CreateIdentityResponse", ident)
    cid = ident["canonical_id"]

    link_res = curl("POST", f"/v1/identity/{cid}/link", {"pillar": "test", "pillar_id": "abc"})
    check("POST /v1/identity/{id}/link", "LinkIdentityResponse", link_res)

    check("GET /v1/identity/{id}", "IdentityResponse", curl("GET", f"/v1/identity/{cid}"))
    check("GET /v1/identity/lookup", "IdentityResponse", curl("GET", f"/v1/identity/lookup?pillar=test&pillar_id=abc"))

    print()
    if fails == 0:
        print("ALL LIVE RESPONSES MATCH THEIR PUBLISHED SCHEMA")
        return 0
    else:
        print(f"{fails} MISMATCH(ES)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
