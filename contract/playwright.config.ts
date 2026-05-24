import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  workers: 1,
  use: {
    ignoreHTTPSErrors: true,
    launchOptions: {
      args: ['--no-proxy-server'],
    },
  },
});
