# Copyright 2021 The Bazel Authors. All rights reserved.
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

"""Implementation of the xcframework rules."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@build_bazel_rules_apple//apple:providers.bzl",
    "AppleBundleVersionInfo",
    "ApplePlatformInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal:apple_product_type.bzl",
    "apple_product_type",
)
load(
    "@build_bazel_rules_apple//apple/internal:apple_toolchains.bzl",
    "apple_toolchain_utils",
)
load(
    "@build_bazel_rules_apple//apple/internal:cc_info_support.bzl",
    "cc_info_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:experimental.bzl",
    "is_experimental_tree_artifact_enabled",
)
load(
    "@build_bazel_rules_apple//apple/internal:intermediates.bzl",
    "intermediates",
)
load(
    "@build_bazel_rules_apple//apple/internal:linking_support.bzl",
    "linking_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:outputs.bzl",
    "outputs",
)
load(
    "@build_bazel_rules_apple//apple/internal:partials.bzl",
    "partials",
)
load(
    "@build_bazel_rules_apple//apple/internal:platform_support.bzl",
    "platform_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:processor.bzl",
    "processor",
)
load(
    "@build_bazel_rules_apple//apple/internal:providers.bzl",
    "new_applebundleinfo",
    "new_applestaticxcframeworkbundleinfo",
    "new_applexcframeworkbundleinfo",
)
load(
    "@build_bazel_rules_apple//apple/internal:resources.bzl",
    "resources",
)
load(
    "@build_bazel_rules_apple//apple/internal:rule_attrs.bzl",
    "rule_attrs",
)
load(
    "@build_bazel_rules_apple//apple/internal:rule_factory.bzl",
    "rule_factory",
)
load(
    "@build_bazel_rules_apple//apple/internal:rule_support.bzl",
    "rule_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:swift_support.bzl",
    "swift_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:transition_support.bzl",
    "transition_support",
)
load(
    "@build_bazel_rules_apple//apple/internal/aspects:resource_aspect.bzl",
    "apple_resource_aspect",
)
load(
    "@build_bazel_rules_apple//apple/internal/aspects:swift_usage_aspect.bzl",
    "swift_usage_aspect",
)
load(
    "@build_bazel_rules_apple//apple/internal/utils:files.bzl",
    "files",
)
load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftInfo")

visibility([
    "//apple/...",
    "//test/...",
])

def _group_link_outputs_by_library_identifier(
        *,
        actions,
        apple_fragment,
        deps,
        label_name,
        link_result,
        xcode_config):
    """Groups linking outputs by library identifier with additional platform information.

    Linking outputs artifacts are combined using the lipo tool if necessary due to grouping.

    Args:
        actions: The actions provider from `ctx.actions`.
        apple_fragment: An Apple fragment (ctx.fragments.apple).
        deps: Label list of dependencies from rule context (ctx.split_attr.deps).
        label_name: Name of the target being built.
        link_result: The struct returned by `linking_support.register_binary_linking_action`.
        xcode_config: The `apple_common.XcodeVersionConfig` provider from the context.

    Returns:
        A list of structs with the following fields; `architectures` containing a list of the
        architectures that the binary was built with, `binary` referencing the output binary linked
        with the `lipo` tool if necessary, or referencing a symlink to the original binary if not,
        `dsym_binaries` which is a mapping of architectures to dsym binaries if any were created,
        `environment` to reference the target environment the binary was built for, `linkmaps` which
        is a mapping of architectures to linkmaps if any were created, and `platform` to reference
        the target platform the binary was built for.
    """
    linking_type = None
    for attr_name in ["binary", "library"]:
        if hasattr(link_result, attr_name):
            linking_type = attr_name
            break

    if not linking_type:
        fail("Apple linking APIs output struct must define either 'binary' or 'library'.\n" +
             "This is most likely a rules_apple bug, please file a bug with reproduction steps.")

    # Organize each output as a platform_environment, where each can accept one or more archs.
    link_outputs_by_framework = {}

    # Iterate through the outputs of the registered linking action, match archs to platform and
    # environment combinations.
    for link_output in link_result.outputs:
        framework_key = link_output.platform + "_" + link_output.environment
        if link_outputs_by_framework.get(framework_key):
            link_outputs_by_framework[framework_key].append(link_output)
        else:
            link_outputs_by_framework[framework_key] = [link_output]

    link_outputs_by_library_identifier = {}

    # Iterate through the structure again, this time creating a structure equivalent to link_result
    # .outputs but with .architecture replaced with .architectures, .dsym_binary replaced with
    # .dsym_binaries, and .linkmap replaced with .linkmaps
    for framework_key, link_outputs in link_outputs_by_framework.items():
        inputs = [getattr(output, linking_type) for output in link_outputs]
        filename = "{}_{}".format(label_name, framework_key)
        extension = inputs[0].extension
        if extension != "":
            filename = "{}.{}".format(filename, extension)
        fat_binary = actions.declare_file(filename)
        linking_support.lipo_or_symlink_inputs(
            actions = actions,
            inputs = inputs,
            output = fat_binary,
            apple_fragment = apple_fragment,
            xcode_config = xcode_config,
        )

        architectures = []
        dsym_binaries = {}
        linkmaps = {}
        split_attr_keys = []
        swift_infos = {}
        uses_swift = False
        for link_output in link_outputs:
            split_attr_key = transition_support.xcframework_split_attr_key(
                arch = link_output.architecture,
                environment = link_output.environment,
                platform_type = link_output.platform,
            )

            architectures.append(link_output.architecture)
            split_attr_keys.append(split_attr_key)

            # If there's any Swift dependencies on this framework rule,
            # look for providers to see if we need to generate Swift interfaces.
            if swift_support.uses_swift(deps[split_attr_key]):
                uses_swift = True
                for dep in deps[split_attr_key]:
                    if SwiftInfo in dep:
                        swift_infos[link_output.architecture] = dep[SwiftInfo]

            # static library linking does not support dsym, and linkmaps yet.
            if linking_type == "binary":
                dsym_binaries[link_output.architecture] = link_output.dsym_binary
                linkmaps[link_output.architecture] = link_output.linkmap

        environment = link_outputs[0].environment
        platform = link_outputs[0].platform

        library_identifier = _library_identifier(
            architectures = architectures,
            environment = environment,
            platform = platform,
        )

        link_outputs_by_library_identifier[library_identifier] = struct(
            architectures = architectures,
            binary = fat_binary,
            dsym_binaries = dsym_binaries,
            environment = environment,
            linkmaps = linkmaps,
            platform = platform,
            split_attr_keys = split_attr_keys,
            swift_infos = swift_infos,
            uses_swift = uses_swift,
        )

    return link_outputs_by_library_identifier

def _library_identifier(*, architectures, environment, platform):
    """Return a unique identifier for an embedded framework to disambiguate it from others.

    Args:
        architectures: The architectures of the target that was built. For example, `x86_64` or
            `arm64`.
        environment: The environment of the target that was built, which corresponds to the
            toolchain's target triple values as reported by `apple_common` linking APIs.
            Typically `device` or `simulator`.
        platform: The platform of the target that was built, which corresponds to the toolchain's
            target triple values as reported by `apple_common` linking APIs.
            For example, `ios`, `macos`, `tvos` or `watchos`.

    Returns:
        A string that can be used to determine the subfolder this embedded framework will be found
        in the final XCFramework bundle. This mirrors the formatting for subfolders as given by the
        xcodebuild -create-xcframework tool.
    """
    library_identifier = "{}-{}".format(platform, "_".join(architectures))
    if environment != "device":
        library_identifier += "-{}".format(environment)
    return library_identifier

def _unioned_attrs(*, attr_names, split_attr, split_attr_keys):
    """Return a list of attribute values unioned for the given attributes, by split attribute key.

     Args:
        attr_names: The rule attributes to union. Assumed to contain lists of values.
        split_attr: The Starlark interface for 1:2+ transitions, typically from `ctx.split_attr`.
        split_attr_keys: A list of strings representing each 1:2+ transition key to check.

    Returns:
        A new list of attributes based on the union of all rule attributes given, by split
        attribute key.
    """
    unioned_attrs = []
    for attr_name in attr_names:
        attr = getattr(split_attr, attr_name)
        if not attr:
            continue
        for split_attr_key in split_attr_keys:
            found_attr = attr.get(split_attr_key)
            if found_attr:
                unioned_attrs += found_attr
    return unioned_attrs

def _available_library_dictionary(
        *,
        architectures,
        environment,
        headers_path,
        library_identifier,
        library_path,
        platform):
    """Generates a dictionary containing keys referencing a framework in the XCFramework bundle.

     Args:
        architectures: The architectures of the target that was built. For example, `x86_64` or
            `arm64`.
        environment: The environment of the target that was built, which corresponds to the
            toolchain's target triple values as reported by `apple_common` linking APIs.
            Typically `device` or `simulator`.
        headers_path: A string representing the path inside the library identifier to reference
            bundled headers and modulemap files.
        library_identifier: A string representing the path to the framework to reference in the
            xcframework bundle.
        library_path: A string representing the path inside the library identifier to reference in
            the xcframework bundle.
        platform: The platform of the target that was built, which corresponds to the toolchain's
            target triple values as reported by `apple_common` linking APIs.
            For example, `ios`, `macos`, `tvos` or `watchos`.

    Returns:
        A dictionary containing keys representing how a given framework should be referenced in the
        root Info.plist of a given XCFramework bundle.
    """
    available_library = {
        "LibraryIdentifier": library_identifier,
        "LibraryPath": library_path,
        "SupportedArchitectures": architectures,
        "SupportedPlatform": platform,
    }

    if headers_path:
        available_library["HeadersPath"] = headers_path

    if environment != "device":
        available_library["SupportedPlatformVariant"] = environment
    return available_library

def _create_xcframework_root_infoplist(
        *,
        actions,
        apple_fragment,
        available_libraries,
        exec_group,
        resolved_plisttool,
        rule_label,
        xcode_config):
    """Generates a root Info.plist for a given XCFramework.

     Args:
        actions: The actions provider from `ctx.actions`.
        apple_fragment: An Apple fragment (ctx.fragments.apple).
        available_libraries: A dictionary containing keys representing how a given framework should
            be referenced in the root Info.plist of a given XCFramework bundle.
        exec_group: The exec_group associated with resolved_plisttool
        resolved_plisttool: A struct referencing the resolved plist tool.
        rule_label: The label of the target being analyzed.
        xcode_config: The `apple_common.XcodeVersionConfig` provider from the context.

    Returns:
        A `File` representing a root Info.plist to be embedded within an XCFramework bundle.
    """
    root_info_plist = intermediates.file(
        actions = actions,
        target_name = rule_label.name,
        output_discriminator = None,
        file_name = "Info.plist",
    )

    default_xcframework_plist = {
        "CFBundlePackageType": "XFWK",
        "XCFrameworkFormatVersion": "1.0",
    }

    plisttool_control = struct(
        binary = False,
        output = root_info_plist.path,
        plists = [{"AvailableLibraries": available_libraries}, default_xcframework_plist],
        target = str(rule_label),
    )
    plisttool_control_file = intermediates.file(
        actions = actions,
        target_name = rule_label.name,
        output_discriminator = None,
        file_name = "xcframework_plisttool_control.json",
    )
    actions.write(
        output = plisttool_control_file,
        content = json.encode(plisttool_control),
    )
    apple_support.run(
        actions = actions,
        apple_fragment = apple_fragment,
        arguments = [plisttool_control_file.path],
        executable = resolved_plisttool.executable,
        exec_group = exec_group,
        inputs = depset([plisttool_control_file], transitive = [resolved_plisttool.inputs]),
        input_manifests = resolved_plisttool.input_manifests,
        mnemonic = "CreateXCFrameworkRootInfoPlist",
        outputs = [root_info_plist],
        xcode_config = xcode_config,
    )
    return root_info_plist

def _create_xcframework_bundle(
        *,
        actions,
        bundle_name,
        framework_archive_files,
        framework_archive_merge_files,
        framework_archive_merge_zips = [],
        label_name,
        output_archive,
        bundletool,
        xplat_exec_group,
        root_info_plist):
    """Generates the bundle archive for an XCFramework.

     Args:
        actions: The actions providerx from `ctx.actions`.
        bundle_name: The name of the XCFramework bundle.
        framework_archive_files: A list of depsets referencing files to be used as inputs to the
            bundling action. This should include every archive referenced as a "src" of
            framework_archive_merge_zips.
        framework_archive_merge_files: A list of structs representing files that should be merged
            into the bundle. Each struct contains two fields: "src", the path of the file that
            should be merged into the bundle; and "dest", the path inside the bundle where the file
            should be placed. The destination path is relative to `bundle_path`.
        framework_archive_merge_zips: A list of structs representing ZIP archives whose contents
            should be merged into the bundle. Each struct contains two fields: "src", the path of
            the archive whose contents should be merged into the bundle; and "dest", the path inside
            the bundle where the ZIPs contents should be placed. The destination path is relative to
            `bundle_path`.
        label_name: Name of the target being built.
        output_archive: The file representing the final bundled archive.
        bundletool: A bundle tool from xplat toolchain.
        xplat_exec_group: A string. The exec_group for actions using xplat toolchain.
        root_info_plist: A `File` representing a fully formed root Info.plist for this XCFramework.
    """
    bundletool_control_file = intermediates.file(
        actions = actions,
        target_name = label_name,
        output_discriminator = None,
        file_name = "xcframework_bundletool_control.json",
    )
    root_info_plist_merge_file = struct(src = root_info_plist.path, dest = "Info.plist")
    bundletool_control = struct(
        bundle_merge_files = [root_info_plist_merge_file] + framework_archive_merge_files,
        bundle_merge_zips = framework_archive_merge_zips,
        bundle_path = bundle_name + ".xcframework",
        output = output_archive.path,
    )
    actions.write(
        output = bundletool_control_file,
        content = json.encode(bundletool_control),
    )

    actions.run(
        arguments = [bundletool_control_file.path],
        executable = bundletool.files_to_run,
        inputs = depset(
            direct = [bundletool_control_file, root_info_plist],
            transitive = framework_archive_files,
        ),
        mnemonic = "CreateXCFrameworkBundle",
        outputs = [output_archive],
        progress_message = "Bundling %s" % label_name,
        exec_group = xplat_exec_group,
    )

def _apple_xcframework_impl(ctx):
    """Implementation of apple_xcframework."""
    actions = ctx.actions
    apple_mac_toolchain_info = apple_toolchain_utils.get_mac_toolchain(ctx)
    apple_xplat_toolchain_info = apple_toolchain_utils.get_xplat_toolchain(ctx)
    bundle_name = ctx.attr.bundle_name or ctx.attr.name
    deps = ctx.split_attr.deps
    mac_exec_group = apple_toolchain_utils.get_mac_exec_group(ctx)

    if (apple_xplat_toolchain_info.build_settings.use_tree_artifacts_outputs or
        is_experimental_tree_artifact_enabled(config_vars = ctx.var)):
        fail("The apple_xcframework rule does not yet support the experimental tree artifact. " +
             "Please ensure that the `apple.experimental.tree_artifact_outputs` variable is not " +
             "set to 1 on the command line or in your active build configuration.")

    # Add the disable_legacy_signing feature to the list of features
    # TODO(b/72148898): Remove this when dossier based signing becomes the default.
    features = ctx.features
    features.append("disable_legacy_signing")
    label = ctx.label

    # Bundle extension needs to be ".xcframework" for root bundle, but macos/ios/tvos will always
    # be ".framework"
    nested_bundle_extension = ".framework"

    # Similarly, bundle_id is expected to be in terms of the bundle ID for each embedded framework,
    # as this value is not used in the XCFramework's root Info.plist.
    nested_bundle_id = ctx.attr.bundle_id

    link_result = linking_support.register_binary_linking_action(
        ctx,
        # Frameworks do not have entitlements.
        entitlements = None,
        exported_symbols_lists = ctx.files.exported_symbols_lists,
        extra_linkopts = [
            # iOS, tvOS and watchOS single target app framework binaries live in
            # Application.app/Frameworks/Framework.framework/Framework
            # watchOS 2 extension-dependent app framework binaries live in
            # Application.app/PlugIns/Extension.appex/Frameworks/Framework.framework/Framework
            #
            # iOS, tvOS and watchOS single target app frameworks are packaged in executable as
            # Application.app/Frameworks
            # watchOS 2 extension-dependent app frameworks are packaged in executable as
            # Application.app/PlugIns/Extension.appex/Frameworks
            #
            # While different, these resolve to the same paths relative to their respective
            # executables. Only macOS (which is not yet supported) is an outlier; this will require
            # changes to native Bazel linking logic for Apple binary targets.
            "-Wl,-rpath,@executable_path/Frameworks",
            "-install_name",
            "@rpath/{name}{extension}/{name}".format(
                extension = nested_bundle_extension,
                name = bundle_name,
            ),
        ],
        extra_requested_features = ["link_dylib"],
        platform_prerequisites = None,
        # All required knowledge for 3P facing frameworks is passed directly through the given
        # `extra_linkopts`; no rule_descriptor is needed to share with this linking action.
        rule_descriptor = None,
        stamp = ctx.attr.stamp,
    )

    link_outputs_by_library_identifier = _group_link_outputs_by_library_identifier(
        actions = actions,
        apple_fragment = ctx.fragments.apple,
        deps = deps,
        label_name = label.name,
        link_result = link_result,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
    )

    available_libraries = []
    framework_archive_files = []
    framework_archive_merge_files = []
    framework_archive_merge_zips = []
    framework_output_files = []
    framework_output_groups = []

    for library_identifier, link_output in link_outputs_by_library_identifier.items():
        binary_artifact = link_output.binary

        rule_descriptor = rule_support.rule_descriptor(
            platform_type = link_output.platform,
            product_type = apple_product_type.framework,
        )

        cc_toolchain = ctx.split_attr._cc_toolchain_forwarder[link_output.split_attr_keys[0]]
        apple_platform_info = cc_toolchain[ApplePlatformInfo]
        platform_prerequisites = platform_support.platform_prerequisites(
            apple_fragment = ctx.fragments.apple,
            apple_platform_info = apple_platform_info,
            build_settings = apple_xplat_toolchain_info.build_settings,
            config_vars = ctx.var,
            cpp_fragment = ctx.fragments.cpp,
            device_families = ctx.attr.families_required.get(
                link_output.platform,
                default = rule_descriptor.allowed_device_families,
            ),
            explicit_minimum_os = ctx.attr.minimum_os_versions.get(link_output.platform),
            objc_fragment = ctx.fragments.objc,
            uses_swift = link_output.uses_swift,
            xcode_version_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        )

        overridden_predeclared_outputs = struct(
            archive = intermediates.file(
                actions = actions,
                target_name = label.name,
                output_discriminator = library_identifier,
                file_name = label.name + ".zip",
            ),
        )

        resource_deps = _unioned_attrs(
            attr_names = ["data", "deps"],
            split_attr = ctx.split_attr,
            split_attr_keys = link_output.split_attr_keys,
        )

        top_level_infoplists = resources.collect(
            attr = ctx.split_attr,
            res_attrs = ["infoplists"],
            split_attr_keys = link_output.split_attr_keys,
        )
        top_level_resources = resources.collect(
            attr = ctx.split_attr,
            res_attrs = ["data"],
            split_attr_keys = link_output.split_attr_keys,
        )

        environment_plist = files.get_file_with_name(
            name = "environment_plist_{platform}".format(
                platform = link_output.platform,
            ),
            files = ctx.files._environment_plist_files,
        )

        processor_partials = [
            partials.apple_bundle_info_partial(
                actions = actions,
                bundle_extension = nested_bundle_extension,
                bundle_id = nested_bundle_id,
                bundle_name = bundle_name,
                entitlements = None,
                label_name = label.name,
                output_discriminator = library_identifier,
                platform_prerequisites = platform_prerequisites,
                predeclared_outputs = overridden_predeclared_outputs,
                product_type = rule_descriptor.product_type,
            ),
            partials.binary_partial(
                actions = actions,
                binary_artifact = binary_artifact,
                bundle_name = bundle_name,
                label_name = label.name,
                output_discriminator = library_identifier,
            ),
            partials.debug_symbols_partial(
                actions = actions,
                bundle_extension = nested_bundle_extension,
                bundle_name = bundle_name,
                debug_discriminator = link_output.platform + "_" + link_output.environment,
                dsym_binaries = link_output.dsym_binaries,
                dsym_info_plist_template = apple_mac_toolchain_info.dsym_info_plist_template,
                linkmaps = link_output.linkmaps,
                mac_exec_group = mac_exec_group,
                output_discriminator = library_identifier,
                platform_prerequisites = platform_prerequisites,
                resolved_plisttool = apple_mac_toolchain_info.resolved_plisttool,
                rule_label = label,
                version = ctx.attr.version,
            ),
            partials.resources_partial(
                actions = actions,
                apple_mac_toolchain_info = apple_mac_toolchain_info,
                bundle_extension = nested_bundle_extension,
                bundle_id = nested_bundle_id,
                bundle_name = bundle_name,
                environment_plist = environment_plist,
                mac_exec_group = mac_exec_group,
                output_discriminator = library_identifier,
                platform_prerequisites = platform_prerequisites,
                resource_deps = resource_deps,
                rule_descriptor = rule_descriptor,
                rule_label = label,
                top_level_infoplists = top_level_infoplists,
                top_level_resources = top_level_resources,
                version = ctx.attr.version,
                version_keys_required = False,
            ),
            partials.swift_dylibs_partial(
                actions = actions,
                apple_mac_toolchain_info = apple_mac_toolchain_info,
                binary_artifact = binary_artifact,
                label_name = label.name,
                mac_exec_group = mac_exec_group,
                platform_prerequisites = platform_prerequisites,
            ),
        ]

        if link_output.uses_swift and link_output.swift_infos:
            processor_partials.append(
                partials.swift_framework_partial(
                    actions = actions,
                    apple_xplat_toolchain_info = apple_xplat_toolchain_info,
                    bundle_name = bundle_name,
                    label_name = label.name,
                    output_discriminator = library_identifier,
                    swift_infos = link_output.swift_infos,
                ),
            )
        else:
            processor_partials.append(
                partials.framework_header_modulemap_partial(
                    actions = actions,
                    bundle_name = bundle_name,
                    hdrs = ctx.files.public_hdrs,
                    label_name = label.name,
                    output_discriminator = library_identifier,
                ),
            )

        processor_result = processor.process(
            actions = actions,
            apple_mac_toolchain_info = apple_mac_toolchain_info,
            mac_exec_group = mac_exec_group,
            apple_xplat_toolchain_info = apple_xplat_toolchain_info,
            xplat_exec_group = apple_toolchain_utils.get_xplat_exec_group(ctx),
            bundle_extension = nested_bundle_extension,
            bundle_name = bundle_name,
            entitlements = None,
            features = features,
            ipa_post_processor = None,
            output_discriminator = library_identifier,
            partials = processor_partials,
            platform_prerequisites = platform_prerequisites,
            predeclared_outputs = overridden_predeclared_outputs,
            process_and_sign_template = apple_mac_toolchain_info.process_and_sign_template,
            provisioning_profile = None,
            rule_descriptor = rule_descriptor,
            rule_label = label,
        )

        for provider in processor_result.providers:
            # Save the framework archive.
            if getattr(provider, "archive", None):
                # Repackage every archive found for bundle_merge_zips in the final bundler action.
                framework_archive_merge_zips.append(
                    struct(src = provider.archive.path, dest = library_identifier),
                )

                # Save a reference to those archives as file-friendly inputs to the bundler action.
                framework_archive_files.append(depset([provider.archive]))

            # Save the dSYMs.
            if getattr(provider, "dsyms", None):
                framework_output_files.append(depset(transitive = [provider.dsyms]))
                framework_output_groups.append({"dsyms": provider.dsyms})

            # Save the linkmaps.
            if getattr(provider, "linkmaps", None):
                framework_output_files.append(depset(transitive = [provider.linkmaps]))
                framework_output_groups.append({"linkmaps": provider.linkmaps})

        # Save additional library details for the XCFramework's root info plist.
        available_libraries.append(_available_library_dictionary(
            architectures = link_output.architectures,
            environment = link_output.environment,
            headers_path = None,
            library_identifier = library_identifier,
            library_path = bundle_name + nested_bundle_extension,
            platform = link_output.platform,
        ))

    root_info_plist = _create_xcframework_root_infoplist(
        actions = actions,
        apple_fragment = ctx.fragments.apple,
        available_libraries = available_libraries,
        exec_group = mac_exec_group,
        resolved_plisttool = apple_mac_toolchain_info.resolved_plisttool,
        rule_label = label,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
    )

    _create_xcframework_bundle(
        actions = actions,
        bundle_name = bundle_name,
        framework_archive_files = framework_archive_files,
        framework_archive_merge_files = framework_archive_merge_files,
        framework_archive_merge_zips = framework_archive_merge_zips,
        label_name = label.name,
        output_archive = ctx.outputs.archive,
        bundletool = apple_xplat_toolchain_info.bundletool,
        xplat_exec_group = apple_toolchain_utils.get_xplat_exec_group(ctx),
        root_info_plist = root_info_plist,
    )

    processor_output = [
        # Limiting the contents of AppleBundleInfo to what is necessary for testing and validation.
        new_applebundleinfo(
            archive = ctx.outputs.archive,
            bundle_extension = ".xcframework",
            bundle_id = nested_bundle_id,
            bundle_name = bundle_name,
            infoplist = root_info_plist,
            platform_type = None,
        ),
        new_applexcframeworkbundleinfo(),
        DefaultInfo(
            files = depset([ctx.outputs.archive], transitive = framework_output_files),
        ),
        OutputGroupInfo(
            **outputs.merge_output_groups(
                *framework_output_groups
            )
        ),
    ]
    return processor_output

apple_xcframework = rule_factory.create_apple_rule(
    cfg = transition_support.xcframework_base_transition,
    doc = "Builds and bundles an XCFramework for third-party distribution.",
    implementation = _apple_xcframework_impl,
    predeclared_outputs = {"archive": "%{name}.xcframework.zip"},
    attrs = [
        rule_attrs.cc_toolchain_forwarder_attrs(
            deps_cfg = transition_support.xcframework_split_transition,
        ),
        rule_attrs.common_tool_attrs(),
        rule_attrs.binary_linking_attrs(
            base_cfg = transition_support.xcframework_base_transition,
            deps_cfg = transition_support.xcframework_split_transition,
            extra_deps_aspects = [
                apple_resource_aspect,
            ],
            is_test_supporting_rule = False,
            requires_legacy_cc_toolchain = False,
        ),
        {
            "_environment_plist_files": attr.label_list(
                default = [
                    "@build_bazel_rules_apple//apple/internal:environment_plist_ios",
                    "@build_bazel_rules_apple//apple/internal:environment_plist_tvos",
                ],
            ),
            "bundle_id": attr.string(
                doc = """
The bundle ID (reverse-DNS path followed by app name) for each of the embedded frameworks. If
present, this value will be embedded in an Info.plist within each framework bundle.
""",
            ),
            "bundle_name": attr.string(
                mandatory = False,
                doc = """
The desired name of the xcframework bundle (without the extension) and the bundles for all embedded
frameworks. If this attribute is not set, then the name of the target will be used instead.
""",
            ),
            "data": attr.label_list(
                allow_files = True,
                aspects = [apple_resource_aspect],
                cfg = transition_support.xcframework_split_transition,
                doc = """
A list of resources or files bundled with the bundle. The resources will be stored in the
appropriate resources location within each of the embedded framework bundles.
""",
            ),
            "families_required": attr.string_list_dict(
                doc = """
A list of device families supported by this extension, with platforms such as `ios` as keys. Valid
values are `iphone` and `ipad` for `ios`; at least one must be specified if a platform is defined.
Currently, this only affects processing of `ios` resources.
""",
            ),
            "infoplists": attr.label_list(
                allow_empty = False,
                allow_files = [".plist"],
                cfg = transition_support.xcframework_split_transition,
                doc = """
A list of .plist files that will be merged to form the Info.plist for each of the embedded
frameworks. At least one file must be specified. Please see
[Info.plist Handling](https://github.com/bazelbuild/rules_apple/blob/master/doc/common_info.md#infoplist-handling)
for what is supported.
""",
                mandatory = True,
            ),
            "ios": attr.string_list_dict(
                doc = """
A dictionary of strings indicating which platform variants should be built for the iOS platform (
`device` or `simulator`) as keys, and arrays of strings listing which architectures should be
built for those platform variants (for example, `x86_64`, `arm64`) as their values.
""",
            ),
            "tvos": attr.string_list_dict(
                doc = """
A dictionary of strings indicating which platform variants should be built for the tvOS platform (
`device` or `simulator`) as keys, and arrays of strings listing which architectures should be
built for those platform variants (for example, `x86_64`, `arm64`) as their values.
""",
            ),
            "minimum_os_versions": attr.string_dict(
                doc = """
A dictionary of strings indicating the minimum OS version supported by the target, represented as a
dotted version number (for example, "8.0") as values, with their respective platforms such as `ios`,
or `tvos` as keys:

    minimum_os_versions = {
        "ios": "13.0",
        "tvos": "15.0",
    }
""",
                mandatory = True,
            ),
            "public_hdrs": attr.label_list(
                allow_files = [".h"],
                doc = """
A list of files directly referencing header files to be used as the publicly visible interface for
each of these embedded frameworks. These header files will be embedded within each bundle,
typically in a subdirectory such as `Headers`.
""",
            ),
            "version": attr.label(
                providers = [[AppleBundleVersionInfo]],
                doc = """
An `apple_bundle_version` target that represents the version for this target. See
[`apple_bundle_version`](https://github.com/bazelbuild/rules_apple/blob/master/doc/rules-general.md?cl=head#apple_bundle_version).
""",
            ),
        },
    ],
)

def _apple_static_xcframework_impl(ctx):
    """Implementation of apple_static_xcframework."""

    actions = ctx.actions
    apple_fragment = ctx.fragments.apple
    apple_mac_toolchain_info = apple_toolchain_utils.get_mac_toolchain(ctx)
    apple_xplat_toolchain_info = apple_toolchain_utils.get_xplat_toolchain(ctx)
    bundle_name = ctx.attr.bundle_name or ctx.label.name
    deps = ctx.split_attr.deps
    label = ctx.label
    mac_exec_group = apple_toolchain_utils.get_mac_exec_group(ctx)
    outputs_archive = ctx.outputs.archive
    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]

    binary_name = bundle_name + ".a"
    link_result = linking_support.register_static_library_linking_action(ctx = ctx)
    link_outputs_by_library_identifier = _group_link_outputs_by_library_identifier(
        actions = actions,
        apple_fragment = apple_fragment,
        deps = deps,
        label_name = bundle_name,
        link_result = link_result,
        xcode_config = xcode_config,
    )

    available_libraries = []
    framework_archive_files = []
    framework_archive_merge_files = []
    for library_identifier, link_output in link_outputs_by_library_identifier.items():
        # Bundle binary artifact for specific library identifier
        binary_artifact = link_output.binary
        framework_archive_merge_files.append(struct(
            src = binary_artifact.path,
            dest = paths.join(library_identifier, binary_name),
        ))
        framework_archive_files.append(depset([binary_artifact]))

        if link_output.uses_swift and link_output.swift_infos:
            # Generate headers, modulemaps, and swiftmodules
            interface_artifacts = partial.call(
                partials.swift_framework_partial(
                    actions = actions,
                    apple_xplat_toolchain_info = apple_xplat_toolchain_info,
                    avoid_deps = ctx.attr.avoid_deps,
                    bundle_name = bundle_name,
                    framework_modulemap = False,
                    label_name = label.name,
                    output_discriminator = library_identifier,
                    swift_infos = link_output.swift_infos,
                ),
            )
        else:
            # Generate headers, and modulemaps
            sdk_frameworks = cc_info_support.get_sdk_frameworks(
                deps = ctx.split_attr.deps,
                split_deps_keys = link_output.split_attr_keys,
            )
            sdk_dylibs = cc_info_support.get_sdk_dylibs(
                deps = ctx.split_attr.deps,
                split_deps_keys = link_output.split_attr_keys,
            )
            interface_artifacts = partial.call(partials.framework_header_modulemap_partial(
                actions = actions,
                bundle_name = bundle_name,
                framework_modulemap = False,
                hdrs = ctx.files.public_hdrs,
                label_name = label.name,
                output_discriminator = library_identifier,
                sdk_frameworks = sdk_frameworks,
                sdk_dylibs = sdk_dylibs,
            ))

        # An XCFramework with static libraries can include Objective-C(++) headers from
        # the `public_hdrs` rule attribute or generated headers from a Swift module.
        # This boolean is required to add/omit headers from the Info.plist accordingly,
        # through the inspection of the partial outputs for both Objective-C(++)/Swift.
        found_header_files = False

        # Bundle headers & modulemaps (and swiftmodules if available)
        for _, bundle_relative_path, files in interface_artifacts.bundle_files:
            framework_archive_files.append(files)
            for file in files.to_list():
                if not found_header_files and file.extension == "h":
                    found_header_files = True

                # For Swift based static XCFrameworks, Xcode requires .swiftmodule files to be
                # located under each library identifier directory. While headers and modulemap
                # files need to be under a Headers/ directory. Thus, we default all interface
                # artifacts to be moved to the Headers directory, except for swiftmodule files.
                #
                # e.g.
                #     ios_arm64/
                #       ├── libStatic.a
                #       ├── Headers/<bundle_name>..
                #       └── libStatic.swiftmodule/..
                dest_bundle_relative_path = paths.join("Headers", bundle_name)
                if ".swiftmodule" in bundle_relative_path:
                    dest_bundle_relative_path = bundle_relative_path.replace("Modules/", "")
                framework_archive_merge_files.append(struct(
                    src = file.path,
                    dest = paths.join(
                        library_identifier,
                        dest_bundle_relative_path,
                        file.basename,
                    ),
                ))

        # Save additional library details for the XCFramework's root info plist.
        available_libraries.append(
            _available_library_dictionary(
                architectures = link_output.architectures,
                environment = link_output.environment,
                headers_path = "Headers" if found_header_files else None,
                library_identifier = library_identifier,
                library_path = binary_name,
                platform = link_output.platform,
            ),
        )

    root_info_plist = _create_xcframework_root_infoplist(
        actions = actions,
        apple_fragment = apple_fragment,
        available_libraries = available_libraries,
        exec_group = mac_exec_group,
        resolved_plisttool = apple_mac_toolchain_info.resolved_plisttool,
        rule_label = label,
        xcode_config = xcode_config,
    )

    _create_xcframework_bundle(
        actions = actions,
        bundle_name = bundle_name,
        framework_archive_files = framework_archive_files,
        framework_archive_merge_files = framework_archive_merge_files,
        label_name = label.name,
        output_archive = outputs_archive,
        bundletool = apple_xplat_toolchain_info.bundletool,
        xplat_exec_group = apple_toolchain_utils.get_xplat_exec_group(ctx),
        root_info_plist = root_info_plist,
    )

    return [
        # Limiting the contents of AppleBundleInfo to what is necessary for testing and validation.
        new_applebundleinfo(
            archive = outputs_archive,
            bundle_extension = ".xcframework",
            bundle_name = bundle_name,
            infoplist = root_info_plist,
            platform_type = None,
        ),
        new_applestaticxcframeworkbundleinfo(),
        DefaultInfo(
            files = depset([outputs_archive]),
        ),
    ]

apple_static_xcframework = rule_factory.create_apple_rule(
    cfg = None,
    doc = "Generates an XCFramework with static libraries for third-party distribution.",
    implementation = _apple_static_xcframework_impl,
    predeclared_outputs = {"archive": "%{name}.xcframework.zip"},
    toolchains = [],
    attrs = [
        rule_attrs.common_tool_attrs(),
        rule_attrs.static_library_linking_attrs(
            deps_cfg = transition_support.xcframework_split_transition,
        ),
        {
            "avoid_deps": attr.label_list(
                allow_files = True,
                cfg = transition_support.xcframework_split_transition,
                mandatory = False,
                doc = """
A list of library targets on which this framework depends in order to compile, but the transitive
closure of which will not be linked into the framework's binary.
""",
            ),
            "bundle_name": attr.string(
                mandatory = False,
                doc = """
The desired name of the XCFramework bundle (without the extension) and the binaries for all embedded
static libraries. If this attribute is not set, then the name of the target will be used instead.
""",
            ),
            "deps": attr.label_list(
                aspects = [swift_usage_aspect],
                allow_files = True,
                cfg = transition_support.xcframework_split_transition,
                mandatory = True,
                doc = """
A list of files directly referencing libraries to be represented for each given platform split in
the XCFramework. These libraries will be embedded within each platform split.
""",
            ),
            "ios": attr.string_list_dict(
                doc = """
A dictionary of strings indicating which platform variants should be built for the `ios` platform (
`device` or `simulator`) as keys, and arrays of strings listing which architectures should be
built for those platform variants (for example, `x86_64`, `arm64`) as their values.
""",
            ),
            "minimum_os_versions": attr.string_dict(
                mandatory = True,
                doc = """
A dictionary of strings indicating the minimum OS version supported by the target, represented as a
dotted version number (for example, "8.0") as values, with their respective platforms such as `ios`
as keys.
""",
            ),
            "public_hdrs": attr.label_list(
                allow_files = [".h"],
                cfg = transition_support.xcframework_split_transition,
                doc = """
A list of files directly referencing header files to be used as the publicly visible interface for
each of these embedded libraries. These header files will be embedded within each platform split,
typically in a subdirectory such as `Headers`.
""",
            ),
        },
    ],
)
