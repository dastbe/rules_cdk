# Design: Starlark bindings generated from CloudFormation specs

Status: **Draft for review**

## 1. Goal

`rules_cdk` today runs a CDK app (JS/Go/...) inside a Bazel action to produce a
cloud assembly, then diffs, deploys or destroys it with the CDK CLI. This
proposal keeps that end-to-end shape (author, synthesize, deploy, all in Bazel)
but takes CDK out of the authoring step:

1. **Spec in, bindings out.** Take a raw CloudFormation spec, fetched as a
   pluggable remote archive, and generate Starlark bindings for every resource
   type in it, during the repository phase.
2. **Starlark libraries produce CloudFormation.** Users and third parties write
   ordinary Starlark functions ("constructs") against those bindings. The
   functions return template values, which are validated against the spec when
   they are built.
3. **Materialize.** Turn those values into real artifacts: a plain template
   JSON, and a CDK-compatible cloud assembly so that the existing
   `cdk_diff` / `cdk_deploy` / `cdk_destroy` rules work unchanged.

Non-goals for v1: an L2-style high-level construct library, drift detection,
and running Starlark outside Bazel (we design for it but don't ship it, see §9).

## 2. User-facing sketch

```starlark
# MODULE.bazel
cfn = use_extension("@contrib_rules_cdk//cfn:extensions.bzl", "cfn")
cfn.spec(
    name = "cfn",
    format = "registry",            # or "resource_spec", see §3
    urls = ["https://mirror.example.com/cfn-schema/us-east-1/2026-10-01.zip"],
    sha256 = "…",
)
cfn.overlay(spec = "cfn", urls = ["…/my-org-private-types.zip"], sha256 = "…")
use_repo(cfn, "cfn")
```

```starlark
# //infra/lib/logging.bzl  (a reusable "library")
load("@cfn//aws:s3.bzl", "s3")
load("@cfn//aws:iam.bzl", "iam")
load("@contrib_rules_cdk//cfn:core.bzl", "fn", "scope")

def log_bucket(sc, retention_days = 30):
    bucket = s3.Bucket(
        sc.id("Bucket"),
        VersioningConfiguration = {"Status": "Enabled"},
        LifecycleConfiguration = {"Rules": [{
            "Status": "Enabled",
            "ExpirationInDays": retention_days,
        }]},
        deletion_policy = "Retain",
    )
    return struct(
        resources = [bucket],
        bucket_arn = bucket.attr.Arn,      # -> {"Fn::GetAtt": ["LogsBucket", "Arn"]}
    )
```

```starlark
# //infra/BUILD.bazel
load("@contrib_rules_cdk//cfn:defs.bzl", "cfn_stack", "cfn_assembly")
load("@contrib_rules_cdk//cdk:defs.bzl", "cdk_deploy", "cdk_diff")
load("//infra/lib:logging.bzl", "log_bucket")
load("@contrib_rules_cdk//cfn:core.bzl", "scope", "template")

logs = log_bucket(scope("Logs"), retention_days = 90)

cfn_stack(
    name = "logging_stack",
    stack_name = "logging",
    template = template(
        resources = logs.resources,
        outputs = {"LogBucketArn": {"Value": logs.bucket_arn}},
    ),
)

cfn_assembly(name = "assembly", stacks = [":logging_stack"])
cdk_diff(name = "diff", assembly = ":assembly")
cdk_deploy(name = "deploy", assembly = ":assembly")
```

A bad property fails at load time and names the exact field:

```
Error: AWS::S3::Bucket "LogsBucket": .VersioningConfiguration.Status:
  "enabled" is not one of ["Enabled", "Suspended"]
```

## 3. Spec sources (pluggable remote archives)

There are two upstream formats AWS publishes. We normalize both into one
internal IR, so codegen doesn't care which one it got.

| Format key      | Source                                                                 | Notes |
|-----------------|------------------------------------------------------------------------|-------|
| `registry`      | Per-region `CloudformationSchema.zip`: one JSON-Schema-style provider schema per type (`aws-s3-bucket.json`) | The current, maintained format. It has enums, patterns, `readOnlyProperties`, `createOnlyProperties`, `$ref` definitions and descriptions. Third-party and private registry types use the same format. |
| `resource_spec` | Per-region `CloudFormationResourceSpecification.json` (gzip)          | The legacy single-file format (`ResourceTypes`/`PropertyTypes`/`Attributes`). It's useful for older pins and SAM-like extensions. |

**Pluggability model**

- `cfn.spec(name, format, urls, sha256, strip_prefix, include, exclude)`
  declares one spec repo. `include`/`exclude` take type globs
  (`"AWS::S3::*"`) to keep generated output small.
- `cfn.overlay(spec, urls, sha256, format)` layers more archives into the same
  spec repo: private registry types, third-party types (`MongoDB::Atlas::*`),
  a SAM schema, or hand-written schemas for `Custom::*` resources. If two
  layers define the same type, the build fails unless `override = True`.
- A local directory or a label to an archive also works
  (`cfn.spec(..., archive = "//specs:my.zip")`), for air-gapped setups and tests.
- WORKSPACE users get the same thing as a macro:
  `cfn_spec_repository(name, ...)`.

**Pinning problem.** AWS's URLs point at "latest" and change underneath you, so
a `sha256` against them breaks. Following what `cdk/private/versions.bzl` does
for CDK, we:

- ship a `cfn/private/versions.bzl` of mirrored, dated snapshots (GitHub release
  assets on this repo) as the defaults (`cfn.spec(version = "2026-10-01")`).
- add `//cfn/tools:snapshot` (`bazel run`), which downloads the current
  upstream spec, prints its sha256 and writes a release asset. A scheduled
  workflow plus Renovate opens PRs for new snapshots, the same way CDK version
  bumps work today.

## 4. Code generation

### Where it runs: pure Starlark inside the repository rule (recommended)

The repository rule calls `rctx.download_and_extract`, reads each schema with
`rctx.read` + `json.decode`, builds the IR, and writes `.bzl` files with
`rctx.file`. Why:

- There's no tool to bootstrap: no Go or Node toolchain at fetch time, and it
  works the same on every host platform.
- It's "dynamic" in the sense you asked for: change the archive and the
  bindings regenerate on the next fetch.
- Cost: about 1,400 types, decoded once per fetch and then cached by Bazel's
  repository cache. This needs a spike to measure (§10, phase 0). The fallback
  is a small Go generator run via `rctx.execute`, prebuilt and fetched per
  platform.

### Layout of the generated repo

```
@cfn//
  BUILD.bazel                 # bzl_library targets, exports_files
  spec_info.bzl               # SPEC = struct(version, sha256, region, types=[...])
  aws/s3.bzl                  # one file per service namespace (~250 files)
  aws/iam.bzl
  mongodb/atlas.bzl           # overlays land in their own namespace
  _schemas/aws_s3.bzl         # compact validation tables (private)
```

There's one file per *service* (not one per type and not one global file), so a
`load()` only pays for the services it uses. Loading one big file with every
type in it would make every BUILD file that touches CFN slow.

### Shape of a generated binding

```starlark
# @cfn//aws:s3.bzl  (generated, do not edit)
load("@contrib_rules_cdk//cfn/private:runtime.bzl", "resource")
load("//_schemas:aws_s3.bzl", "BUCKET")

def _Bucket(
        logical_id,
        *,
        # --- properties (from spec, verbatim PascalCase) ---
        AccelerateConfiguration = None,
        BucketName = None,
        VersioningConfiguration = None,
        # ...
        # --- resource attributes (lower_snake, cannot collide with PascalCase) ---
        depends_on = None,
        condition = None,
        deletion_policy = None,
        update_replace_policy = None,
        creation_policy = None,
        update_policy = None,
        metadata = None):
    """AWS::S3::Bucket

    The AWS::S3::Bucket resource creates an Amazon S3 bucket ...

    Args:
      BucketName: (string, create-only) A name for the bucket ...
      ...
    """
    return resource(BUCKET, logical_id, locals())

s3 = struct(
    Bucket = _Bucket,
    BucketPolicy = _BucketPolicy,
    # ...
)
```

Decisions baked in here:

- **Property names stay verbatim** (PascalCase). Users can map 1:1 to AWS docs
  and existing templates, and there's no name-translation layer to get wrong.
  CFN properties are PascalCase and Starlark keywords are lowercase, so the
  two never collide.
- **Explicit keyword signatures**, not `**kwargs`. Bazel then rejects typos
  natively, and Stardoc can render docs straight from the spec's
  descriptions.
- **Nested property types are plain dicts** that the parent constructor
  validates recursively against the schema tables, with path-aware errors.
  Typed helper constructors (`s3.Bucket_VersioningConfiguration(...)`) are
  optional sugar we can add later, because Starlark structs can't hang
  attributes off a function.
- **Validation checks:** required props, primitive types, enums, list and map
  shapes, `oneOf`/`anyOf` (accepted if any branch matches). Patterns and
  min/max are optional behind `--@contrib_rules_cdk//cfn:strict`, because regex
  support in Starlark is nonexistent and we'd have to hand-roll it. Any value
  can also be an intrinsic (`Ref`, `Fn::*`), which skips static checks for
  that field.
- **Attributes:** `resource.attr.<Name>` is generated from
  `readOnlyProperties` (or `Attributes` in the legacy spec), so
  `bucket.attr.Arnn` is a load-time error. `resource.ref` gives `{"Ref": id}`.

### Schema normalization (IR)

```
Type      { name, namespace, service, short, doc, props: {name: Prop},
            attrs: {name: Shape}, required, create_only, write_only }
Prop      { shape: Shape, doc, required }
Shape     = Primitive(string|integer|number|boolean|json)
          | List(Shape, unique) | Map(Shape) | Object(name, props)
          | Enum([...]) | Union([Shape]) | Any
```

`$ref` is resolved and cycles are broken by name. Recursive definitions exist,
for example in WAFv2 and Bedrock.

## 5. Core runtime (`//cfn:core.bzl`, hand-written)

This is pure Starlark with no Bazel-only APIs (§9).

- `fn.ref`, `fn.get_att`, `fn.sub`, `fn.join`, `fn.select`, `fn.split`,
  `fn.if_`, `fn.equals`, `fn.and_`/`or_`/`not_`, `fn.import_value`,
  `fn.find_in_map`, `fn.base64`, `fn.cidr`, `fn.get_azs`, `fn.length`,
  `fn.to_json_string`. These are tagged structs that serialize to
  `{"Fn::X": ...}`.
- `pseudo.AccountId`, `pseudo.Region`, `pseudo.StackName`, ...
- `parameter(id, type, default, allowed_values, ...)`, `condition(id, expr)`,
  `mapping(id, table)`, `output(id, value, export_name)`.
- `template(resources, parameters, conditions, mappings, outputs, transform,
  metadata, description)` checks:
  - logical IDs are unique and alphanumeric
  - every `Ref`/`GetAtt` points at a resource or parameter in the template
  - `condition=` names exist
  - the template fits under CFN limits (500 resources, 200 outputs, ...)
  It returns a frozen struct with `.to_json()` (deterministic key order).
- `scope(prefix)` gives libraries composable logical-ID namespacing
  (`scope("Logs").child("Bucket").id("Policy")` → `LogsBucketPolicy`). This is
  the only "construct" concept, kept deliberately thin.

## 6. Materialization

Starlark values can't flow into rule attributes directly, so the bridge is
JSON:

```
BUILD/.bzl (loading phase)               analysis / execution
───────────────────────────               ───────────────────────────────────
template(...)  ──json.encode──▶ attr.string ──▶ cfn_stack ──▶ <name>.template.json
                                               │   ▲ asset placeholders
                                 attr.label_keyed_string_dict (assets)
                                               ▼
                                         cfn_assembly ──▶ cloud assembly dir
                                                            ├─ manifest.json
                                                            ├─ *.template.json
                                                            └─ *.assets.json + asset files
                                                                │
                                         cdk_diff / cdk_deploy / cdk_destroy (existing)
```

### 6.1 `cfn_stack` (macro + rule)

- The macro calls `json.encode(template)` and passes it to a private rule as
  `attr.string`, along with `stack_name`, `env` (`aws://acct/region` or
  unknown), `tags` and `termination_protection`.
- The rule writes `<name>.template.json` and returns
  `CfnStackInfo(template, stack_name, env, assets, dependencies)`.
- An optional `cfn_lint_test(stack = ...)` wraps `cfn-lint`, pip-installed
  through `rules_python`, for checks we don't do in Starlark: regexes, and
  semantics such as "this AMI property doesn't match this region".

### 6.2 `cfn_assembly`: reuse rules_cdk's deploy path

- It emits a **CDK cloud assembly**: a `manifest.json` with
  `aws:cloudformation:stack` artifacts, templates, and asset manifests. The
  CDK CLI accepts a directory as `--app`, so `cdk_exec` and the
  diff/deploy/destroy/bootstrap rules work unchanged.
- Cross-stack dependencies (`dependencies` in the manifest) come from
  `fn.import_value` usages, or from an explicit `deps = [":other_stack"]`.
- We'd pin the cloud-assembly schema version we emit and test it against each
  mirrored CDK CLI version in `versions.bzl`.

### 6.3 Assets (Lambda code, container images, nested templates)

Asset hashes are only known at execution time, so templates get placeholders:

```starlark
code = asset("//svc:lambda_zip")   # -> {"__cfn_asset__": "//svc:lambda_zip"}
lambda_.Function("Fn", Code = {"S3Bucket": code.bucket, "S3Key": code.key}, ...)
```

The `cfn_stack` macro collects the asset labels into a label-keyed attr. An
execution-time action (a small Node script, since the Node toolchain is
already a dependency) then:

1. sha256-hashes each asset file or directory (zipping directories
   deterministically),
2. substitutes `bucket` and `key` with the CDK bootstrap conventions
   (`cdk-hnb659fds-assets-${AWS::AccountId}-${AWS::Region}`, `<hash>.zip`),
3. writes `<stack>.assets.json` so `cdk deploy` uploads them.

Docker image assets work the same way against the bootstrap ECR repo, and
`cdk_bootstrap` already exists. Nested stacks are a `cfn_stack` used as an
asset.

### 6.4 Plain outputs

`cfn_stack`'s default output is the bare template, so users who deploy with
`aws cloudformation deploy`, StackSets, Service Catalog or Proton can skip the
assembly entirely.

## 7. Library ecosystem

- A library is just a `.bzl` that does `load("@cfn//aws:...")`. The problem is
  that the library author doesn't control which spec repo the consumer
  configured.
- The fix is a **hub repo name convention**: the extension always exposes the
  root module's chosen spec as `@cfn`, and libraries `use_repo(cfn, "cfn")`.
  The root module's `cfn.spec` tag wins, and non-root tags only contribute
  overlays. A library that needs types the consumer's spec lacks fails at load
  time with a clear message. Libraries can declare that dependency through
  `require_types(["AWS::Bedrock::Agent"])` against `spec_info.bzl`.
- Multi-region specs: `cfn.spec(name = "cfn_cn_north_1", ...)` lets a
  consumer validate against a second region's resource availability.

## 8. Repo organization

The new code goes in a sibling `//cfn` package in this repo, which shares
`//cdk` for deploy:

```
cfn/
  defs.bzl            # cfn_stack, cfn_assembly, cfn_lint_test, asset
  core.bzl            # fn, pseudo, template, scope, parameter, output...
  extensions.bzl      # bzlmod: cfn.spec / cfn.overlay
  repositories.bzl    # WORKSPACE: cfn_spec_repository
  private/
    spec_repo.bzl     # repository rule
    normalize_registry.bzl, normalize_resource_spec.bzl
    codegen.bzl       # IR -> .bzl text
    runtime.bzl       # resource(), validation engine
    assembly.bzl, stack.bzl, assets.js
    versions.bzl      # mirrored spec snapshots
  tests/
    fixtures/         # tiny hand-rolled schema archives
    golden/           # expected generated .bzl
e2e/workspace/examples/starlark/
```

This also means adding `MODULE.bazel`. The repo is WORKSPACE-only on Bazel 6
today, so module extensions need bzlmod, and we'd keep the WORKSPACE macro for
parity.

## 9. Designing for a standalone runtime later

Every generated file and `core.bzl` avoid Bazel-only builtins: no `native.*`,
no `Label`, no `select`. Only `struct`, `json` and `fail` are used, and
starlark-go has all three. A later `cfn-star` CLI (starlark-go plus a
`load()` resolver mapping `@cfn//aws:s3.bzl` to generated files) could then run
the same libraries outside Bazel, for quick iteration or non-Bazel users,
without forking the bindings. Out of scope for v1, but it constrains §4 and §5
now.

## 10. Phased plan

| Phase | Deliverable | Exit criteria |
|------:|-------------|---------------|
| 0. Spike (≈2–3 days) | Hand-write bindings for `AWS::S3::Bucket` + `AWS::IAM::Role`. Time `json.decode` over the full registry zip in a repository rule. | API ergonomics agreed; fetch+codegen of the full spec < ~10s, or a decision to use the Go fallback. |
| 1. Core runtime | `core.bzl`: intrinsics, template, scope, serialization; `runtime.bzl` validation engine | skylib unittest coverage; golden JSON for sample templates |
| 2. Spec repo + codegen (registry format) | `cfn.spec`, normalization, per-service `.bzl` output, `include`/`exclude` | Golden tests on fixture archives; full us-east-1 spec generates and every generated file loads (a `bzl_library` build test) |
| 3. `cfn_stack` | Template materialization, `CfnStackInfo`, optional `cfn_lint_test` | e2e example produces a template that passes cfn-lint |
| 4. `cfn_assembly` | Cloud assembly output, wired into the existing `cdk_diff/deploy/destroy` | `cdk diff` against an assembly works in e2e (synth-only in CI) |
| 5. Assets | Placeholder substitution, asset manifests, Lambda zip example | Deploys a Lambda from a `pkg_zip` target in a sandbox account |
| 6. Pluggability polish | `cfn.overlay`, `resource_spec` adapter, SAM schema overlay, mirrored snapshot versions + snapshot tool + Renovate | Private-type overlay fixture; two pinned snapshot versions in `versions.bzl` |
| 7. Docs | Stardoc for core + one generated service, README section, migration notes | — |

## 11. Open questions for review

1. **Codegen language:** pure Starlark in the repository rule (recommended) or
   a Go generator? It hinges on the phase 0 timing.
2. **Nested types:** plain dicts plus deep validation (recommended), or
   generated typed constructors from day one?
3. **Naming:** keep CFN PascalCase property names (recommended), or snake_case
   them to match Starlark style?
4. **Deploy path:** lean on the CDK CLI and cloud assembly (recommended, it
   reuses everything here), or also offer a direct
   `aws cloudformation deploy` runner so users don't need Node or CDK
   bootstrap?
5. **Packaging:** put this in this repo under `//cfn` (recommended), or split it
   into its own `rules_cfn` that depends on `rules_cdk` for deploy?
6. **Bzlmod:** OK to add `MODULE.bazel` and raise the minimum Bazel to 6.x+ for
   this feature?
7. **Strictness defaults:** should regex/min/max validation be on by default
   (slower loads, hand-rolled matcher) or opt-in?
