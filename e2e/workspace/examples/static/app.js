const cdk = require("aws-cdk-lib");
const s3 = require("aws-cdk-lib/aws-s3");
const s3deploy = require("aws-cdk-lib/aws-s3-deployment");

const app = new cdk.App();
const stack = new cdk.Stack(app, "StaticContentStack");

const bucket = new s3.Bucket(stack, 'Bucket', {});
new s3deploy.BucketDeployment(stack, 'Content', {
  sources: [s3deploy.Source.asset(`${process.env.RUNFILES}/e2e/examples/static/content`)],
  destinationBucket: bucket,
});

app.synth();
