'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { incrVisits, parseWorkDuration, summarizePod } = require('../../server');
const { startBackend } = require('../helpers');

test('visitas: envía INCR y convierte la respuesta entera de Redis', async () => {
  const visits = await incrVisits(async args => {
    assert.deepEqual(args, ['INCR', 'visits']);
    return ':42';
  });
  assert.equal(visits, 42);
});

test('visitas: rechaza errores, respuestas truncadas y enteros no seguros', async () => {
  for (const reply of ['-ERR unavailable', '+OK', ':', ':12oops', ':9007199254740992']) {
    await assert.rejects(incrVisits(async () => reply));
  }
});

test('visitas: propaga errores de conexión al llamador', async () => {
  await assert.rejects(incrVisits(async () => { throw new Error('connection refused'); }), /connection refused/);
});

test('trabajo CPU: valor predeterminado, cero y límite máximo', () => {
  assert.equal(parseWorkDuration(null), 50);
  assert.equal(parseWorkDuration(''), 50);
  assert.equal(parseWorkDuration('0'), 0);
  assert.equal(parseWorkDuration('80'), 80);
  assert.equal(parseWorkDuration('2000'), 1000);
});

test('trabajo CPU: rechaza valores que podrían dejar el trabajo sin terminar', () => {
  for (const value of ['abc', 'NaN', 'Infinity', '-1', '1.5', '80ms']) {
    assert.throws(() => parseWorkDuration(value), /entero no negativo/);
  }
});

function pod(overrides = {}) {
  return {
    metadata: { name: 'backend-123', labels: { app: 'backend' }, creationTimestamp: new Date().toISOString() },
    spec: { nodeName: 'worker-1' },
    status: { phase: 'Running', ...overrides },
  };
}

test('dashboard: un pod sin contenedores listos no aparece como ready', () => {
  const summary = summarizePod(pod());
  assert.equal(summary.ready, false);
  assert.equal(summary.restarts, 0);
  assert.equal(summary.reason, null);
});

test('dashboard: requiere todos los contenedores listos y suma sus reinicios', () => {
  const summary = summarizePod(pod({ containerStatuses: [
    { ready: true, restartCount: 2 },
    { ready: false, restartCount: 3, state: { waiting: { reason: 'CrashLoopBackOff' } } },
  ] }));
  assert.equal(summary.ready, false);
  assert.equal(summary.restarts, 5);
  assert.equal(summary.reason, 'CrashLoopBackOff');
});

test('dashboard: muestra pods listos y distingue terminación de creación normal', () => {
  assert.equal(summarizePod(pod({ containerStatuses: [{ ready: true, restartCount: 0 }] })).ready, true);
  const deleting = pod({ containerStatuses: [{ ready: false, restartCount: 0, state: { waiting: { reason: 'ContainerCreating' } } }] });
  deleting.metadata.deletionTimestamp = new Date().toISOString();
  const summary = summarizePod(deleting);
  assert.equal(summary.phase, 'Terminating');
  assert.equal(summary.reason, null);
});

test('modo degradado: la API sigue disponible si Redis falla', async t => {
  const request = await startBackend(t, { pod: 'unit-pod', redisCommand: async () => { throw new Error('offline'); } });
  const { status, body } = await request('/api/info');
  assert.equal(status, 200);
  assert.equal(body.visits, null);
  assert.equal(body.pod, 'unit-pod');
});

test('cluster: conserva los pods cuando la consulta del HPA falla', async t => {
  const request = await startBackend(t, {
    getNamespace: () => 'netflix-lab',
    kubernetesRequest: async (method, path) => {
      assert.equal(method, 'GET');
      if (path === '/api/v1/namespaces/netflix-lab/pods') return { items: [pod()] };
      throw new Error('HPA unavailable');
    },
  });
  const { status, body } = await request('/api/cluster');
  assert.equal(status, 200);
  assert.equal(body.pods[0].name, 'backend-123');
  assert.equal(body.hpa, null);
});

test('cluster: expone CPU y límites del HPA recibidos de Kubernetes', async t => {
  const request = await startBackend(t, {
    getNamespace: () => 'netflix-lab',
    kubernetesRequest: async (method, path) => path.endsWith('/pods') ? { items: [] } : {
      spec: { minReplicas: 1, maxReplicas: 2, metrics: [{ resource: { target: { averageUtilization: 50 } } }] },
      status: { currentReplicas: 1, desiredReplicas: 2, currentMetrics: [{ resource: { current: { averageUtilization: 75 } } }] },
    },
  });
  const { body } = await request('/api/cluster');
  assert.deepEqual(body.hpa, { current: 1, desired: 2, min: 1, max: 2, cpu: 75, target: 50 });
});

test('borrado: rechaza nombres inválidos sin llamar a Kubernetes', async t => {
  let calls = 0;
  const request = await startBackend(t, {
    kubernetesRequest: async () => { calls++; },
  });
  for (const name of ['', '../secrets', 'INVALID']) {
    const { status } = await request(`/api/pods/delete?name=${encodeURIComponent(name)}`, { method: 'POST' });
    assert.equal(status, 400);
  }
  assert.equal(calls, 0);
});

test('borrado: limita la petición al namespace configurado', async t => {
  const calls = [];
  const request = await startBackend(t, {
    getNamespace: () => 'netflix-lab',
    kubernetesRequest: async (...args) => { calls.push(args); return {}; },
  });
  const { status, body } = await request('/api/pods/delete?name=backend-123', { method: 'POST' });
  assert.equal(status, 200);
  assert.deepEqual(body, { deleted: 'backend-123' });
  assert.deepEqual(calls, [['DELETE', '/api/v1/namespaces/netflix-lab/pods/backend-123']]);
});
