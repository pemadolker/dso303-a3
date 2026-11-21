const db = require('./db');

const ROLE_ORDER = ['admin', 'tutor', 'student'];
let verifier;

function pickRole(groups = []) {
  return ROLE_ORDER.find((r) => groups.includes(r)) || null;
}

function getVerifier() {
  if (!verifier) {
    const { CognitoJwtVerifier } = require('aws-jwt-verify');
    verifier = CognitoJwtVerifier.create({
      userPoolId: process.env.USER_POOL_ID,
      clientId: process.env.CLIENT_ID,
      tokenUse: 'id',
    });
  }
  return verifier;
}

// Remember which users we have already written to the users table, so autosave does not cause a write per request.
const seen = new Map();
async function rememberUser(u) {
  const hit = seen.get(u.sub);
  if (hit && hit.role === u.role && hit.until > Date.now()) return;
  await db.query(
    `INSERT INTO users (sub, email, role, last_seen) VALUES ($1,$2,$3, now())
     ON CONFLICT (sub) DO UPDATE SET email = EXCLUDED.email, role = EXCLUDED.role, last_seen = now()`,
    [u.sub, u.email, u.role]
  );
  seen.set(u.sub, { role: u.role, until: Date.now() + 10 * 60 * 1000 });
}

async function authenticate(req, res, next) {
  try {
    let user;
    if (process.env.AUTH_MODE === 'dev' && process.env.NODE_ENV !== 'production') {
      // Local development and tests only: "sub|email|role"
      const h = req.get('x-dev-user');
      if (!h) return res.status(401).json({ error: 'missing token' });
      const [sub, email, role] = h.split('|');
      user = { sub, email, role };
    } else {
      const m = /^Bearer (.+)$/.exec(req.get('authorization') || '');
      if (!m) return res.status(401).json({ error: 'missing token' });
      const claims = await getVerifier().verify(m[1]);
      user = { sub: claims.sub, email: claims.email, role: pickRole(claims['cognito:groups']) };
    }
    if (!user.role) return res.status(403).json({ error: 'account has no role' });
    await rememberUser(user);
    req.user = user;
    next();
  } catch (e) {
    res.status(401).json({ error: 'invalid token' });
  }
}

const requireRole = (...roles) => (req, res, next) =>
  roles.includes(req.user.role) ? next() : res.status(403).json({ error: 'forbidden' });

module.exports = { authenticate, requireRole, pickRole };
