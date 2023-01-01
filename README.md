# Bazel rules for CDK

This ruleset makes it straightforward to run CDK applications to generate Cloud
assemblies and deploy them with built-in CDK targets.

Features:

- Supports all CDK languages (Javascript, Java, Go, .NET)
- diff, deploy, and destroy CDK applications all from within bazel

[rules_cdk_example](https://github.com/dastbe/rules_cdk_example) is sample
application that shows how to set up a CDK application in bazel and deploy
across multiple languages and application types.

## Installation

From the release you wish to use:
<https://github.com/dastbe/cdk_rules/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.
