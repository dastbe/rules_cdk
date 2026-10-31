load("@cfn//aws/dynamodb:table.star", "table", "table_key_schema")
load("@cfn//aws/lambda:function.star", "function", "function_code")
load("@cfn//aws/s3:bucket.star", "bucket", "bucket_lifecycle_configuration", "bucket_versioning_configuration")
load("@rules_cfn//cfn:core.star", "template")
KS = [table_key_schema(attribute_name = "id", key_type = "HASH")]
function("F", role = "arn:aws:iam::1:role/r", handler = "bad handler", runtime = "nodejs24.x", code = function_code(zip_file = "x"))
