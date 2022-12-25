"""TODO"""

load("@aspect_rules_js//js:defs.bzl", "js_binary")

def cdk_bootstrap(name):
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
