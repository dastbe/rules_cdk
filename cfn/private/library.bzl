"""cfn_library: a set of .star files and the repositories their load() labels refer to."""

load(":providers.bzl", "CfnLibraryInfo")

def repo_entry(label, repo_name):
    """(name, exec_path, short_path) for the repository holding `label`."""
    if label.workspace_root:
        short = "../" + label.workspace_name
        return (repo_name, label.workspace_root, short)
    return (repo_name, ".", ".")

def collect(targets, srcs = [], own = []):
    return CfnLibraryInfo(
        srcs = depset(srcs, transitive = [t[CfnLibraryInfo].srcs for t in targets]),
        repos = depset(own, transitive = [t[CfnLibraryInfo].repos for t in targets]),
    )

def _cfn_library_impl(ctx):
    own = []
    if ctx.attr.repo_name:
        own.append(repo_entry(ctx.label, ctx.attr.repo_name))
    elif ctx.label.workspace_root:
        fail("cfn_library {}: libraries outside the main repository must set repo_name to the name load() labels use".format(ctx.label))
    info = collect(ctx.attr.deps, ctx.files.srcs, own)
    return [DefaultInfo(files = info.srcs), info]

cfn_library = rule(
    implementation = _cfn_library_impl,
    doc = "Starlark (.star) sources for CloudFormation, loadable with load(\"//pkg:file.star\", ...).",
    attrs = {
        "srcs": attr.label_list(allow_files = [".star"]),
        "deps": attr.label_list(providers = [CfnLibraryInfo], doc = "Libraries and bindings these sources load."),
        "repo_name": attr.string(doc = "For libraries in other modules: the repository name load() labels refer to them by."),
    },
)
