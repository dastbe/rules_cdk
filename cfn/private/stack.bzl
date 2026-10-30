"""cfn_stack: materializes a cfn.template() into a deployable template + manifest."""

load("//cfn/private:runtime.bzl", "is_cfn")

CfnStackInfo = provider(
    doc = "A packaged CloudFormation stack.",
    fields = {
        "stack_name": "Stack name",
        "template": "File: the final template JSON",
        "manifest": "File: the stack manifest read by cfnctl",
        "assets": "File: directory of packaged assets",
    },
)

def _rel_path(f, label):
    """Path of f relative to label's package (for zip entry names)."""
    prefix = ""
    if label.workspace_name:
        prefix = "../" + label.workspace_name + "/"
    if label.package:
        prefix += label.package + "/"
    sp = f.short_path
    if sp.startswith(prefix):
        return sp[len(prefix):]
    return f.basename

def _cfn_stack_impl(ctx):
    name = ctx.label.name
    raw = ctx.actions.declare_file(name + ".raw.json")
    ctx.actions.write(raw, ctx.attr.template_json)

    deps = [d[CfnStackInfo].stack_name for d in ctx.attr.deps]
    config = ctx.actions.declare_file(name + ".config.json")
    ctx.actions.write(config, json.encode_indent({
        "stack_name": ctx.attr.stack_name,
        "region": ctx.attr.region,
        "account": ctx.attr.account,
        "parameters": ctx.attr.parameters,
        "tags": ctx.attr.stack_tags,
        "capabilities": ctx.attr.capabilities,
        "termination_protection": ctx.attr.termination_protection,
        "asset_bucket": ctx.attr.asset_bucket,
        "role_arn": ctx.attr.role_arn,
        "depends_on": deps,
    }, indent = "  "))

    schema_files = ctx.files.schemas
    schema_list = ctx.actions.declare_file(name + ".schemas.txt")
    ctx.actions.write(schema_list, "\n".join([f.path for f in schema_files]) + "\n")

    asset_lines = []
    asset_inputs = []
    for target, packaging in ctx.attr.assets.items():
        files = target[DefaultInfo].files.to_list()
        if not files:
            fail("asset {} produces no files".format(target.label))
        label = str(target.label)
        if label.startswith("@@//"):
            label = label[2:]
        for f in files:
            if f.is_directory:
                fail("asset {}: directories are not supported yet; list the files instead".format(target.label))
            asset_lines.append("\t".join([label, packaging, _rel_path(f, target.label), f.path]))
            asset_inputs.append(f)
    asset_list = ctx.actions.declare_file(name + ".assets.txt")
    ctx.actions.write(asset_list, "\n".join(asset_lines) + "\n")

    template = ctx.outputs.template
    manifest = ctx.outputs.manifest
    assets_dir = ctx.actions.declare_directory(name + ".assets")
    ctx.actions.run(
        executable = ctx.executable._cfnctl,
        arguments = [
            "package",
            "--raw=" + raw.path,
            "--config=" + config.path,
            "--schema-list=" + schema_list.path,
            "--asset-list=" + asset_list.path,
            "--out-template=" + template.path,
            "--out-manifest=" + manifest.path,
            "--out-assets=" + assets_dir.path,
        ],
        inputs = [raw, config, schema_list, asset_list] + schema_files + asset_inputs,
        outputs = [template, manifest, assets_dir],
        mnemonic = "CfnPackage",
        progress_message = "Packaging CloudFormation stack %{label}",
    )
    return [
        DefaultInfo(
            files = depset([template, manifest]),
            runfiles = ctx.runfiles(files = [template, manifest, assets_dir]),
        ),
        CfnStackInfo(stack_name = ctx.attr.stack_name, template = template, manifest = manifest, assets = assets_dir),
        OutputGroupInfo(raw = depset([raw]), assets = depset([assets_dir])),
    ]

_cfn_stack = rule(
    implementation = _cfn_stack_impl,
    # Predeclared so `:<name>.template.json` and `:<name>.manifest.json` are addressable labels.
    outputs = {
        "template": "%{name}.template.json",
        "manifest": "%{name}.manifest.json",
    },
    attrs = {
        "template_json": attr.string(mandatory = True),
        "assets": attr.label_keyed_string_dict(allow_files = True),
        "schemas": attr.label_list(allow_files = True),
        "stack_name": attr.string(mandatory = True),
        "region": attr.string(),
        "account": attr.string(),
        "parameters": attr.string_dict(),
        "stack_tags": attr.string_dict(),
        "capabilities": attr.string_list(),
        "termination_protection": attr.bool(),
        "asset_bucket": attr.string(),
        "role_arn": attr.string(),
        "deps": attr.label_list(providers = [CfnStackInfo]),
        "_cfnctl": attr.label(default = "//cfn/cmd/cfnctl", executable = True, cfg = "exec"),
    },
)

def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _cfn_command_impl(ctx):
    info = ctx.attr.stack[CfnStackInfo]
    cfnctl = ctx.executable._cfnctl
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, """#!/usr/bin/env bash
set -euo pipefail
# bazel run executes in the runfiles tree; resolve paths before changing directory.
cfnctl="$PWD/{cfnctl}"
manifest="$PWD/{manifest}"
cd "${{BUILD_WORKING_DIRECTORY:-.}}"
exec "$cfnctl" {cmd} --manifest="$manifest" "$@"
""".format(
        cfnctl = cfnctl.short_path,
        manifest = info.manifest.short_path,
        cmd = _sh_quote(ctx.attr.command),
    ), is_executable = True)
    runfiles = ctx.runfiles(files = [cfnctl]).merge(ctx.attr.stack[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr._cfnctl[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

_cfn_command = rule(
    implementation = _cfn_command_impl,
    executable = True,
    attrs = {
        "stack": attr.label(mandatory = True, providers = [CfnStackInfo]),
        "command": attr.string(mandatory = True, values = ["diff", "plan", "deploy", "destroy"]),
        "_cfnctl": attr.label(default = "//cfn/cmd/cfnctl", executable = True, cfg = "exec"),
    },
)

def cfn_stack(
        name,
        template,
        stack_name = None,
        region = None,
        account = None,
        parameters = None,
        stack_tags = None,
        capabilities = None,
        termination_protection = False,
        asset_bucket = None,
        role_arn = None,
        deps = [],
        visibility = None,
        **kwargs):
    """Materializes a cfn.template() as a deployable stack.

    Builds `<name>.template.json` and `<name>.manifest.json` (plus packaged
    assets), and defines run targets `<name>.diff`, `<name>.plan`,
    `<name>.deploy` and `<name>.destroy`.

    Args:
      name: target name.
      template: a cfn.template() value.
      stack_name: CloudFormation stack name (default: name).
      region: region to deploy to; commands refuse to run against any other.
      account: AWS account ID; commands refuse to run with credentials for any other.
      parameters: template parameter values.
      stack_tags: tags applied to the stack (and propagated to resources).
      capabilities: extra capabilities beyond the inferred ones.
      termination_protection: enable stack termination protection.
      asset_bucket: bucket for assets (default: the `cfnctl bootstrap` bucket). May use
        ${AWS::AccountId} and ${AWS::Region}.
      role_arn: service role CloudFormation assumes.
      deps: other cfn_stack targets this stack must be deployed after.
      visibility: visibility of the stack target.
      **kwargs: common attributes (tags, testonly, ...) for every generated target.
    """
    if not is_cfn(template, "template"):
        fail("cfn_stack: template must be a cfn.template()")
    assets = {}
    for label, packaging in template.assets:
        if assets.get(label, packaging) != packaging:
            fail("cfn_stack: asset {} is used with packaging {} and {}".format(label, assets[label], packaging))
        assets[label] = packaging
    _cfn_stack(
        name = name,
        template_json = json.encode(template.json),
        assets = assets,
        schemas = [str(s) for s in template.specs],
        stack_name = stack_name or name,
        region = region or "",
        account = account or "",
        parameters = parameters or {},
        stack_tags = stack_tags or {},
        capabilities = capabilities or [],
        termination_protection = termination_protection,
        asset_bucket = asset_bucket or "",
        role_arn = role_arn or "",
        deps = deps,
        visibility = visibility,
        **kwargs
    )
    for cmd in ["diff", "plan", "deploy", "destroy"]:
        _cfn_command(
            name = name + "." + cmd,
            stack = ":" + name,
            command = cmd,
            visibility = visibility,
            **kwargs
        )
