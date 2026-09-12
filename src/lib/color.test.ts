import { hexToHsv, hsvToHex } from "./color.ts";

let pass = 0, fail = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { pass++; console.log(`  PASS  ${name} ${detail}`); }
  else { fail++; console.log(`  FAIL  ${name} ${detail}`); }
}

console.log("\n1. Primary hues");
{
  check("hue 0 is red", hsvToHex(0, 1, 1) === "#ff0000");
  check("hue 120 is green", hsvToHex(120, 1, 1) === "#00ff00");
  check("hue 240 is blue", hsvToHex(240, 1, 1) === "#0000ff");
}

console.log("\n2. Saturation and value edges");
{
  check("zero saturation is white regardless of hue", hsvToHex(0, 0, 1) === "#ffffff");
  check("zero saturation at half value is mid-gray", hsvToHex(200, 0, 0.5) === "#808080");
  check("hue wraps at 360", hsvToHex(0, 1, 1) === hsvToHex(360, 1, 1));
}

console.log("\n3. hexToHsv inverts hsvToHex");
{
  const red = hexToHsv("#ff0000");
  check("red hue", red.h === 0);
  check("red fully saturated", red.s === 1);
  check("red full value", red.v === 1);

  const green = hexToHsv("#00ff00");
  check("green hue", green.h === 120);
}

console.log("\n4. Round trip through hex stays close for an arbitrary color");
{
  const original = { h: 205, s: 0.62, v: 0.77 };
  const hex = hsvToHex(original.h, original.s, original.v);
  const back = hexToHsv(hex);
  // Hex quantizes to 8 bits per channel, so allow the rounding this introduces.
  check("hue within 2 degrees", Math.abs(back.h - original.h) < 2, `(${back.h})`);
  check("saturation within 0.02", Math.abs(back.s - original.s) < 0.02, `(${back.s})`);
  check("value within 0.02", Math.abs(back.v - original.v) < 0.02, `(${back.v})`);
}

console.log("\n5. App default accent round-trips sanely");
{
  const hsv = hexToHsv("#4C9A5E");
  const hex = hsvToHex(hsv.h, hsv.s, hsv.v);
  check("default accent survives a round trip", hex === "#4c9a5e", `(${hex})`);
}

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail === 0 ? 0 : 1);
