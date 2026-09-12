import { useMemo, useRef } from "react";
import { PanResponder, View } from "react-native";
import Svg, { Circle, Defs, Path, RadialGradient, Stop } from "react-native-svg";

import { hexToHsv, hsvToHex } from "../lib/color.ts";

/**
 * Hue by angle, saturation by radius, value fixed at 1 — the classic HSV
 * wheel. react-native-svg has no conic gradient, so the wheel is approximated
 * with many solid pie-slice wedges (one per few degrees of hue) with a white
 * radial gradient laid on top to fade toward the center, which is the
 * standard trick for this without a raster image.
 */
const SIZE = 220;
const CENTER = SIZE / 2;
const RADIUS = SIZE / 2;
const WEDGES = 60;
const KNOB_RADIUS = 11;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

function wedgePath(index: number): string {
  const start = (index / WEDGES) * 360;
  const end = ((index + 1) / WEDGES) * 360;
  const x1 = CENTER + RADIUS * Math.cos(toRad(start));
  const y1 = CENTER + RADIUS * Math.sin(toRad(start));
  const x2 = CENTER + RADIUS * Math.cos(toRad(end));
  const y2 = CENTER + RADIUS * Math.sin(toRad(end));
  return `M ${CENTER} ${CENTER} L ${x1} ${y1} A ${RADIUS} ${RADIUS} 0 0 1 ${x2} ${y2} Z`;
}

export default function ColorWheel({ value, onChange }: { value: string; onChange: (hex: string) => void }) {
  const hsv = useMemo(() => hexToHsv(value), [value]);
  const wedges = useMemo(() => Array.from({ length: WEDGES }, (_, i) => i), []);

  const emit = (x: number, y: number) => {
    const dx = x - CENTER;
    const dy = y - CENTER;
    const dist = Math.min(Math.sqrt(dx * dx + dy * dy), RADIUS);
    let angle = (Math.atan2(dy, dx) * 180) / Math.PI;
    if (angle < 0) angle += 360;
    onChange(hsvToHex(angle, dist / RADIUS, 1));
  };

  const pan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (e) => emit(e.nativeEvent.locationX, e.nativeEvent.locationY),
      onPanResponderMove: (e) => emit(e.nativeEvent.locationX, e.nativeEvent.locationY),
    }),
  ).current;

  const knobAngle = toRad(hsv.h);
  const knobX = CENTER + hsv.s * RADIUS * Math.cos(knobAngle);
  const knobY = CENTER + hsv.s * RADIUS * Math.sin(knobAngle);

  return (
    <View style={{ width: SIZE, height: SIZE }} {...pan.panHandlers}>
      <Svg width={SIZE} height={SIZE}>
        <Defs>
          <RadialGradient id="centerFade" cx="50%" cy="50%" r="50%">
            <Stop offset="0%" stopColor="#fff" stopOpacity={1} />
            <Stop offset="100%" stopColor="#fff" stopOpacity={0} />
          </RadialGradient>
        </Defs>
        {wedges.map((i) => (
          <Path key={i} d={wedgePath(i)} fill={hsvToHex((i / WEDGES) * 360, 1, 1)} />
        ))}
        <Circle cx={CENTER} cy={CENTER} r={RADIUS} fill="url(#centerFade)" />
        <Circle cx={knobX} cy={knobY} r={KNOB_RADIUS} fill={value} stroke="#fff" strokeWidth={3} />
      </Svg>
    </View>
  );
}
