/**
 * Weight trend analysis — the Happy Scale core.
 *
 * Two separate jobs, deliberately using two different methods:
 *
 *  1. The DISPLAY LINE uses an exponentially weighted moving average (the
 *     Hacker's Diet trend). It is smooth, updates intuitively, and answers
 *     "what do I actually weigh, ignoring water?".
 *
 *  2. The RATE OF CHANGE uses ordinary least squares on the RAW weights.
 *     It is tempting to regress the EWMA series instead, since it looks
 *     cleaner — but EWMA output is heavily autocorrelated by construction,
 *     which collapses the apparent residuals and produces a standard error
 *     that is far too small. You get a confident number that is not earned.
 *     Regressing raw weights gives both an unbiased slope and an honest
 *     uncertainty.
 *
 * Caveat kept in view: consecutive daily weights are themselves somewhat
 * autocorrelated (water retention persists for days), so even the raw-OLS
 * standard error is mildly optimistic. It is close enough to be useful and
 * far better than the smoothed alternative.
 */

export interface WeightPoint {
  date: string; // local day, 'YYYY-MM-DD'
  kg: number;
}

export interface TrendPoint extends WeightPoint {
  trend: number;
}

const DAY_MS = 86_400_000;

/** Parse a local-day string as a UTC instant, so DST never shifts a day count. */
function dayNumber(date: string): number {
  const [y, m, d] = date.split("-").map(Number);
  return Date.UTC(y, m - 1, d) / DAY_MS;
}

function dayString(n: number): string {
  return new Date(n * DAY_MS).toISOString().slice(0, 10);
}

/**
 * EWMA with gap correction.
 *
 * A naive EWMA treats each row as one time step, so a three-week gap between
 * weigh-ins gets the same pull as a single day and the trend lurches. Scaling
 * alpha by the true elapsed days fixes that: alpha_eff = 1 - (1-alpha)^days.
 *
 * @param halfLifeDays how long until a reading loses half its influence.
 */
export function ewmaTrend(points: WeightPoint[], halfLifeDays = 10): TrendPoint[] {
  if (points.length === 0) return [];
  const sorted = [...points].sort((a, b) => a.date.localeCompare(b.date));
  const alpha = 1 - Math.pow(2, -1 / halfLifeDays);

  const out: TrendPoint[] = [];
  let trend = sorted[0].kg;
  let prevDay = dayNumber(sorted[0].date);

  for (const p of sorted) {
    const day = dayNumber(p.date);
    const gap = Math.max(1, day - prevDay);
    const alphaEff = 1 - Math.pow(1 - alpha, gap);
    trend = trend + alphaEff * (p.kg - trend);
    out.push({ ...p, trend });
    prevDay = day;
  }
  return out;
}

export interface Rate {
  kgPerWeek: number;
  /** Standard error of the estimate, same units. */
  seKgPerWeek: number;
  /** 95% confidence interval. */
  ci95: [number, number];
  n: number;
  /** True when the interval straddles zero — that IS the definition of a plateau. */
  plateau: boolean;
}

/**
 * Rate of change over a trailing window, by OLS on raw weights.
 * Returns null when there is not enough data to say anything (n < 3).
 */
export function rateOfChange(points: WeightPoint[], windowDays = 30): Rate | null {
  const sorted = [...points].sort((a, b) => a.date.localeCompare(b.date));
  if (sorted.length === 0) return null;

  const lastDay = dayNumber(sorted[sorted.length - 1].date);
  const win = sorted.filter((p) => lastDay - dayNumber(p.date) < windowDays);
  const n = win.length;
  if (n < 3) return null;

  const xs = win.map((p) => dayNumber(p.date));
  const ys = win.map((p) => p.kg);
  const xbar = xs.reduce((a, b) => a + b, 0) / n;
  const ybar = ys.reduce((a, b) => a + b, 0) / n;

  let sxx = 0;
  let sxy = 0;
  for (let i = 0; i < n; i++) {
    sxx += (xs[i] - xbar) ** 2;
    sxy += (xs[i] - xbar) * (ys[i] - ybar);
  }
  // Every weigh-in on the same day: slope is undefined, not zero.
  if (sxx === 0) return null;

  const slope = sxy / sxx; // kg per day
  const intercept = ybar - slope * xbar;

  let sse = 0;
  for (let i = 0; i < n; i++) {
    sse += (ys[i] - (intercept + slope * xs[i])) ** 2;
  }
  const sigma = Math.sqrt(sse / (n - 2));
  const seSlope = sigma / Math.sqrt(sxx);

  const kgPerWeek = slope * 7;
  const seKgPerWeek = seSlope * 7;
  const lo = kgPerWeek - 1.96 * seKgPerWeek;
  const hi = kgPerWeek + 1.96 * seKgPerWeek;

  return {
    kgPerWeek,
    seKgPerWeek,
    ci95: [lo, hi],
    n,
    plateau: lo <= 0 && hi >= 0,
  };
}

export interface Projection {
  /** Central estimate. null when the trend is flat or moving away from the goal. */
  date: string | null;
  /** Range implied by the 95% CI on the rate. null ends are "possibly never". */
  earliest: string | null;
  latest: string | null;
  reason?: string;
}

/**
 * Project when the trend line reaches a goal weight.
 *
 * Happy Scale shows a single date. A single date is a claim of precision that
 * two weeks of noisy bathroom-scale data cannot support, so this returns a cone
 * instead: the fast and slow ends implied by the confidence interval on the rate.
 */
export function projectToGoal(
  points: WeightPoint[],
  goalKg: number,
  windowDays = 30,
  halfLifeDays = 10,
): Projection {
  const trend = ewmaTrend(points, halfLifeDays);
  const rate = rateOfChange(points, windowDays);
  if (trend.length === 0 || !rate) {
    return { date: null, earliest: null, latest: null, reason: "not enough data" };
  }

  const current = trend[trend.length - 1].trend;
  const lastDay = dayNumber(trend[trend.length - 1].date);
  const remaining = goalKg - current;

  if (Math.abs(remaining) < 0.05) {
    return { date: dayString(lastDay), earliest: null, latest: null, reason: "already there" };
  }

  // days = remaining / (kgPerWeek / 7); only counts if the sign moves toward goal.
  const daysFor = (kgPerWeek: number): string | null => {
    const perDay = kgPerWeek / 7;
    if (perDay === 0) return null;
    const d = remaining / perDay;
    if (d <= 0 || !Number.isFinite(d)) return null;
    return dayString(Math.round(lastDay + d));
  };

  const central = daysFor(rate.kgPerWeek);

  // A negative time-to-goal means the goal lies behind you along your current
  // direction of travel — you passed it and are still going. That deserves a
  // different message from "you are drifting the wrong way and never arrive".
  if (central === null && !rate.plateau) {
    const perDay = rate.kgPerWeek / 7;
    if (perDay !== 0 && remaining / perDay < 0) {
      return {
        date: null,
        earliest: null,
        latest: null,
        reason: "goal already passed; trend is continuing beyond it",
      };
    }
  }
  const ends = [daysFor(rate.ci95[0]), daysFor(rate.ci95[1])]
    .filter((d): d is string => d !== null)
    .sort();

  return {
    date: central,
    earliest: ends[0] ?? null,
    latest: ends.length > 1 ? ends[ends.length - 1] : null,
    reason: central === null ? "trend is not moving toward the goal" : undefined,
  };
}
