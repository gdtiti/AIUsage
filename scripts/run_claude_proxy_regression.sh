#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/2] Running Claude proxy regression tests..."
(
  cd "$ROOT_DIR/QuotaBackend"
  swift test --filter QuotaHTTPServerProxyIntegrationTests
)

echo "[2/2] Building AIUsage and bundled QuotaServer helper..."
(
  cd "$ROOT_DIR"
  xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build CODE_SIGNING_ALLOWED=NO
)

echo "Claude proxy regression checks passed."
