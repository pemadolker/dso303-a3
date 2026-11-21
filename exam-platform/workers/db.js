// Shared by the marking and upload workers. The AWS SDK v3 is already included in the Lambda Node runtime.
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

let pool;
let sqsClient;

async function getPool() {
  if (pool) return pool;
  const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
  const sm = new SecretsManagerClient({});
  const out = await sm.send(new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN }));
  const s = JSON.parse(out.SecretString);
  pool = new Pool({
    host: s.host,
    port: s.port,
    database: s.dbname,
    user: s.username,
    password: s.password,
    ssl: { ca: fs.readFileSync(path.join(__dirname, 'rds-ca.pem'), 'utf8'), rejectUnauthorized: true },
    max: 2, // each Lambda container holds at most 2 connections; marking concurrency is capped at 5
    idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 5000,
  });
  return pool;
}

const setPool = (p) => { pool = p; };
const setSqs = (c) => { sqsClient = c; };

async function query(text, params) {
  return (await getPool()).query(text, params);
}

async function enqueueEmail(msg) {
  if (!sqsClient) {
    const { SQSClient } = require('@aws-sdk/client-sqs');
    sqsClient = new SQSClient({});
  }
  const { SendMessageCommand } = require('@aws-sdk/client-sqs');
  await sqsClient.send(new SendMessageCommand({ QueueUrl: process.env.EMAIL_QUEUE_URL, MessageBody: JSON.stringify(msg) }));
}

module.exports = { query, setPool, setSqs, enqueueEmail };
