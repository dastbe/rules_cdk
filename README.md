# rules_cfn

Write CloudFormation in typed Starlark, generated straight from CloudFormation's
own registry schemas, and build, diff and deploy it with Bazel.

> This repository used to hold `rules_cdk`. The CDK rules are gone; see
> [docs/design/starlark-cloudformation.md](docs/design/starlark-cloudformation.md)
> for the design.

```starlark
load("@cfn//aws:s3.bzl", "s3", "s3_types")
load("@rules_cfn//cfn:core.bzl", "cfn")
load("@rules_cfn//cfn:defs.bzl", "cfn_stack")

logs = s3.bucket(
    "Logs",
    versioning_configuration = s3_types.bucket_versioning_configuration(status = "Enabled"),
    deletion_policy = "Retain",
)

cfn_stack(
    name = "logging",
    region = "us-east-1",
    template = cfn.template(
        resources = [logs],
        outputs = [cfn.output("LogsArn", logs.attr.arn)],
    ),
)
```

```
bazel build //infra:logging            # logging.template.json + logging.manifest.json
bazel run   //infra:logging.diff       # semantic diff against the deployed stack
bazel run   //infra:logging.plan       # dry run: create, show and delete a change set
bazel run   //infra:logging.deploy     # upload assets, create + execute a change set
bazel run   //infra:logging.destroy
```

Mistakes fail when the BUILD file loads, with the exact field named:

```
Error in fail: s3_types.bucket_versioning_configuration: status: expected one of ["Enabled", "Suspended"], got "enabled"
```

## How it works

1. **Specs are remote archives.** The `cfn` module extension fetches registry
   schema archives (or local schema directories) and a repository rule
   generates `@cfn//<namespace>:<service>.bzl` for every service. Each file
   exports three structs: `<service>` (resources), `<service>_types` (property
   types) and `<service>_enums`. Everything is snake_case, and constructors are
   typed: a typed property only accepts the matching constructor, not a dict.
   The full us-east-1 spec (about 1,870 resource types, 12,900 constructors)
   generates and loads in about 10 seconds.
2. **Libraries are plain Starlark.** Functions take a `cfn.scope()` for
   logical-ID namespacing and return resources. See
   [examples/crud_api/lib](examples/crud_api/lib).
3. **`cfn_stack` materializes.** Bazel serializes the template. Then
   `cfnctl package` (Go) zips and hashes assets into content-addressed S3
   keys, applies the schema checks Starlark can't (regex `pattern`s, lengths,
   ranges, item counts), infers IAM capabilities, and writes the final
   template plus a manifest.
4. **`cfnctl` deploys raw CloudFormation** with change sets. No CDK, no Node.
   It refuses to run against an account or region other than the one the
   stack is pinned to.

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

```
bazel build //examples/crud_api:stack
```

## Development

```
bazel test //...                      # Go unit tests + golden tests
cfn/tests/load_errors.sh              # load-time error messages
bazel build @cfn_latest//_smoke       # generate + load bindings for AWS's latest full spec
```
