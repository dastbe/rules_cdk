"""Rules for generating CDK assemblies and deploying them"""

load("//cdk/private:assembly.bzl", _cdk_assembly = "cdk_assembly")
load("//cdk/private:bootstrap.bzl", _cdk_bootstrap = "cdk_bootstrap")
load("//cdk/private:deploy.bzl", _cdk_deploy = "cdk_deploy")
load("//cdk/private:destroy.bzl", _cdk_destroy = "cdk_destroy")
load("//cdk/private:diff.bzl", _cdk_diff = "cdk_diff")

cdk_assembly = _cdk_assembly
cdk_bootstrap = _cdk_bootstrap
cdk_deploy = _cdk_deploy
cdk_destroy = _cdk_destroy
cdk_diff = _cdk_diff
