const test = require('node:test');
const assert = require('node:assert');
const { newDb } = require('pg-mem');

process.env.AUTH_MODE = 'dev';
process.env.NODE_ENV = 'test';

const db = require('../src/db');
const { SQL } = require('../src/schema');
const { createApp } = require('../src/app');

const calls = { marking: [], emails: [], presign: [], users: [] };
const fakeAws = {
  sendMarking: async (id) => calls.marking.push(id),
  sendEmails: async (m) => calls.emails.push(...m),
  presignedPost: async (o) => { calls.presign.push(o); return { url: 'https://s3.example/bucket', fields: { key: o.key } }; },
  createUser: async (e, r) => calls.users.push([e, r]),
};

let server, base;
const H = (who) => ({ 'content-type': 'application/json', 'x-dev-user': who });
const TUTOR = 't1|tutor@rub.edu.bt|tutor', STUDENT = 's1|s1@rub.edu.bt|student', STUDENT2 = 's2|s2@rub.edu.bt|student', ADMIN = 'a1|admin@rub.edu.bt|admin';
const call = async (method, path, who, body) => {
  const r = await fetch(base + path, { method, headers: who ? H(who) : { 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => null) };
};

test.before(async () => {
  const mem = newDb();
  const { Pool } = mem.adapters.createPg();
  db.setPool(new Pool());
  await db.query(SQL);
  server = createApp(fakeAws).listen(0);
  base = `http://127.0.0.1:${server.address().port}`;
});
test.after(() => server.close());

const future = (m) => new Date(Date.now() + m * 60000).toISOString();
const exam = (extra = {}) => ({
  title: 'Cloud 101', durationMin: 60, opensAt: future(-10), closesAt: future(120),
  questions: [
    { type: 'mcq', prompt: '2+2?', options: ['3', '4', '5'], correctIndex: 1, points: 2 },
    { type: 'short', prompt: 'Define AZ', points: 5 },
  ], ...extra,
});

test('health endpoints and auth', async () => {
  assert.equal((await call('GET', '/health')).status, 200);
  assert.equal((await call('GET', '/api/me')).status, 401);
  assert.equal((await call('GET', '/api/me', STUDENT)).body.role, 'student');
});

test('students cannot create exams, tutors can', async () => {
  assert.equal((await call('POST', '/api/exams', STUDENT, exam())).status, 403);
  assert.equal((await call('POST', '/api/exams', TUTOR, exam({ questions: [] }))).status, 400);
  const r = await call('POST', '/api/exams', TUTOR, exam());
  assert.equal(r.status, 201);
});

test('start -> autosave -> resume -> submit -> release', async () => {
  const id = (await call('POST', '/api/exams', TUTOR, exam())).body.id;

  const s = await call('POST', `/api/exams/${id}/start`, STUDENT);
  assert.equal(s.status, 200);
  assert.equal(s.body.questions.length, 2);
  assert.ok(!JSON.stringify(s.body).includes('correct'), 'answers must never reach the browser');
  const attemptId = s.body.attemptId;
  const [q1, q2] = s.body.questions.map((q) => q.id);

  const save1 = await call('PUT', `/api/attempts/${attemptId}/answers`, STUDENT, { answers: { [q1]: 1 } });
  assert.equal(save1.status, 200);
  await call('PUT', `/api/attempts/${attemptId}/answers`, STUDENT, { answers: { [q1]: 1, [q2]: 'an isolated data centre' } });
  // another student cannot write to this attempt
  assert.equal((await call('PUT', `/api/attempts/${attemptId}/answers`, STUDENT2, { answers: { [q1]: 0 } })).status, 404);

  // refresh the page: same deadline, saved answers come back
  const resume = await call('POST', `/api/exams/${id}/start`, STUDENT);
  assert.equal(resume.body.deadlineAt, s.body.deadlineAt);
  assert.equal(resume.body.answers[q2], 'an isolated data centre');

  const sub = await call('POST', `/api/attempts/${attemptId}/submit`, STUDENT);
  assert.equal(sub.status, 202);
  assert.deepEqual(calls.marking, [attemptId]);
  // submitting twice must not enqueue twice
  await call('POST', `/api/attempts/${attemptId}/submit`, STUDENT);
  assert.equal(calls.marking.length, 1);
  assert.equal((await call('PUT', `/api/attempts/${attemptId}/answers`, STUDENT, { answers: { [q1]: 0 } })).status, 409);
  assert.equal((await call('POST', `/api/exams/${id}/start`, STUDENT)).status, 409);

  // result hidden until release
  assert.equal((await call('GET', `/api/exams/${id}/result`, STUDENT)).body.released, false);
  const rel = await call('POST', `/api/exams/${id}/release`, TUTOR);
  assert.equal(rel.body.emailsQueued, 1);
  assert.equal(calls.emails[0].to, 's1@rub.edu.bt');
  assert.equal((await call('GET', `/api/exams/${id}/result`, STUDENT)).body.released, true);
  // a different tutor cannot release it
  assert.equal((await call('POST', `/api/exams/${id}/release`, 't2|other@rub.edu.bt|tutor')).status, 404);
});

test('exam window is enforced on the server', async () => {
  const later = (await call('POST', '/api/exams', TUTOR, exam({ opensAt: future(30), closesAt: future(90) }))).body.id;
  assert.equal((await call('POST', `/api/exams/${later}/start`, STUDENT)).status, 403);
  const over = (await call('POST', '/api/exams', TUTOR, exam({ opensAt: future(-90), closesAt: future(-30) }))).body.id;
  assert.equal((await call('POST', `/api/exams/${over}/start`, STUDENT)).status, 403);
});

test('upload presign: type, size and assignment checks', async () => {
  const a = (await call('POST', '/api/assignments', TUTOR, { title: 'Assignment 2' })).body.id;
  const ok = { assignmentId: a, filename: 'report.pdf', contentType: 'application/pdf', size: 40 * 1024 * 1024 };
  const r = await call('POST', '/api/uploads/presign', STUDENT, ok);
  assert.equal(r.status, 201);
  assert.match(calls.presign[0].key, new RegExp(`^submissions/${a}/s1/`));
  assert.equal(calls.presign[0].maxBytes, 50 * 1024 * 1024);
  assert.equal((await call('POST', '/api/uploads/presign', STUDENT, { ...ok, size: 51 * 1024 * 1024 })).status, 400);
  assert.equal((await call('POST', '/api/uploads/presign', STUDENT, { ...ok, filename: 'virus.exe' })).status, 400);
  assert.equal((await call('POST', '/api/uploads/presign', STUDENT, { ...ok, contentType: 'text/html' })).status, 400);
  assert.equal((await call('POST', '/api/uploads/presign', STUDENT, { ...ok, assignmentId: 9999 })).status, 404);
  assert.equal((await call('GET', `/api/submissions/${r.body.submissionId}`, STUDENT)).body.status, 'pending');
  assert.equal((await call('GET', `/api/submissions/${r.body.submissionId}`, STUDENT2)).status, 404);
});

test('admin creates users', async () => {
  assert.equal((await call('POST', '/api/admin/users', TUTOR, { email: 'x@rub.edu.bt', role: 'student' })).status, 403);
  assert.equal((await call('POST', '/api/admin/users', ADMIN, { email: 'x@rub.edu.bt', role: 'student' })).status, 201);
  assert.equal((await call('POST', '/api/admin/users', ADMIN, { email: 'bad', role: 'student' })).status, 400);
  assert.deepEqual(calls.users[0], ['x@rub.edu.bt', 'student']);
});

test('security headers', async () => {
  const r = await fetch(base + '/health');
  const csp = r.headers.get('content-security-policy');
  assert.match(csp, /connect-src 'self' https:\/\/\*\.amazonaws\.com/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.ok(r.headers.get('strict-transport-security'));
});
