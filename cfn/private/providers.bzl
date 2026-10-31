"""Providers shared by the rules_cfn rules."""

CfnLibraryInfo = provider(
    doc = "Starlark (.star) sources and the repository roots their load() labels resolve against.",
    fields = {
        "srcs": "depset of File: .star files (or directories of them)",
        "repos": "depset of (name, exec_path, short_path): repository name in load() labels -> its root in the execroot / runfiles",
    },
)

CfnStackInfo = provider(
    doc = "A packaged CloudFormation stack.",
    fields = {
        "stack_name": "Stack name",
        "template": "File: the final template JSON",
        "manifest": "File: the stack manifest read by cfnctl",
        "assets": "File: directory of packaged assets",
    },
)
