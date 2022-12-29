"""TODO"""

load(":exec.bzl", "cdk_exec")

def cdk_diff(name, assembly):
    cdk_exec(
        name = name,
        assembly = assembly,
        action = "diff",
    )
