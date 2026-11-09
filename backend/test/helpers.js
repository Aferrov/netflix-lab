'use strict';
const { once } = require('node:events');
const { createBackend } = require('../server');

async function startBackend(t, options) {
  const server = createBackend(options);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));

  return async (pathname, options) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${pathname}`, {
      ...options,
      signal: AbortSignal.timeout(5000),
    });
    return { status: response.status, body: await response.json() };
  };
}

module.exports = { startBackend };
