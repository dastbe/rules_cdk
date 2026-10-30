"""A REST API built from a declarative route table (CDK's RestApi + addResource/addMethod)."""

load("@cfn//aws:apigateway.bzl", "apigateway", "apigateway_types")
load("@cfn//aws:lambda.bzl", "lambda_")
load("@rules_cfn//cfn:core.bzl", "cfn")

CORS = "cors"

_CORS_HEADERS = {
    "Access-Control-Allow-Headers": "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-User-Agent'",
    "Access-Control-Allow-Origin": "'*'",
    "Access-Control-Allow-Credentials": "'false'",
    "Access-Control-Allow-Methods": "'OPTIONS,GET,PUT,POST,DELETE'",
}

def _pascal(path_part):
    out = []
    for word in path_part.replace("{", " ").replace("}", " ").replace("-", " ").replace("_", " ").split(" "):
        if word:
            out.append(word[0].upper() + word[1:])
    return "".join(out)

def _cors_method(sc, api, resource_id):
    return apigateway.method(
        sc.id("Options"),
        rest_api_id = api.ref,
        resource_id = resource_id,
        http_method = "OPTIONS",
        authorization_type = "NONE",
        integration = apigateway_types.method_integration(
            type = "MOCK",
            passthrough_behavior = "NEVER",
            request_templates = {"application/json": "{\"statusCode\": 200}"},
            integration_responses = [apigateway_types.method_integration_response(
                status_code = "200",
                response_parameters = {"method.response.header." + k: v for k, v in _CORS_HEADERS.items()},
            )],
        ),
        method_responses = [apigateway_types.method_method_response(
            status_code = "200",
            response_parameters = {"method.response.header." + k: True for k in _CORS_HEADERS},
        )],
    )

def _lambda_method(sc, api, resource_id, verb, path, fn):
    method = apigateway.method(
        sc.id(_pascal(verb.lower())),
        rest_api_id = api.ref,
        resource_id = resource_id,
        http_method = verb,
        authorization_type = "NONE",
        integration = apigateway_types.method_integration(
            type = "AWS_PROXY",
            integration_http_method = "POST",
            uri = cfn.sub(
                "arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${Fn}/invocations",
                {"Fn": fn.attr.arn},
            ),
        ),
    )

    # Any stage (including the console's test-invoke) may call the function for this route.
    permission = lambda_.permission(
        sc.id(_pascal(verb.lower()) + "Permission"),
        action = "lambda:InvokeFunction",
        function_name = fn.attr.arn,
        principal = "apigateway.amazonaws.com",
        source_arn = cfn.sub(
            "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${Api}/*/" + verb + path,
            {"Api": api.ref},
        ),
    )
    return [method, permission]

def rest_api(sc, name, routes, stage_name = "prod"):
    """A REST API with a deployment and stage.

    Args:
      sc: cfn.scope for logical IDs.
      name: API name.
      routes: dict of path ("items", "items/{id}") -> dict of HTTP verb -> lambda_.function
        resource, or CORS for a mock OPTIONS method returning permissive CORS headers.
        Parent paths must appear before their children.
      stage_name: name of the stage to deploy.

    Returns:
      struct(api, url, resources)
    """
    api = apigateway.rest_api(sc.id("RestApi"), name = name)
    resources = [api]
    methods = []
    path_ids = {"": api.attr.root_resource_id}
    for path, verbs in routes.items():
        parts = path.split("/")
        parent = "/".join(parts[:-1])
        if parent not in path_ids:
            fail("rest_api: route {} is listed before its parent {}".format(path, parent))
        rsc = sc.child("".join([_pascal(p) for p in parts]))
        resource = apigateway.resource(
            rsc.id("Resource"),
            rest_api_id = api.ref,
            parent_id = path_ids[parent],
            path_part = parts[-1],
        )
        path_ids[path] = resource.ref
        resources.append(resource)
        for verb, target in verbs.items():
            if target == CORS:
                m = _cors_method(rsc, api, resource.ref)
                methods.append(m)
                resources.append(m)
            else:
                ms = _lambda_method(rsc, api, resource.ref, verb, "/" + path, target)
                methods.append(ms[0])
                resources.extend(ms)

    # A deployment snapshots the methods that exist when it is created, so it must come after them.
    deployment = apigateway.deployment(
        sc.id("Deployment"),
        rest_api_id = api.ref,
        description = "Automatically created by rules_cfn",
        depends_on = methods,
    )
    stage = apigateway.stage(
        sc.id("Stage"),
        rest_api_id = api.ref,
        deployment_id = deployment.attr.deployment_id,
        stage_name = stage_name,
    )
    url = cfn.sub(
        "https://${Api}.execute-api.${AWS::Region}.${AWS::URLSuffix}/" + stage_name + "/",
        {"Api": api.ref},
    )
    return struct(api = api, url = url, resources = resources + [deployment, stage])
