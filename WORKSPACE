# Declare the local Bazel workspace.
workspace(name = "contrib_rules_cdk")

load(":internal_deps.bzl", "rules_cdk_internal_deps")

# Fetch deps needed only locally for development
rules_cdk_internal_deps()

load("//cdk:dependencies.bzl", "rules_cdk_dependencies")

# Fetch dependencies which users need as well
rules_cdk_dependencies()

# Load stardoc dependencies
load("@io_bazel_stardoc//:setup.bzl", "stardoc_repositories")

stardoc_repositories()

load("@rules_jvm_external//:repositories.bzl", "rules_jvm_external_deps")

rules_jvm_external_deps()

load("@rules_jvm_external//:setup.bzl", "rules_jvm_external_setup")

rules_jvm_external_setup()

load("@io_bazel_stardoc//:deps.bzl", "stardoc_external_deps")

stardoc_external_deps()

load("@stardoc_maven//:defs.bzl", stardoc_pinned_maven_install = "pinned_maven_install")

stardoc_pinned_maven_install()

# Necessary to make doc testing work, at least in bazel < 6.0.0
load("@aspect_bazel_lib//lib:repositories.bzl", "aspect_bazel_lib_dependencies")

aspect_bazel_lib_dependencies(override_local_config_platform = True)

# Fetch and register a nodejs interpreter, if you haven't already
load("@rules_nodejs//nodejs:repositories.bzl", "DEFAULT_NODE_VERSION", "nodejs_register_toolchains")

nodejs_register_toolchains(
    name = "node",
    node_version = DEFAULT_NODE_VERSION,
)

load("//cdk:repositories.bzl", "cdk_repositories")

cdk_repositories()

load("@cdk//:npm_repositories.bzl", cdk_npm_repositories = "npm_repositories")

cdk_npm_repositories()

# For running our own unit tests
load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

############################################
# Gazelle, for generating bzl_library targets
load("@bazel_skylib_gazelle_plugin//:workspace.bzl", "bazel_skylib_gazelle_plugin_workspace")

bazel_skylib_gazelle_plugin_workspace()

load("@bazel_skylib_gazelle_plugin//:setup.bzl", "bazel_skylib_gazelle_plugin_setup")

bazel_skylib_gazelle_plugin_setup()
