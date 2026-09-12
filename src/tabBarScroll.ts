import { createContext, useContext, useRef, useState } from "react";
import { Animated } from "react-native";
import type { NativeScrollEvent, NativeSyntheticEvent } from "react-native";

/**
 * Drives the tab bar's minimize-on-scroll (App Store / iOS 26 behavior):
 * scrolling down past a small threshold collapses the bar to just the active
 * icon; scrolling up, or being near the top, expands it back. A single
 * Animated.Value is shared across every scrollable screen and the tab bar
 * itself via context, since App.tsx mounts only one screen at a time.
 */
export interface TabBarScroll {
  collapsed: Animated.Value;
  isCollapsed: boolean;
  expand: () => void;
  onScroll: (e: NativeSyntheticEvent<NativeScrollEvent>) => void;
}

export const TabBarScrollContext = createContext<TabBarScroll | null>(null);

const DIRECTION_THRESHOLD = 12; // px of scroll before reacting, so tiny jitters don't toggle it
const TOP_THRESHOLD = 24; // always expanded near the top, regardless of direction

export function useTabBarScrollProvider(): TabBarScroll {
  const collapsed = useRef(new Animated.Value(0)).current;
  const lastY = useRef(0);
  const isCollapsedRef = useRef(false);
  const [isCollapsed, setIsCollapsed] = useState(false);

  const setCollapsed = (next: boolean) => {
    if (isCollapsedRef.current === next) return;
    isCollapsedRef.current = next;
    setIsCollapsed(next);
    Animated.spring(collapsed, {
      toValue: next ? 1 : 0,
      useNativeDriver: false, // width/opacity aren't native-driver properties
      bounciness: 4,
      speed: 14,
    }).start();
  };

  const onScroll = (e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const y = e.nativeEvent.contentOffset.y;
    const delta = y - lastY.current;

    if (y <= TOP_THRESHOLD) {
      setCollapsed(false);
    } else if (delta > DIRECTION_THRESHOLD) {
      setCollapsed(true);
      lastY.current = y;
    } else if (delta < -DIRECTION_THRESHOLD) {
      setCollapsed(false);
      lastY.current = y;
    }
  };

  return { collapsed, isCollapsed, expand: () => setCollapsed(false), onScroll };
}

/** For scrollable screens: spread the result onto a ScrollView/FlatList's onScroll + scrollEventThrottle. */
export function useTabBarScrollHandler() {
  const ctx = useContext(TabBarScrollContext);
  if (!ctx) return { onScroll: undefined, scrollEventThrottle: undefined };
  return { onScroll: ctx.onScroll, scrollEventThrottle: 16 };
}
