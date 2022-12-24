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
| <a id="cdk_assembly-app"></a>app |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="cdk_deploy"></a>

## cdk_deploy

<pre>
cdk_deploy(<a href="#cdk_deploy-name">name</a>, <a href="#cdk_deploy-assembly">assembly</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_deploy-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="cdk_deploy-assembly"></a>assembly |  <p align="center"> - </p>   |  none |


<a id="cdk_diff"></a>

## cdk_diff

<pre>
cdk_diff(<a href="#cdk_diff-name">name</a>, <a href="#cdk_diff-assembly">assembly</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="cdk_diff-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="cdk_diff-assembly"></a>assembly |  <p align="center"> - </p>   |  none |


