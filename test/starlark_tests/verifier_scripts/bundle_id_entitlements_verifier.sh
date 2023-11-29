#!/bin/bash

# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

TEMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/codesign_output.XXXXXX")"
TEMP_DER_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/codesign_der_output.XXXXXX")"

# Test for the presence of the bundle ID string within the test entitlements.
TEST_BUNDLE_ID_STRING="${BUNDLE_ID}"

if [[ "$BUILD_TYPE" == "simulator" ]]; then
  # First check the legacy xml plist section.
  xcrun llvm-objdump --macho --section=__TEXT,__entitlements "$BINARY" | \
      sed -e 's/^[0-9a-f][0-9a-f]*[[:space:]][[:space:]]*//' \
      -e 'tx' -e 'd' -e ':x' | xxd -r -p > "$TEMP_OUTPUT"

  assert_contains ".$TEST_BUNDLE_ID_STRING</string>" "$TEMP_OUTPUT"

  # Then check the new DER encoded section.
  xcrun llvm-objdump --macho --section=__TEXT,__ents_der "$BINARY" | \
      sed -e 's/^[0-9a-f][0-9a-f]*[[:space:]][[:space:]]*//' \
      -e 'tx' -e 'd' -e ':x' | xxd -r -p > "$TEMP_DER_OUTPUT"

  assert_contains ".$TEST_BUNDLE_ID_STRING" "$TEMP_DER_OUTPUT"

elif [[ "$BUILD_TYPE" == "device" ]]; then
  # First check the legacy xml plist section.
  codesign --display --xml --entitlements "$TEMP_OUTPUT" "$BUNDLE_ROOT"

  assert_contains ".$TEST_BUNDLE_ID_STRING</string>" "$TEMP_OUTPUT"

  # Then check the new DER encoded section.
  codesign --display --der --entitlements "$TEMP_DER_OUTPUT" "$BUNDLE_ROOT"

  assert_contains ".$TEST_BUNDLE_ID_STRING" "$TEMP_DER_OUTPUT"
else
  fail "Unsupported BUILD_TYPE = $BUILD_TYPE for this test"
fi

rm -rf "$TEMP_OUTPUT"
rm -rf "$TEMP_DER_OUTPUT"
