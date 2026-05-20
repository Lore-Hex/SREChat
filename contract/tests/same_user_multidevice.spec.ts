import { test, expect } from '@playwright/test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ADMIN_API_KEY =
  process.env.OPENCHAT_ADMIN_API_KEY || (TARGET_HOST.startsWith('localhost') ? 'local-api-key' : '');

async function loadSdk(page: any) {
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: sdkPath });
  await page.evaluate(
    async ({ appId, targetHost }) => {
      const { CometChat } = window as any;
      const settings = new CometChat.AppSettingsBuilder()
        .setRegion('us')
        .overrideClientHost(targetHost)
        .overrideAdminHost(targetHost)
        .autoEstablishSocketConnection(true)
        .build();
      await CometChat.init(appId, settings);
    },
    { appId: APP_ID, targetHost: TARGET_HOST },
  );
}

async function adminPost(request: any, path: string, data: any = {}) {
  const response = await request.post(`https://${TARGET_HOST}${path}`, {
    headers: { apiKey: ADMIN_API_KEY },
    data,
  });
  expect(response.ok(), `${path} failed: ${response.status()} ${await response.text()}`).toBeTruthy();
  return (await response.json()).data;
}

test('same user receives group messages live on a second SDK client', async ({ browser, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for user/group setup.');
  test.setTimeout(60_000);

  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const uid = `multi-device-${suffix}`;
  const room = `multi-device-room-${suffix}`;

  await adminPost(request, '/users', { uid, name: 'Multi Device User' });
  const auth = await adminPost(request, `/users/${uid}/auth_tokens`);
  await adminPost(request, '/groups', { guid: room, type: 'public' });

  const sender = await browser.newPage();
  const receiver = await browser.newPage();

  for (const page of [sender, receiver]) {
    await loadSdk(page);
    await page.evaluate(
      async ({ token, room }) => {
        const { CometChat } = window as any;
        await CometChat.login(token);
        try {
          await CometChat.joinGroup(room);
        } catch (e: any) {
          if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
        }
      },
      { token: auth.authToken, room },
    );
  }

  await receiver.evaluate(() => {
    const { CometChat } = window as any;
    (window as any).__receivedTexts = [];
    CometChat.addMessageListener(
      'SAME_USER_SECOND_CLIENT',
      new CometChat.MessageListener({
        onTextMessageReceived: (message: any) => {
          (window as any).__receivedTexts.push(message.getData?.()?.text);
        },
      }),
    );
  });

  await receiver.waitForTimeout(500);

  const text = `same-user-live-${Date.now()}`;
  await sender.evaluate(
    async ({ room, text }) => {
      const { CometChat } = window as any;
      await CometChat.sendMessage(new CometChat.TextMessage(room, text, 'group'));
    },
    { room, text },
  );

  await receiver.waitForFunction(
    ({ text }) => ((window as any).__receivedTexts || []).includes(text),
    { text },
    { timeout: 15_000 },
  );

  await receiver.evaluate(() => {
    const { CometChat } = window as any;
    CometChat.removeMessageListener('SAME_USER_SECOND_CLIENT');
  });

  await sender.close();
  await receiver.close();
});
