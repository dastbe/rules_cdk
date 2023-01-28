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
        sha256 = "4dd05f44200db3b78f72f56ebd8b102d5bcdc17c0299955d4eb20c38c6f07cd7",
        strip_prefix = "bazel-skylib-1.4.0",
        urls = ["https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.4.0.tar.gz"],
    )

    http_archive(
        name = "bazel_skylib_gazelle_plugin",
        sha256 = "04182233284fcb6545d36b94248fe28186b4d9d574c4131d6a511d5aeb278c46",
        urls = ["https://github.com/bazelbuild/bazel-skylib/releases/download/1.4.0/bazel-skylib-gazelle-plugin-1.4.0.tar.gz"],
    )

    http_archive(
        name = "io_bazel_stardoc",
        sha256 = "3fd8fec4ddec3c670bd810904e2e33170bedfe12f90adf943508184be458c8bb",
        urls = ["https://github.com/bazelbuild/stardoc/releases/download/0.5.3/stardoc-0.5.3.tar.gz"],
    )
