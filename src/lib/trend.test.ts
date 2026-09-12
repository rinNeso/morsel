import { ewmaTrend, rateOfChange, projectToGoal } from "./trend.ts";
import type { WeightPoint } from "./trend.ts";

// Seeded PRNG so results are reproducible run to run.
function mulberry32(seed: number) {
  return function () {
    seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(42);
function gauss(sd: number) {
  const u = Math.max(rnd(), 1e-12), v = rnd();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v) * sd;
}
function series(days: number, startKg: number, kgPerWeek: number, noiseSd: number): WeightPoint[] {
  const out: WeightPoint[] = [];
  const t0 = Date.UTC(2026, 0, 1);
  for (let i = 0; i < days; i++) {
    out.push({
      date: new Date(t0 + i * 86400000).toISOString().slice(0, 10),
      kg: startKg + (kgPerWeek / 7) * i + gauss(noiseSd),
    });
  }
  return out;
}
const f = (n: number | undefined | null, d = 3) => (n == null ? "null" : n.toFixed(d));
let pass = 0, fail = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { pass++; console.log(`  PASS  ${name} ${detail}`); }
  else { fail++; console.log(`  FAIL  ${name} ${detail}`); }
}

console.log("\n1. Noiseless linear loss, 60d @ -0.50 kg/wk");
{
  const s = series(60, 90, -0.5, 0);
  const r = rateOfChange(s, 60)!;
  console.log(`     rate=${f(r.kgPerWeek)} se=${f(r.seKgPerWeek, 5)} plateau=${r.plateau}`);
  check("recovers exact slope", Math.abs(r.kgPerWeek - -0.5) < 1e-9);
  check("SE ~0 with no noise", r.seKgPerWeek < 1e-9);
  check("not flagged plateau", !r.plateau);
}

console.log("\n2. Realistic noise (sd 0.8 kg), 90d @ -0.50 kg/wk");
{
  const s = series(90, 90, -0.5, 0.8);
  const r = rateOfChange(s, 90)!;
  console.log(`     rate=${f(r.kgPerWeek)} CI=[${f(r.ci95[0])}, ${f(r.ci95[1])}] n=${r.n}`);
  check("estimate within 0.15 of truth", Math.abs(r.kgPerWeek - -0.5) < 0.15);
  check("CI covers the true value", r.ci95[0] <= -0.5 && r.ci95[1] >= -0.5);
  check("not flagged plateau", !r.plateau);
}

console.log("\n3. The short-window problem: same data, 14d window");
{
  const s = series(90, 90, -0.5, 0.8);
  const r14 = rateOfChange(s, 14)!;
  const r30 = rateOfChange(s, 30)!;
  const r90 = rateOfChange(s, 90)!;
  console.log(`     14d: rate=${f(r14.kgPerWeek)} CI=[${f(r14.ci95[0])}, ${f(r14.ci95[1])}] width=${f(r14.ci95[1]-r14.ci95[0])}`);
  console.log(`     30d: rate=${f(r30.kgPerWeek)} CI=[${f(r30.ci95[0])}, ${f(r30.ci95[1])}] width=${f(r30.ci95[1]-r30.ci95[0])}`);
  console.log(`     90d: rate=${f(r90.kgPerWeek)} CI=[${f(r90.ci95[0])}, ${f(r90.ci95[1])}] width=${f(r90.ci95[1]-r90.ci95[0])}`);
  check("CI narrows as window grows",
    (r14.ci95[1]-r14.ci95[0]) > (r30.ci95[1]-r30.ci95[0]) &&
    (r30.ci95[1]-r30.ci95[0]) > (r90.ci95[1]-r90.ci95[0]));
}

console.log("\n4. True plateau: flat weight, pure noise");
{
  const s = series(45, 90, 0, 0.8);
  const r = rateOfChange(s, 45)!;
  console.log(`     rate=${f(r.kgPerWeek)} CI=[${f(r.ci95[0])}, ${f(r.ci95[1])}] plateau=${r.plateau}`);
  check("flagged as plateau", r.plateau);
}

console.log("\n5. EWMA gap correction (30-day gap, then a 3 kg jump)");
{
  const pts: WeightPoint[] = [
    { date: "2026-01-01", kg: 90 }, { date: "2026-01-02", kg: 90 },
    { date: "2026-01-03", kg: 90 }, { date: "2026-02-02", kg: 93 },
  ];
  const gapAware = ewmaTrend(pts, 10);
  const last = gapAware[gapAware.length - 1].trend;
  // A naive one-step-per-row EWMA would barely move (alpha~0.067 -> ~90.2).
  console.log(`     trend after gap = ${f(last)} (naive single-step would be ~90.20)`);
  check("30-day gap pulls trend most of the way to the new reading", last > 92.0);
  check("but does not snap all the way to raw", last < 93.0);
}

console.log("\n6. Projection cone, 90d @ -0.50 kg/wk, goal 80 kg");
{
  const s = series(90, 90, -0.5, 0.8);
  const p = projectToGoal(s, 80, 90);
  console.log(`     central=${p.date} earliest=${p.earliest} latest=${p.latest}`);
  check("produces a central date", p.date !== null);
  check("produces a bracketing cone", p.earliest !== null && p.latest !== null);
  check("cone is ordered", (p.earliest ?? "") <= (p.date ?? "") && (p.date ?? "") <= (p.latest ?? ""));
}

console.log("\n7. Degenerate inputs");
{
  check("empty series -> no trend", ewmaTrend([]).length === 0);
  check("empty series -> no rate", rateOfChange([]) === null);
  check("2 points -> no rate (n<3)", rateOfChange(series(2, 90, -0.5, 0)) === null);
  const p = projectToGoal(series(30, 90, 0.5, 0.1), 85, 30); // gaining, goal is below
  check("wrong-direction trend -> no date", p.date === null, `(${p.reason})`);
}

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail === 0 ? 0 : 1);
