# Copyright 2020 The Bazel Authors. All rights reserved.
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

"""Bitcode support."""

load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)

load(
    "@build_bazel_rules_apple//apple/internal:intermediates.bzl",
    "intermediates",
)

def _bitcode_mode_string(apple_fragment):
    """Returns a string representing the current Bitcode mode."""

    bitcode_mode = apple_fragment.bitcode_mode
    if not bitcode_mode:
        fail("Internal error: Can't figure out bitcode_mode from apple " +
             "fragment")

    bitcode_mode_string = str(bitcode_mode)
    bitcode_modes = ["embedded", "embedded_markers", "none"]
    if bitcode_mode_string in bitcode_modes:
        return bitcode_mode_string

    fail("Internal error: expected bitcode_mode to be one of: " +
         "{}, but got '{}'".format(
             bitcode_modes,
             bitcode_mode_string,
         ))

def _strip_bitcode(
    actions,
    binary_artifact,
    rule_label,
    platform_prerequisites,
    resolved_xctoolrunner,
    output_discriminator = None):
    """Strips bitcode from the binary.
    """
    intermediate = intermediates.file(
        actions = actions,
        target_name = rule_label.name,
        output_discriminator = output_discriminator,
        file_name = "BitcodeStriped",
    )
    args = [
        "bitcode_strip",
        binary_artifact.path,
        "-r",
        "-keep_cs",
        "-o",
        intermediate.path,
    ]
    apple_support.run(
        actions = actions,
        apple_fragment = platform_prerequisites.apple_fragment,
        arguments = args,
        executable = resolved_xctoolrunner.executable,
        inputs = depset([binary_artifact], transitive = [resolved_xctoolrunner.inputs]),
        input_manifests = resolved_xctoolrunner.input_manifests,
        mnemonic = "StripBitcode",
        outputs = [intermediate],
        xcode_config = platform_prerequisites.xcode_version_config,
    )
    return intermediate

bitcode_support = struct(
    bitcode_mode_string = _bitcode_mode_string,
    strip_bitcode = _strip_bitcode,
)
