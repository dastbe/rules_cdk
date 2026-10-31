# rules_cfn

Write CloudFormation in typed Starlark, generated straight from CloudFormation's
own registry schemas, then build, diff and deploy it with Bazel.

> This repository used to hold `rules_cdk`. The CDK rules are gone; see
> [docs/design/starlark-cloudformation.md](docs/design/starlark-cloudformation.md)
> for the design.

```python
# infra/logging.star
load("@cfn//aws/s3:bucket.star", "bucket", "bucket_versioning_configuration")
load("@rules_cfn//cfn:core.star", "Template", "output", "template")

def main() -> Template:
    logs = bucket(
        "Logs",
        versioning_configuration = bucket_versioning_configuration(status = "Enabled"),
        deletion_policy = "Retain",
    )
    return template(resources = [logs], outputs = [output("LogsArn", logs.attr.arn)])
```

```starlark
# infra/BUILD.bazel
load("@rules_cfn//cfn:defs.bzl", "cfn_stack")

cfn_stack(name = "logging", src = "logging.star", region = "us-east-1")
```

```
bazel build //infra:logging            # logging.template.json + logging.manifest.json
bazel run   //infra:logging.diff       # semantic diff against the deployed stack
bazel run   //infra:logging.plan       # dry run: create, show and delete a change set
bazel run   //infra:logging.deploy     # upload assets, create + execute a change set
bazel run   //infra:logging.destroy
```

## Typed, and checked before anything runs

Bindings are ordinary Starlark files, one per resource type, generated from the
schemas. Every property type is a `record`, and every constructor parameter
carries a type annotation. [starlark-rust](https://github.com/facebook/starlark-rust)
typechecks all code statically, including functions nothing calls yet:

```
error: Expected type `None | BucketVersioningConfiguration | Intrinsic` but got `BucketLifecycleConfiguration`
error: Object of type `record` has no attribute `arnn`, did you mean `arn`?
```

What types can't express (enums, patterns, lengths, ranges) is checked when the
value is built:

```
error: fail: bucket_versioning_configuration: status: expected one of ["Enabled", "Suspended"], got "enabled"
```

## Editor support

`cfnctl lsp` is a language server that understands `@repo//pkg:file.star` labels.
It offers completion of keyword arguments, hover docs from the schemas,
go-to-definition into the generated bindings, and typecheck diagnostics as you
type. Point your editor's Starlark LSP command at:

```
bazel run --ui_event_filters=-info --noshow_progress //:lsp
```

where `//:lsp` is a `cfn_lsp(name = "lsp")` target.

## How it works

1. **Specs are remote archives.** The `cfn` module extension fetches registry
   schema archives or local schema directories. `@cfn//:bindings` runs
   `cfnctl gen` to produce `<namespace>/<service>/<resource>.star`. AWS's full
   us-east-1 spec (about 1,875 types) generates in about 2 seconds and
   typechecks in about 3.
2. **Libraries are plain `.star` files** (`cfn_library`). They take a `scope()`
   for logical-ID namespacing and return typed records. See
   [examples/crud_api/lib](examples/crud_api/lib).
3. **`cfn_stack` materializes.** `cfnctl build` evaluates `main()` and packages
   the result:
   - zips assets canonically and stores them under content-addressed S3 keys,
   - infers IAM capabilities,
   - writes the final template and a manifest.
4. **`cfnctl` deploys raw CloudFormation** with change sets. It refuses to run
   against an account or region other than the one the stack is pinned to.

`cfnctl` is a single Rust binary (starlark-rust, starlark_lsp, AWS SDK for
Rust), built with `rules_rust`.

## Setup

```starlark
# MODULE.bazel
bazel_dep(name = "rules_cfn", version = "...")

cfn = use_extension("@rules_cfn//cfn:extensions.bzl", "cfn")
cfn.spec(
    name = "cfn",
    urls = ["https://example.com/mirror/CloudformationSchema-2026-10-30.zip"],
    sha256 = "...",
    # include = ["AWS::S3::*", "AWS::Lambda::*"],
)
# Private or third-party types layered on top:
# cfn.overlay(spec = "cfn", urls = ["..."], sha256 = "...")
use_repo(cfn, "cfn")
```

AWS publishes the schemas only at a "latest" URL
(`https://schema.cloudformation.<region>.amazonaws.com/CloudformationSchema.zip`)
whose bytes change without notice, so mirror a snapshot and pin its sha256.
If you don't declare a spec, you get the small pinned subset vendored in this
repo (IAM, Lambda, API Gateway, DynamoDB, S3, Logs).

Assets are uploaded to `rules-cfn-assets-<account>-<region>`. Create that
bucket once per account and region:

```
bazel run @rules_cfn//cfn/bootstrap:bootstrap.deploy
```

You can also point `cfn_stack(asset_bucket = ...)` at your own bucket.

## Example

[examples/crud_api](examples/crud_api) is a port of the AWS CDK example
[`api-cors-lambda-crud-dynamodb`](https://github.com/aws-samples/aws-cdk-examples/tree/main/typescript/api-cors-lambda-crud-dynamodb).
It has a DynamoDB table, five Lambda functions with read/write grants, and a
REST API with CORS. Its materialized template and manifest are checked in
under [examples/crud_api/golden](examples/crud_api/golden) and diff-tested.

## Development

```
bazel test //...                                # Rust unit tests, error-message tests, golden tests
bazel test //cfn/tests:full_spec_check_test     # generate + typecheck AWS's latest full spec
cd cfnctl && cargo test                         # the Rust crate on its own
```
