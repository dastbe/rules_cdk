"""General-purpose rule for execution an action against a CDK assembly using the currently configured AWS credentials"""

CDK_ACTIONS = [
    "deploy",
    "diff",
    "destroy",
]

deploy_template = """\
#!/bin/bash
CLOUD_ASSEMBLY=$(rootpath {assembly})
WRITEABLE_CLOUD_ASSEMBLY=$(mktemp -d)

# Forward slash is load-bearing
cp -r $CLOUD_ASSEMBLY/. $WRITEABLE_CLOUD_ASSEMBLY
chmod -R 755 $WRITEABLE_CLOUD_ASSEMBLY

$(rootpath {cdk}) {action} --app $WRITEABLE_CLOUD_ASSEMBLY $@
"""

def _cdk_exec_impl(ctx):
    script = ctx.actions.declare_file("%s.sh" % ctx.label.name)
    script_content = ctx.expand_location(
        deploy_template.format(
            action = ctx.attr.action,
            assembly = ctx.attr.assembly.label,
            cdk = ctx.attr.cdk.label,
        ),
        targets = [ctx.attr.assembly, ctx.attr.cdk],
    )

    ctx.actions.write(script, script_content, is_executable = True)

    files = []
    files.extend(ctx.files.assembly)
    files.extend(ctx.files.cdk)
    runfiles = ctx.runfiles(files = files)
    runfiles = runfiles.merge(ctx.attr.assembly[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.cdk[DefaultInfo].default_runfiles)

    return [DefaultInfo(executable = script, runfiles = runfiles)]

cdk_exec = rule(
    implementation = _cdk_exec_impl,
    executable = True,
    attrs = {
        "assembly": attr.label(mandatory = True, doc = "The cloud assembly to perform operations against", allow_single_file = True),
        "cdk": attr.label(default = "@cdk//:cdk_bin", doc = "The CDK binary to perform actions with", allow_single_file = True, executable = True, cfg = "exec"),
        "action": attr.string(mandatory = True, doc = "The action to perform on the cloud assembly", values = CDK_ACTIONS),
    },
)
