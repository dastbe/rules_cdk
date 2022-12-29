"""Rule for diffing a cloud assembly using the currently configured AWS credentials"""

load(":exec.bzl", "cdk_exec")

def cdk_diff(name, assembly):
    """Diffs a cloud assembly using the currently configured AWS credentials


    This rule runs the [AWS CDK](https://aws.amazon.com/cdk/) on a given cloud
    assembly and outputs the difference between the assembly and what is deployed.

    Use `bazel run` to run the command.

    Args:
      name: A unique name for this rule.
      assembly: A CDK cloud assembly
    """
    cdk_exec(
        name = name,
        assembly = assembly,
        action = "diff",
    )
