const db = require('./db');

const SQL = `
CREATE TABLE IF NOT EXISTS users (
  sub        TEXT PRIMARY KEY,
  email      TEXT NOT NULL,
  role       TEXT NOT NULL,
  last_seen  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS exams (
  id                SERIAL PRIMARY KEY,
  title             TEXT NOT NULL,
  created_by        TEXT NOT NULL,
  duration_min      INTEGER NOT NULL,
  opens_at          TIMESTAMPTZ NOT NULL,
  closes_at         TIMESTAMPTZ NOT NULL,
  results_released  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS questions (
  id             SERIAL PRIMARY KEY,
  exam_id        INTEGER NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
  position       INTEGER NOT NULL,
  type           TEXT NOT NULL,
  prompt         TEXT NOT NULL,
  options        TEXT,
  correct_index  INTEGER,
  points         INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS attempts (
  id            SERIAL PRIMARY KEY,
  exam_id       INTEGER NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
  student_sub   TEXT NOT NULL,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deadline_at   TIMESTAMPTZ NOT NULL,
  submitted_at  TIMESTAMPTZ,
  status        TEXT NOT NULL DEFAULT 'in_progress',
  mcq_score     NUMERIC,
  manual_score  NUMERIC,
  UNIQUE (exam_id, student_sub)
);

CREATE TABLE IF NOT EXISTS answers (
  attempt_id   INTEGER NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  question_id  INTEGER NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  answer       TEXT,
  saved_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (attempt_id, question_id)
);

CREATE TABLE IF NOT EXISTS assignments (
  id           SERIAL PRIMARY KEY,
  title        TEXT NOT NULL,
  tutor_sub    TEXT NOT NULL,
  tutor_email  TEXT NOT NULL,
  due_at       TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS submissions (
  id             TEXT PRIMARY KEY,
  assignment_id  INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  student_sub    TEXT NOT NULL,
  student_email  TEXT NOT NULL,
  s3_key         TEXT NOT NULL UNIQUE,
  filename       TEXT NOT NULL,
  size_bytes     BIGINT,
  status         TEXT NOT NULL DEFAULT 'pending',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  received_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_attempts_exam ON attempts(exam_id);
CREATE INDEX IF NOT EXISTS idx_attempts_open ON attempts(status, deadline_at);
CREATE INDEX IF NOT EXISTS idx_sub_assignment ON submissions(assignment_id);
`;

// Several tasks start at once and all run this. IF NOT EXISTS can still race, so retry a few times.
async function migrate() {
  let lastErr;
  for (let i = 0; i < 5; i++) {
    try {
      await db.query(SQL);
      return;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, 500 * (i + 1)));
    }
  }
  throw lastErr;
}

module.exports = { migrate, SQL };
