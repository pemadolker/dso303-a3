const db = require('./db');
const { migrate } = require('./schema');
const { createApp } = require('./app');

async function main() {
  await migrate();
  const app = createApp(require('./aws'));
  const server = app.listen(3000, () => console.log(JSON.stringify({ level: 'info', msg: 'listening', port: 3000 })));

  // The ALB keeps connections open for 60s, so Node must hold them longer or it will drop requests mid-flight.
  server.keepAliveTimeout = 65000;
  server.headersTimeout = 66000;

  // ECS sends SIGTERM when a task is replaced: stop accepting, finish in-flight requests, close the pool.
  const stop = () => {
    server.close(async () => {
      await db.getPool().end().catch(() => {});
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 20000).unref();
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

main().catch((e) => {
  console.error(JSON.stringify({ level: 'fatal', err: e.message }));
  process.exit(1);
});
