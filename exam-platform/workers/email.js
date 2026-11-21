// Sends one email per SQS message through Amazon SES.
let client;
exports.setClient = (c) => { client = c; };

function getClient() {
  if (!client) {
    const { SESv2Client } = require('@aws-sdk/client-sesv2');
    client = new SESv2Client({});
  }
  return client;
}

exports.handler = async (event) => {
  const { SendEmailCommand } = require('@aws-sdk/client-sesv2');
  const failures = [];
  for (const rec of event.Records || []) {
    try {
      const m = JSON.parse(rec.body);
      await getClient().send(
        new SendEmailCommand({
          FromEmailAddress: process.env.SES_SENDER,
          Destination: { ToAddresses: [m.to] },
          Content: { Simple: { Subject: { Data: m.subject }, Body: { Text: { Data: m.text } } } },
        })
      );
      console.log(JSON.stringify({ level: 'info', msg: 'email sent', to: m.to }));
    } catch (e) {
      console.error(JSON.stringify({ level: 'error', msg: 'send failed', id: rec.messageId, err: e.message }));
      failures.push({ itemIdentifier: rec.messageId }); // only this message is retried
    }
  }
  return { batchItemFailures: failures };
};
