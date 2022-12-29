"""Rule for destroying a CDK assembly using the currently configured AWS credentials"""

load(":exec.bzl", "cdk_exec")

def cdk_destroy(name, assembly):
    """Destroys a cloud assembly using the currently configured AWS credentials


    This rule runs the [AWS CDK](https://aws.amazon.com/cdk/) on a given cloud
    assembly and deletes the assembly.

    Use `bazel run` to run the command.

    Args:
      name: A unique name for this rule.
      assembly: A CDK cloud assembly
    """
    cdk_exec(
        name = name,
        assembly = assembly,
        action = "destroy",
    )
