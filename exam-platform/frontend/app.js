'use strict';
// No framework on purpose: one file, no build step, and everything user-supplied goes in through textContent.

const $ = (sel) => document.querySelector(sel);
const app = $('#app');
let CFG, session, me;

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) el.append(kid instanceof Node ? kid : document.createTextNode(kid ?? ''));
  return el;
}
const show = (...nodes) => app.replaceChildren(...nodes);
const fmt = (d) => (d ? new Date(d).toLocaleString() : '');
const pad = (n) => String(n).padStart(2, '0');

// ---------------- Cognito (plain HTTPS calls, no SDK) ----------------
async function cognito(target, body) {
  const r = await fetch(`https://cognito-idp.${CFG.region}.amazonaws.com/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-amz-json-1.1', 'X-Amz-Target': `AWSCognitoIdentityProviderService.${target}` },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j.message || j.__type || 'sign-in failed');
  return j;
}
const store = {
  get: () => { try { return JSON.parse(sessionStorage.getItem('sess')); } catch { return null; } },
  set: (v) => { try { v ? sessionStorage.setItem('sess', JSON.stringify(v)) : sessionStorage.removeItem('sess'); } catch { /* private mode */ } },
};
const jwtExp = (t) => JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).exp * 1000;
function adopt(res, prevRefresh) {
  const a = res.AuthenticationResult;
  session = { idToken: a.IdToken, refreshToken: a.RefreshToken || prevRefresh };
  store.set(session);
}
async function token() {
  if (jwtExp(session.idToken) - Date.now() < 120000) {
    adopt(await cognito('InitiateAuth', { AuthFlow: 'REFRESH_TOKEN_AUTH', ClientId: CFG.clientId, AuthParameters: { REFRESH_TOKEN: session.refreshToken } }), session.refreshToken);
  }
  return session.idToken;
}
async function api(method, path, body) {
  const r = await fetch('/api' + path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + (await token()) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error || r.statusText); e.status = r.status; throw e; }
  return j;
}

// ---------------- login ----------------
function loginView(msg = '') {
  const email = h('input', { type: 'email', placeholder: 'email', autocomplete: 'username' });
  const pw = h('input', { type: 'password', placeholder: 'password', autocomplete: 'current-password' });
  const err = h('p', { class: 'err' }, msg);
  const go = async () => {
    try {
      const res = await cognito('InitiateAuth', { AuthFlow: 'USER_PASSWORD_AUTH', ClientId: CFG.clientId, AuthParameters: { USERNAME: email.value.trim(), PASSWORD: pw.value } });
      if (res.ChallengeName === 'NEW_PASSWORD_REQUIRED') return newPasswordView(res.Session, email.value.trim());
      adopt(res); boot();
    } catch (e) { err.textContent = e.message; }
  };
  show(h('div', { class: 'card' }, h('h2', {}, 'Sign in'), email, pw, h('button', { onclick: go }, 'Sign in'), err));
}
function newPasswordView(sess, username) {
  const pw = h('input', { type: 'password', placeholder: 'new password (12+ characters, upper, lower, number)' });
  const err = h('p', { class: 'err' });
  show(h('div', { class: 'card' }, h('h2', {}, 'Choose a new password'), pw,
    h('button', { onclick: async () => {
      try {
        const res = await cognito('RespondToAuthChallenge', { ChallengeName: 'NEW_PASSWORD_REQUIRED', ClientId: CFG.clientId, Session: sess, ChallengeResponses: { USERNAME: username, NEW_PASSWORD: pw.value } });
        adopt(res); boot();
      } catch (e) { err.textContent = e.message; }
    } }, 'Save and continue'), err));
}

// ---------------- student ----------------
async function studentHome() {
  const [exams, assignments] = await Promise.all([api('GET', '/exams'), api('GET', '/assignments')]);
  const now = Date.now();
  show(
    h('div', { class: 'card' }, h('h2', {}, 'Exams'),
      exams.length ? h('table', {}, h('tr', {}, ...['Exam', 'Opens', 'Closes', 'Mins', ''].map((x) => h('th', {}, x))),
        exams.map((e) => {
          const open = now >= new Date(e.opens_at) && now <= new Date(e.closes_at);
          let action;
          if (e.attempt_status && e.attempt_status !== 'in_progress') {
            action = e.results_released ? h('button', { class: 'secondary', onclick: () => resultView(e.id) }, 'View result') : h('span', { class: 'muted' }, 'Submitted');
          } else if (open) action = h('button', { onclick: () => takeExam(e.id) }, e.attempt_id ? 'Resume' : 'Start');
          else action = h('span', { class: 'muted' }, now < new Date(e.opens_at) ? 'Not open yet' : 'Closed');
          return h('tr', {}, h('td', {}, e.title), h('td', {}, fmt(e.opens_at)), h('td', {}, fmt(e.closes_at)), h('td', {}, e.duration_min), h('td', {}, action));
        })) : h('p', { class: 'muted' }, 'No exams yet.')),
    h('div', { class: 'card' }, h('h2', {}, 'Upload an assignment'), uploadForm(assignments)));
}

async function resultView(id) {
  const r = await api('GET', `/exams/${id}/result`);
  show(h('div', { class: 'card' }, h('h2', {}, r.title || 'Result'), h('p', {}, r.released ? `Score: ${r.score} / ${r.max}` : 'Results not released yet.'), h('button', { class: 'secondary', onclick: boot }, 'Back')));
}

async function takeExam(examId) {
  let data;
  try { data = await api('POST', `/exams/${examId}/start`); } catch (e) { alert(e.message); return boot(); }
  const skew = new Date(data.serverTime) - Date.now(); // timer follows the server clock, not the student's laptop
  const deadline = new Date(data.deadlineAt).getTime();
  const key = `answers-${data.attemptId}`;
  let answers = { ...data.answers };
  try { Object.assign(answers, JSON.parse(localStorage.getItem(key) || '{}')); } catch { /* ignore */ }
  const dirty = new Set(Object.keys(answers)); // first save also pushes any locally kept answers
  const status = h('span', { class: 'muted' }, 'Not saved yet');
  const clock = h('span', { class: 'big' }, '');
  let finished = false;

  const set = (qid, v) => {
    answers[qid] = v; dirty.add(String(qid));
    try { localStorage.setItem(key, JSON.stringify(answers)); } catch { /* ignore */ }
  };
  const save = async () => {
    if (finished || !dirty.size) return;
    const batch = [...dirty]; const payload = Object.fromEntries(batch.map((k) => [k, answers[k]]));
    try {
      await api('PUT', `/attempts/${data.attemptId}/answers`, { answers: payload });
      batch.forEach((k) => { if (answers[k] === payload[k]) dirty.delete(k); });
      const t = new Date(); status.textContent = `Saved ${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`; status.className = 'ok';
    } catch (e) {
      status.textContent = e.status === 409 ? 'Time is up or already submitted' : 'Save failed, will retry (answers are kept on this device)'; status.className = 'err';
    }
  };
  const finish = async () => {
    if (finished) return; finished = true; clearInterval(tick); clearInterval(saver);
    try { finished = false; await save(); finished = true; await api('POST', `/attempts/${data.attemptId}/submit`); } catch { /* server sweeper will submit it */ }
    try { localStorage.removeItem(key); } catch { /* ignore */ }
    show(h('div', { class: 'card' }, h('h2', {}, 'Submitted'), h('p', {}, 'Your answers were submitted. You will get an email when results are released.'), h('button', { onclick: boot }, 'Back')));
  };
  const tick = setInterval(() => {
    const left = Math.max(0, Math.round((deadline - (Date.now() + skew)) / 1000));
    clock.textContent = `${pad(Math.floor(left / 60))}:${pad(left % 60)}`;
    if (left === 0) finish();
  }, 500);
  const saver = setInterval(save, 30000); // autosave every 30 seconds

  show(
    h('div', { class: 'timer' }, h('div', {}, h('strong', {}, data.title), ' ', status), clock),
    h('div', { class: 'card' }, data.questions.map((q, i) =>
      h('div', { class: 'q' }, h('div', {}, h('strong', {}, `${i + 1}. `), q.prompt, h('span', { class: 'muted' }, ` (${q.points} pt)`)),
        q.type === 'mcq'
          ? q.options.map((o, idx) => h('label', {}, h('input', { type: 'radio', name: 'q' + q.id, checked: String(answers[q.id]) === String(idx), onchange: () => set(q.id, idx) }), o))
          : h('textarea', { oninput: (e) => set(q.id, e.target.value) }, answers[q.id] ?? ''))),
      h('div', { class: 'row' }, h('button', { class: 'secondary', onclick: save }, 'Save now'), h('button', { onclick: () => confirm('Submit your exam? You cannot change answers afterwards.') && finish() }, 'Submit exam'))));
}

function uploadForm(assignments) {
  const sel = h('select', {}, assignments.map((a) => h('option', { value: a.id }, a.title)));
  const file = h('input', { type: 'file', accept: '.pdf,.zip' });
  const bar = h('progress', { value: 0, max: 100, hidden: true });
  const msg = h('p', {});
  const go = async () => {
    const f = file.files[0];
    if (!f || !sel.value) return;
    const ext = f.name.toLowerCase().match(/\.(pdf|zip)$/);
    if (!ext) { msg.textContent = 'Only PDF or ZIP files'; msg.className = 'err'; return; }
    if (f.size > 50 * 1024 * 1024) { msg.textContent = 'File is larger than 50 MB'; msg.className = 'err'; return; }
    const type = ext[1] === 'pdf' ? 'application/pdf' : 'application/zip';
    try {
      msg.className = 'muted'; msg.textContent = 'Requesting upload slot...';
      const slot = await api('POST', '/uploads/presign', { assignmentId: Number(sel.value), filename: f.name, contentType: type, size: f.size });
      const form = new FormData();
      Object.entries(slot.fields).forEach(([k, v]) => form.append(k, v));
      form.append('file', f); // must be the last field
      bar.hidden = false;
      await new Promise((resolve, reject) => {
        const x = new XMLHttpRequest(); // XHR because fetch has no upload progress events
        x.open('POST', slot.url);
        x.upload.onprogress = (e) => { if (e.lengthComputable) bar.value = (e.loaded / e.total) * 100; };
        x.onload = () => (x.status >= 200 && x.status < 300 ? resolve() : reject(new Error('S3 rejected the file (' + x.status + ')')));
        x.onerror = () => reject(new Error('network error during upload'));
        x.send(form);
      });
      msg.textContent = 'Uploaded. Waiting for confirmation...';
      for (let i = 0; i < 30; i++) { // the worker confirms within a few seconds
        const s = await api('GET', `/submissions/${slot.submissionId}`);
        if (s.status === 'received') { msg.className = 'ok'; msg.textContent = `Received: ${s.filename}. Your tutor has been notified.`; return; }
        await new Promise((r) => setTimeout(r, 2000));
      }
      msg.textContent = 'Upload finished; confirmation is taking longer than usual. Check again shortly.';
    } catch (e) { msg.className = 'err'; msg.textContent = e.message; }
  };
  return h('div', {}, assignments.length ? [sel, file, h('button', { onclick: go }, 'Upload'), bar, msg] : h('p', { class: 'muted' }, 'No assignments open.'));
}

// ---------------- tutor ----------------
async function tutorHome() {
  const [exams, assignments] = await Promise.all([api('GET', '/exams'), api('GET', '/assignments')]);
  show(
    h('div', { class: 'card' }, h('h2', {}, 'My exams'), h('button', { onclick: createExamView }, 'New exam'),
      h('table', {}, exams.map((e) => h('tr', {}, h('td', {}, e.title), h('td', {}, fmt(e.opens_at)), h('td', {}, e.results_released ? 'released' : ''),
        h('td', {}, h('button', { class: 'secondary', onclick: () => attemptsView(e) }, 'Attempts')))))),
    h('div', { class: 'card' }, h('h2', {}, 'Assignments'), assignmentCreate(),
      h('table', {}, assignments.map((a) => h('tr', {}, h('td', {}, a.title), h('td', {}, fmt(a.due_at)), h('td', {}, h('button', { class: 'secondary', onclick: () => submissionsView(a) }, 'Submissions')))))));
}
function assignmentCreate() {
  const t = h('input', { placeholder: 'Assignment title' });
  return h('div', { class: 'row' }, t, h('button', { onclick: async () => { if (t.value) { await api('POST', '/assignments', { title: t.value }); boot(); } } }, 'Create'));
}
function createExamView() {
  const f = { title: h('input', { placeholder: 'Title' }), mins: h('input', { type: 'number', value: 60 }), opens: h('input', { type: 'datetime-local' }), closes: h('input', { type: 'datetime-local' }),
    qs: h('textarea', {}, 'mcq | What does AZ stand for? | Availability Zone ; Access Zone ; Auto Zone | 1 | 2\nshort | Explain Multi-AZ in one sentence. | | | 5') };
  const err = h('p', { class: 'err' });
  show(h('div', { class: 'card' }, h('h2', {}, 'New exam'), 'Title', f.title, 'Duration (minutes)', f.mins, 'Opens', f.opens, 'Closes', f.closes,
    h('p', { class: 'muted' }, 'One question per line: type | question | options separated by ; | correct option number | points'), f.qs,
    h('div', { class: 'row' }, h('button', { class: 'secondary', onclick: boot }, 'Cancel'), h('button', { onclick: async () => {
      try {
        const questions = f.qs.value.split('\n').filter((l) => l.trim()).map((l) => {
          const [type, prompt, opts, correct, pts] = l.split('|').map((s) => s.trim());
          return type === 'mcq' ? { type, prompt, options: opts.split(';').map((s) => s.trim()), correctIndex: Number(correct) - 1, points: Number(pts) || 1 } : { type: 'short', prompt, points: Number(pts) || 1 };
        });
        await api('POST', '/exams', { title: f.title.value, durationMin: Number(f.mins.value), opensAt: new Date(f.opens.value).toISOString(), closesAt: new Date(f.closes.value).toISOString(), questions });
        boot();
      } catch (e) { err.textContent = e.message; }
    } }, 'Create exam')), err));
}
async function attemptsView(exam) {
  const rows = await api('GET', `/exams/${exam.id}/attempts`);
  show(h('div', { class: 'card' }, h('h2', {}, exam.title), h('div', { class: 'row' }, h('button', { class: 'secondary', onclick: boot }, 'Back'),
    h('button', { onclick: async () => { const r = await api('POST', `/exams/${exam.id}/release`); alert(`Released. ${r.emailsQueued} emails queued.`); attemptsView(exam); } }, 'Release results')),
    h('table', {}, h('tr', {}, ...['Student', 'Status', 'MCQ', 'Manual', ''].map((x) => h('th', {}, x))),
      rows.map((r) => h('tr', {}, h('td', {}, r.email || '(unknown)'), h('td', {}, r.status), h('td', {}, r.mcq_score ?? ''), h('td', {}, r.manual_score ?? ''),
        h('td', {}, h('button', { class: 'secondary', onclick: () => gradeView(exam, r.id) }, 'Open')))))));
}
async function gradeView(exam, id) {
  const d = await api('GET', `/attempts/${id}`);
  const score = h('input', { type: 'number', min: 0, value: d.attempt.manual_score ?? '' });
  show(h('div', { class: 'card' }, h('h2', {}, 'Attempt'), d.questions.map((q) => h('div', { class: 'q' }, h('strong', {}, q.prompt), h('div', {}, q.type === 'mcq' ? `Answer: ${q.options[q.answer] ?? '(none)'}  | correct: ${q.options[q.correct_index]}` : (q.answer || '(blank)')))),
    h('p', {}, 'Manual (short answer) score:'), score,
    h('div', { class: 'row' }, h('button', { class: 'secondary', onclick: () => attemptsView(exam) }, 'Back'), h('button', { onclick: async () => { await api('PUT', `/attempts/${id}/manual-score`, { score: Number(score.value) }); attemptsView(exam); } }, 'Save score'))));
}
async function submissionsView(a) {
  const rows = await api('GET', `/assignments/${a.id}/submissions`);
  show(h('div', { class: 'card' }, h('h2', {}, a.title), h('button', { class: 'secondary', onclick: boot }, 'Back'),
    h('table', {}, h('tr', {}, ...['Student', 'File', 'MB', 'Status'].map((x) => h('th', {}, x))),
      rows.map((r) => h('tr', {}, h('td', {}, r.student_email), h('td', {}, r.filename), h('td', {}, r.size_bytes ? (r.size_bytes / 1048576).toFixed(1) : ''), h('td', {}, r.status))))));
}

// ---------------- admin ----------------
async function adminHome() {
  const users = await api('GET', '/admin/users');
  const email = h('input', { type: 'email', placeholder: 'new user email' });
  const role = h('select', {}, ['student', 'tutor', 'admin'].map((r) => h('option', {}, r)));
  const msg = h('p', {});
  const exams = await api('GET', '/exams');
  const eSel = h('select', {}, exams.map((e) => h('option', { value: e.id }, e.title)));
  const o = h('input', { type: 'datetime-local' }), c = h('input', { type: 'datetime-local' });
  show(
    h('div', { class: 'card' }, h('h2', {}, 'Create user'), email, role, h('button', { onclick: async () => {
      try { await api('POST', '/admin/users', { email: email.value, role: role.value }); msg.className = 'ok'; msg.textContent = 'User created. They receive a temporary password by email.'; } catch (e) { msg.className = 'err'; msg.textContent = e.message; }
    } }, 'Create'), msg),
    h('div', { class: 'card' }, h('h2', {}, 'Exam schedule'), eSel, 'Opens', o, 'Closes', c, h('button', { onclick: async () => {
      await api('PATCH', `/exams/${eSel.value}/schedule`, { opensAt: new Date(o.value).toISOString(), closesAt: new Date(c.value).toISOString() }); alert('Schedule updated');
    } }, 'Update')),
    h('div', { class: 'card' }, h('h2', {}, 'Users who have signed in'), h('table', {}, users.map((u) => h('tr', {}, h('td', {}, u.email), h('td', {}, u.role), h('td', {}, fmt(u.last_seen)))))));
}

// ---------------- boot ----------------
async function boot() {
  try {
    if (!session) return loginView();
    me = await api('GET', '/me');
    $('#who').textContent = `${me.email} (${me.role})`;
    $('#logout').hidden = false;
    if (me.role === 'student') await studentHome();
    else if (me.role === 'tutor') await tutorHome();
    else await adminHome();
  } catch (e) {
    session = null; store.set(null); loginView(e.status === 403 ? 'This account has no role yet. Ask an administrator.' : '');
  }
}
$('#logout').addEventListener('click', () => { session = null; store.set(null); $('#who').textContent = ''; $('#logout').hidden = true; loginView(); });

(async () => {
  CFG = await (await fetch('/config.json', { cache: 'no-store' })).json();
  session = store.get();
  boot();
})();
