const crypto = require('crypto');
const express = require('express');
const helmet = require('helmet');
const db = require('./db');
const { authenticate, requireRole } = require('./auth');

const MAX_UPLOAD = 50 * 1024 * 1024;
const GRACE_SECONDS = 30; // autosave that arrives just after the deadline (clock skew, slow network) is still accepted
const ALLOWED_TYPES = {
  '.pdf': ['application/pdf'],
  '.zip': ['application/zip', 'application/x-zip-compressed'],
};

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
const isInt = (v) => Number.isInteger(Number(v)) && Number(v) > 0;

function createApp(aws) {
  const app = express();
  app.disable('x-powered-by');
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          // the browser talks to Cognito (sign-in) and S3 (uploads) directly
          connectSrc: ["'self'", 'https://*.amazonaws.com'],
          imgSrc: ["'self'", 'data:'],
          objectSrc: ["'none'"],
          frameAncestors: ["'none'"],
        },
      },
    })
  );
  app.use(express.json({ limit: '256kb' }));

  // Liveness only. It must NOT touch the database, otherwise a DB failover would make the load balancer
  // mark every task unhealthy at the same moment.
  app.get('/health', (req, res) => res.json({ ok: true }));
  app.get('/health/deep', wrap(async (req, res) => {
    await db.query('SELECT 1');
    res.json({ ok: true, db: true });
  }));

  app.use('/api', (req, res, next) => {
    const t0 = Date.now();
    res.on('finish', () =>
      console.log(JSON.stringify({ level: 'info', method: req.method, path: req.path, status: res.statusCode, ms: Date.now() - t0 }))
    );
    next();
  });
  app.use('/api', authenticate);

  app.get('/api/me', (req, res) => res.json(req.user));

  // ---------------- admin ----------------
  app.post('/api/admin/users', requireRole('admin'), wrap(async (req, res) => {
    const { email, role } = req.body || {};
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email || '') || !['student', 'tutor', 'admin'].includes(role)) {
      return res.status(400).json({ error: 'email and role (student|tutor|admin) required' });
    }
    await aws.createUser(email, role);
    res.status(201).json({ email, role });
  }));

  app.get('/api/admin/users', requireRole('admin'), wrap(async (req, res) => {
    const r = await db.query('SELECT sub, email, role, last_seen FROM users ORDER BY email LIMIT 500');
    res.json(r.rows);
  }));

  // ---------------- exams ----------------
  app.post('/api/exams', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const { title, durationMin, opensAt, closesAt, questions } = req.body || {};
    const opens = new Date(opensAt), closes = new Date(closesAt);
    if (!title || !isInt(durationMin) || isNaN(opens) || isNaN(closes) || closes <= opens) {
      return res.status(400).json({ error: 'title, durationMin, opensAt < closesAt required' });
    }
    if (!Array.isArray(questions) || questions.length < 1 || questions.length > 200) {
      return res.status(400).json({ error: '1 to 200 questions required' });
    }
    for (const q of questions) {
      const okMcq = q.type === 'mcq' && Array.isArray(q.options) && q.options.length >= 2 && Number.isInteger(q.correctIndex) && q.correctIndex >= 0 && q.correctIndex < q.options.length;
      if (!q.prompt || !(okMcq || q.type === 'short')) return res.status(400).json({ error: 'bad question: ' + JSON.stringify(q).slice(0, 80) });
    }
    const id = await db.tx(async (c) => {
      const e = await c.query(
        'INSERT INTO exams (title, created_by, duration_min, opens_at, closes_at) VALUES ($1,$2,$3,$4,$5) RETURNING id',
        [title, req.user.sub, Number(durationMin), opens.toISOString(), closes.toISOString()]
      );
      let pos = 1;
      for (const q of questions) {
        await c.query(
          'INSERT INTO questions (exam_id, position, type, prompt, options, correct_index, points) VALUES ($1,$2,$3,$4,$5,$6,$7)',
          [e.rows[0].id, pos++, q.type, q.prompt, q.type === 'mcq' ? JSON.stringify(q.options) : null, q.type === 'mcq' ? q.correctIndex : null, Number(q.points) > 0 ? Number(q.points) : 1]
        );
      }
      return e.rows[0].id;
    });
    res.status(201).json({ id });
  }));

  app.get('/api/exams', wrap(async (req, res) => {
    if (req.user.role === 'student') {
      const r = await db.query(
        `SELECT e.id, e.title, e.duration_min, e.opens_at, e.closes_at, e.results_released,
                a.id AS attempt_id, a.status AS attempt_status
           FROM exams e LEFT JOIN attempts a ON a.exam_id = e.id AND a.student_sub = $1
          ORDER BY e.opens_at DESC LIMIT 100`,
        [req.user.sub]
      );
      return res.json(r.rows);
    }
    const r = req.user.role === 'admin'
      ? await db.query('SELECT * FROM exams ORDER BY opens_at DESC LIMIT 200')
      : await db.query('SELECT * FROM exams WHERE created_by = $1 ORDER BY opens_at DESC LIMIT 200', [req.user.sub]);
    res.json(r.rows);
  }));

  // Admin (or the owning tutor) moves an exam window.
  app.patch('/api/exams/:id/schedule', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const opens = new Date(req.body.opensAt), closes = new Date(req.body.closesAt);
    if (!isInt(req.params.id) || isNaN(opens) || isNaN(closes) || closes <= opens) return res.status(400).json({ error: 'bad dates' });
    const r = await db.query(
      `UPDATE exams SET opens_at=$1, closes_at=$2 WHERE id=$3 AND ($4 = 'admin' OR created_by = $5) RETURNING id`,
      [opens.toISOString(), closes.toISOString(), req.params.id, req.user.role, req.user.sub]
    );
    r.rowCount ? res.json({ ok: true }) : res.status(404).json({ error: 'not found' });
  }));

  // Student opens the exam. The deadline is fixed here, on the server, and never trusted from the browser.
  app.post('/api/exams/:id/start', requireRole('student'), wrap(async (req, res) => {
    if (!isInt(req.params.id)) return res.status(400).json({ error: 'bad id' });
    const ex = (await db.query('SELECT * FROM exams WHERE id=$1', [req.params.id])).rows[0];
    if (!ex) return res.status(404).json({ error: 'exam not found' });
    const now = new Date();
    if (now < new Date(ex.opens_at)) return res.status(403).json({ error: 'exam has not opened yet' });
    if (now > new Date(ex.closes_at)) return res.status(403).json({ error: 'exam window has closed' });

    const deadline = new Date(Math.min(now.getTime() + ex.duration_min * 60000, new Date(ex.closes_at).getTime()));
    await db.query(
      'INSERT INTO attempts (exam_id, student_sub, deadline_at) VALUES ($1,$2,$3) ON CONFLICT (exam_id, student_sub) DO NOTHING',
      [ex.id, req.user.sub, deadline.toISOString()]
    );
    const attempt = (await db.query('SELECT * FROM attempts WHERE exam_id=$1 AND student_sub=$2', [ex.id, req.user.sub])).rows[0];
    if (attempt.status !== 'in_progress') return res.status(409).json({ error: 'already submitted' });

    const qs = (await db.query('SELECT id, position, type, prompt, options, points FROM questions WHERE exam_id=$1 ORDER BY position', [ex.id])).rows;
    const saved = (await db.query('SELECT question_id, answer FROM answers WHERE attempt_id=$1', [attempt.id])).rows;
    res.json({
      attemptId: attempt.id,
      title: ex.title,
      serverTime: now.toISOString(),
      deadlineAt: attempt.deadline_at,
      questions: qs.map((q) => ({ ...q, options: q.options ? JSON.parse(q.options) : null })), // correct_index is never sent
      answers: Object.fromEntries(saved.map((s) => [s.question_id, s.answer])),
    });
  }));

  // Autosave, called every 30 seconds. Idempotent: sending the same answers twice changes nothing.
  app.put('/api/attempts/:id/answers', requireRole('student'), wrap(async (req, res) => {
    if (!isInt(req.params.id)) return res.status(400).json({ error: 'bad id' });
    const a = (await db.query('SELECT * FROM attempts WHERE id=$1 AND student_sub=$2', [req.params.id, req.user.sub])).rows[0];
    if (!a) return res.status(404).json({ error: 'attempt not found' });
    if (a.status !== 'in_progress') return res.status(409).json({ error: 'attempt already submitted' });
    const secondsLeft = (new Date(a.deadline_at).getTime() - Date.now()) / 1000;
    if (secondsLeft < -GRACE_SECONDS) return res.status(409).json({ error: 'time is up' });

    const entries = Object.entries(req.body.answers || {}).filter(([k]) => isInt(k)).slice(0, 200);
    if (entries.length) {
      const valid = new Set((await db.query('SELECT id FROM questions WHERE exam_id=$1', [a.exam_id])).rows.map((r) => r.id));
      const rows = entries.filter(([k]) => valid.has(Number(k)));
      if (rows.length) {
        const vals = [], params = [a.id];
        rows.forEach(([k, v], i) => {
          vals.push(`($1, $${i * 2 + 2}, $${i * 2 + 3}, now())`);
          params.push(Number(k), String(v ?? '').slice(0, 20000));
        });
        await db.query(
          `INSERT INTO answers (attempt_id, question_id, answer, saved_at) VALUES ${vals.join(',')}
           ON CONFLICT (attempt_id, question_id) DO UPDATE SET answer = EXCLUDED.answer, saved_at = now()`,
          params
        );
      }
    }
    res.json({ savedAt: new Date().toISOString(), secondsLeft: Math.max(0, Math.round(secondsLeft)) });
  }));

  app.post('/api/attempts/:id/submit', requireRole('student'), wrap(async (req, res) => {
    if (!isInt(req.params.id)) return res.status(400).json({ error: 'bad id' });
    const r = await db.query(
      `UPDATE attempts SET status='submitted', submitted_at=now()
        WHERE id=$1 AND student_sub=$2 AND status='in_progress' RETURNING id`,
      [req.params.id, req.user.sub]
    );
    if (!r.rowCount) {
      const exists = (await db.query('SELECT status FROM attempts WHERE id=$1 AND student_sub=$2', [req.params.id, req.user.sub])).rows[0];
      return exists ? res.json({ status: exists.status }) : res.status(404).json({ error: 'attempt not found' });
    }
    await aws.sendMarking(Number(req.params.id)); // marking happens asynchronously, off the request path
    res.status(202).json({ status: 'submitted' });
  }));

  app.get('/api/exams/:id/result', requireRole('student'), wrap(async (req, res) => {
    const r = await db.query(
      `SELECT e.title, e.results_released, a.status, a.mcq_score, a.manual_score
         FROM exams e JOIN attempts a ON a.exam_id = e.id AND a.student_sub = $2 WHERE e.id = $1`,
      [req.params.id, req.user.sub]
    );
    const row = r.rows[0];
    if (!row) return res.status(404).json({ error: 'no attempt' });
    if (!row.results_released) return res.json({ released: false });
    const max = (await db.query('SELECT COALESCE(SUM(points),0) AS m FROM questions WHERE exam_id=$1', [req.params.id])).rows[0].m;
    res.json({ released: true, title: row.title, score: Number(row.mcq_score || 0) + Number(row.manual_score || 0), max: Number(max) });
  }));

  // ---------------- tutor: marking and release ----------------
  const ownsExam = async (req, examId) =>
    (await db.query('SELECT id, title FROM exams WHERE id=$1 AND ($2 = \'admin\' OR created_by = $3)', [examId, req.user.role, req.user.sub])).rows[0];

  app.get('/api/exams/:id/attempts', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    if (!isInt(req.params.id) || !(await ownsExam(req, req.params.id))) return res.status(404).json({ error: 'not found' });
    const r = await db.query(
      `SELECT a.id, u.email, a.status, a.submitted_at, a.mcq_score, a.manual_score
         FROM attempts a LEFT JOIN users u ON u.sub = a.student_sub WHERE a.exam_id=$1 ORDER BY u.email`,
      [req.params.id]
    );
    res.json(r.rows);
  }));

  app.get('/api/attempts/:id', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const a = (await db.query('SELECT * FROM attempts WHERE id=$1', [req.params.id])).rows[0];
    if (!a || !(await ownsExam(req, a.exam_id))) return res.status(404).json({ error: 'not found' });
    const r = await db.query(
      `SELECT q.id, q.position, q.type, q.prompt, q.points, q.options, q.correct_index, an.answer
         FROM questions q LEFT JOIN answers an ON an.question_id = q.id AND an.attempt_id = $1
        WHERE q.exam_id = $2 ORDER BY q.position`,
      [a.id, a.exam_id]
    );
    res.json({ attempt: a, questions: r.rows.map((q) => ({ ...q, options: q.options ? JSON.parse(q.options) : null })) });
  }));

  app.put('/api/attempts/:id/manual-score', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const score = Number(req.body.score);
    const a = (await db.query('SELECT exam_id FROM attempts WHERE id=$1', [req.params.id])).rows[0];
    if (!a || !(await ownsExam(req, a.exam_id)) || !(score >= 0)) return res.status(400).json({ error: 'bad request' });
    await db.query('UPDATE attempts SET manual_score=$1 WHERE id=$2', [score, req.params.id]);
    res.json({ ok: true });
  }));

  app.post('/api/exams/:id/release', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const ex = isInt(req.params.id) && (await ownsExam(req, req.params.id));
    if (!ex) return res.status(404).json({ error: 'not found' });
    await db.query('UPDATE exams SET results_released = TRUE WHERE id=$1', [ex.id]);
    const rows = (await db.query(
      `SELECT u.email FROM attempts a JOIN users u ON u.sub = a.student_sub WHERE a.exam_id=$1 AND a.status IN ('marked','submitted')`,
      [ex.id]
    )).rows;
    await aws.sendEmails(rows.map((r) => ({
      to: r.email,
      subject: `Results released: ${ex.title}`,
      text: `Your result for "${ex.title}" is now available. Sign in to the exam platform to view it.`,
    })));
    res.json({ released: true, emailsQueued: rows.length });
  }));

  // ---------------- assignments and file uploads ----------------
  app.post('/api/assignments', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const { title, dueAt } = req.body || {};
    if (!title) return res.status(400).json({ error: 'title required' });
    const r = await db.query('INSERT INTO assignments (title, tutor_sub, tutor_email, due_at) VALUES ($1,$2,$3,$4) RETURNING id', [
      title, req.user.sub, req.user.email, dueAt ? new Date(dueAt).toISOString() : null,
    ]);
    res.status(201).json({ id: r.rows[0].id });
  }));

  app.get('/api/assignments', wrap(async (req, res) => {
    const r = await db.query('SELECT id, title, due_at FROM assignments ORDER BY created_at DESC LIMIT 100');
    res.json(r.rows);
  }));

  // Step 1 of an upload. The 40 MB file itself never touches the API: the browser posts it straight to S3.
  app.post('/api/uploads/presign', requireRole('student'), wrap(async (req, res) => {
    const { assignmentId, filename, contentType, size } = req.body || {};
    const ext = (/\.[a-z0-9]+$/i.exec(filename || '') || [''])[0].toLowerCase();
    if (!ALLOWED_TYPES[ext] || !ALLOWED_TYPES[ext].includes(contentType)) return res.status(400).json({ error: 'only PDF or ZIP files are accepted' });
    if (!(size > 0) || size > MAX_UPLOAD) return res.status(400).json({ error: 'file must be 1 byte to 50 MB' });
    if (!isInt(assignmentId) || !(await db.query('SELECT 1 FROM assignments WHERE id=$1', [assignmentId])).rowCount) return res.status(404).json({ error: 'assignment not found' });

    const id = crypto.randomUUID();
    const safe = filename.replace(/[^A-Za-z0-9._-]/g, '_').slice(-100);
    const key = `submissions/${assignmentId}/${req.user.sub}/${id}-${safe}`;
    await db.query(
      'INSERT INTO submissions (id, assignment_id, student_sub, student_email, s3_key, filename) VALUES ($1,$2,$3,$4,$5,$6)',
      [id, assignmentId, req.user.sub, req.user.email, key, filename]
    );
    const post = await aws.presignedPost({ key, contentType, maxBytes: MAX_UPLOAD });
    res.status(201).json({ submissionId: id, url: post.url, fields: post.fields });
  }));

  // The browser polls this until the upload worker has confirmed the file arrived.
  app.get('/api/submissions/:id', requireRole('student'), wrap(async (req, res) => {
    const r = await db.query('SELECT id, filename, status, size_bytes, received_at FROM submissions WHERE id=$1 AND student_sub=$2', [req.params.id, req.user.sub]);
    r.rows[0] ? res.json(r.rows[0]) : res.status(404).json({ error: 'not found' });
  }));

  app.get('/api/assignments/:id/submissions', requireRole('tutor', 'admin'), wrap(async (req, res) => {
    const r = await db.query(
      `SELECT s.id, s.student_email, s.filename, s.size_bytes, s.status, s.received_at
         FROM submissions s JOIN assignments a ON a.id = s.assignment_id
        WHERE s.assignment_id=$1 AND ($2 = 'admin' OR a.tutor_sub = $3) ORDER BY s.created_at DESC`,
      [req.params.id, req.user.role, req.user.sub]
    );
    res.json(r.rows);
  }));

  app.use((req, res) => res.status(404).json({ error: 'not found' }));
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    console.error(JSON.stringify({ level: 'error', path: req.path, err: err.message }));
    res.status(500).json({ error: 'internal error' }); // details stay in the logs, not in the response
  });
  return app;
}

module.exports = { createApp };
