const db = require('./db');

// Marks the multiple-choice part of one attempt. Safe to run twice: it recomputes the score from the saved answers.
async function markAttempt(attemptId) {
  const r = await db.query(
    `SELECT q.points, q.correct_index, an.answer
       FROM attempts a
       JOIN questions q ON q.exam_id = a.exam_id AND q.type = 'mcq'
       LEFT JOIN answers an ON an.question_id = q.id AND an.attempt_id = a.id
      WHERE a.id = $1`,
    [attemptId]
  );
  const score = r.rows.reduce((sum, q) => sum + (q.answer !== null && String(q.answer) === String(q.correct_index) ? Number(q.points) : 0), 0);
  await db.query(`UPDATE attempts SET mcq_score = $1, status = 'marked' WHERE id = $2 AND status IN ('submitted','marked')`, [score, attemptId]);
  return score;
}

// Runs every 5 minutes: any attempt whose time ran out without the student pressing submit is submitted for them.
async function sweep() {
  const r = await db.query(
    `UPDATE attempts SET status = 'submitted', submitted_at = now()
      WHERE status = 'in_progress' AND deadline_at < now() - interval '60 seconds' RETURNING id`
  );
  for (const row of r.rows) await markAttempt(row.id);
  console.log(JSON.stringify({ level: 'info', msg: 'sweep', autoSubmitted: r.rowCount }));
  return { autoSubmitted: r.rowCount };
}

exports.handler = async (event) => {
  if (event.source === 'sweep') return sweep();

  const failures = [];
  for (const rec of event.Records || []) {
    try {
      const { attemptId } = JSON.parse(rec.body);
      const score = await markAttempt(attemptId);
      console.log(JSON.stringify({ level: 'info', msg: 'marked', attemptId, score }));
    } catch (e) {
      console.error(JSON.stringify({ level: 'error', msg: 'marking failed', id: rec.messageId, err: e.message }));
      failures.push({ itemIdentifier: rec.messageId }); // only this message goes back to the queue
    }
  }
  return { batchItemFailures: failures };
};
exports.markAttempt = markAttempt;
exports.sweep = sweep;
