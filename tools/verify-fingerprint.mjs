import crypto from 'node:crypto';
import { sha256Hex } from './core/sha256.js';
import { computeFingerprint, normalizeMessage, normalizeStackFrames, normalizeEndpoint } from './core/fingerprint.js';

let fail = 0;
const check = (name, actual, expected) => {
  const ok = actual === expected;
  if (!ok) fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
  if (!ok) console.log(`      expected: ${expected}\n      actual:   ${actual}`);
};

// --- NIST / RFC vectors -----------------------------------------------------
check('sha256("")', sha256Hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
check('sha256("abc")', sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
check('sha256(448-bit msg)', sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
  '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');

// --- agreement with Node's own SHA-256 over random + unicode input ----------
let agree = 0;
for (let i = 0; i < 400; i++) {
  const len = Math.floor(Math.random() * 300);
  let s = '';
  for (let j = 0; j < len; j++) s += String.fromCharCode(Math.floor(Math.random() * 0x2e80));
  const mine = sha256Hex(s);
  const theirs = crypto.createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');
  if (mine === theirs) agree++;
  else { console.log('MISMATCH on', JSON.stringify(s).slice(0,80)); break; }
}
check('400 random unicode strings match node:crypto', agree, 400);
// block-boundary lengths, where padding bugs live
let boundaryBad = [];
for (let n = 0; n <= 200; n++) {
  const s = 'x'.repeat(n);
  if (sha256Hex(s) !== crypto.createHash('sha256').update(s).digest('hex')) boundaryBad.push(n);
}
check('every message length 0..200 matches node:crypto', boundaryBad.join(',') || 'none', 'none');

// --- positive control: the test must be able to fail ------------------------
const control = sha256Hex('abc') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae';
check('positive control (deliberately wrong digest is rejected)', control, false);

// --- normalisation ----------------------------------------------------------
check('normalizeMessage strips ids',
  normalizeMessage("Invoice 40821 for customer 'ACME LTD' failed on 2026-09-15T10:22:31Z"),
  "Invoice {n} for customer '{str}' failed on {date}");
check('normalizeMessage strips guid',
  normalizeMessage('Row 3f2504e0-4f89-41d3-9a0c-0305e82c3301 not found'),
  'Row {guid} not found');
check('normalizeEndpoint strips ids',
  normalizeEndpoint('/api/invoices/4821/lines?page=2'), '/api/invoices/{id}/lines');

const stack = `Error: boom
    at PurchaseOrderComponent.save (http://erp.local/main-8F2A1C.js:12:3456)
    at ZoneDelegate.invokeTask (http://erp.local/polyfills-A1.js:3:99)
    at InvoiceService.post (http://erp.local/main-8F2A1C.js:88:12)`;
check('normalizeStackFrames drops zone + locations',
  JSON.stringify(normalizeStackFrames(stack)),
  JSON.stringify(['PurchaseOrderComponent.save', 'InvoiceService.post']));

// --- the property that matters: same fault -> same hash ---------------------
const mk = (id, line) => computeFingerprint({
  layer: 'angular', category: 'angular_runtime',
  exceptionType: 'TypeError',
  message: `Cannot read properties of undefined (reading 'total') for order ${id}`,
  stackTrace: `TypeError: x\n    at OrderComponent.calc (http://erp/main-${line}.js:${line}:12)`,
  component: 'OrderComponent', erpModule: 'SD',
});
const a = mk(1001, 'AAA1'), b = mk(9987, 'BBB9');
check('same fault, different record id + bundle hash -> SAME fingerprint', a.hash, b.hash);

const c = computeFingerprint({
  layer: 'angular', category: 'angular_runtime', exceptionType: 'TypeError',
  message: "Cannot read properties of undefined (reading 'total') for order 1001",
  stackTrace: `TypeError: x\n    at CustomerComponent.calc (http://erp/main-AAA1.js:1:12)`,
  component: 'CustomerComponent', erpModule: 'SD',
});
check('same message, DIFFERENT component -> different fingerprint', a.hash === c.hash, false);

const d = computeFingerprint({ layer: 'database', category: 'sql_deadlock',
  exceptionType: 'SqlException', message: 'Transaction (Process ID 71) was deadlocked',
  sqlErrorNumber: 1205, sqlObjectName: 'usp_PostJournal' });
const e = computeFingerprint({ layer: 'database', category: 'sql_deadlock',
  exceptionType: 'SqlException', message: 'Transaction (Process ID 143) was deadlocked',
  sqlErrorNumber: 1205, sqlObjectName: 'usp_PostJournal' });
check('same deadlock, different SPID -> SAME fingerprint', d.hash, e.hash);
console.log('\nsample signature: ' + a.signature);
console.log('sample hash:      ' + a.hash);
console.log(fail === 0 ? '\nALL CHECKS PASSED' : `\n${fail} CHECK(S) FAILED`);
process.exit(fail === 0 ? 0 : 1);
