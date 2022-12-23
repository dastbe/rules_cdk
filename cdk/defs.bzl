"""Rules for generating CDK assemblies and deploying them"""

load("//cdk/private:assembly.bzl", _cdk_assembly = "cdk_assembly")

cdk_assembly = _cdk_assembly
