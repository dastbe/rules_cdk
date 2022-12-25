"""TODO"""

load("@aspect_rules_js//js:defs.bzl", "js_binary")

def cdk_destroy(name, assembly):
    js_binary(
        name = name,
        data = [
            assembly,
            "@cdk//:cdk",
        ],
        entry_point = "@cdk//:cdk_entry_point",
        args = [
            "destroy",
            "--app",
            "$(location {assembly})".format(assembly = assembly),
        ],
    )
