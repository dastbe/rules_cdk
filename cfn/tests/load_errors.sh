#!/usr/bin/env bash
# Checks that invalid Starlark CloudFormation fails at load (or build) time with
# a precise message. Load-time fail() can't be caught from inside Bazel, so this
# drives `bazel build` on throwaway packages.
#
#   cfn/tests/load_errors.sh [bazel command]
set -uo pipefail
BAZEL=${1:-bazel}
cd "$(dirname "$0")/../.."
PKG=cfn/tests/_load_errors_tmp
trap 'rm -rf "$PKG"' EXIT

HEADER='load("@cfn//aws:dynamodb.bzl", "dynamodb", "dynamodb_types")
load("@cfn//aws:lambda.bzl", "lambda_", "lambda_types")
load("@cfn//aws:s3.bzl", "s3", "s3_types")
load("@rules_cfn//cfn:core.bzl", "cfn")
load("@rules_cfn//cfn:defs.bzl", "cfn_stack")
KS = [dynamodb_types.table_key_schema(attribute_name = "id", key_type = "HASH")]
'

failures=0
check() {
  local name=$1 body=$2 want=$3
  mkdir -p "$PKG"
  printf '%s\n%s\n' "$HEADER" "$body" > "$PKG/BUILD.bazel"
  out=$($BAZEL build "//$PKG:all" 2>&1)
  if grep -qF -- "$want" <<<"$out"; then
    echo "PASS $name"
  else
    echo "FAIL $name: wanted: $want"
    grep -E "Error|error" <<<"$out" | head -5 | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

check enum \
  's3.bucket("B", versioning_configuration = s3_types.bucket_versioning_configuration(status = "enabled"))' \
  's3_types.bucket_versioning_configuration: status: expected one of ["Enabled", "Suspended"], got "enabled"'
check dict_for_typed \
  's3.bucket("B", versioning_configuration = {"Status": "Enabled"})' \
  'AWS::S3::Bucket "B": versioning_configuration: expected s3_types.bucket_versioning_configuration, got dict'
check unknown_property \
  's3.bucket("B", bucket_nmae = "x")' \
  'unexpected keyword argument'
check missing_required \
  'dynamodb.table("T")' \
  'missing 1 required keyword-only argument: key_schema'
check wrong_primitive \
  'dynamodb.table("T", key_schema = KS, table_name = 5)' \
  'AWS::DynamoDB::Table "T": table_name: expected string, got 5'
check list_element \
  'dynamodb.table("T", key_schema = KS + ["oops"])' \
  'key_schema[1]: expected dynamodb_types.table_key_schema, got "oops"'
check unknown_attribute \
  'b = s3.bucket("B")
x = b.attr.arnn' \
  "has no field or method 'arnn'"
check resource_as_value \
  'b = s3.bucket("B")
s3.bucket("C", bucket_name = b)' \
  'bucket_name: got resource B (AWS::S3::Bucket); use .ref or .attr.<name>'
check dangling_ref \
  'b = s3.bucket("B")
cfn.template(resources = [s3.bucket("C", bucket_name = b.ref)])' \
  'cfn.template: C references B which is not a resource or parameter in this template'
check duplicate_id \
  'cfn.template(resources = [s3.bucket("B"), s3.bucket("B")])' \
  'cfn.template: duplicate logical ID B'
check bad_logical_id \
  's3.bucket("my-bucket")' \
  'logical ID "my-bucket" must be alphanumeric'
check deletion_policy \
  's3.bucket("B", deletion_policy = "Keep")' \
  'DeletionPolicy must be one of'
check pattern_at_build \
  'cfn_stack(name = "s", template = cfn.template(resources = [lambda_.function("F", role = "arn:aws:iam::1:role/r", handler = "bad handler", runtime = "nodejs24.x", code = lambda_types.function_code(zip_file = "x"))]))' \
  'F (AWS::Lambda::Function): Handler: "bad handler" does not match pattern ^[^\s]+$'
check max_length_at_build \
  'cfn_stack(name = "s", template = cfn.template(resources = [lambda_.function("F", role = "arn:aws:iam::1:role/r", handler = "h" * 200, runtime = "nodejs24.x", code = lambda_types.function_code(zip_file = "x"))]))' \
  'is longer than maxLength 128'

exit $failures
