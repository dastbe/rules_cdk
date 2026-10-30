"""Public rules for materializing CloudFormation stacks.

    load("@rules_cfn//cfn:defs.bzl", "cfn_stack")
"""

load("//cfn/private:stack.bzl", _CfnStackInfo = "CfnStackInfo", _cfn_stack = "cfn_stack")

CfnStackInfo = _CfnStackInfo
cfn_stack = _cfn_stack
