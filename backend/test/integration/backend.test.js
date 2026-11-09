'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { startBackend } = require('../helpers');

// Estas pruebas usan el cliente TCP real y un Redis dedicado. No se omiten si falta Redis.
test('HTTP + Redis: visitas persistentes entre dos instancias del backend', async t => {
  const first = await startBackend(t, { pod: 'backend-a' });
  const second = await startBackend(t, { pod: 'backend-b' });
  const a = await first('/api/info');
  assert.equal(a.status, 200);
  assert.ok(Number.isSafeInteger(a.body.visits), 'Redis debe responder; visits:null no es una integración exitosa');
  const b = await second('/api/info');
  assert.equal(b.status, 200);
  assert.equal(b.body.visits, a.body.visits + 1);
  assert.equal(a.body.pod, 'backend-a');
  assert.equal(b.body.pod, 'backend-b');
  assert.equal(a.body.served, 1);
  assert.equal(b.body.served, 1);
});

test('HTTP + Redis: incrementos concurrentes no pierden visitas', async t => {
  const request = await startBackend(t);
  const baseline = await request('/api/info');
  assert.ok(Number.isSafeInteger(baseline.body.visits), 'Se requiere Redis real');
  const responses = await Promise.all(Array.from({ length: 8 }, () => request('/api/info')));
  for (const response of responses) assert.equal(response.status, 200);
  const visits = responses.map(response => response.body.visits).sort((a, b) => a - b);
  assert.deepEqual(visits, Array.from({ length: 8 }, (_, i) => baseline.body.visits + i + 1));
});

test('HTTP: sondas de salud no inflan el contador de peticiones', async t => {
  const request = await startBackend(t);
  assert.deepEqual(await request('/healthz'), { status: 200, body: { ok: true } });
  assert.deepEqual(await request('/ready'), { status: 200, body: { ready: true } });
  const { body } = await request('/api/info');
  assert.equal(body.served, 1);
  assert.ok(Number.isSafeInteger(body.visits));
  assert.ok(body.uptime >= 0);
});

test('HTTP: readiness y liveness reflejan fallos independientes', async t => {
  const request = await startBackend(t);
  assert.equal((await request('/api/unready', { method: 'POST' })).status, 200);
  assert.deepEqual(await request('/ready'), { status: 503, body: { ready: false } });
  assert.equal((await request('/healthz')).status, 200);
  assert.equal((await request('/api/sick', { method: 'POST' })).status, 200);
  assert.deepEqual(await request('/healthz'), { status: 500, body: { ok: false } });
  // Otro servidor no debe heredar el estado de fallo del anterior.
  const fresh = await startBackend(t);
  assert.equal((await fresh('/ready')).status, 200);
  assert.equal((await fresh('/healthz')).status, 200);
});

test('HTTP: trabajo CPU válido responde y parámetros inválidos devuelven 400', async t => {
  const request = await startBackend(t, { pod: 'worker' });
  assert.deepEqual(await request('/api/work?ms=1'), { status: 200, body: { pod: 'worker', cpuMs: 1 } });
  for (const value of ['abc', '-1', '1.5']) {
    assert.equal((await request(`/api/work?ms=${value}`)).status, 400);
  }
});

test('HTTP: rutas inexistentes y Kubernetes no disponible producen errores JSON', async t => {
  const request = await startBackend(t, { getNamespace: () => { throw new Error('sin Kubernetes'); } });
  assert.deepEqual(await request('/not-found'), { status: 404, body: { error: 'not found' } });
  assert.deepEqual(await request('/api/cluster'), { status: 500, body: { error: 'sin Kubernetes' } });
});
