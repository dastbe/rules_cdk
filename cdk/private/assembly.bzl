"""Rule for running a CDK app with conventional configuration and extracting
its generated configuration to a defined targeted. Can be consumed by cdk rules
to diff, deploy, etc."""

load("@bazel_skylib//lib:paths.bzl", "paths")

# this is a pretty big hack to use pwd to resolve the full path of the node binary
# This is necessary because go no longer allows relative-path lookups. Ideally we
# can get rid of this if we can support an alternative way of specifying the
# node entrypoint: https://github.com/aws/jsii/issues/3889
#
# separately, all js_binaries need to have BAZEL_BINDIR. Hopefully this doesn't
# pollute further :/
command_template = """\
PATH=`pwd`/{node}:$PATH CDK_OUTDIR=`pwd`/{cdk_outdir} BAZEL_BINDIR={bindir} $(execpath {app})
"""

def _cdk_assembly_impl(ctx):
    cdk_out = ctx.actions.declare_directory(ctx.attr.name + ".cdk.out")
    node_toolchain = ctx.toolchains["@rules_nodejs//nodejs:toolchain_type"].nodeinfo

    files = []
    files.extend(ctx.files.app)
    files.extend(node_toolchain.npm_files)
    files.extend(node_toolchain.tool_files)
    runfiles = ctx.runfiles(files = files)
    runfiles = runfiles.merge(ctx.attr.app[DefaultInfo].default_runfiles)

    command = ctx.expand_location(command_template.format(node = paths.dirname(node_toolchain.target_tool_path), cdk_outdir = cdk_out.path, bindir = ctx.var["BINDIR"], app = ctx.attr.app.label), targets = [ctx.attr.app])

    ctx.actions.run_shell(
        inputs = runfiles.files.to_list(),
        outputs = [cdk_out],
        tools = ctx.files.app,
        command = command,
        mnemonic = "CdkAssembly",
    )

    return [DefaultInfo(files = depset([cdk_out]))]

cdk_assembly = rule(
    doc = """Executes a binary target and generates a CDK cloud assembly

The output of this rule can be consumed by rules to diff/deploy/destroy stacks
from the cloud assembly. Alternatively, it can be referenced directly via
`bazel query` and used with a user-installed CDK, or compressed and distributed
independently.""",
    implementation = _cdk_assembly_impl,
    attrs = {
        "app": attr.label(mandatory = True, doc = "An executable that generates a CDK cloud assembly", executable = True, cfg = "exec"),
    },
    toolchains = ["@rules_nodejs//nodejs:toolchain_type"],
)
