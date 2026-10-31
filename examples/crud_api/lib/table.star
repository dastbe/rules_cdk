"""A DynamoDB table with a single string partition key, plus IAM grants for it."""

load(
    "@cfn//aws/dynamodb:table.star",
    "Table",
    "table",
    "table_attribute_definition",
    "table_key_schema",
    "table_provisioned_throughput",
)
load("@rules_cfn//cfn:core.star", "Scope", "Statement", "join", "statement")

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

SimpleTable = record(table = Table, partition_key = str, resources = list[typing.Any])

def simple_table(
        sc: Scope,
        partition_key: str,
        table_name: str | None = None,
        removal_policy: str = "Retain",
        read_capacity: int = 5,
        write_capacity: int = 5) -> SimpleTable:
    """A provisioned table keyed by one string attribute (CDK's `new Table(...)` defaults).

    Args:
      sc: scope for logical IDs.
      partition_key: name of the string partition key attribute.
      table_name: physical table name, or None to let CloudFormation pick one.
      removal_policy: DeletionPolicy/UpdateReplacePolicy for the table.
      read_capacity: provisioned read capacity units.
      write_capacity: provisioned write capacity units.
    """
    t = table(
        sc.id("Table"),
        table_name = table_name,
        key_schema = [table_key_schema(attribute_name = partition_key, key_type = "HASH")],
        attribute_definitions = [table_attribute_definition(attribute_name = partition_key, attribute_type = "S")],
        provisioned_throughput = table_provisioned_throughput(
            read_capacity_units = read_capacity,
            write_capacity_units = write_capacity,
        ),
        deletion_policy = removal_policy,
        update_replace_policy = removal_policy,
    )
    return SimpleTable(table = t, partition_key = partition_key, resources = [t])

def grant_read_write_data(t: SimpleTable) -> list[Statement]:
    """IAM statements allowing read/write on the table and its indexes (CDK's grantReadWriteData)."""
    return [statement(
        actions = _READ_ACTIONS + _WRITE_ACTIONS,
        resources = [t.table.attr.arn, join("", [t.table.attr.arn, "/index/*"])],
    )]
