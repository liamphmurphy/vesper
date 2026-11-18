import { defineConfig, devices } from "@playwright/test";

// The chat spec mocks the REST API (e2e/mock-chat-api.ts), so only the static
// app (served by design-worker/server.ts) needs to run. Set E2E_BASE_URL to run against an already running stack.
const external = process.env.E2E_BASE_URL;

export default defineConfig({
  testDir: "./e2e",
  // Real-stack only (own fake-harness mode): e2e-stack/designs-review.spec.ts runs it.
  testIgnore: "**/designs-review.spec.ts",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: { baseURL: external ?? "http://localhost:3100", trace: "retain-on-failure" },
  projects: [
    // Desktop specs; *.mobile.spec.ts belong to the mobile project.
    { name: "chromium", testIgnore: ["**/designs-review.spec.ts", "**/*.mobile.spec.ts"], use: { ...devices["Desktop Chrome"] } },
    // Compact shell: iPhone 15 emulated on Chromium (CI installs only Chromium), at 390×844.
    {
      name: "mobile",
      testMatch: "**/*.mobile.spec.ts",
      use: { ...devices["iPhone 15"], defaultBrowserType: "chromium", viewport: { width: 390, height: 844 } },
    },
  ],
  webServer: external
    ? undefined
    : {
        command: "npm run build && node dist/design-worker/server.mjs",
        env: { STATIC_DIR: "dist", PORT: "3100" },
        url: "http://localhost:3100",
        reuseExistingServer: !process.env.CI,
        timeout: 240_000,
      },
});
