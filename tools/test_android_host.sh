#!/usr/bin/env bash
# No downloads. Requires an existing JDK with jdk.compiler, Python 3, and C99 compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
src=platforms/android/edge-service/src/main/java/actor/starintel/edge/service
java com.sun.tools.javac.Main -source 17 -target 17 -d "$out" \
  "$src/LocalRuntimeBackend.java" "$src/RuntimeController.java" "$src/PrivateInitFile.java" "$src/EclLifecycle.java" "$src/RuntimeAssets.java" \
  tests/android/RuntimeControllerTest.java tests/android/EclLifecycleTest.java
java -cp "$out" actor.starintel.edge.service.RuntimeControllerTest
java -cp "$out" actor.starintel.edge.service.EclLifecycleTest
python3 -m unittest discover -s tests/android -p 'test_*.py' -v
