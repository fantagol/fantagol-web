import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "app.fantagol.android",
  appName: "FantaGol",
  webDir: "android-shell",
  server: {
    url: "https://fantagol.app/leghe",
    cleartext: false,
    androidScheme: "https",
  },
  android: {
    allowMixedContent: false,
  },
};

export default config;
