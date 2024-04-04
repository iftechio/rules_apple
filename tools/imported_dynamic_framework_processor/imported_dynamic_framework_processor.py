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
#
"""Execution-phase imported Apple framework processing tool.

The imported dynamic framework processor tool is an execution-phase tool
handling imported Apple frameworks' file with two main tasks:

  - Copy (or symlink) framework files
  - Slice (if required) and copy framework binaries.

Symbolic links are required for macOS/Darwin frameworks; which contain multiple
framework versions under the '.framework/Versions' directory.

Slicing framework binaries is only performed if the binary supports more
architectures than those requested at analysis time by Bazel/rules_apple.

For more information, see Apple's documentation on framework bundles:
https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/FrameworkAnatomy.html
"""

import argparse
import os
import re
import shutil
import sys
import textwrap
import time
from typing import List, Optional

from build_bazel_rules_apple.tools.codesigningtool import codesigningtool
from build_bazel_rules_apple.tools.wrapper_common import execute
from build_bazel_rules_apple.tools.wrapper_common import lipo


def _is_versioned_file(filepath: str, version: Optional[str] = None) -> bool:
  """Returns True if file is below a Darwin framework versioned file.

  Args:
    filepath: Path of the file to match against.
    version: Framework version identifier to include in path matching. If
      provided, version is used to match against `filepath`.
  Returns:
    True if filepath is a versioned framework file, False otherwise.
  """
  if version:
    return f".framework/Versions/{version}/" in filepath

  return ".framework/Versions/" in filepath


def _update_modified_timestamps(framework_temp_path: str) -> None:
  """Updates framework files modified timestamp before creating the zip file.

  Args:
    framework_temp_path: Directory filepath holding framework files.
  """
  zip_epoch_timestamp = 946684800  # 2000-01-01 00:00
  timestamp = zip_epoch_timestamp + time.timezone
  if os.path.exists(framework_temp_path):
    # Apply the fixed utime to the files within directories, then their parent
    # directories and files adjacent to those directories.
    #
    # Avoids accidentally resetting utime on the directories when utime is set
    # on the files within.
    for root, dirs, files in os.walk(framework_temp_path, topdown=False):
      for file_name in dirs + files:
        file_path = os.path.join(root, file_name)
        if os.path.islink(file_path):
          # Skip symlinks, since those were created by this tool.
          # It's safe to assume so because Bazel resolves symlinks.
          continue
        os.utime(file_path, (timestamp, timestamp))
    os.utime(framework_temp_path, (timestamp, timestamp))


def _relpath_from_framework(framework_absolute_path):
  """Returns a relative path to the root of the framework bundle."""
  framework_dir = None
  parent_dir = os.path.dirname(framework_absolute_path)
  while parent_dir != "/" and framework_dir is None:
    if parent_dir.endswith(".framework"):
      framework_dir = parent_dir
    else:
      parent_dir = os.path.dirname(parent_dir)

  if parent_dir == "/":
    print("Internal Error: Could not find path in framework: " +
          framework_absolute_path)
    return None

  return os.path.relpath(framework_absolute_path, framework_dir)


def _copy_framework_file(framework_file, executable, output_path):
  """Copies file to given path, marking as writable and executable as needed."""
  path_from_framework = _relpath_from_framework(framework_file)
  if not path_from_framework:
    return 1

  temp_framework_path = os.path.join(output_path, path_from_framework)
  temp_framework_dirs = os.path.dirname(temp_framework_path)
  if not os.path.exists(temp_framework_dirs):
    os.makedirs(temp_framework_dirs)
  shutil.copy(framework_file, temp_framework_path)
  os.chmod(temp_framework_path, 0o755 if executable else 0o644)
  return 0


def _strip_framework_binary(framework_binary, output_path, slices_needed):
  """Strips the binary to only the slices needed, saves output to given path."""
  if not slices_needed:
    print("Internal Error: Did not specify any slices needed for binary at "
          "path: " + framework_binary)
    return 1

  path_from_framework = _relpath_from_framework(framework_binary)
  if not path_from_framework:
    return 1

  temp_framework_path = os.path.join(output_path, path_from_framework)

  # Creating intermediate directories is only required for macOS framework
  # binaries which are not at the top-level directory, and are located under:
  # '.framework/Versions/<version_id>/<framework_binary>'
  temp_framework_dirs = os.path.dirname(temp_framework_path)
  if not os.path.exists(temp_framework_dirs):
    os.makedirs(temp_framework_dirs)

  lipo.invoke_lipo(framework_binary, slices_needed, temp_framework_path)
  os.chmod(temp_framework_path, 0o755)
  return 0


def _strip_or_copy_binary(
    *,
    framework_binary: str,
    output_path: str,
    requested_archs: List[str]) -> None:
  """Copies and strips (if necessary) a framework binary.

  Args:
    framework_binary: Filepath to the framework binary to copy/thin.
    output_path: Target filepath for the copied binary.
    requested_archs: List of requested binary architectures to preserve.
  """
  binary_archs, _ = lipo.find_archs_for_binaries([framework_binary])
  if not binary_archs:
    raise ValueError(
        "Could not find binary architectures for binaries using lipo."
        f"\n{framework_binary}")

  slices_needed = binary_archs.intersection(requested_archs)
  if not slices_needed:
    raise ValueError(
        "Error: Precompiled framework does not share any binary "
        "architectures with the binaries that were built.\n"
        f"Binary architectures: {binary_archs}\n"
        f"Build architectures: {requested_archs}\n")

  # If the imported framework is single architecture, and therefore assumed
  # that it doesn't need to be lipoed, or if the binary architectures match
  # the framework architectures perfectly, treat as a copy instead of a lipo
  # operation.
  should_skip_lipo = (
      len(binary_archs) == 1 or
      binary_archs == set(requested_archs)
  )

  if should_skip_lipo:
    _copy_framework_file(framework_binary,
                         executable=True,
                         output_path=output_path)
  else:
    _strip_framework_binary(framework_binary,
                            output_path,
                            slices_needed)


def _get_parser():
  """Returns command line arguments parser extending codesigningtool parser."""
  parser = argparse.ArgumentParser(
      description="imported dynamic framework processor")

  parser.add_argument(
      "--framework_binary", type=str, required=True,
      help="path to a binary file scoped to one of the imported frameworks"
  )
  parser.add_argument(
      "--slice", type=str, required=True, action="append", help="binary slice "
      "expected to represent the target architectures"
  )
  parser.add_argument(
      "--framework_file",
      type=str,
      default=[],
      action="append",
      help=("path to a file scoped to one of the imported"
            " frameworks, distinct from the binary files")
  )
  parser.add_argument(
      "--temp_path", type=str, required=True, help="temporary path to copy "
      "all framework files to"
  )
  parser.add_argument(
      "--output_zip", type=str, required=True, help="path to save the zip file "
      "containing a codesigned, lipoed version of the imported framework"
  )

  # Add mutually exclusive flags:
  #   - '--disable_signing' to disable code signing.
  #   - An argument group containing codesigningtool args.
  mutex_group = parser.add_mutually_exclusive_group()
  mutex_group.add_argument(
      "--disable_signing",
      action="store_true",
      help="Disables code signing for imported frameworks.",
  )
  codesigningtool_args = mutex_group.add_argument_group()
  codesigningtool.add_parser_arguments(codesigningtool_args)

  return parser


def main() -> None:
  """Copies/link framework files and copy/thin framework binaries."""
  parser = _get_parser()
  args = parser.parse_args()

  # Delete any existing stale framework files, if any exist.
  if os.path.exists(args.temp_path):
    shutil.rmtree(args.temp_path)
  if os.path.exists(args.output_zip):
    os.remove(args.output_zip)
  os.makedirs(args.temp_path)

  is_versioned_framework = any(map(_is_versioned_file, args.framework_file))

  if not is_versioned_framework:
    _strip_or_copy_binary(
        framework_binary=args.framework_binary,
        output_path=args.temp_path,
        requested_archs=args.slice)

    for framework_file in args.framework_file:
      _copy_framework_file(framework_file,
                           executable=False,
                           output_path=args.temp_path)
  else:
    # Always assume that the version is "A", matching Apple's recommended
    # "modern" Versions/A/... paths:
    # https://developer.apple.com/documentation/bundleresources/placing_content_in_a_bundle#3875936
    version = "A"

    # Copy files from Versions/<version_id>
    for framework_file in args.framework_file:
      if not _is_versioned_file(framework_file, version):
        # Ignore non-current/effective version framework files.
        #
        # While Xcode does copies all Versions in a macOS framework bundle,
        # codesign verification fails during validations of all other framework
        # versions (ie. non 'Current' version). This is either by design or a
        # bug from Apple.
        #
        # Furthermore, Apple best practices recommends adopting single version
        # macOS frameworks. See more at:
        # https://developer.apple.com/documentation/bundleresources/placing_content_in_a_bundle
        #
        # To learn more about previous codesign implementation verifying
        # additional versions see:
        # https://opensource.apple.com/source/Security/Security-57740.51.3/OSX/libsecurity_codesigning/lib/StaticCode.cpp.auto.html
        continue

      _copy_framework_file(
          framework_file,
          executable=False,
          output_path=args.temp_path)

    # Copy the binary.
    _strip_or_copy_binary(
        framework_binary=args.framework_binary,
        output_path=args.temp_path,
        requested_archs=args.slice)

    # Create symbolic link from Current to effective version directory.
    symlink_path = os.path.join(args.temp_path, "Versions", "Current")
    symlink_data = version
    os.symlink(symlink_data, symlink_path)

    # Create symbolic links from top-level entries to Versions/Current entries.
    versions_dir = os.path.join(args.temp_path, "Versions")
    version_dir = os.path.join(versions_dir, version)
    for entry in os.listdir(version_dir):
      symlink_path = os.path.join(args.temp_path, entry)
      symlink_data = os.path.join("Versions", "Current", entry)
      os.symlink(symlink_data, symlink_path)

    # Modify codesigningtool arg to sign the current framework version
    # This matches Xcode behavior of re-signing only the effective version.
    args.target_to_sign = [version_dir]

  # Attempt to sign the framework, check for an error when signing.
  if not args.disable_signing:
    status_code = codesigningtool.find_identity_and_sign_bundle_paths(args)
    if status_code:
      return status_code

  # Update modified timestamps and create archive using ditto.
  _update_modified_timestamps(args.temp_path)

  # Previous implementation of creating the processed framework archive
  # using shutil/zip already stripped the extended attributes of the bundle.
  execute.execute_and_filter_output(
      cmd_args=[
          "/usr/bin/ditto",
          "-c",
          "-k",  # use PKZip format for bundletool compatibility.
          "--keepParent",  # preserves the .framework directory.
          "--norsrc",  # strip resource forks and HFS metadata.
          "--noextattr",  # strip extended attributes.
          args.temp_path,
          args.output_zip
      ],
      raise_on_failure=True)


if __name__ == "__main__":
  sys.exit(main())
