# Vendored CloudFormation registry schemas

A subset of the AWS CloudFormation resource provider schemas, from
`https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip`
(fetched 2026-10-30). This repo's tests and examples use them so they don't
depend on AWS's unpinned "latest" archive, which changes without notice.

Included services: IAM, Lambda, API Gateway, DynamoDB, S3, CloudWatch Logs.

To refresh, download the archive and copy the matching `aws-<service>-*.json`
files over these.
