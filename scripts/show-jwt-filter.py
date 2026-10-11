#!/usr/bin/env python3
"""Read Envoy listener JSON from stdin and print the jwt_authn filter config."""
import json
import sys

cfg = json.load(sys.stdin)
for listener in cfg:
    for fc in listener.get("filterChains", []):
        for f in fc.get("filters", []):
            name = f.get("name", "")
            if "jwt_authn" in name or "jwt" in str(f).lower():
                print(json.dumps(f, indent=2)[:600])
                break
