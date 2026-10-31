"""A REST API built from a declarative route table (CDK's RestApi + addResource/addMethod)."""

load("@cfn//aws/apigateway:deployment.star", "deployment")
load(
    "@cfn//aws/apigateway:method.star",
    "method",
    "method_integration",
    "method_integration_response",
    "method_method_response",
)
load("@cfn//aws/apigateway:resource.star", "resource")
load("@cfn//aws/apigateway:rest_api.star", "RestApi", api_resource = "rest_api")
load("@cfn//aws/apigateway:stage.star", "stage")
load("@cfn//aws/lambda:function.star", "Function")
load("@cfn//aws/lambda:permission.star", "permission")
load("@rules_cfn//cfn:core.star", "Intrinsic", "Scope", "sub")

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
    return method(
        sc.id("Options"),
        rest_api_id = api.ref,
        resource_id = resource_id,
        http_method = "OPTIONS",
        authorization_type = "NONE",
        integration = method_integration(
            type_ = "MOCK",
            passthrough_behavior = "NEVER",
            request_templates = {"application/json": "{\"statusCode\": 200}"},
            integration_responses = [method_integration_response(
                status_code = "200",
                response_parameters = {"method.response.header." + k: v for k, v in _CORS_HEADERS.items()},
            )],
        ),
        method_responses = [method_method_response(
            status_code = "200",
            response_parameters = {"method.response.header." + k: True for k in _CORS_HEADERS},
        )],
    )

def _lambda_method(sc, api, resource_id, verb, path, fn):
    m = method(
        sc.id(_pascal(verb.lower())),
        rest_api_id = api.ref,
        resource_id = resource_id,
        http_method = verb,
        authorization_type = "NONE",
        integration = method_integration(
            type_ = "AWS_PROXY",
            integration_http_method = "POST",
            uri = sub(
                "arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${Fn}/invocations",
                {"Fn": fn.attr.arn},
            ),
        ),
    )

    # Any stage (including the console's test-invoke) may call the function for this route.
    p = permission(
        sc.id(_pascal(verb.lower()) + "Permission"),
        action = "lambda:InvokeFunction",
        function_name = fn.attr.arn,
        principal = "apigateway.amazonaws.com",
        source_arn = sub(
            "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${Api}/*/" + verb + path,
            {"Api": api.ref},
        ),
    )
    return [m, p]

Api = record(api = RestApi, url = Intrinsic, resources = list[typing.Any])

def rest_api(sc: Scope, name: str, routes: dict[str, dict[str, Function | str]], stage_name: str = "prod") -> Api:
    """A REST API with a deployment and stage.

    Args:
      sc: scope for logical IDs.
      name: API name.
      routes: path ("items", "items/{id}") -> HTTP verb -> lambda function resource, or
        CORS for a mock OPTIONS method returning permissive CORS headers. Parent paths
        must come before their children.
      stage_name: name of the stage to deploy.
    """
    api = api_resource(sc.id("RestApi"), name = name)
    resources = [api]
    methods = []
    path_ids = {"": api.attr.root_resource_id}
    for path, verbs in routes.items():
        parts = path.split("/")
        parent = "/".join(parts[:-1])
        if parent not in path_ids:
            fail("rest_api: route {} is listed before its parent {}".format(path, parent))
        rsc = sc.child("".join([_pascal(p) for p in parts]))
        res = resource(
            rsc.id("Resource"),
            rest_api_id = api.ref,
            parent_id = path_ids[parent],
            path_part = parts[-1],
        )
        path_ids[path] = res.ref
        resources.append(res)
        for verb, target in verbs.items():
            if target == CORS:
                m = _cors_method(rsc, api, res.ref)
                methods.append(m)
                resources.append(m)
            else:
                ms = _lambda_method(rsc, api, res.ref, verb, "/" + path, target)
                methods.append(ms[0])
                resources.extend(ms)

    # A deployment snapshots the methods that exist when it is created, so it must come after them.
    d = deployment(
        sc.id("Deployment"),
        rest_api_id = api.ref,
        description = "Automatically created by rules_cfn",
        depends_on = methods,
    )
    s = stage(
        sc.id("Stage"),
        rest_api_id = api.ref,
        deployment_id = d.attr.deployment_id,
        stage_name = stage_name,
    )
    url = sub(
        "https://${Api}.execute-api.${AWS::Region}.${AWS::URLSuffix}/" + stage_name + "/",
        {"Api": api.ref},
    )
    return Api(api = api, url = url, resources = resources + [d, s])
