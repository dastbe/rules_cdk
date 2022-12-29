"""TODO"""

load(":exec.bzl", "cdk_exec")

def cdk_destroy(name, assembly):
    cdk_exec(
        name = name,
        assembly = assembly,
        action = "destroy",
    )
