#!/usr/bin/env bash
# Fast iOS 18 availability check without a simulator runtime or destination:
# type-checks the app and widget sources against the installed iOS SDK with an
# iOS 18 deployment target, so every iOS 26-only API shows up as an error.
# Use it after merging upstream (ios18 branch). Needs Xcode 26+.
#
# Usage: scripts/typecheck-ios18.sh        (logs: build/tc-app.log, build/tc-widget.log)
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
FLAGS=(
  -typecheck -sdk "$SDK" -target "${ARCH}-apple-ios18.0-simulator"
  -swift-version 5 -default-isolation MainActor
  -enable-upcoming-feature MemberImportVisibility
  # SWIFT_APPROACHABLE_CONCURRENCY = YES
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature DisableOutwardActorInference
  -enable-bare-slash-regex -D DEBUG -continue-building-after-errors
)

app_files=()
while IFS= read -r -d '' f; do app_files+=("$f"); done < <(find OpenLens -name '*.swift' -print0)
widget_files=(
  OpenLens/Models/OpenLensActivityAttributes.swift
  OpenLens/Models/SharedConnectionStore.swift
  OpenLens/Models/LiveActivityIntents.swift
  OpenLens/Models/AppGroupResolver.swift
)
while IFS= read -r -d '' f; do widget_files+=("$f"); done < <(find OpenLensActivityWidget -name '*.swift' -print0)

xcrun swiftc "${FLAGS[@]}" -module-name OpenLens "${app_files[@]}" > build/tc-app.log 2>&1
app_rc=$?
xcrun swiftc "${FLAGS[@]}" -module-name OpenLensActivityWidgetExtension -application-extension \
  "${widget_files[@]}" > build/tc-widget.log 2>&1
widget_rc=$?

for log in build/tc-app.log build/tc-widget.log; do
  echo "== $log: $(grep -cE '^[^ ].*: error:' "$log") error(s)"
  grep -E '^[^ ].*: error:' "$log" | sort -u | head -60
done
[ "$app_rc" -eq 0 ] && [ "$widget_rc" -eq 0 ]
