import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { StatusBar } from "expo-status-bar";
import { Animated, Pressable, StyleSheet, Text, View, useWindowDimensions } from "react-native";
import { SafeAreaProvider, useSafeAreaInsets } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { BlurView } from "expo-blur";
import TimerScreen from "./src/screens/TimerScreen.tsx";
import HistoryScreen from "./src/screens/HistoryScreen.tsx";
import SettingsScreen from "./src/screens/SettingsScreen.tsx";
import { AccentColorContext, DEFAULT_ACCENT, ThemeModeContext, useIsDark, useTheme } from "./src/theme.ts";
import type { ThemeMode } from "./src/theme.ts";
import { TabBarScrollContext, useTabBarScrollProvider } from "./src/tabBarScroll.ts";
import { getSetting, setSetting } from "./src/lib/db.ts";

const ACCENT_SETTING_KEY = "accent_color";
const THEME_MODE_SETTING_KEY = "theme_mode";
const TAB_BUBBLE_SETTING_KEY = "tab_bubble_enabled";
const BUBBLE_INSET = 6;
const BAR_MARGIN = 16;
const COLLAPSED_WIDTH = 64;

function isThemeMode(v: string): v is ThemeMode {
  return v === "system" || v === "light" || v === "dark";
}

type Screen = "timer" | "history" | "settings";

const TABS: { key: Screen; label: string; icon: keyof typeof Ionicons.glyphMap; iconActive: keyof typeof Ionicons.glyphMap }[] = [
  { key: "timer", label: "Timer", icon: "timer-outline", iconActive: "timer" },
  { key: "history", label: "History", icon: "list-outline", iconActive: "list" },
  { key: "settings", label: "Settings", icon: "color-palette-outline", iconActive: "color-palette" },
];

// Liquid Glass tab bar per Apple's iOS 26 HIG and the App Store's own tab bar:
// capsule-shaped, inset from the screen edges, floating above content, and
// physically shrinking to just the active icon on scroll-down, expanding
// back on scroll-up or near the top (tabBarMinimizeBehavior in UIKit/SwiftUI).
// https://developer.apple.com/design/human-interface-guidelines/tab-bars
function TabBar({
  screen,
  onChange,
  bubbleEnabled,
}: {
  screen: Screen;
  onChange: (s: Screen) => void;
  bubbleEnabled: boolean;
}) {
  const c = useTheme();
  const dark = useIsDark();
  const insets = useSafeAreaInsets();
  const { width: windowWidth } = useWindowDimensions();
  const scroll = useContextRequired();

  const fullWidth = windowWidth - BAR_MARGIN * 2;
  const activeIndex = TABS.findIndex((t) => t.key === screen);
  const tabWidth = fullWidth / TABS.length;
  const active = TABS[activeIndex];

  const bubbleX = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.spring(bubbleX, {
      toValue: activeIndex * tabWidth,
      useNativeDriver: true,
      bounciness: 8,
      speed: 16,
    }).start();
  }, [activeIndex, tabWidth, bubbleX]);

  const barWidth = scroll.collapsed.interpolate({ inputRange: [0, 1], outputRange: [fullWidth, COLLAPSED_WIDTH] });
  const expandedOpacity = scroll.collapsed.interpolate({ inputRange: [0, 0.4, 1], outputRange: [1, 0, 0] });
  const collapsedOpacity = scroll.collapsed.interpolate({ inputRange: [0, 0.6, 1], outputRange: [0, 0, 1] });

  return (
    <View style={[s.barWrap, { bottom: insets.bottom + 12 }]} pointerEvents="box-none">
      <Animated.View
        style={[
          s.glassBar,
          { width: barWidth, borderColor: dark ? "rgba(255,255,255,0.14)" : "rgba(255,255,255,0.65)" },
        ]}
      >
        <BlurView intensity={70} tint={dark ? "dark" : "light"} style={StyleSheet.absoluteFill} />
        {/* Faint accent tint ties the glass surface to the user's chosen color. */}
        <View style={[StyleSheet.absoluteFill, { backgroundColor: `${c.ready}1A` }]} />

        {/* Per-tab "glass bubble" on the active tab, opt-in: a real-time
            blur that re-renders every frame of the slide animation costs
            more than the bar's static background blur, so this stays off
            by default (the owner's "performance mode"). Hidden while
            collapsed since only one tab is visible then. */}
        {bubbleEnabled && !scroll.isCollapsed && (
          <Animated.View
            pointerEvents="none"
            style={[
              s.bubble,
              {
                width: tabWidth - BUBBLE_INSET * 2,
                opacity: expandedOpacity,
                transform: [{ translateX: Animated.add(bubbleX, new Animated.Value(BUBBLE_INSET)) }],
              },
            ]}
          >
            <BlurView intensity={90} tint={dark ? "light" : "dark"} style={StyleSheet.absoluteFill} />
            <View style={[StyleSheet.absoluteFill, { backgroundColor: `${c.ready}33` }]} />
          </Animated.View>
        )}

        {/* Expanded: every tab, icon + label. */}
        <Animated.View
          style={[s.barContent, { width: fullWidth, opacity: expandedOpacity }]}
          pointerEvents={scroll.isCollapsed ? "none" : "auto"}
        >
          {TABS.map((tab) => {
            const isActive = tab.key === screen;
            const color = isActive ? c.ready : c.dim;
            return (
              <Pressable key={tab.key} onPress={() => onChange(tab.key)} style={s.tab}>
                <Ionicons name={isActive ? tab.iconActive : tab.icon} size={24} color={color} />
                <Text style={[s.tabLabel, { color, fontWeight: isActive ? "700" : "500" }]}>
                  {tab.label}
                </Text>
              </Pressable>
            );
          })}
        </Animated.View>

        {/* Collapsed: just the active icon. Tapping re-expands the bar. */}
        <Animated.View
          style={[s.collapsedContent, { opacity: collapsedOpacity }]}
          pointerEvents={scroll.isCollapsed ? "auto" : "none"}
        >
          <Pressable onPress={scroll.expand} style={s.collapsedTap}>
            <Ionicons name={active.iconActive} size={22} color={c.ready} />
          </Pressable>
        </Animated.View>
      </Animated.View>
    </View>
  );
}

// Small helper so TabBar can assume the context is present — it's only ever
// rendered inside the provider set up by App below.
function useContextRequired() {
  const ctx = useContext(TabBarScrollContext);
  if (!ctx) throw new Error("TabBar rendered outside TabBarScrollContext");
  return ctx;
}

export default function App() {
  const [screen, setScreen] = useState<Screen>("timer");
  const [accent, setAccent] = useState(DEFAULT_ACCENT);
  const [themeMode, setThemeMode] = useState<ThemeMode>("system");
  const [bubbleEnabled, setBubbleEnabled] = useState(false);
  const tabBarScroll = useTabBarScrollProvider();

  useEffect(() => {
    getSetting(ACCENT_SETTING_KEY)
      .then((stored) => { if (stored) setAccent(stored); })
      .catch(() => {});
    getSetting(THEME_MODE_SETTING_KEY)
      .then((stored) => { if (stored && isThemeMode(stored)) setThemeMode(stored); })
      .catch(() => {});
    getSetting(TAB_BUBBLE_SETTING_KEY)
      .then((stored) => { if (stored) setBubbleEnabled(stored === "1"); })
      .catch(() => {});
  }, []);

  // Switching tabs should always land on an expanded bar.
  const changeScreen = useCallback((next: Screen) => {
    setScreen(next);
    tabBarScroll.expand();
  }, [tabBarScroll]);

  const changeAccent = useCallback((hex: string) => {
    setAccent(hex);
    setSetting(ACCENT_SETTING_KEY, hex).catch(() => {});
  }, []);

  const changeThemeMode = useCallback((mode: ThemeMode) => {
    setThemeMode(mode);
    setSetting(THEME_MODE_SETTING_KEY, mode).catch(() => {});
  }, []);

  const changeBubbleEnabled = useCallback((enabled: boolean) => {
    setBubbleEnabled(enabled);
    setSetting(TAB_BUBBLE_SETTING_KEY, enabled ? "1" : "0").catch(() => {});
  }, []);

  return (
    <SafeAreaProvider>
      <AccentColorContext.Provider value={accent}>
        <ThemeModeContext.Provider value={themeMode}>
          <TabBarScrollContext.Provider value={tabBarScroll}>
            <StatusBar style="auto" />
            <View style={s.root}>
              <View style={s.content}>
                {screen === "timer" && <TimerScreen />}
                {screen === "history" && <HistoryScreen />}
                {screen === "settings" && (
                  <SettingsScreen
                    accent={accent}
                    onChangeAccent={changeAccent}
                    themeMode={themeMode}
                    onChangeThemeMode={changeThemeMode}
                    bubbleEnabled={bubbleEnabled}
                    onChangeBubbleEnabled={changeBubbleEnabled}
                  />
                )}
              </View>
              <TabBar screen={screen} onChange={changeScreen} bubbleEnabled={bubbleEnabled} />
            </View>
          </TabBarScrollContext.Provider>
        </ThemeModeContext.Provider>
      </AccentColorContext.Provider>
    </SafeAreaProvider>
  );
}

const s = StyleSheet.create({
  root: { flex: 1 },
  content: { flex: 1 },
  barWrap: { position: "absolute", left: 0, right: 0, alignItems: "center" },
  glassBar: {
    borderRadius: 999,
    overflow: "hidden",
    borderWidth: 1,
    shadowColor: "#000",
    shadowOpacity: 0.18,
    shadowRadius: 18,
    shadowOffset: { width: 0, height: 8 },
  },
  barContent: { flexDirection: "row", paddingVertical: 14 },
  tab: { flex: 1, alignItems: "center", gap: 3 },
  tabLabel: { fontSize: 12 },
  bubble: { position: "absolute", top: 8, bottom: 8, borderRadius: 999, overflow: "hidden" },
  collapsedContent: { position: "absolute", left: 0, right: 0, top: 0, bottom: 0 },
  collapsedTap: { flex: 1, alignItems: "center", justifyContent: "center" },
});
