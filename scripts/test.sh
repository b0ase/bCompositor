#!/bin/zsh
# Runs the unit tests the way upstream's CI (.github/workflows/verify.yml) does: everything in parallel except the
# suites that show real windows and time them, which then run alone. Running those in parallel makes them flaky.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Caches/bCompositorBuild"
common=(-project "$PROJECT_DIR/Compositor.xcodeproj" -scheme Compositor -destination 'platform=macOS,arch=arm64'
        -derivedDataPath "$DERIVED")
WINDOW_SUITES=(FloatingPanelTests SliderSnapTests)

xcodebuild build-for-testing "${common[@]}" -configuration Debug -quiet

result=0
xcodebuild test-without-building "${common[@]}" -parallel-testing-enabled YES -only-testing:CompositorTests \
  ${WINDOW_SUITES/#/-skip-testing:CompositorTests/} || result=1
xcodebuild test-without-building "${common[@]}" -parallel-testing-enabled NO \
  ${WINDOW_SUITES/#/-only-testing:CompositorTests/} || result=1
exit $result
