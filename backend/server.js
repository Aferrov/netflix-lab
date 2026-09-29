'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const net = require('net');

const POD = process.env.HOSTNAME || 'local';
const REDIS_HOST = process.env.REDIS_HOST || 'redis';
const SA = '/var/run/secrets/kubernetes.io/serviceaccount';
const startedAt = Date.now();
let served = 0;
let sick = false;      // /healthz falla -> el kubelet reinicia el contenedor (liveness)
let unready = false;   // /ready falla   -> el pod sale del balanceo sin reiniciarse (readiness)

function redis(args) {
  return new Promise((resolve, reject) => {
    const s = net.connect(6379, REDIS_HOST);
    s.setTimeout(800);
    s.on('connect', () => s.write(`*${args.length}\r\n` + args.map(a => `$${Buffer.byteLength(a)}\r\n${a}\r\n`).join('')));
    s.on('data', d => { s.end(); resolve(d.toString().trim()); });
    s.on('timeout', () => { s.destroy(); reject(new Error('redis timeout')); });
    s.on('error', reject);
  });
}

async function incrVisits() {
  const r = await redis(['INCR', 'visits']);
  if (r[0] !== ':') throw new Error(r);
  return parseInt(r.slice(1), 10);
}

function k8s(method, path) {
  return new Promise((resolve, reject) => {
    let token, ca;
    try {
      token = fs.readFileSync(`${SA}/token`, 'utf8');
      ca = fs.readFileSync(`${SA}/ca.crt`);
    } catch { return reject(new Error('no estoy corriendo dentro de Kubernetes')); }
    const req = https.request({ host: 'kubernetes.default.svc', path, method, ca, headers: { Authorization: `Bearer ${token}` } }, res => {
      let b = '';
      res.on('data', d => (b += d));
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
    });
    req.on('error', reject);
    req.end();
  });
}

const namespace = () => fs.readFileSync(`${SA}/namespace`, 'utf8');

function burnCpu(ms) {
  return new Promise(resolve => {
    const c0 = process.cpuUsage();
    (function slice() {
      const stop = Date.now() + 10;
      while (Date.now() < stop) Math.sqrt(Math.random());
      const u = process.cpuUsage(c0);
      if ((u.user + u.system) / 1000 >= ms) resolve();
      else setImmediate(slice);
    })();
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
  try {
    if (u.pathname === '/healthz') return sick ? send(500, { ok: false }) : send(200, { ok: true });
    if (u.pathname === '/ready') return unready ? send(503, { ready: false }) : send(200, { ready: true });

    served++;

    if (u.pathname === '/api/info') {
      let visits = null;
      try { visits = await incrVisits(); } catch { /* modo degradado: seguimos sin Redis */ }
      return send(200, { pod: POD, served, uptime: Math.round((Date.now() - startedAt) / 1000), visits });
    }

    if (u.pathname === '/api/work') {
      const ms = Math.min(parseInt(u.searchParams.get('ms') || '50', 10), 1000);
      await burnCpu(ms);
      return send(200, { pod: POD, cpuMs: ms });
    }

    if (u.pathname === '/api/cluster') {
      const ns = namespace();
      const [pods, hpa] = await Promise.all([
        k8s('GET', `/api/v1/namespaces/${ns}/pods`),
        k8s('GET', `/apis/autoscaling/v2/namespaces/${ns}/horizontalpodautoscalers/backend`).catch(() => null),
      ]);
      return send(200, {
        pod: POD,
        pods: (pods.items || []).map(p => {
          const cs = p.status.containerStatuses || [];
          const waiting = cs.map(c => c.state && c.state.waiting && c.state.waiting.reason).find(Boolean);
          return {
            name: p.metadata.name,
            app: (p.metadata.labels || {}).app,
            phase: p.metadata.deletionTimestamp ? 'Terminating' : p.status.phase,
            ready: cs.length > 0 && cs.every(c => c.ready),
            reason: waiting && waiting !== 'ContainerCreating' ? waiting : null,
            restarts: cs.reduce((a, c) => a + c.restartCount, 0),
            node: p.spec.nodeName,
            age: Math.round((Date.now() - new Date(p.metadata.creationTimestamp)) / 1000),
          };
        }),
        hpa: hpa && hpa.status ? {
          current: hpa.status.currentReplicas,
          desired: hpa.status.desiredReplicas,
          min: hpa.spec.minReplicas,
          max: hpa.spec.maxReplicas,
          cpu: ((hpa.status.currentMetrics || [])[0] || {}).resource
            ? hpa.status.currentMetrics[0].resource.current.averageUtilization : null,
          target: hpa.spec.metrics[0].resource.target.averageUtilization,
        } : null,
      });
    }

    if (req.method === 'POST' && u.pathname === '/api/pods/delete') {
      const name = u.searchParams.get('name') || '';
      if (!/^[a-z0-9-]+$/.test(name)) return send(400, { error: 'nombre inválido' });
      await k8s('DELETE', `/api/v1/namespaces/${namespace()}/pods/${name}`);
      return send(200, { deleted: name });
    }

    if (req.method === 'POST' && u.pathname === '/api/crash') {
      send(200, { pod: POD, action: 'crash' });
      return setTimeout(() => process.exit(1), 100);
    }
    if (req.method === 'POST' && u.pathname === '/api/sick') { sick = true; return send(200, { pod: POD, action: 'sick' }); }
    if (req.method === 'POST' && u.pathname === '/api/unready') { unready = true; return send(200, { pod: POD, action: 'unready' }); }

    send(404, { error: 'not found' });
  } catch (e) {
    send(500, { error: String(e.message || e) });
  }
});

server.listen(8080, () => console.log(`[${POD}] escuchando en :8080`));

process.on('SIGTERM', () => {
  console.log(`[${POD}] SIGTERM: terminando peticiones en curso`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 10000).unref();
});
