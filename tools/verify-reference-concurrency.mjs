/**
 * Concurrency proof for the LinkedScam reference-code standard, point 7:
 *
 *   "The reference-generation mechanism must guarantee that duplicate codes
 *    cannot be generated when multiple users, requests, or application
 *    instances create tickets/errors concurrently."
 *
 * A daily-resetting counter is the case where the naive implementation breaks.
 * SELECT MAX(counter)+1 looks correct in every manual test, because a person
 * cannot click twice in the same millisecond - and then collides the first time
 * a bad deployment throws hundreds of errors at once from different users.
 *
 * So this fires a burst of genuinely parallel requests at the running demo and
 * asserts that every reference that comes back is distinct, and that the set is
 * exactly 1..N with no gaps and no repeats.
 *
 * Run the demo first:   cd demo/api && dotnet run
 * Then:                 node tools/verify-reference-concurrency.mjs
 *
 * The demo is SQLite and production is SQL Server, so this exercises the SHAPE
 * of the algorithm (atomic increment-and-return, no read-then-write window)
 * rather than SQL Server's own locking. The T-SQL uses UPDATE ... OUTPUT for
 * the same reason; see db/002_core_tables.sql.
 */

const BASE = process.env.ERM_DEMO || 'http://localhost:5146';
const API = `${BASE}/api/error-management`;
const BURST = 120;

const fail = (m) => {
  console.error(`FAIL  ${m}`);
  process.exitCode = 1;
};
const pass = (m) => console.log(`PASS  ${m}`);

async function reset() {
  await fetch(`${API}/demo/reset`, { method: 'POST' });
}

/** Fire every request at once - no awaiting in between. */
async function burstTickets(n) {
  const calls = Array.from({ length: n }, (_, i) =>
    fetch(`${API}/tickets/manual`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Demo-User': 'fatima.saeed' },
      body: JSON.stringify({ title: `concurrent ticket ${i}`, requestCategory: 'other' }),
    }).then((r) => (r.ok ? r.json() : null)),
  );
  const results = await Promise.all(calls);
  return results.filter(Boolean).map((r) => r.ticketNumber).filter(Boolean);
}

function analyse(refs, type, expected) {
  const today = new Date();
  const yy = String(today.getUTCFullYear()).slice(2);
  const mm = String(today.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(today.getUTCDate()).padStart(2, '0');
  const prefix = `LS-ERM-${type}-${yy}${mm}${dd}-`;

  console.log(`\n  requested ${expected}, received ${refs.length}`);
  console.log(`  sample: ${refs.slice(0, 3).join('  ')}`);

  if (refs.length !== expected) {
    fail(`every request produced a reference (${refs.length}/${expected})`);
  } else {
    pass(`every request produced a reference (${expected})`);
  }

  const badFormat = refs.filter((r) => !r.startsWith(prefix));
  if (badFormat.length) fail(`all references match ${prefix}N  (${badFormat[0]})`);
  else pass(`all references match ${prefix}N`);

  // THE point of the exercise.
  const unique = new Set(refs);
  if (unique.size !== refs.length) {
    const seen = new Set();
    const dupes = refs.filter((r) => (seen.has(r) ? true : (seen.add(r), false)));
    fail(`no duplicates under concurrency - found ${refs.length - unique.size}: ${[...new Set(dupes)].slice(0, 5)}`);
  } else {
    pass(`no duplicates across ${refs.length} concurrent requests`);
  }

  // Counter should be a contiguous 1..N: no gaps means nothing was skipped,
  // no repeats means nothing was handed out twice.
  const counters = refs.map((r) => Number(r.slice(prefix.length))).sort((a, b) => a - b);
  const contiguous = counters.every((v, i) => v === i + 1);
  if (!contiguous) {
    const missing = [];
    for (let i = 1; i <= counters.length; i++) if (!counters.includes(i)) missing.push(i);
    fail(`counter is a contiguous 1..${counters.length} (missing: ${missing.slice(0, 5)})`);
  } else {
    pass(`counter is a contiguous 1..${counters.length}, no gaps and no repeats`);
  }
}

(async () => {
  try {
    await fetch(`${API}/demo/reset`, { method: 'POST' });
  } catch {
    console.error(`Cannot reach the demo at ${BASE}. Start it with: cd demo/api && dotnet run`);
    process.exit(1);
  }

  console.log(`Firing ${BURST} simultaneous ticket creations at ${BASE} ...`);
  const refs = await burstTickets(BURST);
  analyse(refs, 'TKT', BURST);

  // POSITIVE CONTROL: the checker must be able to SEE a duplicate, otherwise
  // "no duplicates" proves nothing about the checker.
  console.log('\n  positive control (deliberately duplicated input):');
  const rigged = [...refs.slice(0, 5), refs[0]];
  const riggedUnique = new Set(rigged);
  if (riggedUnique.size === rigged.length) fail('positive control: the duplicate check can detect a duplicate');
  else pass('positive control: the duplicate check does detect a duplicate');

  console.log(process.exitCode ? '\nCONCURRENCY CHECK FAILED' : '\nALL CONCURRENCY CHECKS PASSED');
})();
