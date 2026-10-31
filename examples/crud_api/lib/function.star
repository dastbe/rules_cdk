"""A Lambda function with its execution role (CDK's lambda.Function / NodejsFunction)."""

load("@cfn//aws/iam:role.star", "Role", "role", "role_policy")
load("@cfn//aws/lambda:function.star", "Function", "function_code", "function_environment", lambda_function = "function")
load(
    "@rules_cfn//cfn:core.star",
    "Asset",
    "Scope",
    "Statement",
    "join",
    "policy_document",
    "pseudo",
    "service_principal",
    "statement",
)

_BASIC_EXECUTION = join("", [
    "arn:",
    pseudo.partition,
    ":iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
])

NodeFunction = record(function = Function, role = Role, resources = list[typing.Any])

def function(
        sc: Scope,
        code: Asset,
        handler: str,
        runtime: str,
        environment: dict[str, typing.Any] | None = None,
        statements: list[Statement] = [],
        memory_size: int | None = None,
        timeout: int | None = None) -> NodeFunction:
    """A Lambda function whose role can write logs plus whatever `statements` grant.

    Args:
      sc: scope for logical IDs.
      code: an asset() holding the function code.
      handler: e.g. "get-one.handler".
      runtime: e.g. "nodejs24.x".
      environment: environment variables.
      statements: extra IAM statements for the execution role.
      memory_size: memory in MB.
      timeout: timeout in seconds.
    """
    r = role(
        sc.id("ServiceRole"),
        assume_role_policy_document = policy_document([statement(
            actions = "sts:AssumeRole",
            principal = service_principal("lambda.amazonaws.com"),
        )]),
        managed_policy_arns = [_BASIC_EXECUTION],
        policies = [role_policy(
            policy_name = "inline",
            policy_document = policy_document(statements),
        )] if statements else None,
    )
    fn = lambda_function(
        sc.id("Function"),
        code = function_code(s3_bucket = code.bucket, s3_key = code.key),
        handler = handler,
        runtime = runtime,
        role = r.attr.arn,
        environment = function_environment(variables = environment) if environment else None,
        memory_size = memory_size,
        timeout = timeout,
    )
    return NodeFunction(function = fn, role = r, resources = [r, fn])
