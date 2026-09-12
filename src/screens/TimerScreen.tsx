import { useMemo, useState } from "react";
import {
  Pressable, StyleSheet, Text, View, useColorScheme, ScrollView,
} from "react-native";
import Svg, { Circle } from "react-native-svg";
import { SafeAreaView } from "react-native-safe-area-context";

import { useMealTimer } from "../hooks/useMealTimer.ts";

const REST_PRESETS = [15, 20, 30, 45, 60];
const RING = 280;
const STROKE = 18;
const RADIUS = (RING - STROKE) / 2;
const CIRC = 2 * Math.PI * RADIUS;

function palette(dark: boolean) {
  return {
    bg: dark ? "#12100E" : "#FBF8F4",
    card: dark ? "#1E1B18" : "#FFFFFF",
    text: dark ? "#F2EEE8" : "#22201D",
    dim: dark ? "#9A9187" : "#7A736B",
    track: dark ? "#2C2823" : "#EAE3D9",
    // Green = permission to eat. Amber = rest in progress. Never red: this app
    // reports, it does not scold.
    ready: "#4C9A5E",
    resting: "#C98B3A",
    paused: dark ? "#5A544C" : "#B5ADA2",
  };
}

function mmss(ms: number): string {
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export default function TimerScreen() {
  const dark = useColorScheme() === "dark";
  const c = useMemo(() => palette(dark), [dark]);
  const [restSec, setRestSec] = useState(30);
  const t = useMealTimer(restSec * 1000);

  const { phase, progress, remainingMs, elapsedMs, biteCount, summary, dispatch } = t;
  const restingPhase = phase === "resting" || (phase === "paused" && t.state.phaseBeforePause === "resting");
  const ringColor = phase === "paused" ? c.paused : restingPhase ? c.resting : c.ready;
  const canConfirm = phase === "ready" || phase === "resting";

  if (phase === "idle") {
    return (
      <SafeAreaView style={[s.root, { backgroundColor: c.bg }]}>
        <View style={s.center}>
          <Text style={[s.h1, { color: c.text }]}>Morsel</Text>
          <Text style={[s.sub, { color: c.dim }]}>
            Put the utensil down after every bite, then tap.
          </Text>

          <Text style={[s.label, { color: c.dim }]}>REST BETWEEN BITES</Text>
          <View style={s.presets}>
            {REST_PRESETS.map((sec) => {
              const on = sec === restSec;
              return (
                <Pressable
                  key={sec}
                  onPress={() => setRestSec(sec)}
                  style={[
                    s.preset,
                    { borderColor: on ? c.ready : c.track, backgroundColor: on ? c.ready : "transparent" },
                  ]}
                >
                  <Text style={[s.presetText, { color: on ? "#fff" : c.dim }]}>{sec}s</Text>
                </Pressable>
              );
            })}
          </View>

          <Pressable
            onPress={() => dispatch({ type: "START", restMs: restSec * 1000 })}
            style={[s.primary, { backgroundColor: c.ready }]}
          >
            <Text style={s.primaryText}>Start meal</Text>
          </Pressable>
        </View>
      </SafeAreaView>
    );
  }

  if (phase === "ended") {
    const drift = summary.paceDrift;
    return (
      <SafeAreaView style={[s.root, { backgroundColor: c.bg }]}>
        <ScrollView contentContainerStyle={s.center}>
          <Text style={[s.h1, { color: c.text }]}>Meal complete</Text>
          <View style={[s.card, { backgroundColor: c.card }]}>
            <Row c={c} k="Bites" v={String(summary.biteCount)} />
            <Row c={c} k="Duration" v={mmss(summary.durationMs)} />
            {summary.pausedMs > 0 && <Row c={c} k="Paused" v={mmss(summary.pausedMs)} />}
            {summary.meanBiteMs !== null && (
              <Row c={c} k="Avg time per bite" v={`${(summary.meanBiteMs / 1000).toFixed(1)}s`} />
            )}
            {summary.earlyBites > 0 && <Row c={c} k="Early bites" v={String(summary.earlyBites)} />}
            {drift !== null && (
              <Row
                c={c}
                k="Pace through meal"
                v={drift < 0.8 ? `sped up ${Math.round((1 - drift) * 100)}%`
                  : drift > 1.2 ? `slowed ${Math.round((drift - 1) * 100)}%`
                  : "steady"}
              />
            )}
          </View>
          <Text style={[s.sub, { color: c.dim }]}>
            Fullness rating and saving come next.
          </Text>
          <Pressable
            onPress={() => dispatch({ type: "RESET" })}
            style={[s.primary, { backgroundColor: c.ready }]}
          >
            <Text style={s.primaryText}>Done</Text>
          </Pressable>
        </ScrollView>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={[s.root, { backgroundColor: c.bg }]}>
      <View style={s.header}>
        <Text style={[s.stat, { color: c.dim }]}>{biteCount} bites</Text>
        <Text style={[s.stat, { color: c.dim }]}>{mmss(elapsedMs)}</Text>
      </View>

      {/* The ring is the tap target: a large, unmissable surface you can hit
          without looking away from the table. */}
      <Pressable
        style={s.center}
        disabled={!canConfirm}
        onPress={t.confirmBite}
        accessibilityLabel={phase === "ready" ? "Confirm bite taken" : "Confirm bite early"}
      >
        <View style={{ width: RING, height: RING, alignItems: "center", justifyContent: "center" }}>
          <Svg width={RING} height={RING} style={StyleSheet.absoluteFill}>
            <Circle cx={RING / 2} cy={RING / 2} r={RADIUS} stroke={c.track} strokeWidth={STROKE} fill="none" />
            <Circle
              cx={RING / 2} cy={RING / 2} r={RADIUS}
              stroke={ringColor} strokeWidth={STROKE} fill="none"
              strokeDasharray={CIRC}
              strokeDashoffset={CIRC * (1 - progress)}
              strokeLinecap="round"
              transform={`rotate(-90 ${RING / 2} ${RING / 2})`}
            />
          </Svg>

          {phase === "paused" ? (
            <Text style={[s.big, { color: c.paused }]}>Paused</Text>
          ) : phase === "ready" ? (
            <>
              <Text style={[s.big, { color: c.ready }]}>Take a bite</Text>
              <Text style={[s.sub, { color: c.dim }]}>then tap when it's down</Text>
            </>
          ) : (
            <>
              <Text style={[s.countdown, { color: c.text }]}>{Math.ceil(remainingMs / 1000)}</Text>
              <Text style={[s.sub, { color: c.dim }]}>utensil down</Text>
            </>
          )}
        </View>
      </Pressable>

      <View style={s.footer}>
        <Pressable
          onPress={() => dispatch({ type: phase === "paused" ? "RESUME" : "PAUSE" })}
          style={[s.secondary, { borderColor: c.track }]}
        >
          <Text style={[s.secondaryText, { color: c.text }]}>
            {phase === "paused" ? "Resume" : "Pause"}
          </Text>
        </Pressable>
        <Pressable
          onPress={() => dispatch({ type: "END" })}
          style={[s.secondary, { borderColor: c.track }]}
        >
          <Text style={[s.secondaryText, { color: c.text }]}>End meal</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

function Row({ c, k, v }: { c: ReturnType<typeof palette>; k: string; v: string }) {
  return (
    <View style={s.row}>
      <Text style={[s.rowKey, { color: c.dim }]}>{k}</Text>
      <Text style={[s.rowVal, { color: c.text }]}>{v}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1 },
  center: { flex: 1, alignItems: "center", justifyContent: "center", padding: 24, gap: 16 },
  header: { flexDirection: "row", justifyContent: "space-between", paddingHorizontal: 28, paddingTop: 8 },
  footer: { flexDirection: "row", justifyContent: "center", gap: 12, padding: 24 },
  h1: { fontSize: 34, fontWeight: "700", letterSpacing: -0.5 },
  sub: { fontSize: 15, textAlign: "center" },
  label: { fontSize: 12, fontWeight: "600", letterSpacing: 1.2, marginTop: 24 },
  big: { fontSize: 30, fontWeight: "700" },
  countdown: { fontSize: 76, fontWeight: "200", fontVariant: ["tabular-nums"] },
  stat: { fontSize: 15, fontVariant: ["tabular-nums"] },
  presets: { flexDirection: "row", gap: 8, flexWrap: "wrap", justifyContent: "center" },
  preset: { paddingHorizontal: 18, paddingVertical: 10, borderRadius: 999, borderWidth: 1.5 },
  presetText: { fontSize: 16, fontWeight: "600" },
  primary: { paddingHorizontal: 40, paddingVertical: 16, borderRadius: 999, marginTop: 12 },
  primaryText: { color: "#fff", fontSize: 17, fontWeight: "600" },
  secondary: { paddingHorizontal: 28, paddingVertical: 14, borderRadius: 999, borderWidth: 1.5 },
  secondaryText: { fontSize: 16, fontWeight: "600" },
  card: { width: "100%", borderRadius: 16, padding: 20, gap: 12 },
  row: { flexDirection: "row", justifyContent: "space-between" },
  rowKey: { fontSize: 15 },
  rowVal: { fontSize: 15, fontWeight: "600", fontVariant: ["tabular-nums"] },
});
