#!/usr/bin/env node
// Intent: INF-259 / captain's “Build the safe rule”; list only until review.
// Real X.509 decoding and CLI/JWT paths, disposable keys, no Apple or keychains.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { run, decision, archiveSigners } = require('../.github/scripts/prune_asc_development_certs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ew-cert-rule-'));
const key = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
function certificate(cn, type = 'DEVELOPMENT') {
  const pem = execFileSync('openssl', ['req', '-new', '-x509', '-key', '/dev/stdin', '-subj', `/CN=${cn}`, '-days', '365'], { input: key, stdio: ['pipe', 'pipe', 'pipe'] });
  const cert = new crypto.X509Certificate(pem);
  return { id: cert.serialNumber, attributes: { certificateType: type, certificateContent: cert.raw.toString('base64') } };
}
function fingerprint(record) { return new crypto.X509Certificate(Buffer.from(record.attributes.certificateContent, 'base64')).fingerprint.replace(/:/g, ''); }
async function test() {
  const signer = certificate('Apple Development: Created via API (TESTKEY)');
  const old = certificate('Apple Development: Created via API (TESTKEY)');
  const personal = certificate('Apple Development: Test Parent');
  personal.attributes.name = 'Apple Development: Created via API (TESTKEY)'; // API names cannot override the signed subject.
  const distribution = certificate('Apple Distribution: Test Parent', 'DISTRIBUTION');
  const start = Date.parse(new crypto.X509Certificate(Buffer.from(old.attributes.certificateContent, 'base64')).validFrom);
  const day = 86400000;
  const now = start + day + 1000;
  const hash = fingerprint(signer);
  // Realistic xcodebuild command layout, including its absolute codesign path.
  const command = `/usr/bin/codesign --force --sign ${hash} --entitlements /tmp/App.xcent /tmp/App.app`;
  const log = `${command}\n** ARCHIVE SUCCEEDED **\n`;
  const signers = archiveSigners(log);
  assert.equal(decision(old, signers, now).reason, 'would-revoke');
  assert.equal(decision(signer, signers, now).reason, 'archive-signer');
  assert.equal(decision(personal, signers, now).reason, 'not-api-created');
  assert.equal(decision(distribution, signers, now).reason, 'not-development');
  assert.equal(decision(old, signers, start + day - 1000).reason, 'not-over-24-hours');
  assert.equal(decision(old, signers, start + day).reason, 'not-over-24-hours');
  assert.equal(decision(old, signers, start - 1).reason, 'not-over-24-hours');
  assert.equal(decision(old, signers, NaN).reason, 'not-over-24-hours');
  assert.equal(decision({ id: 'bad', attributes: { certificateType: 'DEVELOPMENT', certificateContent: 'bad' } }, signers, now).reason, 'unreadable-certificate');
  assert.equal(decision({ ...old, id: '' }, signers, now).reason, 'missing-id');
  assert.equal(archiveSigners(command), null);
  assert.equal(archiveSigners('** ARCHIVE SUCCEEDED **'), null);
  assert.equal(archiveSigners(`${log}/usr/bin/codesign --sign - /tmp/Other.app`), null);
  const multi = archiveSigners(`${log}/usr/bin/codesign --sign '${fingerprint(old).toLowerCase()}' /tmp/Other.app`);
  assert.equal(decision(old, multi, now).reason, 'archive-signer');
  const archive = path.join(root, 'archive.log');
  fs.writeFileSync(archive, log);
  const env = { RUNNER_NAME: 'mini-mac-1', ASC_CERTIFICATE_CLEANUP_ARCHIVE_LOG: archive, APP_STORE_CONNECT_KEY_ID: 'TESTKEY', APP_STORE_CONNECT_ISSUER_ID: 'test-issuer', APP_STORE_CONNECT_API_KEY: Buffer.from(key).toString('base64') };
  const records = [signer, personal, distribution, old];
  const requests = [];
  const request = async (method, url) => {
    assert.equal(method, 'GET');
    requests.push(url);
    return requests.length === 1 ? { data: records.slice(0, 2), links: { next: '/v1/certificates?cursor=next' } } : { data: records.slice(2), links: { next: null } };
  };
  const lines = [];
  await run({ env, request, now, write: line => lines.push(line) });
  assert.equal(requests.length, 2);
  assert.match(lines.at(-1), /1 would revoke; 3 kept; 0 revoked/);
  assert.ok(!lines.join('\n').includes('TESTKEY'));
  for (const extra of [{ RUNNER_NAME: 'GitHub-hosted' }, { ASC_CERTIFICATE_CLEANUP_ARCHIVE_LOG: '/not-found' }]) {
    await run({ env: { ...env, ...extra }, request: () => assert.fail('unsafe run reached Apple'), write: () => {} });
  }
  fs.writeFileSync(archive, command);
  await run({ env, request: () => assert.fail('failed archive reached Apple'), write: () => {} });
  fs.writeFileSync(archive, log);
  for (const next of ['https://example.com/v1/certificates', '/v1/profiles', '/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200']) {
    await assert.rejects(run({ env, request: async () => ({ data: [old], links: { next } }), now, write: () => {} }), /pagination/);
  }
  await assert.rejects(run({ env, request: async () => ({ data: null }), write: () => {} }), /data array/);
  // Exercise the actual command used by release.yml with a fake GET boundary.
  // The old opt-out must NOT reactivate deletion, even if it remains in an env.
  const preload = path.join(root, 'preload.cjs');
  fs.writeFileSync(preload, `Date.now = () => ${now};\nglobal.fetch = async (url, options) => { if (options.method !== 'GET') throw new Error('mutation attempted'); return {ok:true,text:async()=>JSON.stringify(${JSON.stringify({ data: records })})}; };`);
  const cli = spawnSync(process.execPath, ['-r', preload, '.github/scripts/prune_asc_development_certs.js'], { encoding: 'utf8', env: { ...env, ASC_CERTIFICATE_CLEANUP_DRY_RUN: '0' } });
  assert.equal(cli.status, 0);
  assert.match(cli.stdout, /1 would revoke; 3 kept; 0 revoked/);
  assert.ok(!cli.stdout.includes('WARNING'));
  console.log('CLI demonstration (disposable certificates; fake Apple GET boundary):');
  console.log(cli.stdout.trim());
  console.log('PASS: signer, personal, distribution, 24-hour boundary, future date, malformed certificate, missing identity, multiple signers, failed archive, hosted runner, pagination, unsafe links, and list-only CLI.');
}
test().finally(() => fs.rmSync(root, { recursive: true, force: true })).catch(error => { console.error(error); process.exitCode = 1; });
