const cdk = require("aws-cdk-lib");
const s3 = require("aws-cdk-lib/aws-s3");

const app = new cdk.App();
const stack = new cdk.Stack(app, "TestStack");
const bucket = new s3.Bucket(stack, "test-bucket", {});

app.synth();
