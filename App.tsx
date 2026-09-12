import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";
import TimerScreen from "./src/screens/TimerScreen.tsx";

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="auto" />
      <TimerScreen />
    </SafeAreaProvider>
  );
}
