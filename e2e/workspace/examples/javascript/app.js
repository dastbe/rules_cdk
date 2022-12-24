const cdk = require("aws-cdk-lib");
const ecs = require("aws-cdk-lib/aws-ecs");

const app = new cdk.App();
const stack = new cdk.Stack(app, "TestStack");
const bucket = new ecs.Cluster(stack, "test-cluster", {});

app.synth();
