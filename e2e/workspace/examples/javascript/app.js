const cdk = require("aws-cdk-lib");
const appmesh = require("aws-cdk-lib/aws-appmesh");

const app = new cdk.App();
const stack = new cdk.Stack(app, "TestStack");
const bucket = new appmesh.Mesh(stack, "test-mesh");

app.synth();
