#!/usr/bin/env bash
# Delete the kind cluster. CLEAN=1 also removes .tools/ (downloaded istioctl + addon samples).
source "$(dirname "$0")/lib.sh"
require kind
run kind delete cluster --name "$CLUSTER_NAME"
if [[ "${CLEAN:-0}" == 1 ]]; then run rm -rf "$TOOLS_DIR"; fi
