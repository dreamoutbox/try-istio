#!/usr/bin/env python3
"""Patch k8s/jwt/request-authn.yaml template by inlining the JWKS JSON."""
import sys


def main() -> None:
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <template.yaml> <jwks.json> <output.yaml>", file=sys.stderr)
        sys.exit(1)

    template_path = sys.argv[1]
    jwks_path = sys.argv[2]
    out_path = sys.argv[3]

    with open(template_path, "r", encoding="utf-8") as f:
        template = f.read()

    with open(jwks_path, "r", encoding="utf-8") as f:
        jwks = f.read().strip()

    # Indent each JWKS line by 8 spaces to fit YAML block scalar under `jwks: |`
    indented_jwks = "\n".join("        " + line for line in jwks.splitlines())
    patched = template.replace("        PLACEHOLDER_REPLACE_WITH_JWKS_JSON", indented_jwks)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(patched)


if __name__ == "__main__":
    main()
