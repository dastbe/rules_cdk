# Declare the local Bazel workspace.
workspace(name = "contrib_rules_cdk")

load(":internal_deps.bzl", "rules_cdk_internal_deps")

# Fetch deps needed only locally for development
rules_cdk_internal_deps()

load("//cdk:repositories.bzl", "cdk_register_toolchains", "rules_cdk_dependencies")

# Fetch dependencies which users need as well
rules_cdk_dependencies()

# TODO(dastbe): fix toolchains for cdk
cdk_register_toolchains(
    name = "cdk1_14",
    cdk_version = "1.14.2",
)

# For running our own unit tests
load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

############################################
# Gazelle, for generating bzl_library targets
load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")

go_rules_dependencies()

go_register_toolchains(version = "1.19.3")

gazelle_dependencies()
