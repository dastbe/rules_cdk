"""Module extension for declaring CloudFormation specs.

    cfn = use_extension("@rules_cfn//cfn:extensions.bzl", "cfn")
    cfn.spec(name = "cfn", urls = [...], sha256 = "...")
    cfn.overlay(spec = "cfn", urls = [...], sha256 = "...")
    use_repo(cfn, "cfn")
"""

load("//cfn/private:spec_repo.bzl", "cfn_spec_repo")

_spec = tag_class(
    doc = "Declares a spec repository generated from CloudFormation registry schemas.",
    attrs = {
        "name": attr.string(default = "cfn", doc = "Repository name; libraries conventionally load from @cfn."),
        "urls": attr.string_list(doc = "URLs of a registry schema archive (e.g. CloudformationSchema.zip)."),
        "sha256": attr.string(),
        "strip_prefix": attr.string(),
        "schema_dirs": attr.label_list(
            allow_files = True,
            doc = "Labels of a file inside each directory of local schema JSON files (searched recursively), layered after the archive.",
        ),
        "include": attr.string_list(doc = "Type-name globs to include, e.g. [\"AWS::S3::*\"]."),
        "exclude": attr.string_list(doc = "Type-name globs to exclude."),
    },
)

_overlay = tag_class(
    doc = "Layers additional schemas (private/third-party types, hand-written Custom:: schemas) into a spec.",
    attrs = {
        "spec": attr.string(default = "cfn"),
        "urls": attr.string_list(),
        "sha256": attr.string(),
        "strip_prefix": attr.string(),
        "allow_override": attr.bool(doc = "Allow this overlay to replace types defined by earlier layers."),
    },
)

def _cfn_impl(mctx):
    specs = {}
    overlays = {}
    # mctx.modules lists the root module first, so the root's spec wins and a
    # library's spec is only used when nobody above it declared that name.
    for mod in mctx.modules:
        for s in mod.tags.spec:
            if s.name not in specs:
                specs[s.name] = s
        for o in mod.tags.overlay:
            overlays.setdefault(o.spec, []).append(o)

    for name, s in specs.items():
        archives = []
        if s.urls:
            archives.append(json.encode({"urls": s.urls, "sha256": s.sha256, "strip_prefix": s.strip_prefix, "type": "zip" if s.urls[0].endswith(".zip") else ""}))
        for o in overlays.get(name, []):
            archives.append(json.encode({
                "urls": o.urls,
                "sha256": o.sha256,
                "strip_prefix": o.strip_prefix,
                "allow_override": o.allow_override,
            }))
        cfn_spec_repo(
            name = name,
            archives = archives,
            schema_dirs = s.schema_dirs,
            include = s.include,
            exclude = s.exclude,
        )
    for name in overlays:
        if name not in specs:
            fail("cfn.overlay: no cfn.spec named {}".format(name))

cfn = module_extension(
    implementation = _cfn_impl,
    tag_classes = {"spec": _spec, "overlay": _overlay},
)
