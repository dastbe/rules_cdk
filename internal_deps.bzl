"""Our "development" dependencies

Users should *not* need to install these. If users see a load()
statement from these, that's a bug in our distribution.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

def rules_cdk_internal_deps():
    "Fetch deps needed for local development"

    http_archive(
        name = "bazel_skylib",
        sha256 = "de9d2cedea7103d20c93a5cc7763099728206bd5088342d0009315913a592cc0",
        strip_prefix = "bazel-skylib-1.4.2",
        urls = ["https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.4.2.tar.gz"],
    )

    http_archive(
        name = "bazel_skylib_gazelle_plugin",
        sha256 = "3327005dbc9e49cc39602fb46572525984f7119a9c6ffe5ed69fbe23db7c1560",
        urls = ["https://github.com/bazelbuild/bazel-skylib/releases/download/1.4.2/bazel-skylib-gazelle-plugin-1.4.2.tar.gz"],
    )

    http_archive(
        name = "io_bazel_stardoc",
        sha256 = "62bd2e60216b7a6fec3ac79341aa201e0956477e7c8f6ccc286f279ad1d96432",
        urls = ["https://github.com/bazelbuild/stardoc/releases/download/0.6.2/stardoc-0.6.2.tar.gz"],
    )
