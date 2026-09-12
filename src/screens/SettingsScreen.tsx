import { Pressable, ScrollView, StyleSheet, Switch, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

import ColorWheel from "../components/ColorWheel.tsx";
import { DEFAULT_ACCENT, useTheme, TAB_BAR_CLEARANCE } from "../theme.ts";
import type { ThemeMode } from "../theme.ts";
import { useTabBarScrollHandler } from "../tabBarScroll.ts";

// A handful of starting points, not a limit — the wheel above picks any color.
const PRESETS = [
  DEFAULT_ACCENT, // original green
  "#3B82C4", // blue
  "#7C5CBF", // purple
  "#2E9E96", // teal
  "#D97B29", // orange
  "#C4527A", // pink
  "#C0392B", // red
];

const THEME_MODES: { key: ThemeMode; label: string }[] = [
  { key: "system", label: "System" },
  { key: "light", label: "Light" },
  { key: "dark", label: "Dark" },
];

export default function SettingsScreen({
  accent,
  onChangeAccent,
  themeMode,
  onChangeThemeMode,
  bubbleEnabled,
  onChangeBubbleEnabled,
}: {
  accent: string;
  onChangeAccent: (hex: string) => void;
  themeMode: ThemeMode;
  onChangeThemeMode: (mode: ThemeMode) => void;
  bubbleEnabled: boolean;
  onChangeBubbleEnabled: (enabled: boolean) => void;
}) {
  const c = useTheme();
  const tabBarScroll = useTabBarScrollHandler();

  return (
    <SafeAreaView style={[s.root, { backgroundColor: c.bg }]} edges={["top", "left", "right"]}>
      <ScrollView
        contentContainerStyle={s.content}
        onScroll={tabBarScroll.onScroll}
        scrollEventThrottle={tabBarScroll.scrollEventThrottle}
      >
        <Text style={[s.title, { color: c.text }]}>Settings</Text>

        <Text style={[s.label, { color: c.dim }]}>APPEARANCE</Text>
        <View style={[s.segmented, { borderColor: c.track }]}>
          {THEME_MODES.map((mode) => {
            const active = mode.key === themeMode;
            return (
              <Pressable
                key={mode.key}
                onPress={() => onChangeThemeMode(mode.key)}
                style={[s.segment, active && { backgroundColor: c.ready }]}
              >
                <Text style={[s.segmentText, { color: active ? "#fff" : c.dim, fontWeight: active ? "700" : "500" }]}>
                  {mode.label}
                </Text>
              </Pressable>
            );
          })}
        </View>

        <View style={s.toggleRow}>
          <View style={s.toggleText}>
            <Text style={[s.toggleLabel, { color: c.text }]}>Tab bar glass bubble</Text>
            <Text style={[s.sub, { color: c.dim, marginBottom: 0 }]}>
              Animated highlight behind the active tab. Off by default to save battery.
            </Text>
          </View>
          <Switch
            value={bubbleEnabled}
            onValueChange={onChangeBubbleEnabled}
            trackColor={{ true: c.ready, false: c.track }}
          />
        </View>

        <Text style={[s.label, { color: c.dim }]}>ACCENT COLOR</Text>
        <Text style={[s.sub, { color: c.dim }]}>
          This is your "ready" color — permission to eat. Pick anything.
        </Text>

        <View style={s.wheelWrap}>
          <ColorWheel value={accent} onChange={onChangeAccent} />
        </View>

        <View style={s.presets}>
          {PRESETS.map((hex) => (
            <Pressable
              key={hex}
              onPress={() => onChangeAccent(hex)}
              accessibilityLabel={`Use ${hex} as accent color`}
              style={[
                s.swatch,
                { backgroundColor: hex, borderColor: hex.toLowerCase() === accent.toLowerCase() ? c.text : "transparent" },
              ]}
            />
          ))}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1 },
  content: { padding: 24, paddingBottom: TAB_BAR_CLEARANCE, alignItems: "center", gap: 8 },
  title: { fontSize: 28, fontWeight: "700", alignSelf: "flex-start", marginBottom: 8 },
  label: { fontSize: 12, fontWeight: "600", letterSpacing: 1.2, alignSelf: "flex-start", marginTop: 16 },
  sub: { fontSize: 14, alignSelf: "flex-start", marginBottom: 8 },
  segmented: {
    flexDirection: "row", borderRadius: 10, borderWidth: 1.5, padding: 3,
    width: "100%", marginTop: 8,
  },
  segment: { flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: "center" },
  segmentText: { fontSize: 14 },
  toggleRow: {
    flexDirection: "row", alignItems: "center", justifyContent: "space-between",
    width: "100%", marginTop: 20, gap: 12,
  },
  toggleText: { flex: 1, gap: 2 },
  toggleLabel: { fontSize: 15, fontWeight: "600" },
  wheelWrap: { paddingVertical: 16 },
  presets: { flexDirection: "row", flexWrap: "wrap", gap: 12, justifyContent: "center", paddingTop: 8 },
  swatch: { width: 40, height: 40, borderRadius: 20, borderWidth: 3 },
});
