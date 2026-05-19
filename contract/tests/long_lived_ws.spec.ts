import { test, expect } from '@playwright/test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ADMIN_API_KEY =
  process.env.OPENCHAT_ADMIN_API_KEY || (TARGET_HOST.startsWith('localhost') ? 'local-api-key' : '');
const DURATION_MS = Number(process.env.OPENCHAT_WS_SOAK_MS || 10 * 60 * 1000);
const INTERVAL_MS = Number(process.env.OPENCHAT_WS_SOAK_INTERVAL_MS || 75 * 1000);

async function loadSdk(page: any, autoSocket = true) {
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: sdkPath });
  await page.evaluate(
    async ({ appId, targetHost, autoSocket }) => {
      const { CometChat } = window as any;
      const settings = new CometChat.AppSettingsBuilder()
        .setRegion('us')
        .overrideClientHost(targetHost)
        .overrideAdminHost(targetHost)
        .autoEstablishSocketConnection(autoSocket)
        .build();
      await CometChat.init(appId, settings);
    },
    { appId: APP_ID, targetHost: TARGET_HOST, autoSocket },
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

test('long-lived SDK websocket clients keep receiving room events after idle periods', async ({
  browser,
  request,
}) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user/group setup.');
  test.setTimeout(DURATION_MS + 90_000);

  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const aliceUid = `ws-soak-alice-${suffix}`;
  const bobUid = `ws-soak-bob-${suffix}`;
  const room = `ws-soak-room-${suffix}`;

  await adminPost(request, '/users', { uid: aliceUid, name: 'WS Soak Alice' });
  await adminPost(request, '/users', { uid: bobUid, name: 'WS Soak Bob' });
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);
  await adminPost(request, '/groups', { guid: room, type: 'public' });

  const alice = await browser.newPage();
  const bob = await browser.newPage();
  const aliceLogs: string[] = [];
  const bobLogs: string[] = [];
  alice.on('console', (msg) => aliceLogs.push(`${msg.type()}: ${msg.text()}`));
  bob.on('console', (msg) => bobLogs.push(`${msg.type()}: ${msg.text()}`));

  await loadSdk(alice, true);
  await loadSdk(bob, true);

  await bob.evaluate(
    async ({ token, room }) => {
      const { CometChat } = window as any;
      await CometChat.login(token);
      try {
        await CometChat.joinGroup(room);
      } catch (e: any) {
        if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
      }

      (window as any).__soak = {
        connection: [],
        events: [],
        startedAt: Date.now(),
      };
      const recordMessageEvent = (type: string, m: any) => {
        const data = m.getData?.() || m.data || {};
        const entity = data.entities?.on?.entity || m;
        const entityData = entity.getData?.() || entity.data || {};
        const metadata = entity.getMetadata?.() || entity.metadata || entityData.metadata || {};
        (window as any).__soak.events.push({
          type,
          id: String(entity.getId?.() || entity.id || m.getId?.() || m.id || ''),
          onId: String(data.entities?.on?.entity?.id || ''),
          text: entityData.text,
          reactions: metadata?.['@injected']?.extensions?.reactions || {},
          updatedAt: entity.getUpdatedAt?.() ?? entity.updatedAt,
          at: Date.now(),
        });
      };

      CometChat.addConnectionListener(
        'WS_SOAK_CONNECTION',
        new CometChat.ConnectionListener({
          onConnected: () => (window as any).__soak.connection.push({ type: 'connected', at: Date.now() }),
          onDisconnected: () =>
            (window as any).__soak.connection.push({ type: 'disconnected', at: Date.now() }),
        }),
      );

      CometChat.addMessageListener(
        'WS_SOAK_MESSAGES',
        new CometChat.MessageListener({
          onTextMessageReceived: (m: any) => recordMessageEvent('text', m),
          onMessageEdited: (m: any) => recordMessageEvent('edited', m),
          onMessageDeleted: (m: any) =>
            (window as any).__soak.events.push({
              type: 'deleted',
              id: String(m.getId()),
              onId: String(m.getData?.()?.entities?.on?.entity?.id || ''),
              at: Date.now(),
            }),
          onMessageReactionAdded: (reaction: any) =>
            (window as any).__soak.events.push({
              type: 'reaction-added',
              messageId: String(reaction.getMessageId?.() || reaction.messageId || ''),
              reaction: reaction.getReaction?.() || reaction.reaction,
              at: Date.now(),
            }),
        }),
      );
    },
    { token: bobAuth.authToken, room },
  );

  await alice.evaluate(
    async ({ token, room }) => {
      const { CometChat } = window as any;
      await CometChat.login(token);
      try {
        await CometChat.joinGroup(room);
      } catch (e: any) {
        if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
      }
      (window as any).__sent = [];
      (window as any).__soak = {
        connection: [],
        events: [],
        startedAt: Date.now(),
      };
      const recordMessageEvent = (type: string, m: any) => {
        const data = m.getData?.() || m.data || {};
        const entity = data.entities?.on?.entity || m;
        const entityData = entity.getData?.() || entity.data || {};
        const metadata = entity.getMetadata?.() || entity.metadata || entityData.metadata || {};
        (window as any).__soak.events.push({
          type,
          id: String(entity.getId?.() || entity.id || m.getId?.() || m.id || ''),
          text: entityData.text,
          reactions: metadata?.['@injected']?.extensions?.reactions || {},
          updatedAt: entity.getUpdatedAt?.() ?? entity.updatedAt,
          at: Date.now(),
        });
      };

      CometChat.addConnectionListener(
        'WS_SOAK_ALICE_CONNECTION',
        new CometChat.ConnectionListener({
          onConnected: () => (window as any).__soak.connection.push({ type: 'connected', at: Date.now() }),
          onDisconnected: () =>
            (window as any).__soak.connection.push({ type: 'disconnected', at: Date.now() }),
        }),
      );

      CometChat.addMessageListener(
        'WS_SOAK_ALICE_MESSAGES',
        new CometChat.MessageListener({
          onTextMessageReceived: (m: any) => recordMessageEvent('text', m),
          onMessageEdited: (m: any) => recordMessageEvent('edited', m),
        }),
      );
    },
    { token: aliceAuth.authToken, room },
  );

  await bob.waitForTimeout(1500);

  const iterations = Math.max(2, Math.floor(DURATION_MS / INTERVAL_MS) + 1);
  const sent: Array<{ id: string; text: string }> = [];
  let reactedMessage: { id: string; text: string } | null = null;

  for (let i = 0; i < iterations; i += 1) {
    if (i > 0) {
      await bob.waitForTimeout(INTERVAL_MS);
    }

    const message = await alice.evaluate(
      async ({ room, i }) => {
        const { CometChat } = window as any;
        const text = `ws-soak-${i}-${Date.now()}`;
        const sent = await CometChat.sendMessage(new CometChat.TextMessage(room, text, 'group'));
        const item = { id: String(sent.getId()), text };
        (window as any).__sent.push(item);
        return item;
      },
      { room, i },
    );
    sent.push(message);

    await bob.waitForFunction(
      ({ text }) => ((window as any).__soak.events || []).some((e: any) => e.type === 'text' && e.text === text),
      { text: message.text },
      { timeout: 30_000 },
    );

    if (i === Math.floor(iterations / 2)) {
      reactedMessage = message;

      await bob.evaluate(async (messageId) => {
        const { CometChat } = window as any;
        await CometChat.callExtension('reactions', 'POST', 'v1/react', {
          msgId: messageId,
          emoji: '🎧',
        });
      }, message.id);

      await alice.waitForFunction(
        ({ messageId, bobUid }) =>
          ((window as any).__soak.events || []).some(
            (e: any) =>
              e.type === 'edited' && e.id === String(messageId) && e.reactions?.['🎧']?.[bobUid]?.name,
          ),
        { messageId: message.id, bobUid },
        { timeout: 30_000 },
      );
    }
  }

  const deleteTarget = sent[0];
  await alice.evaluate(async (messageId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(messageId);
  }, deleteTarget.id);

  await bob.waitForFunction(
    ({ messageId }) =>
      ((window as any).__soak.events || []).some((e: any) => e.type === 'deleted' && e.id === String(messageId)),
    { messageId: deleteTarget.id },
    { timeout: 30_000 },
  );

  const result = await bob.evaluate(
    async ({ room, expectedTexts }) => {
      const { CometChat } = window as any;
      const events = (window as any).__soak.events || [];
      const req = new CometChat.MessagesRequestBuilder().setGUID(room).setLimit(100).build();
      const history = await req.fetchPrevious();
      return {
        connection: (window as any).__soak.connection || [],
        eventTexts: events.filter((e: any) => e.type === 'text').map((e: any) => e.text),
        deletedIds: events.filter((e: any) => e.type === 'deleted').map((e: any) => String(e.id)),
        reactionEvents: events.filter((e: any) => e.type === 'reaction-added'),
        reactedUpdates: events.filter((e: any) => e.reactions?.['🎧']),
        history: history
          .map((m: any) => ({
            id: String(m.getId()),
            text: m.getData?.()?.text,
            category: m.getCategory?.(),
            action: m.getData?.()?.action,
            onId: String(m.getData?.()?.entities?.on?.entity?.id || ''),
          }))
          .filter((m: any) => expectedTexts.includes(m.text) || expectedTexts.includes(m.onId)),
      };
    },
    { room, expectedTexts: sent.map((m) => m.text) },
  );

  expect(result.eventTexts).toEqual(expect.arrayContaining(sent.map((m) => m.text)));
  expect(result.deletedIds).toContain(deleteTarget.id);
  expect(result.connection.filter((e: any) => e.type === 'disconnected')).toEqual([]);
  expect(reactedMessage).toBeTruthy();

  const historyTexts = result.history.map((m: any) => m.text).filter(Boolean);
  expect(historyTexts).toEqual(expect.arrayContaining(sent.slice(1).map((m) => m.text)));
  expect(historyTexts).not.toContain(deleteTarget.text);

  const aliceResult = await alice.evaluate(() => ({
    connection: (window as any).__soak.connection || [],
    reactedUpdates: ((window as any).__soak.events || []).filter((e: any) => e.reactions?.['🎧']),
  }));
  expect(aliceResult.connection.filter((e: any) => e.type === 'disconnected')).toEqual([]);
  expect(
    aliceResult.reactedUpdates.some(
      (e: any) =>
        e.type === 'edited' && e.id === reactedMessage!.id && e.reactions?.['🎧']?.[bobUid]?.name,
    ),
  ).toBe(true);

  await bob.evaluate(() => {
    const { CometChat } = window as any;
    CometChat.removeMessageListener('WS_SOAK_MESSAGES');
    CometChat.removeConnectionListener('WS_SOAK_CONNECTION');
  });
  await alice.evaluate(() => {
    const { CometChat } = window as any;
    CometChat.removeMessageListener('WS_SOAK_ALICE_MESSAGES');
    CometChat.removeConnectionListener('WS_SOAK_ALICE_CONNECTION');
  });

  await alice.close();
  await bob.close();

  console.log(
    JSON.stringify(
      {
        target: TARGET_HOST,
        durationMs: DURATION_MS,
        intervalMs: INTERVAL_MS,
        iterations,
        sent: sent.length,
        eventTexts: result.eventTexts.length,
        disconnects: result.connection.filter((e: any) => e.type === 'disconnected').length,
        reactionUpdates: aliceResult.reactedUpdates.length,
        aliceLogs,
        bobLogs,
      },
      null,
      2,
    ),
  );
});
