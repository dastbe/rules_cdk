load("@cfn//aws/dynamodb:table.star", "table", "table_key_schema")
load("@cfn//aws/lambda:function.star", "function", "function_code")
load("@cfn//aws/s3:bucket.star", "bucket", "bucket_lifecycle_configuration", "bucket_versioning_configuration")
load("@rules_cfn//cfn:core.star", "template")
KS = [table_key_schema(attribute_name = "id", key_type = "HASH")]
bucket("B", bucket_nmae = "x")
