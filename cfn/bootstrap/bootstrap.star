"""The asset bucket cfnctl uploads Lambda code and large templates to."""

load(
    "@cfn//aws/s3:bucket.star",
    "bucket",
    "bucket_abort_incomplete_multipart_upload",
    "bucket_bucket_encryption",
    "bucket_lifecycle_configuration",
    "bucket_ownership_controls",
    "bucket_ownership_controls_rule",
    "bucket_public_access_block_configuration",
    "bucket_rule",
    "bucket_server_side_encryption_by_default",
    "bucket_server_side_encryption_rule",
)
load("@cfn//aws/s3:bucket_policy.star", "bucket_policy")
load("@rules_cfn//cfn:core.star", "Template", "join", "output", "policy_document", "statement", "sub", "template")

def main() -> Template:
    """The bootstrap stack."""
    b = bucket(
        "AssetBucket",
        # Must match DEFAULT_ASSET_BUCKET in cfnctl/src/package.rs.
        bucket_name = sub("rules-cfn-assets-${AWS::AccountId}-${AWS::Region}"),
        bucket_encryption = bucket_bucket_encryption(
            server_side_encryption_configuration = [bucket_server_side_encryption_rule(
                server_side_encryption_by_default = bucket_server_side_encryption_by_default(sse_algorithm = "AES256"),
            )],
        ),
        public_access_block_configuration = bucket_public_access_block_configuration(
            block_public_acls = True,
            block_public_policy = True,
            ignore_public_acls = True,
            restrict_public_buckets = True,
        ),
        ownership_controls = bucket_ownership_controls(
            rules = [bucket_ownership_controls_rule(object_ownership = "BucketOwnerEnforced")],
        ),
        lifecycle_configuration = bucket_lifecycle_configuration(
            rules = [bucket_rule(
                id = "abort-incomplete-uploads",
                status = "Enabled",
                abort_incomplete_multipart_upload = bucket_abort_incomplete_multipart_upload(days_after_initiation = 1),
            )],
        ),
        # Deployed stacks keep referencing their code here; never delete it with the stack.
        deletion_policy = "Retain",
        update_replace_policy = "Retain",
    )
    p = bucket_policy(
        "AssetBucketPolicy",
        bucket = b.ref,
        policy_document = policy_document([statement(
            sid = "DenyInsecureTransport",
            effect = "Deny",
            principal = "*",
            actions = "s3:*",
            resources = [b.attr.arn, join("", [b.attr.arn, "/*"])],
            condition = {"Bool": {"aws:SecureTransport": "false"}},
        )]),
    )
    return template(
        description = "rules_cfn asset bucket",
        resources = [b, p],
        outputs = [output("AssetBucket", b.ref)],
    )
