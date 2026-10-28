// SPDX-License-Identifier: GPL-3.0-only
// Independently executes the vendored algorithm with genuine Node Buffer/crypto.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const nodeCrypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Sources/Networking/PureSign.js'), 'utf8');
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'Fixtures/SigningOracle.json'), 'utf8'));
for (const fixture of fixtures) {
  const timestamp = fixture.timestamp;
  const context = { Buffer, Uint32Array, crypto: {...nodeCrypto, randomBytes: n => Buffer.alloc(n, 17)},
    Date: {now: () => timestamp}, Math: Object.assign(Object.create(Math), {random: () => 0.123456789}) };
  vm.createContext(context); vm.runInContext(source, context);
  const output = vm.runInContext(`let body=Buffer.from('{"test":"短剧"}');let url='https://example.com/api?q=test';JSON.stringify([xGorgon('q=test',body,${timestamp/1000},42131),helios(${timestamp/1000}),buildMedusa(url,body,${timestamp/1000},{device_id:'1000000000000001',version_name:'7.2.2.32'})]);`, context);
  const actual = nodeCrypto.createHash('sha256').update(output).digest('hex');
  if (actual !== fixture.sha256) throw new Error('Pinned signing oracle mismatch');
}
console.log(`PASS: ${fixtures.length} independently executed Node Buffer/crypto signing vectors.`);
