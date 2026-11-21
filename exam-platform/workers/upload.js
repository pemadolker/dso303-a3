const db = require('./db');

// S3 object keys arrive URL-encoded in event notifications (spaces become '+').
const decodeKey = (k) => decodeURIComponent(k.replace(/\+/g, ' '));

async function handleObject(key, size) {
  const sub = (await db.query(
    `SELECT s.id, s.status, s.filename, s.student_email, a.title, a.tutor_email
       FROM submissions s JOIN assignments a ON a.id = s.assignment_id WHERE s.s3_key = $1`,
    [key]
  )).rows[0];
  if (!sub) {
    console.warn(JSON.stringify({ level: 'warn', msg: 'object without a submission row', key }));
    return;
  }
  if (sub.status === 'received') return; // duplicate event

  // Email first, database second: if we crash in between, the retry sends a second email instead of losing it.
  await db.enqueueEmail({
    to: sub.tutor_email,
    subject: `New submission: ${sub.title}`,
    text: `${sub.student_email} submitted "${sub.filename}" (${(size / 1048576).toFixed(1)} MB) for "${sub.title}".`,
  });
  await db.query(`UPDATE submissions SET status = 'received', size_bytes = $1, received_at = now() WHERE id = $2`, [size, sub.id]);
  console.log(JSON.stringify({ level: 'info', msg: 'submission received', id: sub.id, size }));
}

exports.handler = async (event) => {
  const failures = [];
  for (const rec of event.Records || []) {
    try {
      const body = JSON.parse(rec.body);
      for (const r of body.Records || []) {
        await handleObject(decodeKey(r.s3.object.key), r.s3.object.size);
      }
    } catch (e) {
      console.error(JSON.stringify({ level: 'error', msg: 'upload handling failed', id: rec.messageId, err: e.message }));
      failures.push({ itemIdentifier: rec.messageId });
    }
  }
  return { batchItemFailures: failures };
};
