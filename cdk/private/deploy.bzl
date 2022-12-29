"""TODO"""

load(":exec.bzl", "cdk_exec")

def cdk_deploy(name, assembly):
    cdk_exec(
        name = name,
        assembly = assembly,
        action = "deploy",
    )
