import { createContext, useContext, useMemo } from "react";
import { useColorScheme } from "react-native";

/** Original "ready" green — the intuitive default before any customization. */
export const DEFAULT_ACCENT = "#4C9A5E";

export function palette(dark: boolean, accent: string = DEFAULT_ACCENT) {
  return {
    bg: dark ? "#12100E" : "#FBF8F4",
    card: dark ? "#1E1B18" : "#FFFFFF",
    text: dark ? "#F2EEE8" : "#22201D",
    dim: dark ? "#9A9187" : "#7A736B",
    track: dark ? "#2C2823" : "#EAE3D9",
    // "ready" is the user's chosen accent (green by default — permission to
    // eat). Resting (amber) and paused (grey) are fixed regardless of accent:
    // those two carry meaning the app relies on and aren't personalization.
    ready: accent,
    resting: "#C98B3A",
    paused: dark ? "#5A544C" : "#B5ADA2",
  };
}

export const AccentColorContext = createContext<string>(DEFAULT_ACCENT);

export type ThemeMode = "system" | "light" | "dark";
export const ThemeModeContext = createContext<ThemeMode>("system");

export function useIsDark(): boolean {
  const systemDark = useColorScheme() === "dark";
  const mode = useContext(ThemeModeContext);
  return mode === "system" ? systemDark : mode === "dark";
}

/** Color scheme (respecting the mode override) + accent, as one palette. */
export function useTheme() {
  const dark = useIsDark();
  const accent = useContext(AccentColorContext);
  return useMemo(() => palette(dark, accent), [dark, accent]);
}

/**
 * The tab bar floats above content (Liquid Glass style) rather than pushing
 * it, so scrollable/bottom-anchored screen content needs this much bottom
 * clearance to avoid sitting under it.
 */
export const TAB_BAR_CLEARANCE = 120;

export function mmss(ms: number): string {
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
