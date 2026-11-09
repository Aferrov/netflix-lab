'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const suite = process.argv[2];
if (!['unit', 'integration'].includes(suite)) {
  console.error('Uso: node scripts/test.js unit|integration');
  process.exit(2);
}

const root = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(root, 'reports'), { recursive: true });
// El proceso de Node genera los reportes y conserva su código de salida.
const result = spawnSync(process.execPath, [
  '--test',
  '--experimental-test-coverage',
  '--test-reporter=spec', '--test-reporter-destination=stdout',
  '--test-reporter=junit', `--test-reporter-destination=reports/${suite}.xml`,
  `test/${suite}`,
], { cwd: root, stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8', maxBuffer: 10 * 1024 * 1024, env: process.env });

// Guardar también la salida legible conserva la tabla de cobertura nativa.
const output = result.stdout || '';
fs.writeFileSync(path.join(root, 'reports', `${suite}.txt`), output);
process.stdout.write(output);

if (result.error) console.error(result.error);
process.exit(result.status ?? 1);
