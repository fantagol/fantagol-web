import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "app.fantagol.android",
  appName: "FantaGol",
  webDir: "out",

  server: {
    url: "https://www.fantagol.app/leghe?fantagol_app=android",
    cleartext: false,
    allowNavigation: [
      "fantagol.app",
      "www.fantagol.app",
    ],
  },
};

export default config;
