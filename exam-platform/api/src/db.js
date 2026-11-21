const fs = require('fs');
const { Pool } = require('pg');

let pool;

function buildSsl() {
  if (process.env.DB_SSL === 'disable') return false; // local development only
  // RDS enforces TLS (rds.force_ssl=1). We verify the server against the RDS CA bundle baked into the image.
  const caPath = process.env.RDS_CA_PATH || '/app/rds-ca.pem';
  return { ca: fs.readFileSync(caPath, 'utf8'), rejectUnauthorized: true };
}

function getPool() {
  if (!pool) {
    pool = new Pool({
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT || 5432),
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      ssl: buildSsl(),
      // Small pool on purpose: (tasks x pool size) must stay below the database connection limit.
      max: Number(process.env.DB_POOL_MAX || 5),
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });
    pool.on('error', (e) => console.error(JSON.stringify({ level: 'error', msg: 'idle client error', err: e.message })));
  }
  return pool;
}

// For tests: swap in an in-memory pool.
function setPool(p) {
  pool = p;
}

const query = (text, params) => getPool().query(text, params);

async function tx(fn) {
  const client = await getPool().connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

module.exports = { getPool, setPool, query, tx };
