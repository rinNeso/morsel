import { useCallback, useEffect, useState } from "react";
import {
  FlatList, RefreshControl, StyleSheet, Text, View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

import { listMeals } from "../lib/db.ts";
import type { MealHistoryRow } from "../lib/db.ts";
import { useTheme, mmss, TAB_BAR_CLEARANCE } from "../theme.ts";
import { useTabBarScrollHandler } from "../tabBarScroll.ts";

function formatWhen(ms: number): string {
  const d = new Date(ms);
  const date = d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `${date} · ${time}`;
}

export default function HistoryScreen() {
  const c = useTheme();
  const tabBarScroll = useTabBarScrollHandler();
  const [meals, setMeals] = useState<MealHistoryRow[] | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(() => {
    return listMeals()
      .then(setMeals)
      .catch(() => setMeals([]));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    load().finally(() => setRefreshing(false));
  }, [load]);

  return (
    <SafeAreaView style={[s.root, { backgroundColor: c.bg }]} edges={["top", "left", "right"]}>
      <View style={s.header}>
        <Text style={[s.title, { color: c.text }]}>Meal history</Text>
      </View>

      <FlatList
        data={meals ?? []}
        keyExtractor={(m) => String(m.id)}
        contentContainerStyle={s.list}
        onScroll={tabBarScroll.onScroll}
        scrollEventThrottle={tabBarScroll.scrollEventThrottle}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={c.dim} />}
        ListEmptyComponent={
          meals !== null ? (
            <Text style={[s.empty, { color: c.dim }]}>
              No meals yet — start one from the timer.
            </Text>
          ) : null
        }
        renderItem={({ item }) => (
          <View style={[s.card, { backgroundColor: c.card }]}>
            <View style={s.cardHeader}>
              <Text style={[s.when, { color: c.text }]}>{formatWhen(item.startedAt)}</Text>
              <Text style={[s.duration, { color: c.dim }]}>{mmss(item.durationMs)}</Text>
            </View>
            <View style={s.statsRow}>
              <Stat c={c} label="bites" value={String(item.biteCount)} />
              <Stat
                c={c}
                label="avg pace"
                value={item.meanRestMs !== null ? `${Math.round(item.meanRestMs / 1000)}s` : "—"}
              />
              <Stat c={c} label="early" value={String(item.earlyBites)} />
              <Stat c={c} label="fullness" value={item.fullness !== null ? `${item.fullness}/10` : "—"} />
            </View>
          </View>
        )}
      />
    </SafeAreaView>
  );
}

function Stat({ c, label, value }: { c: ReturnType<typeof useTheme>; label: string; value: string }) {
  return (
    <View style={s.stat}>
      <Text style={[s.statValue, { color: c.text }]}>{value}</Text>
      <Text style={[s.statLabel, { color: c.dim }]}>{label}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1 },
  header: { paddingHorizontal: 16, paddingTop: 8, paddingBottom: 12 },
  title: { fontSize: 20, fontWeight: "700" },
  list: { padding: 16, paddingBottom: TAB_BAR_CLEARANCE, gap: 12, flexGrow: 1 },
  empty: { textAlign: "center", fontSize: 15, marginTop: 48 },
  card: { borderRadius: 16, padding: 16, gap: 12 },
  cardHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "baseline" },
  when: { fontSize: 16, fontWeight: "600" },
  duration: { fontSize: 16, fontVariant: ["tabular-nums"] },
  statsRow: { flexDirection: "row", justifyContent: "space-between" },
  stat: { alignItems: "flex-start", gap: 2 },
  statValue: { fontSize: 15, fontWeight: "600", fontVariant: ["tabular-nums"] },
  statLabel: { fontSize: 11, letterSpacing: 0.3 },
});
