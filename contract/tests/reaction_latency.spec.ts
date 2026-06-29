import { test, expect } from '@playwright/test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ADMIN_API_KEY =
  process.env.OPENCHAT_ADMIN_API_KEY || (TARGET_HOST.startsWith('localhost') ? 'local-api-key' : '');
const MESSAGE_COUNT = Number(process.env.OPENCHAT_LATENCY_MESSAGES || 30);
const MAX_MESSAGE_LATENCY_MS = Number(process.env.OPENCHAT_MAX_MESSAGE_LATENCY_MS || 5000);
const MAX_REACTION_LATENCY_MS = Number(process.env.OPENCHAT_MAX_REACTION_LATENCY_MS || 5000);
const MAX_BOT_MESSAGE_LATENCY_MS = Number(process.env.OPENCHAT_MAX_BOT_MESSAGE_LATENCY_MS || 2500);

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

async function userPost(request: any, token: string, path: string, data: any = {}) {
  const response = await request.post(`https://${TARGET_HOST}${path}`, {
    headers: {
      authtoken: token,
      origin: 'https://tt.live',
      referer: 'https://tt.live/',
      sdk: 'javascript@3.0.10',
    },
    data,
  });
  expect(response.ok(), `${path} failed: ${response.status()} ${await response.text()}`).toBeTruthy();
  return (await response.json()).data;
}

function percentile(values: number[], p: number) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p))] || 0;
}

test('staging SDK room messages and reactions arrive quickly across two browser clients', async ({
  browser,
  request,
}) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user/group setup.');
  test.setTimeout(Math.max(120_000, MESSAGE_COUNT * 10_000));

  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const aliceUid = `latency-alice-${suffix}`;
  const bobUid = `latency-bob-${suffix}`;
  const room = `latency-room-${suffix}`;

  await adminPost(request, '/users', { uid: aliceUid, name: 'Latency Alice' });
  await adminPost(request, '/users', { uid: bobUid, name: 'Latency Bob' });
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);
  await adminPost(request, '/groups', { guid: room, type: 'public' });

  const alice = await browser.newPage();
  const bob = await browser.newPage();
  const aliceLogs: string[] = [];
  const bobLogs: string[] = [];
  alice.on('console', (msg) => aliceLogs.push(`${msg.type()}: ${msg.text()}`));
  bob.on('console', (msg) => bobLogs.push(`${msg.type()}: ${msg.text()}`));

  for (const [page, token, listenerId] of [
    [alice, aliceAuth.authToken, 'ALICE_LATENCY'],
    [bob, bobAuth.authToken, 'BOB_LATENCY'],
  ] as const) {
    await loadSdk(page);
    await page.evaluate(
      async ({ token, room, listenerId }) => {
        const { CometChat } = window as any;
        await CometChat.login(token);
        try {
          await CometChat.joinGroup(room);
        } catch (e: any) {
          if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
        }

        (window as any).__latencyEvents = [];
        (window as any).__connectionEvents = [];
        const recordMessageEvent = (type: string, m: any) => {
          const data = m.getData?.() || m.data || {};
          const entity = data.entities?.on?.entity || m;
          const entityData = entity.getData?.() || entity.data || {};
          const metadata = entity.getMetadata?.() || entity.metadata || entityData.metadata || {};
          (window as any).__latencyEvents.push({
            type,
            id: String(entity.getId?.() || entity.id || m.getId?.() || m.id || ''),
            text: entityData.text,
            reactions: metadata?.['@injected']?.extensions?.reactions || {},
            updatedAt: entity.getUpdatedAt?.() ?? entity.updatedAt,
            at: Date.now(),
          });
        };

        CometChat.addConnectionListener(
          `${listenerId}_CONNECTION`,
          new CometChat.ConnectionListener({
            onConnected: () => (window as any).__connectionEvents.push({ type: 'connected', at: Date.now() }),
            onDisconnected: () =>
              (window as any).__connectionEvents.push({ type: 'disconnected', at: Date.now() }),
          }),
        );

        CometChat.addMessageListener(
          `${listenerId}_MESSAGES`,
          new CometChat.MessageListener({
            onTextMessageReceived: (m: any) => recordMessageEvent('text', m),
            onMessageEdited: (m: any) => recordMessageEvent('edited', m),
            onMessageDeleted: (m: any) =>
              (window as any).__latencyEvents.push({
                type: 'deleted',
                id: String(m.getId()),
                at: Date.now(),
              }),
          }),
        );
      },
      { token, room, listenerId },
    );
  }

  await bob.waitForTimeout(1500);

  const sent: Array<{ id: string; text: string; startedAt: number; completedAt: number }> = [];
  const messageLatencies: number[] = [];
  const reactionLatencies: number[] = [];

  for (let i = 0; i < MESSAGE_COUNT; i += 1) {
    const startedAt = Date.now();
    const message = await alice.evaluate(
      async ({ room, i, startedAt }) => {
        const { CometChat } = window as any;
        const text = `latency-${i}-${startedAt}`;
        const sent = await CometChat.sendMessage(new CometChat.TextMessage(room, text, 'group'));
        return { id: String(sent.getId()), text };
      },
      { room, i, startedAt },
    );

    const completedAt = Date.now();
    sent.push({ ...message, startedAt, completedAt });

    await bob.waitForFunction(
      ({ text }) => ((window as any).__latencyEvents || []).some((e: any) => e.type === 'text' && e.text === text),
      { text: message.text },
      { timeout: 15_000 },
    );

    const receivedAt = await bob.evaluate((text) => {
      const event = ((window as any).__latencyEvents || []).find((e: any) => e.type === 'text' && e.text === text);
      return event?.at;
    }, message.text);
    messageLatencies.push(receivedAt - startedAt);

    if (i % 5 === 0) {
      const reactionStart = Date.now();
      await bob.evaluate(async (messageId) => {
        const { CometChat } = window as any;
        await CometChat.callExtension('reactions', 'POST', 'v1/react', {
          msgId: messageId,
          emoji: '🎧',
        });
      }, message.id);

      await alice.waitForFunction(
        ({ messageId, bobUid }) =>
          ((window as any).__latencyEvents || []).some(
            (e: any) =>
              e.type === 'edited' && e.id === String(messageId) && e.reactions?.['🎧']?.[bobUid]?.name,
          ),
        { messageId: message.id, bobUid },
        { timeout: 15_000 },
      );

      const reactionAt = await alice.evaluate(({ messageId, bobUid }) => {
        const event = ((window as any).__latencyEvents || []).find(
          (e: any) =>
            e.type === 'edited' && e.id === String(messageId) && e.reactions?.['🎧']?.[bobUid]?.name,
        );
        return event?.at;
      }, { messageId: message.id, bobUid });
      reactionLatencies.push(reactionAt - reactionStart);
    }
  }

  const target = sent[Math.floor(sent.length / 2)];
  await alice.evaluate(async (messageId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(messageId);
  }, target.id);

  await bob.waitForFunction(
    ({ messageId }) =>
      ((window as any).__latencyEvents || []).some((e: any) => e.type === 'deleted' && e.id === String(messageId)),
    { messageId: target.id },
    { timeout: 15_000 },
  );

  const bobState = await bob.evaluate(async ({ room, expectedTexts }) => {
    const { CometChat } = window as any;
    const req = new CometChat.MessagesRequestBuilder().setGUID(room).setLimit(100).build();
    const history: any[] = [];
    while (history.length < expectedTexts.length) {
      const page = await req.fetchPrevious();
      if (!page?.length) break;
      history.push(...page);
      if (page.length < 100) break;
    }

    return {
      disconnects: ((window as any).__connectionEvents || []).filter((e: any) => e.type === 'disconnected'),
      texts: ((window as any).__latencyEvents || [])
        .filter((e: any) => e.type === 'text')
        .map((e: any) => e.text),
      historyTexts: history
        .map((m: any) => m.getData?.()?.text)
        .filter((text: any) => expectedTexts.includes(text)),
    };
  }, { room, expectedTexts: sent.map((m) => m.text) });

  const aliceState = await alice.evaluate(() => ({
    disconnects: ((window as any).__connectionEvents || []).filter((e: any) => e.type === 'disconnected'),
  }));

  const summary = {
    target: TARGET_HOST,
    messages: MESSAGE_COUNT,
    messageLatencyMs: {
      max: Math.max(...messageLatencies),
      p50: percentile(messageLatencies, 0.5),
      p95: percentile(messageLatencies, 0.95),
      all: messageLatencies,
    },
    reactionLatencyMs: {
      max: Math.max(...reactionLatencies),
      p50: percentile(reactionLatencies, 0.5),
      p95: percentile(reactionLatencies, 0.95),
      all: reactionLatencies,
    },
    bobDisconnects: bobState.disconnects.length,
    aliceDisconnects: aliceState.disconnects.length,
    bobTextEvents: bobState.texts.length,
    historyTexts: bobState.historyTexts.length,
    aliceLogs,
    bobLogs,
  };

  console.log(JSON.stringify(summary, null, 2));

  expect(bobState.texts).toEqual(expect.arrayContaining(sent.map((m) => m.text)));
  expect(bobState.historyTexts).toEqual(expect.arrayContaining(sent.filter((m) => m.id !== target.id).map((m) => m.text)));
  expect(bobState.historyTexts).not.toContain(target.text);
  expect(bobState.disconnects).toEqual([]);
  expect(aliceState.disconnects).toEqual([]);
  expect(Math.max(...messageLatencies)).toBeLessThan(MAX_MESSAGE_LATENCY_MS);
  expect(Math.max(...reactionLatencies)).toBeLessThan(MAX_REACTION_LATENCY_MS);

  await alice.close();
  await bob.close();
});

test('bot-style REST group replies arrive quickly on live SDK clients', async ({ browser, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user/group setup.');
  test.setTimeout(Math.max(90_000, MESSAGE_COUNT * 10_000));

  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const botUid = `latency-bot-${suffix}`;
  const aliceUid = `latency-bot-alice-${suffix}`;
  const bobUid = `latency-bot-bob-${suffix}`;
  const room = `latency-bot-room-${suffix}`;

  await adminPost(request, '/users', { uid: botUid, name: 'Latency Bot' });
  await adminPost(request, '/users', { uid: aliceUid, name: 'Latency Bot Alice' });
  await adminPost(request, '/users', { uid: bobUid, name: 'Latency Bot Bob' });
  const botAuth = await adminPost(request, `/users/${botUid}/auth_tokens`);
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);
  await adminPost(request, '/groups', { guid: room, type: 'public' });

  await userPost(request, botAuth.authToken, `/groups/${room}/members`, {
    participants: [botUid],
    participantType: 'user',
  });

  const alice = await browser.newPage();
  const bob = await browser.newPage();
  const pages = [
    { page: alice, token: aliceAuth.authToken, listenerId: 'BOT_REST_ALICE' },
    { page: bob, token: bobAuth.authToken, listenerId: 'BOT_REST_BOB' },
  ];

  for (const { page, token, listenerId } of pages) {
    await loadSdk(page);
    await page.evaluate(
      async ({ token, room, listenerId }) => {
        const { CometChat } = window as any;
        await CometChat.login(token);
        try {
          await CometChat.joinGroup(room);
        } catch (e: any) {
          if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
        }

        (window as any).__botRestEvents = [];
        (window as any).__connectionEvents = [];

        CometChat.addConnectionListener(
          `${listenerId}_CONNECTION`,
          new CometChat.ConnectionListener({
            onConnected: () => (window as any).__connectionEvents.push({ type: 'connected', at: Date.now() }),
            onDisconnected: () =>
              (window as any).__connectionEvents.push({ type: 'disconnected', at: Date.now() }),
          }),
        );

        CometChat.addMessageListener(
          `${listenerId}_MESSAGES`,
          new CometChat.MessageListener({
            onTextMessageReceived: (m: any) => {
              const data = m.getData?.() || m.data || {};
              (window as any).__botRestEvents.push({
                id: String(m.getId?.() || m.id || ''),
                text: data.text,
                chatMessage: data.metadata?.chatMessage,
                sender: m.getSender?.()?.getUid?.() || m.sender?.uid || '',
                at: Date.now(),
              });
            },
          }),
        );
      },
      { token, room, listenerId },
    );
  }

  await bob.waitForTimeout(1500);

  const sendResults: Array<{
    text: string;
    startedAt: number;
    responseAt: number;
    aliceLatency: number;
    bobLatency: number;
  }> = [];

  for (let i = 0; i < MESSAGE_COUNT; i += 1) {
    const startedAt = Date.now();
    const text = `!status bot-rest-reply-${i}-${startedAt}`;

    await userPost(request, botAuth.authToken, '/messages', {
      receiver: room,
      receiverType: 'group',
      category: 'message',
      type: 'text',
      data: {
        text,
        metadata: {
          chatMessage: {
            message: text,
            avatarId: 'bot-01',
            userName: 'Latency Bot',
            color: '#ff9900',
            mentions: [],
            userUuid: botUid,
            badges: ['VERIFIED', 'STAFF'],
            id: `bot-rest-${i}-${startedAt}`,
          },
        },
      },
    });
    const responseAt = Date.now();

    for (const { page } of pages) {
      await page.waitForFunction(
        ({ text }) => ((window as any).__botRestEvents || []).some((e: any) => e.text === text),
        { text },
        { timeout: 15_000 },
      );
    }

    const [aliceAt, bobAt] = await Promise.all(
      pages.map(({ page }) =>
        page.evaluate((text) => {
          const event = ((window as any).__botRestEvents || []).find((e: any) => e.text === text);
          return event?.at;
        }, text),
      ),
    );

    sendResults.push({
      text,
      startedAt,
      responseAt,
      aliceLatency: aliceAt - startedAt,
      bobLatency: bobAt - startedAt,
    });
  }

  const aliceState = await alice.evaluate(() => ({
    disconnects: ((window as any).__connectionEvents || []).filter((e: any) => e.type === 'disconnected'),
    events: (window as any).__botRestEvents || [],
  }));
  const bobState = await bob.evaluate(() => ({
    disconnects: ((window as any).__connectionEvents || []).filter((e: any) => e.type === 'disconnected'),
    events: (window as any).__botRestEvents || [],
  }));

  const latencies = sendResults.flatMap((result) => [result.aliceLatency, result.bobLatency]);
  const responseLatencies = sendResults.map((result) => result.responseAt - result.startedAt);
  const summary = {
    target: TARGET_HOST,
    messages: sendResults.length,
    responseLatencyMs: {
      max: Math.max(...responseLatencies),
      p50: percentile(responseLatencies, 0.5),
      p95: percentile(responseLatencies, 0.95),
      all: responseLatencies,
    },
    botRestDeliveryLatencyMs: {
      max: Math.max(...latencies),
      p50: percentile(latencies, 0.5),
      p95: percentile(latencies, 0.95),
      all: latencies,
    },
    aliceDisconnects: aliceState.disconnects.length,
    bobDisconnects: bobState.disconnects.length,
    aliceEvents: aliceState.events.length,
    bobEvents: bobState.events.length,
  };

  console.log(JSON.stringify(summary, null, 2));

  expect(aliceState.disconnects).toEqual([]);
  expect(bobState.disconnects).toEqual([]);
  expect(aliceState.events.map((e: any) => e.text)).toEqual(expect.arrayContaining(sendResults.map((r) => r.text)));
  expect(bobState.events.map((e: any) => e.text)).toEqual(expect.arrayContaining(sendResults.map((r) => r.text)));
  expect(Math.max(...latencies)).toBeLessThan(MAX_BOT_MESSAGE_LATENCY_MS);

  await alice.close();
  await bob.close();
});
