"""cfn_bindings: generates typed .star bindings from registry schemas with `cfnctl gen`."""

load(":providers.bzl", "CfnLibraryInfo")

def _cfn_bindings_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    root = ctx.label.workspace_root
    args = ctx.actions.args()
    args.add("gen")
    args.add("--out", out.path)
    args.add("--repo-name", ctx.attr.repo_name)
    args.add_all(ctx.attr.include, before_each = "--include")
    args.add_all(ctx.attr.exclude, before_each = "--exclude")
    args.add_all([(root + "/" + l) if root else l for l in ctx.attr.layers])
    ctx.actions.run(
        executable = ctx.executable._cfnctl,
        arguments = [args],
        inputs = ctx.files.schemas,
        outputs = [out],
        mnemonic = "CfnGen",
        progress_message = "Generating CloudFormation bindings %{label}",
    )
    return [
        DefaultInfo(files = depset([out])),
        CfnLibraryInfo(
            srcs = depset([out]),
            repos = depset([(ctx.attr.repo_name, out.path, out.short_path)]),
        ),
    ]

cfn_bindings = rule(
    implementation = _cfn_bindings_impl,
    doc = "Typed .star bindings for a set of CloudFormation registry schemas (a tree of <ns>/<service>/<resource>.star).",
    attrs = {
        "repo_name": attr.string(mandatory = True, doc = "Repository name the bindings are loaded from in load() labels."),
        "layers": attr.string_list(mandatory = True, doc = "Schema directories (relative to this repo), in layering order."),
        "schemas": attr.label_list(allow_files = [".json"]),
        "include": attr.string_list(),
        "exclude": attr.string_list(),
        "_cfnctl": attr.label(default = "//cfnctl", executable = True, cfg = "exec"),
    },
)
