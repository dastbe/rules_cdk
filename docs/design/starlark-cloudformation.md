# Design: rules_cfn: typed Starlark bindings generated from CloudFormation specs

Status: **Draft for review (rev 2)**

Rev 2 incorporates review decisions:

| # | Question | Decision |
|---|----------|----------|
| 1 | Codegen language | Bindings are generated **Starlark** |
| 2 | Nested property values | **Typed constructors wherever possible**; plain dicts only where the spec itself is untyped |
| 3 | Naming | **snake_case** for everything user-facing |
| 4 | Deploy path | **Raw CloudFormation, no CDK.** A Go app (`cfnctl`) packages, dry-runs, diffs and executes |
| 5 | Packaging | Build it in this repo and **remove CDK entirely** ("salt the earth"); migrate repos later |
| 6 | Bzlmod | **Yes**, bzlmod only |

## 1. Goal

1. **Spec in, bindings out.** Fetch raw CloudFormation specs as pluggable
   remote archives and generate typed Starlark bindings for every resource and
   property type, during the repository phase.
2. **Starlark libraries produce CloudFormation.** People write ordinary
   Starlark functions against those bindings. Values are validated when they
   are built, and errors name the exact field path.
3. **Materialize with a Go app.** Bazel produces a final template plus a stack
   manifest. `cfnctl` turns that into real stacks with `plan` (dry run via a
   change set), `diff`, `deploy` (execute) and `destroy`.

Non-goals for v1: high-level (L2-style) construct libraries, drift detection,
StackSets.

## 2. User-facing sketch

```starlark
# MODULE.bazel
bazel_dep(name = "rules_cfn", version = "0.1.0")

cfn = use_extension("@rules_cfn//cfn:extensions.bzl", "cfn")
cfn.spec(version = "2026-10-01")                     # mirrored snapshot, or:
# cfn.spec(format = "registry", urls = ["…/CloudformationSchema.zip"], sha256 = "…")
cfn.overlay(urls = ["…/my-org-private-types.zip"], sha256 = "…")
use_repo(cfn, "cfn")
```

```starlark
# //infra/lib/logging.bzl  (a reusable library)
load("@cfn//aws:s3.bzl", "s3", "s3_types")
load("@rules_cfn//cfn:core.bzl", "cfn")

def log_bucket(sc, retention_days = 30):
    bucket = s3.bucket(
        sc.id("Bucket"),
        versioning_configuration = s3_types.bucket.versioning_configuration(
            status = "Enabled",
        ),
        lifecycle_configuration = s3_types.bucket.lifecycle_configuration(
            rules = [s3_types.bucket.rule(
                status = "Enabled",
                expiration_in_days = retention_days,
            )],
        ),
        tags = [cfn.tag("team", "infra")],
        deletion_policy = "Retain",
    )
    return struct(
        resources = [bucket],
        arn = bucket.attr.arn,           # -> {"Fn::GetAtt": ["LogsBucket", "Arn"]}
    )
```

```starlark
# //infra/BUILD.bazel
load("@rules_cfn//cfn:defs.bzl", "cfn_stack")
load("@rules_cfn//cfn:core.bzl", "cfn")
load("//infra/lib:logging.bzl", "log_bucket")

logs = log_bucket(cfn.scope("Logs"), retention_days = 90)

cfn_stack(
    name = "logging",
    stack_name = "logging",
    region = "us-east-1",
    account = "123456789012",          # deploy refuses to run against any other account
    template = cfn.template(
        resources = logs.resources,
        outputs = [cfn.output("LogBucketArn", logs.arn, export_name = "logging-bucket-arn")],
    ),
)
# bazel build //infra:logging          -> logging.template.json + logging.manifest.json
# bazel run   //infra:logging.diff     -> template diff + change-set summary
# bazel run   //infra:logging.plan     -> dry run (create, describe, delete change set)
# bazel run   //infra:logging.deploy   -> create + execute change set, stream events
# bazel run   //infra:logging.destroy
```

Errors happen at load time and name the field path:

```
Error: AWS::S3::Bucket "LogsBucket": .versioning_configuration: expected
  s3_types.bucket.versioning_configuration, got dict
Error: AWS::S3::Bucket "LogsBucket": .versioning_configuration.status:
  "enabled" is not one of ["Enabled", "Suspended"]
```

## 3. Spec sources (pluggable remote archives)

There are two upstream formats. Both are converted into one internal model
(IR, §4.4).

| `format`        | Source | Notes |
|-----------------|--------|-------|
| `registry`      | Per-region `CloudformationSchema.zip`, one provider schema per type | The default. It has enums, patterns, `readOnlyProperties`, `createOnlyProperties`, `$ref` definitions and descriptions. Private and third-party registry types use the same format. |
| `resource_spec` | Per-region `CloudFormationResourceSpecification.json` | The legacy format, for old pins. |

- `cfn.spec(name = "cfn", version | urls+sha256 | archive = label, format,
  strip_prefix, include = ["AWS::S3::*", ...], exclude = [...])`
- `cfn.overlay(spec = "cfn", urls | archive, sha256, format, override = False)`
  layers more types into a spec repo: private types, `MongoDB::Atlas::*`,
  hand-written schemas for `Custom::*`, the SAM schema. A duplicate type name
  fails the build unless `override = True`.
- **Hub repo:** the root module's `cfn.spec` is always exposed as `@cfn`.
  Non-root modules (libraries) may only add overlays. A library declares what
  it needs with `cfn.require_types(["AWS::Bedrock::Agent"])` in its `.bzl`,
  which fails clearly if the consumer's spec lacks those types.
- **Pinning:** AWS publishes "latest" URLs only, so any sha256 pin breaks when
  AWS updates. We mirror dated snapshots as GitHub release assets, listed in
  `cfn/private/versions.bzl`. `bazel run //cfn/tools:snapshot` fetches
  upstream and writes a new snapshot, and a scheduled workflow opens PRs for
  them.

## 4. Code generation

### 4.1 Where it runs

The repository rule runs `rctx.download_and_extract`, then `rctx.read` +
`json.decode` for each schema, builds the IR in Starlark, and writes `.bzl`
text with `rctx.file`. There is no tool to bootstrap at fetch time. Phase 0
measures fetch time for the full spec. If it's too slow, the fallback is the
same generator logic in `cfnctl gen`, executed by the repository rule. Either
way, the *output* is Starlark.

### 4.2 Layout of the generated repo

```
@cfn//
  BUILD.bazel                # bzl_library per file
  spec_info.bzl              # SPEC = struct(version, sha256, types = [...])
  aws/s3.bzl                 # exports: s3, s3_types
  aws/lambda.bzl             # exports: lambda_, lambda_types   ("lambda" is a Starlark keyword)
  mongodb/atlas.bzl
  private/aws_s3_schema.bzl  # compact validation tables
```

There is one file per service namespace (about 250 files), so a `load()` only
pays for what it uses.

### 4.3 Shape of generated code

```starlark
# @cfn//aws:s3.bzl  (generated, do not edit)
load("@rules_cfn//cfn/private:runtime.bzl", "rt")
load("//private:aws_s3_schema.bzl", "S")

def _bucket(
        logical_id,
        *,
        bucket_name = None,                 # BucketName
        versioning_configuration = None,    # VersioningConfiguration
        # ...
        depends_on = None,                  # resource attributes, shared by every resource
        condition = None,
        deletion_policy = None,
        update_replace_policy = None,
        creation_policy = None,
        update_policy = None,
        metadata = None):
    """AWS::S3::Bucket — The AWS::S3::Bucket resource creates an Amazon S3 bucket ...

    Args:
      bucket_name: (string, create-only) A name for the bucket ...
    """
    return rt.resource(S.bucket, logical_id, locals())

def _bucket_versioning_configuration(*, status):
    """AWS::S3::Bucket.VersioningConfiguration ..."""
    return rt.value(S.bucket_versioning_configuration, locals())

s3 = struct(
    bucket = _bucket,
    bucket_policy = _bucket_policy,
)

s3_types = struct(
    bucket = struct(
        versioning_configuration = _bucket_versioning_configuration,
        lifecycle_configuration = _bucket_lifecycle_configuration,
        rule = _bucket_rule,
        # ...
    ),
)
```

**Typing rules (decision 2)**

- Every named or inline object in the schema becomes a constructor. Inline
  anonymous objects get a name built from their property path
  (`bucket.cors_configuration_cors_rule`). Constructors return a tagged
  struct, and a parent only accepts a value carrying the expected type tag.
  **Dicts are rejected for typed properties.**
- **Untyped spec shapes** (`type: object` with no `properties`, JSON-typed
  props such as IAM `PolicyDocument`, `patternProperties` maps) take dicts
  or primitives, passed through verbatim with no key translation. For the
  most common untyped case, the hand-written `cfn.iam` helpers
  (`cfn.iam.policy_document(statements = [cfn.iam.statement(...)])`) give it
  types anyway.
- **Enums** are validated strings. Their values are generated as constants
  where they are valid identifiers:
  `s3_types.bucket.versioning_configuration.enums.status.ENABLED`. Values
  themselves are never snake-cased.
- **Unions** (`oneOf` / `anyOf`) accept any member type.
- **Tags:** properties shaped like `{Key, Value}` accept the shared
  `cfn.tag(key, value)`.
- **Intrinsics** (`cfn.ref`, `cfn.sub`, `x.attr.arn`, ...) are accepted for
  any scalar field. They're typed where we can tell (GetAtt of a list
  attribute is a list), otherwise unchecked.
- **Attributes:** `resource.attr.<snake>` is generated from
  `readOnlyProperties`, so `bucket.attr.arnn` is a load-time error. `resource.ref`
  is `{"Ref": id}`.

**Naming rules (decision 3)**

- Services, resources, property types and properties are all snake_case:
  `AWS::EC2::VPCEndpoint` → `ec2.vpc_endpoint`, `SSESpecification` →
  `sse_specification`.
- The conversion splits on case and digit boundaries, then applies a
  checked-in `naming_overrides.json` for tokens like `IPv6` → `ipv6`, `OAuth`
  → `oauth` and `macOS` → `macos`. The full generated name table is
  golden-tested, so a naming change is visible in review and names stay
  stable across spec versions.
- Starlark keywords get a trailing underscore (`lambda_`, `from_`).
- Codegen **fails** if two properties map to the same snake name, or if a
  property collides with a resource-attribute kwarg (`condition`, `metadata`,
  `depends_on`, ...). These are resolved by adding an override entry, never
  silently.
- The schema tables keep snake→original mappings. Serialization translates
  back to the exact CFN names.
- Logical IDs are user strings and are not transformed.

### 4.4 IR

```
Type   { cfn_name, snake, service, doc, props: {snake: Prop}, attrs: {snake: Attr},
         required, create_only, write_only, primary_identifier }
Prop   { cfn_name, shape: Shape, doc, required }
Shape  = Primitive(string|integer|number|boolean) | Json
       | List(Shape, unique) | Map(Shape) | Ref(TypeName) | Enum([...]) | Union([Shape])
```

`$ref` is resolved and recursive definitions are broken by name (WAFv2 and
Bedrock have them).

## 5. Core runtime (`@rules_cfn//cfn:core.bzl`, hand-written)

- Intrinsics: `cfn.ref`, `cfn.get_att`, `cfn.sub`, `cfn.join`, `cfn.select`,
  `cfn.split`, `cfn.if_`, `cfn.equals`, `cfn.and_`/`or_`/`not_`,
  `cfn.import_value`, `cfn.find_in_map`, `cfn.base64`, `cfn.cidr`,
  `cfn.get_azs`, `cfn.length`, `cfn.to_json_string`.
- Pseudo parameters: `cfn.pseudo.account_id`, `.region`, `.stack_name`,
  `.partition`, ...
- Template sections: `cfn.parameter`, `cfn.condition`, `cfn.mapping`,
  `cfn.output`, `cfn.template(...)`.
- `cfn.template` checks:
  - logical IDs are unique and alphanumeric
  - every `Ref`/`GetAtt` and condition reference resolves
  - the template fits CFN limits (500 resources, 200 outputs/parameters)
  It returns a frozen value with `.to_json()` (deterministic key order).
- `cfn.scope(prefix)` gives libraries composable logical-ID namespacing:
  `scope("Logs").child("Bucket").id("Policy")` → `LogsBucketPolicy`.
- `cfn.asset(label)` creates file or image asset placeholders (§6.3).
- Pure Starlark only, no `native.*`, `Label` or `select`, so `cfnctl` can
  also evaluate the same code with starlark-go later (§9).

## 6. Materialization

```
loading phase                     build (action)                     bazel run
──────────────────────────        ──────────────────────────         ─────────────────────────────
cfn.template(...)                 cfnctl package                     cfnctl plan|diff|deploy|destroy
  └ json.encode ─▶ attr.string ─▶   • snake→CFN key check              • AWS SDK v2, default cred chain
asset labels ─▶ label attrs    ─▶   • hash + deterministic-zip assets  • account/region guard
                                    • strict validation (§7)           • upload assets + template to S3
                                    • canonical JSON                   • change sets, event streaming
                                  ─▶ <name>.template.json
                                  ─▶ <name>.manifest.json
```

### 6.1 `cfn_stack` (macro + rule)

- Attributes: `template` (the Starlark value), `stack_name`, `region`,
  `account`, `parameters`, `tags`, `capabilities` (`cfnctl package` infers
  `CAPABILITY_IAM`/`NAMED_IAM`/`AUTO_EXPAND` from the template, and you can
  override them), `termination_protection`, `role_arn`, `notification_arns`,
  `deps` (other stacks, for ordering).
- Build outputs: the template JSON and a manifest JSON with everything `cfnctl`
  needs at run time: stack config, asset list with hashes, and dependencies.
- Provider: `CfnStackInfo(template, manifest, assets, deps)`.
- Run targets the macro generates: `<name>.plan`, `<name>.diff`,
  `<name>.deploy`, `<name>.destroy`. Extra flags pass through, e.g.
  `bazel run :logging.deploy -- --yes --profile prod`.
- `cfn_app(name, stacks)` deploys several stacks in dependency order. It
  generates the same four run targets, which act on all stacks in order
  (`destroy` goes in reverse).

### 6.2 `cfnctl` (Go, `//cfn/cmd/cfnctl`, built from source with rules_go)

| Command | Behaviour |
|---------|-----------|
| `package` | Build-time action. Validates, hashes assets, writes canonical template + manifest. Hermetic; no AWS calls. |
| `diff` | Fetches the deployed template (`GetTemplate`) and shows a semantic JSON diff (normalized, keyed by logical ID), plus parameter/tag diffs. With `--change-set`, also shows the resource-level change set (Add/Modify/Remove, Replacement: True/Conditional). |
| `plan` | Dry run. Uploads assets, creates a change set (`CREATE` type if the stack is new), prints it with replacement/IAM highlights, then deletes it. Use `--keep` to leave it for console review. Exit code 2 means changes are pending, so CI can gate on it. |
| `deploy` | Like `plan`, then asks for confirmation (`--yes` skips it), executes, streams stack events, waits, and reports failure reasons from events on rollback. "No changes" is success. |
| `destroy` | Confirms, deletes the stack, streams events. Refuses if termination protection is on, unless `--force`. |
| `bootstrap` | Deploys the asset stack (§6.3). The stack is itself written in Starlark against the generated bindings, as dogfooding. |

All commands check `sts:GetCallerIdentity` against the manifest's `account`
and fail on a mismatch. Templates over 51,200 bytes go through S3 (up to the
1 MB limit). AWS calls sit behind an interface, so unit tests use a fake, and
an integration suite can run against LocalStack.

### 6.3 Assets

- `cfn.asset("//svc:lambda_zip")` returns a struct with `.bucket` and `.key`
  placeholders (`{"__cfn_asset__": {...}}`).
- `cfnctl package` hashes each asset (sha256 of the file, or of a
  deterministic zip for a directory). It rewrites the placeholders to
  `{"Fn::Sub": "rules-cfn-assets-${AWS::AccountId}-${AWS::Region}"}` and
  `<hash>.zip`. The template is then **final at build time**; only the upload
  happens at deploy.
- The asset bucket name can be overridden per stack, or the `bootstrap`
  stack can be skipped by pointing at an existing bucket.
- Container images go to a bootstrap ECR repo, tagged with the hash.
- Nested stacks are a `cfn_stack` passed as an asset.

## 7. Validation layers

| Layer | When | Checks |
|-------|------|--------|
| Constructors | Load time (Starlark) | Unknown or missing props, type tags, primitive types, enums, list/map shapes, attribute names |
| `cfn.template` | Load time (Starlark) | Reference resolution, duplicate IDs, limits |
| `cfnctl package` | Build action (Go) | Spec `pattern` (Go `regexp`), `minLength`/`maxLength`, `minimum`/`maximum`, `minItems`/`maxItems`; template size |
| `cfnctl plan` | Run time | CloudFormation's own validation, via the change set |

## 8. Repo reshaping ("salt the earth")

Phase 0 deletes everything CDK-related:

- `cdk/` (rules, pnpm locks, versions), `e2e/workspace/examples/*` and their
  Node/Go CDK deps, `internal_deps.bzl`, `WORKSPACE`
- Node/pnpm/rules_js/rules_nodejs dependencies, CDK Renovate rules and
  `docs/rules.md`

and adds:

```
MODULE.bazel                 # module(name = "rules_cfn"); bzlmod only
.bazelversion                # current Bazel LTS
cfn/
  defs.bzl                   # cfn_stack, cfn_app
  core.bzl                   # cfn.* runtime API
  extensions.bzl             # cfn.spec / cfn.overlay
  private/
    spec_repo.bzl            # repository rule
    normalize_registry.bzl
    normalize_resource_spec.bzl
    naming.bzl
    naming_overrides.json
    codegen.bzl
    runtime.bzl
    stack.bzl
    versions.bzl
  cmd/cfnctl/                # Go app
  internal/                  # Go packages: pkg, diff, changeset, assets, awsapi
  tests/fixtures/, tests/golden/
e2e/                         # bzlmod consumer workspace using a fixture spec + LocalStack
```

The README is rewritten, CI is reworked for bzlmod plus `go test`, and the repo
rename or migration happens later.

## 9. Future: evaluating Starlark in `cfnctl`

Because the bindings and `core.bzl` are pure Starlark, `cfnctl eval file.star`
(starlark-go with a `load()` resolver mapped to `@cfn`) could run the same
libraries outside Bazel for quick iteration or non-Bazel users. This is out
of scope for v1, but it is the reason for the "pure Starlark" constraint in §5.

## 10. Phased plan

| Phase | Deliverable | Exit criteria |
|------:|-------------|---------------|
| 0 | Remove CDK; add `MODULE.bazel`, CI skeleton. Spike: hand-write typed snake bindings for `AWS::S3::Bucket` + `AWS::IAM::Role`; time full-spec decode + codegen in a repository rule | Repo builds empty; API ergonomics agreed; codegen-language fallback decided |
| 1 | `core.bzl` + `runtime.bzl` (intrinsics, template, scope, typed value engine, serialization) | skylib unit tests; golden JSON |
| 2 | Spec repo rule, registry normalization, naming + overrides, codegen | Golden tests on fixtures; the full us-east-1 spec generates, every file loads (build test), no unresolved naming collisions |
| 3 | `cfn_stack` + `cfnctl package` + strict validation | e2e example builds a final template + manifest |
| 4 | `cfnctl diff/plan/deploy/destroy`, `cfn_app` ordering | Unit tests with a fake API; LocalStack integration test; manual run in a sandbox account |
| 5 | Assets, `cfnctl bootstrap` (a Starlark-defined stack) | Lambda from a zip target deploys end-to-end |
| 6 | `cfn.overlay`, `resource_spec` adapter, mirrored snapshots, snapshot tool, Renovate | Private-type overlay fixture; two pinned versions |
| 7 | Stardoc for core + generated service sample, README | — |

## 11. Open questions (rev 2)

1. **Strict validation placement (old Q7):** Bazel's Starlark has no regex, so
   checking spec `pattern`s and min/max at load time means a hand-rolled
   matcher and slower loads. The proposal (§7) does those checks in
   `cfnctl package` with Go `regexp`, so they fail at `bazel build` and not
   at load. Is that acceptable?
2. **Interpretation of decision 4:** this doc assumes Bazel evaluates the
   Starlark and `cfnctl` only materializes the JSON it produces. The
   alternative is that `cfnctl` evaluates the Starlark itself (starlark-go,
   inside an action), which brings regex and file reads but makes libraries
   less like normal `bzl_library` targets. Which did you mean?
3. **Module name:** `rules_cfn`?
4. **`cfnctl` distribution:** build from source with rules_go (v1 proposal),
   or also ship prebuilt release binaries so consumers don't need the Go SDK?
5. **Asset bucket:** own `cfnctl bootstrap` stack (proposed), or require
   users to bring a bucket?
6. **Property-type constructor paths:**
   `s3_types.bucket.versioning_configuration(...)` is proposed. It's
   unambiguous but long. The alternative is flattening to
   `s3_types.bucket_versioning_configuration(...)`. Any preference?
