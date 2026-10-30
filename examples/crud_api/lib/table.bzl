"""A DynamoDB table with a single string partition key, plus IAM grants for it."""

load("@cfn//aws:dynamodb.bzl", "dynamodb", "dynamodb_types")
load("@rules_cfn//cfn:core.bzl", "cfn")

_READ_ACTIONS = [
    "dynamodb:BatchGetItem",
    "dynamodb:ConditionCheckItem",
    "dynamodb:DescribeTable",
    "dynamodb:GetItem",
    "dynamodb:GetRecords",
    "dynamodb:GetShardIterator",
    "dynamodb:Query",
    "dynamodb:Scan",
]

_WRITE_ACTIONS = [
    "dynamodb:BatchWriteItem",
    "dynamodb:DeleteItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
]

def simple_table(sc, partition_key, table_name = None, removal_policy = "Retain", read_capacity = 5, write_capacity = 5):
    """A provisioned table keyed by one string attribute (CDK's `new Table(...)` defaults).

    Args:
      sc: cfn.scope for logical IDs.
      partition_key: name of the string partition key attribute.
      table_name: physical table name, or None to let CloudFormation pick one.
      removal_policy: DeletionPolicy/UpdateReplacePolicy for the table.
      read_capacity: provisioned read capacity units.
      write_capacity: provisioned write capacity units.

    Returns:
      struct(table, resources, partition_key)
    """
    table = dynamodb.table(
        sc.id("Table"),
        table_name = table_name,
        key_schema = [dynamodb_types.table_key_schema(attribute_name = partition_key, key_type = "HASH")],
        attribute_definitions = [dynamodb_types.table_attribute_definition(attribute_name = partition_key, attribute_type = "S")],
        provisioned_throughput = dynamodb_types.table_provisioned_throughput(
            read_capacity_units = read_capacity,
            write_capacity_units = write_capacity,
        ),
        deletion_policy = removal_policy,
        update_replace_policy = removal_policy,
    )
    return struct(table = table, resources = [table], partition_key = partition_key)

def grant_read_write_data(t):
    """IAM statements allowing read/write on the table and its indexes (CDK's grantReadWriteData)."""
    return [cfn.iam.statement(
        actions = _READ_ACTIONS + _WRITE_ACTIONS,
        resources = [t.table.attr.arn, cfn.join("", [t.table.attr.arn, "/index/*"])],
    )]
