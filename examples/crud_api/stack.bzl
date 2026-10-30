"""Starlark port of aws-samples/aws-cdk-examples typescript/api-cors-lambda-crud-dynamodb.

The CDK app defines a DynamoDB table, five Node.js Lambda functions with
read/write access to it, and an API Gateway REST API with CORS:

    GET    /items        -> get-all
    POST   /items        -> create
    OPTIONS /items       -> CORS mock
    GET    /items/{id}   -> get-one
    PATCH  /items/{id}   -> update-one
    DELETE /items/{id}   -> delete-one
    OPTIONS /items/{id}  -> CORS mock
"""

load("@rules_cfn//cfn:core.bzl", "cfn")
load("//examples/crud_api/lib:function.bzl", "function")
load("//examples/crud_api/lib:rest_api.bzl", "CORS", "rest_api")
load("//examples/crud_api/lib:table.bzl", "grant_read_write_data", "simple_table")

_HANDLERS = {
    "GetOneItem": "get-one",
    "GetAllItems": "get-all",
    "CreateItem": "create",
    "UpdateItem": "update-one",
    "DeleteItem": "delete-one",
}

def crud_api_template():
    """Returns the cfn.template() for the stack."""
    root = cfn.scope()

    items = simple_table(
        root.child("Items"),
        partition_key = "itemId",
        table_name = "items",
        # NOT recommended for production code: destroying the stack deletes the table and its data.
        removal_policy = "Delete",
    )

    fns = {}
    for name, src in _HANDLERS.items():
        fns[name] = function(
            root.child(name),
            code = cfn.asset("//examples/crud_api/lambdas:" + src),
            handler = src + ".handler",
            runtime = "nodejs24.x",
            environment = {
                "PRIMARY_KEY": items.partition_key,
                "TABLE_NAME": items.table.ref,
            },
            statements = grant_read_write_data(items),
        )

    api = rest_api(root.child("Crud"), name = "Items Service", routes = {
        "items": {
            "GET": fns["GetAllItems"].function,
            "POST": fns["CreateItem"].function,
            "OPTIONS": CORS,
        },
        "items/{id}": {
            "GET": fns["GetOneItem"].function,
            "PATCH": fns["UpdateItem"].function,
            "DELETE": fns["DeleteItem"].function,
            "OPTIONS": CORS,
        },
    })

    return cfn.template(
        description = "CRUD API backed by DynamoDB (port of aws-cdk-examples api-cors-lambda-crud-dynamodb)",
        resources = [
            items.resources,
            [f.resources for f in fns.values()],
            api.resources,
        ],
        outputs = [
            cfn.output("ItemsApiEndpoint", api.url, description = "Base URL of the items API"),
            cfn.output("ItemsTableName", items.table.ref),
        ],
    )
