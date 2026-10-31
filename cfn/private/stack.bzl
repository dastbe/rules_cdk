"""cfn_stack: evaluates a .star stack and materializes a deployable template + manifest."""

load(":library.bzl", "collect")
load(":providers.bzl", "CfnLibraryInfo", "CfnStackInfo")

_DEFAULT_DEPS = ["@cfn//:bindings", "//cfn:core"]

def _repo_args(info, short):
    args = []
    seen = {}
    for name, exec_path, short_path in info.repos.to_list():
        if not name or name in seen:
            continue
        seen[name] = True
        args.append("--repo={}={}".format(name, short_path if short else exec_path))
    return args

def _rel_path(f, label):
    """Path of f relative to label's package (for zip entry names)."""
    prefix = ""
    if label.workspace_name:
        prefix = "../" + label.workspace_name + "/"
    if label.package:
        prefix += label.package + "/"
    sp = f.short_path
    return sp[len(prefix):] if sp.startswith(prefix) else f.basename

def _label_str(label):
    s = str(label)
    return s[2:] if s.startswith("@@//") else s

def _cfn_stack_impl(ctx):
    name = ctx.label.name
    info = collect(ctx.attr.deps + ctx.attr._default_deps, ctx.files.src)

    deps = [d[CfnStackInfo].stack_name for d in ctx.attr.stack_deps]
    config = ctx.actions.declare_file(name + ".config.json")
    ctx.actions.write(config, json.encode_indent({
        "stack_name": ctx.attr.stack_name or name,
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

    lines = []
    asset_inputs = []
    for target in ctx.attr.assets:
        for f in target[DefaultInfo].files.to_list():
            if f.is_directory:
                fail("asset {}: directories are not supported yet; list the files instead".format(target.label))
            lines.append("\t".join([_label_str(target.label), ctx.attr.asset_packaging.get(_label_str(target.label), "zip"), _rel_path(f, target.label), f.path]))
            asset_inputs.append(f)
    asset_list = ctx.actions.declare_file(name + ".assets.txt")
    ctx.actions.write(asset_list, "\n".join(lines) + "\n")

    template = ctx.outputs.template
    manifest = ctx.outputs.manifest
    assets_dir = ctx.actions.declare_directory(name + ".assets")
    args = ctx.actions.args()
    args.add("build")
    args.add("--root=.")
    args.add_all(_repo_args(info, False))
    args.add("--entry=" + ctx.attr.entry)
    args.add("--config=" + config.path)
    args.add("--asset-list=" + asset_list.path)
    args.add("--out-template=" + template.path)
    args.add("--out-manifest=" + manifest.path)
    args.add("--out-assets=" + assets_dir.path)
    args.add(ctx.file.src.path)
    ctx.actions.run(
        executable = ctx.executable._cfnctl,
        arguments = [args],
        inputs = depset([config, asset_list] + asset_inputs, transitive = [info.srcs]),
        outputs = [template, manifest, assets_dir],
        mnemonic = "CfnBuild",
        progress_message = "Evaluating and packaging CloudFormation stack %{label}",
    )
    return [
        DefaultInfo(files = depset([template, manifest]), runfiles = ctx.runfiles(files = [template, manifest, assets_dir])),
        CfnStackInfo(stack_name = ctx.attr.stack_name or name, template = template, manifest = manifest, assets = assets_dir),
        OutputGroupInfo(assets = depset([assets_dir])),
    ]

_cfn_stack = rule(
    implementation = _cfn_stack_impl,
    outputs = {
        "template": "%{name}.template.json",
        "manifest": "%{name}.manifest.json",
    },
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = [".star"]),
        "entry": attr.string(default = "main"),
        "deps": attr.label_list(providers = [CfnLibraryInfo]),
        "assets": attr.label_list(allow_files = True),
        "asset_packaging": attr.string_dict(doc = "asset label -> \"zip\" (default) or \"file\""),
        "stack_name": attr.string(),
        "region": attr.string(),
        "account": attr.string(),
        "parameters": attr.string_dict(),
        "stack_tags": attr.string_dict(),
        "capabilities": attr.string_list(),
        "termination_protection": attr.bool(),
        "asset_bucket": attr.string(),
        "role_arn": attr.string(),
        "stack_deps": attr.label_list(providers = [CfnStackInfo]),
        "_default_deps": attr.label_list(default = _DEFAULT_DEPS, providers = [CfnLibraryInfo]),
        "_cfnctl": attr.label(default = "//cfnctl", executable = True, cfg = "exec"),
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
# bazel run starts in the runfiles tree; resolve paths before changing directory.
cfnctl="$PWD/{cfnctl}"
manifest="$PWD/{manifest}"
cd "${{BUILD_WORKING_DIRECTORY:-.}}"
exec "$cfnctl" {cmd} --manifest="$manifest" "$@"
""".format(cfnctl = cfnctl.short_path, manifest = info.manifest.short_path, cmd = _sh_quote(ctx.attr.command)), is_executable = True)
    runfiles = ctx.runfiles(files = [cfnctl]).merge(ctx.attr.stack[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

_cfn_command = rule(
    implementation = _cfn_command_impl,
    executable = True,
    attrs = {
        "stack": attr.label(mandatory = True, providers = [CfnStackInfo]),
        "command": attr.string(mandatory = True, values = ["diff", "plan", "deploy", "destroy"]),
        "_cfnctl": attr.label(default = "//cfnctl", executable = True, cfg = "exec"),
    },
)

def cfn_stack(name, src, deps = [], assets = [], visibility = None, **kwargs):
    """Evaluates `src`'s `main()` (a template()) and materializes it as a deployable stack.

    Builds `<name>.template.json` and `<name>.manifest.json` (plus packaged assets),
    and defines run targets `<name>.diff`, `<name>.plan`, `<name>.deploy` and
    `<name>.destroy`.

    Args:
      name: target name.
      src: the .star file defining the entry function.
      deps: cfn_library targets `src` loads (core and @cfn bindings are implicit).
      assets: targets whose files `asset("//pkg:target")` refers to.
      visibility: visibility of the stack target.
      **kwargs: entry, stack_name, region, account, parameters, stack_tags, capabilities,
        termination_protection, asset_bucket, role_arn, stack_deps, asset_packaging, and
        common attributes (tags, testonly, ...).
    """
    common = {k: v for k, v in kwargs.items() if k in ("tags", "testonly", "target_compatible_with")}
    _cfn_stack(name = name, src = src, deps = deps, assets = assets, visibility = visibility, **kwargs)
    for cmd in ["diff", "plan", "deploy", "destroy"]:
        _cfn_command(name = name + "." + cmd, stack = ":" + name, command = cmd, visibility = visibility, **common)

def _cfn_check_test_impl(ctx):
    info = collect(ctx.attr.deps + ctx.attr._default_deps, ctx.files.srcs)
    cfnctl = ctx.executable._cfnctl
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    files = " ".join([_sh_quote(f.short_path) for f in ctx.files.srcs])
    repos = " ".join([_sh_quote(a) for a in _repo_args(info, True)])
    if ctx.attr.expect_error:
        body = """
if out=$("$cfnctl" check --root=. {repos} {files} 2>&1); then
  echo "expected cfnctl check to fail with: {want}"; exit 1
fi
if ! grep -qF -- {want_q} <<<"$out"; then
  echo "expected error containing: {want}"; echo "got:"; echo "$out"; exit 1
fi
""".format(repos = repos, files = files, want = ctx.attr.expect_error.replace('"', '\\"'), want_q = _sh_quote(ctx.attr.expect_error))
    else:
        body = '"$cfnctl" check --root=. {repos} {files}\n'.format(repos = repos, files = files)
    ctx.actions.write(script, "#!/usr/bin/env bash\nset -uo pipefail\ncfnctl={}\n{}".format(_sh_quote(cfnctl.short_path), body), is_executable = True)
    runfiles = ctx.runfiles(files = [cfnctl], transitive_files = info.srcs)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

cfn_check_test = rule(
    implementation = _cfn_check_test_impl,
    test = True,
    doc = "Typechecks and evaluates .star files; with expect_error, passes only if that error is reported.",
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True, doc = ".star files, or targets producing directories of them (e.g. a spec's :bindings)."),
        "deps": attr.label_list(providers = [CfnLibraryInfo]),
        "expect_error": attr.string(),
        "_default_deps": attr.label_list(default = _DEFAULT_DEPS, providers = [CfnLibraryInfo]),
        "_cfnctl": attr.label(default = "//cfnctl", executable = True, cfg = "exec"),
    },
)

def _cfn_lsp_impl(ctx):
    info = collect(ctx.attr.deps + ctx.attr._default_deps)
    cfnctl = ctx.executable._cfnctl
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    repo_lines = []
    for a in _repo_args(info, True):
        name, path = a[len("--repo="):].split("=", 1)
        if path == ".":
            # Main-repository files: point at the workspace so edits and go-to-definition use real files.
            repo_lines.append('args+=("--repo={}=$ws")'.format(name))
        else:
            repo_lines.append('args+=("--repo={}=$PWD/{}")'.format(name, path))
    ctx.actions.write(script, """#!/usr/bin/env bash
set -euo pipefail
# Language server for .star files. Configure your editor to run:
#   bazel run --ui_event_filters=-info --noshow_progress {label}
ws="${{BUILD_WORKSPACE_DIRECTORY:-$PWD}}"
args=()
{repos}
exec "$PWD/{cfnctl}" lsp --root="$ws" "${{args[@]}}"
""".format(label = str(ctx.label), repos = "\n".join(repo_lines), cfnctl = cfnctl.short_path), is_executable = True)
    runfiles = ctx.runfiles(files = [cfnctl], transitive_files = info.srcs)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

cfn_lsp = rule(
    implementation = _cfn_lsp_impl,
    executable = True,
    doc = "Runs `cfnctl lsp` with the repositories of `deps` mapped, for editors.",
    attrs = {
        "deps": attr.label_list(providers = [CfnLibraryInfo]),
        "_default_deps": attr.label_list(default = _DEFAULT_DEPS, providers = [CfnLibraryInfo]),
        "_cfnctl": attr.label(default = "//cfnctl", executable = True, cfg = "exec"),
    },
)
