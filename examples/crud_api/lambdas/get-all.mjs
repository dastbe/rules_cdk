// Ported from aws-samples/aws-cdk-examples (Apache-2.0):
// typescript/api-cors-lambda-crud-dynamodb/lambdas/get-all.ts
// TypeScript annotations removed so it runs on the Lambda Node.js runtime without bundling.

import { DynamoDBDocument } from '@aws-sdk/lib-dynamodb';
import { DynamoDB } from '@aws-sdk/client-dynamodb';

const TABLE_NAME = process.env.TABLE_NAME || '';

const db = DynamoDBDocument.from(new DynamoDB());

export const handler = async () => {

  const params = {
    TableName: TABLE_NAME
  };

  try {
    const response = await db.scan(params);
    return { statusCode: 200, body: JSON.stringify(response.Items) };
  } catch (dbError) {
    return { statusCode: 500, body: JSON.stringify(dbError) };
  }
};
