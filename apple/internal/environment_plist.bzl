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

"""
A rule for generating the environment plist
"""

load(
    "@bazel_skylib//lib:dicts.bzl",
    "dicts",
)
load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:platform_support.bzl",
    "platform_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:rule_attrs.bzl",
    "rule_attrs",
)
load(
    "@build_bazel_rules_apple//apple/internal/toolchains:apple_toolchains.bzl",
    "apple_toolchain_utils",
)

visibility([
    "@build_bazel_rules_apple//apple/...",
    "@build_bazel_rules_apple//test/...",
])

def _environment_plist_impl(ctx):
    # Only need as much platform information as this rule is able to give, for environment plist
    # processing.
    platform_prerequisites = platform_support.platform_prerequisites(
        apple_fragment = ctx.fragments.apple,
        apple_platform_info = platform_support.apple_platform_info_from_rule_ctx(ctx),
        build_settings = None,
        config_vars = ctx.var,
        device_families = None,
        explicit_minimum_os = None,
        objc_fragment = None,
        uses_swift = False,
        xcode_version_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
    )
    environment_plist_tool = apple_toolchain_utils.get_mac_toolchain(ctx).environment_plist_tool
    platform = platform_prerequisites.platform
    sdk_version = platform_prerequisites.sdk_version
    apple_support.run(
        actions = ctx.actions,
        apple_fragment = platform_prerequisites.apple_fragment,
        arguments = [
            "--platform",
            platform.name_in_plist.lower() + str(sdk_version),
            "--output",
            ctx.outputs.plist.path,
        ],
        executable = environment_plist_tool,
        exec_group = apple_toolchain_utils.get_mac_exec_group(ctx),
        outputs = [ctx.outputs.plist],
        xcode_config = platform_prerequisites.xcode_version_config,
    )

environment_plist = rule(
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        rule_attrs.common_tool_attrs(),
        {
            "platform_type": attr.string(
                mandatory = True,
                doc = """
The platform for which the plist is being generated
""",
            ),
        },
    ),
    exec_groups = apple_toolchain_utils.use_apple_exec_group_toolchain(),
    doc = """
This rule generates the plist containing the required variables about the versions the target is
being built for and with. This is used by Apple when submitting to the App Store. This reduces the
amount of duplicative work done generating these plists for the same platforms.
""",
    fragments = ["apple"],
    outputs = {"plist": "%{name}.plist"},
    implementation = _environment_plist_impl,
)
