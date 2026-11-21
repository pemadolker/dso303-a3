const test = require('node:test');
const assert = require('node:assert');
const { newDb } = require('pg-mem');
const db = require('../db');

// The API owns the schema; reuse it so the workers are tested against the same tables.
const { SQL } = require('../../api/src/schema');
const marking = require('../marking');
const upload = require('../upload');

const sent = [];
db.setSqs({ send: async (cmd) => sent.push(JSON.parse(cmd.input.MessageBody)) });
process.env.EMAIL_QUEUE_URL = 'q';
// the SQS command class is only needed for its constructor; stub the module path used by db.enqueueEmail

test.before(async () => {
  const { Pool } = newDb().adapters.createPg();
  db.setPool(new Pool());
  await db.query(SQL);
  await db.query(`INSERT INTO exams (id,title,created_by,duration_min,opens_at,closes_at) VALUES (1,'E','t',60,now(),now() + interval '1 day')`);
  await db.query(`INSERT INTO questions (id,exam_id,position,type,prompt,options,correct_index,points) VALUES
    (1,1,1,'mcq','a','["x","y"]',1,2),(2,1,2,'mcq','b','["x","y"]',0,3),(3,1,3,'short','c',NULL,NULL,5)`);
  await db.query(`INSERT INTO attempts (id,exam_id,student_sub,deadline_at,status) VALUES
    (1,1,'s1', now() + interval '1 hour','submitted'),
    (2,1,'s2', now() - interval '10 minutes','in_progress'),
    (3,1,'s3', now() + interval '1 hour','in_progress')`);
  await db.query(`INSERT INTO answers (attempt_id,question_id,answer) VALUES (1,1,'1'),(1,2,'1'),(1,3,'text'),(2,1,'1')`);
});

const sqsEvent = (obj) => ({ Records: [{ messageId: 'm1', body: JSON.stringify(obj) }] });

test('marking scores only correct MCQ answers and is repeatable', async () => {
  const out = await marking.handler(sqsEvent({ attemptId: 1 }));
  assert.deepEqual(out.batchItemFailures, []);
  let a = (await db.query('SELECT mcq_score, status FROM attempts WHERE id=1')).rows[0];
  assert.equal(Number(a.mcq_score), 2); // q1 right (2 pts), q2 wrong
  assert.equal(a.status, 'marked');
  await marking.handler(sqsEvent({ attemptId: 1 })); // retry
  a = (await db.query('SELECT mcq_score FROM attempts WHERE id=1')).rows[0];
  assert.equal(Number(a.mcq_score), 2);
});

test('a bad message is reported as a failure, not thrown', async () => {
  const out = await marking.handler({ Records: [{ messageId: 'bad', body: 'not json' }] });
  assert.deepEqual(out.batchItemFailures, [{ itemIdentifier: 'bad' }]);
});

test('sweeper auto-submits only expired attempts', async () => {
  const r = await marking.handler({ source: 'sweep' });
  assert.equal(r.autoSubmitted, 1);
  const rows = (await db.query('SELECT id, status, mcq_score FROM attempts ORDER BY id')).rows;
  assert.equal(rows[1].status, 'marked');
  assert.equal(Number(rows[1].mcq_score), 2);
  assert.equal(rows[2].status, 'in_progress'); // still has time
});

test('upload worker records the file and asks for one tutor email, once', async () => {
  await db.query(`INSERT INTO assignments (id,title,tutor_sub,tutor_email) VALUES (1,'Assignment 2','t','tutor@rub.edu.bt')`);
  await db.query(`INSERT INTO submissions (id,assignment_id,student_sub,student_email,s3_key,filename) VALUES
    ('u1',1,'s1','s1@rub.edu.bt','submissions/1/s1/u1-my_report.pdf','my report.pdf')`);
  const ev = sqsEvent({ Records: [{ s3: { object: { key: 'submissions/1/s1/u1-my_report.pdf', size: 40 * 1048576 } } }] });
  const out = await upload.handler(ev);
  assert.deepEqual(out.batchItemFailures, []);
  const s = (await db.query(`SELECT status, size_bytes FROM submissions WHERE id='u1'`)).rows[0];
  assert.equal(s.status, 'received');
  assert.equal(Number(s.size_bytes), 40 * 1048576);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, 'tutor@rub.edu.bt');
  assert.match(sent[0].text, /40\.0 MB/);
  await upload.handler(ev); // duplicate S3 event
  assert.equal(sent.length, 1);
});

test('email-fn sends one SES email per record and reports only failed ones', async () => {
  const email = require('../email');
  const sentCmds = [];
  email.setClient({ send: async (c) => { if (c.input.Destination.ToAddresses[0] === 'bad@x.bt') throw new Error('rejected'); sentCmds.push(c.input); } });
  process.env.SES_SENDER = 'exams@x.bt';
  const out = await email.handler({ Records: [
    { messageId: 'e1', body: JSON.stringify({ to: 't@x.bt', subject: 'New submission', text: 'hi' }) },
    { messageId: 'e2', body: JSON.stringify({ to: 'bad@x.bt', subject: 'x', text: 'y' }) },
  ] });
  assert.deepEqual(out.batchItemFailures, [{ itemIdentifier: 'e2' }]);
  assert.equal(sentCmds[0].FromEmailAddress, 'exams@x.bt');
  assert.deepEqual(sentCmds[0].Destination.ToAddresses, ['t@x.bt']);
});
