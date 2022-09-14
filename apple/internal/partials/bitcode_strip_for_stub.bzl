# Copyright 2018 The Bazel Authors. All rights reserved.
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

"""Partial implementation for placing the messages support stub file in the archive."""

load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@bazel_skylib//lib:partial.bzl",
    "partial",
)

def _strip_bitcode_impl(
    actions, 
    binary, 
    output,
    platform_prerequisites,
    resolved_xctoolrunner):
    """Strips bitcode from the binary.
    """
    args = [
        "bitcode_strip",
        binary.path,
        "-r",
        "-o",
        output.path
    ]
    input_files = [binary]

    apple_support.run(
        actions = actions,
        arguments = args,
        apple_fragment = platform_prerequisites.apple_fragment,
        executable = resolved_xctoolrunner.executable,
        inputs = depset(input_files, transitive = [resolved_xctoolrunner.inputs]),
        input_manifests = resolved_xctoolrunner.input_manifests,
        mnemonic = "StripBitcode",
        outputs = [output],
        xcode_config = platform_prerequisites.xcode_version_config,
    )

def strip_bitcode_f(
        *,
        actions, 
        binary, 
        output,
        platform_prerequisites,
        resolved_xctoolrunner):
    """Constructor for the messages support stub processing partial.

    """
    _strip_bitcode_impl(
        actions = actions,
        binary = binary,
        output = output,
        platform_prerequisites = platform_prerequisites,
        resolved_xctoolrunner = resolved_xctoolrunner,
    )
