"""Public rules for CloudFormation written in typed Starlark.

    load("@rules_cfn//cfn:defs.bzl", "cfn_library", "cfn_stack")
"""

load("//cfn/private:library.bzl", _cfn_library = "cfn_library")
load("//cfn/private:providers.bzl", _CfnLibraryInfo = "CfnLibraryInfo", _CfnStackInfo = "CfnStackInfo")
load("//cfn/private:stack.bzl", _cfn_check_test = "cfn_check_test", _cfn_lsp = "cfn_lsp", _cfn_stack = "cfn_stack")

CfnLibraryInfo = _CfnLibraryInfo
CfnStackInfo = _CfnStackInfo
cfn_check_test = _cfn_check_test
cfn_library = _cfn_library
cfn_lsp = _cfn_lsp
cfn_stack = _cfn_stack
