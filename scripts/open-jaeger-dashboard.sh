#!/usr/bin/env bash
# Open the Jaeger dashboard via istioctl port-forward + browser.
# Blocks until Ctrl-C.
source "$(dirname "$0")/lib.sh"

istioctl dashboard jaeger
