package main

import (
	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsappmesh"
)

func main() {
	stackName := "GolangStack"
	meshName := "golang-mesh"

	app := awscdk.NewApp(nil)
	stack := awscdk.NewStack(app, &stackName, &awscdk.StackProps{})
	awsappmesh.NewMesh(stack, &meshName, &awsappmesh.MeshProps{})

	app.Synth(nil)
}
