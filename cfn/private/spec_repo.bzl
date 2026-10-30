"""Repository rule that fetches CloudFormation registry schemas and generates bindings."""

load(":codegen.bzl", "emit_service", "normalize", "service_symbol")

def _glob_match(pattern, s):
    """Minimal '*' wildcard matching."""
    parts = pattern.split("*")
    if len(parts) == 1:
        return pattern == s
    if not s.startswith(parts[0]):
        return False
    pos = len(parts[0])
    for mid in parts[1:-1]:
        i = s.find(mid, pos)
        if i < 0:
            return False
        pos = i + len(mid)
    last = parts[-1]
    return len(s) - pos >= len(last) and s.endswith(last)

def _selected(type_name, include, exclude):
    if include and not [p for p in include if _glob_match(p, type_name)]:
        return False
    return not [p for p in exclude if _glob_match(p, type_name)]

def _json_files(rctx, root):
    out = []
    stack = [rctx.path(root)]
    for _ in range(1 << 20):
        if not stack:
            break
        d = stack.pop()
        for e in d.readdir():
            if e.is_dir:
                stack.append(e)
            elif e.basename.endswith(".json"):
                out.append(e)
    return sorted(out, key = lambda p: str(p))

_BUILD_ROOT = """\
filegroup(
    name = "schemas",
    srcs = glob(["schemas/**/*.json"]),
    visibility = ["//visibility:public"],
)

exports_files(["spec_info.bzl"])
"""

_BUILD_NS = """\
exports_files(glob(["*.bzl"]))
"""

def _cfn_spec_repo_impl(rctx):
    layers = []
    for i, raw in enumerate(rctx.attr.archives):
        a = json.decode(raw)
        out = "schemas/{}".format(i)
        rctx.download_and_extract(
            url = a["urls"],
            sha256 = a.get("sha256", ""),
            stripPrefix = a.get("strip_prefix", ""),
            output = out,
            type = a.get("type", ""),
        )
        layers.append((out, a.get("allow_override", False)))
    for i, marker in enumerate(rctx.attr.schema_dirs):
        src = rctx.path(marker).dirname
        rctx.watch_tree(src)
        out = "schemas/dir{}".format(i)
        for f in _json_files(rctx, src):
            rctx.symlink(f, "{}/{}".format(out, f.basename))
        layers.append((out, True))
    if not layers:
        fail("cfn spec {}: no archives or schema files given".format(rctx.attr.name))

    include = rctx.attr.include
    exclude = rctx.attr.exclude
    by_type = {}
    for root, allow_override in layers:
        for p in _json_files(rctx, root):
            schema = json.decode(rctx.read(p))
            if type(schema) != "dict" or type(schema.get("typeName")) != "string":
                continue
            tn = schema["typeName"]
            if len(tn.split("::")) != 3:
                continue
            if not _selected(tn, include, exclude):
                continue
            if tn in by_type and not allow_override:
                fail("cfn spec {}: {} is defined by more than one archive; set allow_override on the overlay".format(rctx.attr.name, tn))
            by_type[tn] = schema

    services = {}
    for tn in sorted(by_type):
        ns, svc, _ = tn.split("::")
        key = (ns.lower(), svc.lower())
        services.setdefault(key, []).append(by_type[tn])

    namespaces = {}
    report = []
    for (ns, svc), schemas in sorted(services.items()):
        sym = service_symbol(svc)
        resources = [normalize(s, sym) for s in schemas]
        src, collisions = emit_service(ns, svc, sym, resources)
        rctx.file("{}/{}.bzl".format(ns, svc), src)
        namespaces[ns] = True
        report.extend(["{}/{}.bzl: {}".format(ns, svc, c) for c in collisions])

    for ns in namespaces:
        rctx.file(ns + "/BUILD.bazel", _BUILD_NS)

    # Loading this package loads every generated file: `bazel build @<spec>//_smoke`.
    smoke = ['"""Generated smoke test: loads every service file. DO NOT EDIT."""', ""]
    for (ns, svc) in sorted(services):
        sym = service_symbol(svc)
        smoke.append('load("//{}:{}.bzl", {})'.format(ns, svc, ", ".join([
            '_{}_{} = "{}"'.format(ns, k, k)
            for k in [sym, sym.rstrip("_") + "_types", sym.rstrip("_") + "_enums"]
        ])))
    smoke.append("")
    smoke.append('filegroup(name = "_smoke", visibility = ["//visibility:public"])')
    rctx.file("_smoke/BUILD.bazel", "\n".join(smoke) + "\n")
    rctx.file("BUILD.bazel", _BUILD_ROOT)
    rctx.file("naming_report.txt", "\n".join(report) + "\n")
    rctx.file("spec_info.bzl", "\n".join([
        '"""Generated. DO NOT EDIT."""',
        "",
        "SPEC = struct(",
        "    name = {},".format(json.encode(rctx.attr.name)),
        "    types = {},".format(json.encode(sorted(by_type.keys()))),
        ")",
        "",
    ]))

cfn_spec_repo = repository_rule(
    implementation = _cfn_spec_repo_impl,
    doc = "Fetches CloudFormation registry schema archives and generates typed Starlark bindings.",
    attrs = {
        "archives": attr.string_list(doc = "JSON-encoded {urls, sha256, strip_prefix, type, allow_override} per archive layer, in order."),
        "schema_dirs": attr.label_list(allow_files = True, doc = "Files whose sibling directories hold local schema JSON files, layered last."),
        "include": attr.string_list(doc = "Type-name globs to include (default: everything)."),
        "exclude": attr.string_list(doc = "Type-name globs to exclude."),
    },
)
