"""Rule for bootstrapping CDK infrastructure using the currently configured AWS credentials"""

load("@aspect_rules_js//js:defs.bzl", "js_binary")

def cdk_bootstrap(name):
    """Bootstraps the CDK toolkit using the currently configured AWS credentials

    This rule bootstraps a `CDKToolkit` stack in the currently configured AWS
    account. You can alternatively pass `aws://{{account}}/{{region}}` combinations on
    the command-line.

    Use `bazel run` to run the command.

    Args:
      name: A unique name for this rule.
    """
    js_binary(
        name = name,
        data = [
            "@cdk//:cdk",
        ],
        entry_point = "@cdk//:cdk_entry_point",
        args = [
            "bootstrap",
        ],
    )
