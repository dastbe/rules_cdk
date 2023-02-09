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
        sha256 = "060426b186670beede4104095324a72bd7494d8b4e785bf0d84a612978285908",
        strip_prefix = "bazel-skylib-1.4.1",
        urls = ["https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.4.1.tar.gz"],
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
