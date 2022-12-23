"""Rule for running a CDK app with conventional configuration and extracting
its generated configuration to a defined targeted. Can be consumed by cdk rules
to diff, deploy, etc.

TODO(dastbe): right now, this rule only works with javascript/typescript apps
as the others rely on a node runtime for JSII. 

See https://github.com/aws/jsii/issues/3889 for a future fix"""

def _cdk_assembly_impl(ctx):
    cdk_out = ctx.actions.declare_directory(ctx.attr.name + ".cdk.out")

    ctx.actions.run(
        outputs = [cdk_out],
        executable = ctx.executable.app,
        env = {
            "CDK_OUTDIR": cdk_out.short_path,
            # TODO(dastbe): this seems explicitly necessary to make js_binary work?
            # Would rather not customize this to work with all platforms :shrug:
            "BAZEL_BINDIR": ctx.var["BINDIR"],
        },
        mnemonic = "CdkAssembly",
    )

    return [DefaultInfo(files = depset([cdk_out]))]

cdk_assembly = rule(
    implementation = _cdk_assembly_impl,
    attrs = {
        "app": attr.label(mandatory = True, executable = True, cfg = "exec"),
    },
)
