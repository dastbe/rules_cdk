"""A Lambda function with its execution role (CDK's lambda.Function / NodejsFunction)."""

load("@cfn//aws:iam.bzl", "iam", "iam_types")
load("@cfn//aws:lambda.bzl", "lambda_", "lambda_types")
load("@rules_cfn//cfn:core.bzl", "cfn")

_BASIC_EXECUTION = cfn.join("", [
    "arn:",
    cfn.pseudo.partition,
    ":iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
])

def function(sc, code, handler, runtime, environment = None, statements = [], memory_size = None, timeout = None):
    """A Lambda function whose role can write logs plus whatever `statements` grant.

    Args:
      sc: cfn.scope for logical IDs.
      code: a cfn.asset() holding the function code.
      handler: e.g. "get-one.handler".
      runtime: e.g. "nodejs24.x".
      environment: dict of environment variables.
      statements: extra cfn.iam.statement()s for the execution role.
      memory_size: memory in MB.
      timeout: timeout in seconds.

    Returns:
      struct(function, role, resources)
    """
    role = iam.role(
        sc.id("ServiceRole"),
        assume_role_policy_document = cfn.iam.policy_document([cfn.iam.statement(
            actions = "sts:AssumeRole",
            principal = cfn.iam.service_principal("lambda.amazonaws.com"),
        )]),
        managed_policy_arns = [_BASIC_EXECUTION],
        policies = [iam_types.role_policy(
            policy_name = "inline",
            policy_document = cfn.iam.policy_document(statements),
        )] if statements else None,
    )
    fn = lambda_.function(
        sc.id("Function"),
        code = lambda_types.function_code(s3_bucket = code.bucket, s3_key = code.key),
        handler = handler,
        runtime = runtime,
        role = role.attr.arn,
        environment = lambda_types.function_environment(variables = environment) if environment else None,
        memory_size = memory_size,
        timeout = timeout,
    )
    return struct(function = fn, role = role, resources = [role, fn])
