<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Rules for generating CDK assemblies and deploying them

<a id="cdk_assembly"></a>

## cdk_assembly

<pre>
cdk_assembly(<a href="#cdk_assembly-name">name</a>, <a href="#cdk_assembly-app">app</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="cdk_assembly-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="cdk_assembly-app"></a>app |  The CDK application used to generate the cloud assembly   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="cdk_bootstrap"></a>

## cdk_bootstrap

<pre>
cdk_bootstrap(<a href="#cdk_bootstrap-name">name</a>)
</pre>

Bootstraps the CDK toolkit using the currently configured AWS credentials

This rule bootstraps a `CDKToolkit` stack in the currently configured AWS
account. You can alternatively pass `aws://{{account}}/{{region}}` combinations on
the command-line.

Use `bazel run` to run the command.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_bootstrap-name"></a>name |  A unique name for this rule.   |  none |


<a id="cdk_deploy"></a>

## cdk_deploy

<pre>
cdk_deploy(<a href="#cdk_deploy-name">name</a>, <a href="#cdk_deploy-assembly">assembly</a>)
</pre>

Deploys a cloud assembly using the currently configured AWS credentials


This rule runs the [AWS CDK](https://aws.amazon.com/cdk/) on a given cloud
assembly and deploys the assembly.

Use `bazel run` to run the command.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_deploy-name"></a>name |  A unique name for this rule.   |  none |
| <a id="cdk_deploy-assembly"></a>assembly |  A CDK cloud assembly   |  none |


<a id="cdk_destroy"></a>

## cdk_destroy

<pre>
cdk_destroy(<a href="#cdk_destroy-name">name</a>, <a href="#cdk_destroy-assembly">assembly</a>)
</pre>

Destroys a cloud assembly using the currently configured AWS credentials


This rule runs the [AWS CDK](https://aws.amazon.com/cdk/) on a given cloud
assembly and deletes the assembly.

Use `bazel run` to run the command.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_destroy-name"></a>name |  A unique name for this rule.   |  none |
| <a id="cdk_destroy-assembly"></a>assembly |  A CDK cloud assembly   |  none |


<a id="cdk_diff"></a>

## cdk_diff

<pre>
cdk_diff(<a href="#cdk_diff-name">name</a>, <a href="#cdk_diff-assembly">assembly</a>)
</pre>

Diffs a cloud assembly using the currently configured AWS credentials


This rule runs the [AWS CDK](https://aws.amazon.com/cdk/) on a given cloud
assembly and outputs the difference between the assembly and what is deployed.

Use `bazel run` to run the command.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_diff-name"></a>name |  A unique name for this rule.   |  none |
| <a id="cdk_diff-assembly"></a>assembly |  A CDK cloud assembly   |  none |


