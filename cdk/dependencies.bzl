"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("//cdk/private:versions.bzl", "TOOL_VERSIONS")
load("@aspect_rules_js//npm:npm_import.bzl", _npm_translate_lock = "npm_translate_lock")

LATEST_VERSION = TOOL_VERSIONS[0]

def cdk_repositories(cdk_version = LATEST_VERSION):
    """
    Fetch external tools needed for cdk

    Args:
        cdk_version: The cdk version to fetch.

            See /cdk/private/versions.bzl for available versions.
    """

    # TODO(dastbe): This value is not overridable atm. Make it so
    name = "cdk"
    if cdk_version not in TOOL_VERSIONS:
        fail("""
cdk version {} is not currently mirrored into contrib_rules_cdk.
Please instead choose one of these available versions: {}""".format(cdk_version, TOOL_VERSIONS))

    _npm_translate_lock(
        name = name,
        pnpm_lock = "@contrib_rules_cdk//cdk/private:{version}/pnpm-lock.yaml".format(version = cdk_version),
        # We'll be linking in the @foo repository and not the repository where the pnpm-lock file is located
        link_workspace = name,
        # Override the Bazel package where pnpm-lock.yaml is located and link to the specified package instead
        root_package = "",
        defs_bzl_filename = "npm_link_all_packages.bzl",
        repositories_bzl_filename = "npm_repositories.bzl",
        additional_file_contents = {
            "BUILD.bazel": [
                """load("@aspect_bazel_lib//lib:directory_path.bzl", "directory_path")""",
                """load("@aspect_rules_js//js:defs.bzl", "js_binary")""",
                """load("//:npm_link_all_packages.bzl", "npm_link_all_packages")""",
                """npm_link_all_packages(name = "node_modules")""",
                """directory_path(
    name = "cdk_entry_point",
    directory = ":node_modules/aws-cdk/dir",
    path = "bin/cdk",
    visibility = ["//visibility:public"],
)""",
                """alias(
    name = "cdk",
    actual = ":node_modules/aws-cdk",
    visibility = ["//visibility:public"],
)""",
                """js_binary(
    name = "cdk_bin",
    data = [
        ":cdk",
    ],
    entry_point = ":cdk_entry_point",
    visibility = ["//visibility:public"],
)""",
            ],
        },
    )
