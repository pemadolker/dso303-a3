// Thin wrappers so tests can replace them.
const { SQSClient, SendMessageCommand, SendMessageBatchCommand } = require('@aws-sdk/client-sqs');
const { S3Client } = require('@aws-sdk/client-s3');
const { createPresignedPost } = require('@aws-sdk/s3-presigned-post');
const {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminAddUserToGroupCommand,
} = require('@aws-sdk/client-cognito-identity-provider');

const region = process.env.AWS_REGION || 'ap-south-1';
const sqs = new SQSClient({ region });
const s3 = new S3Client({ region });
const cognito = new CognitoIdentityProviderClient({ region });

module.exports = {
  async sendMarking(attemptId) {
    await sqs.send(new SendMessageCommand({ QueueUrl: process.env.MARKING_QUEUE_URL, MessageBody: JSON.stringify({ attemptId }) }));
  },
  async sendEmails(messages) {
    for (let i = 0; i < messages.length; i += 10) {
      const chunk = messages.slice(i, i + 10);
      await sqs.send(
        new SendMessageBatchCommand({
          QueueUrl: process.env.EMAIL_QUEUE_URL,
          Entries: chunk.map((m, j) => ({ Id: String(j), MessageBody: JSON.stringify(m) })),
        })
      );
    }
  },
  presignedPost({ key, contentType, maxBytes }) {
    return createPresignedPost(s3, {
      Bucket: process.env.UPLOAD_BUCKET,
      Key: key,
      Expires: 300,
      Fields: { 'Content-Type': contentType },
      Conditions: [
        ['content-length-range', 1, maxBytes], // S3 itself rejects anything larger than 50 MB
        ['eq', '$Content-Type', contentType],
      ],
    });
  },
  async createUser(email, role) {
    await cognito.send(
      new AdminCreateUserCommand({
        UserPoolId: process.env.USER_POOL_ID,
        Username: email,
        UserAttributes: [
          { Name: 'email', Value: email },
          { Name: 'email_verified', Value: 'true' },
        ],
        DesiredDeliveryMediums: ['EMAIL'],
      })
    );
    await cognito.send(new AdminAddUserToGroupCommand({ UserPoolId: process.env.USER_POOL_ID, Username: email, GroupName: role }));
  },
};
