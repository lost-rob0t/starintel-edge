#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SBCL="${SBCL:-sbcl}"
# ASDF dependencies must already be available. This script never installs them.
"$SBCL" --script tests/mesh.lisp
"$SBCL" --script tests/mesh-zmq-contract.lisp
"$SBCL" --script tests/mesh-runtime.lisp
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! "$SBCL" --script tests/mesh-sento-security.lisp >"$log" 2>&1; then cat "$log"; exit 1; fi
if grep -q 'MESH-SECRET-MARKER' "$log"; then echo 'Secret marker leaked into default Sento output'; exit 1; fi
tail -1 "$log"
echo 'Default Sento output marker check passed. REAL ZeroMQ test was NOT run.'
