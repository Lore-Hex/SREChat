import { test, expect } from '@playwright/test';
import Module, { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const jsSdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ADMIN_API_KEY =
  process.env.OPENCHAT_ADMIN_API_KEY || (TARGET_HOST.startsWith('localhost') ? 'local-api-key' : '');
const DM_MESSAGE_COUNT = Number(process.env.OPENCHAT_RN_DM_MESSAGES || 12);
const GROUP_MESSAGE_COUNT = Number(process.env.OPENCHAT_RN_GROUP_MESSAGES || 12);
const MAX_LIVE_LATENCY_MS = Number(process.env.OPENCHAT_RN_MAX_LIVE_LATENCY_MS || 5000);

const asyncStore = new Map<string, string>();

function installReactNativeNodeShims() {
  const globalAny = globalThis as any;
  globalAny.window ||= { location: { origin: 'https://localhost' } };
  globalAny.window.navigator ||= { userAgent: 'openchat-rn-contract' };
  globalAny.WebSocket ||= WebSocket;
  globalAny.__DEV__ = false;

  try {
    Object.defineProperty(globalAny, 'navigator', {
      value: { userAgent: 'openchat-rn-contract' },
      configurable: true,
    });
  } catch {
    // Some Node versions already expose navigator.
  }

  if (!globalAny.__openChatFetchPatched) {
    const nativeFetch = globalAny.fetch.bind(globalAny);
    globalAny.fetch = async (...args: any[]) => {
      if (args[1]?.referrer === 'no-referrer') {
        args[1] = { ...args[1] };
        delete args[1].referrer;
      }
      return nativeFetch(...args);
    };
    globalAny.__openChatFetchPatched = true;
  }

  if (globalAny.__openChatRnModulePatchInstalled) return;

  const originalLoad = (Module as any)._load;
  (Module as any)._load = function patchedLoad(request: string, parent: unknown, isMain: boolean) {
    if (request === '@react-native-async-storage/async-storage') {
      return {
        default: {
          async setItem(key: string, value: string) {
            asyncStore.set(key, value);
          },
          async getItem(key: string) {
            return asyncStore.has(key) ? asyncStore.get(key) : null;
          },
          async removeItem(key: string) {
            asyncStore.delete(key);
          },
          async getAllKeys() {
            return Array.from(asyncStore.keys());
          },
        },
      };
    }

    if (request === 'react-native') {
      return {
        AppState: {
          currentState: 'active',
          addEventListener() {
            return { remove() {} };
          },
        },
        Dimensions: {
          get() {
            return { width: 390, height: 844 };
          },
        },
        NativeModules: {},
        Platform: {
          OS: 'ios',
          select(values: Record<string, unknown>) {
            return values.ios || values.default;
          },
        },
      };
    }

    if (request === 'react') {
      class Component {}
      return {
        Component,
        PureComponent: Component,
        createContext() {
          return { Provider: Component, Consumer: Component };
        },
        createElement() {
          return null;
        },
      };
    }

    return originalLoad.apply(this, [request, parent, isMain]);
  };

  globalAny.__openChatRnModulePatchInstalled = true;
}

async function loadWebSdk(page: any, token: string) {
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: jsSdkPath });
  await page.evaluate(
    async ({ appId, targetHost, token }) => {
      const { CometChat } = window as any;
      const settings = new CometChat.AppSettingsBuilder()
        .setRegion('us')
        .overrideClientHost(targetHost)
        .overrideAdminHost(targetHost)
        .autoEstablishSocketConnection(true)
        .build();
      await CometChat.init(appId, settings);
      await CometChat.login(token);

      (window as any).__openChatEvents = [];
      const snapshot = (kind: string, message: any) => {
        const data = message.getData?.() || message.data || {};
        const entity = data.entities?.on?.entity || message;
        const entityData = entity.getData?.() || entity.data || {};
        const metadata = entity.getMetadata?.() || entity.metadata || entityData.metadata || {};
        (window as any).__openChatEvents.push({
          kind,
          id: String(entity.getId?.() || entity.id || message.getId?.() || message.id || ''),
          text: entityData.text,
          reactions: metadata?.['@injected']?.extensions?.reactions || {},
          updatedAt: entity.getUpdatedAt?.() ?? entity.updatedAt,
          sender: entity.getSender?.()?.getUid?.() || entity.sender?.uid || entity.sender,
          receiverId: entity.getReceiverId?.() || entity.receiver,
          receiverType: entity.getReceiverType?.() || entity.receiverType,
          at: Date.now(),
        });
      };
      const reactionSnapshot = (kind: string, reaction: any) => {
        const rawReaction = reaction.getReaction?.() || reaction.reaction;
        (window as any).__openChatEvents.push({
          kind,
          messageId: String(reaction.getMessageId?.() || reaction.messageId || rawReaction?.messageId || ''),
          reaction: typeof rawReaction === 'string' ? rawReaction : rawReaction?.reaction,
          at: Date.now(),
        });
      };

      CometChat.addMessageListener(
        'OPENCHAT_RN_CONTRACT_WEB',
        new CometChat.MessageListener({
          onTextMessageReceived: (message: any) => snapshot('text', message),
          onMessageEdited: (message: any) => snapshot('edited', message),
          onMessageReactionAdded: (reaction: any) => reactionSnapshot('reaction-added', reaction),
          onMessageReactionRemoved: (reaction: any) => reactionSnapshot('reaction-removed', reaction),
        }),
      );
    },
    { appId: APP_ID, targetHost: TARGET_HOST, token },
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

function reactionValue(reaction: any) {
  const rawReaction = reaction?.getReaction?.() || reaction?.reaction;
  return typeof rawReaction === 'string' ? rawReaction : rawReaction?.reaction;
}

function reactionMessageId(reaction: any) {
  const rawReaction = reaction?.getReaction?.() || reaction?.reaction;
  return String(reaction?.getMessageId?.() || reaction?.messageId || rawReaction?.messageId || '');
}

function recordRnEvent(events: any[], kind: string, message: any, cometChat: any) {
  const data = message?.getData?.() || message?.data || {};
  const entity = data.entities?.on?.entity || message;
  const entityData = entity?.getData?.() || entity?.data || {};
  const metadata = entity?.getMetadata?.() || entity?.metadata || entityData.metadata || {};
  const receiver = entity?.getReceiver?.() || entity?.receiver || message?.getReceiver?.();
  const sender = entity?.getSender?.() || entity?.sender || message?.getSender?.();
  events.push({
    kind,
    id: String(entity?.getId?.() || entity?.id || message?.getId?.() || message?.id || ''),
    text: entityData.text,
    reactions: metadata?.['@injected']?.extensions?.reactions || {},
    updatedAt: entity?.getUpdatedAt?.() ?? entity?.updatedAt,
    sender: sender?.getUid?.() || sender?.uid || sender,
    receiverId: entity?.getReceiverId?.() || entity?.receiver,
    receiverType: entity?.getReceiverType?.() || entity?.receiverType,
    receiverUid: receiver?.getUid?.() || receiver?.uid,
    receiverGuid: receiver?.getGuid?.() || receiver?.guid,
    receiverClass: receiver?.constructor?.name,
    receiverIsGroup: cometChat?.Group ? receiver instanceof cometChat.Group : false,
    receiverIsUser: cometChat?.User ? receiver instanceof cometChat.User : false,
    at: Date.now(),
  });
}

async function waitFor(predicate: () => boolean | Promise<boolean>, timeoutMs = 10_000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (await predicate()) return Date.now();
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return null;
}

test('real React Native SDK DMs and reactions stay live and durable across web and mobile', async ({
  browser,
  request,
}) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user/group setup.');
  test.setTimeout(120_000);
  installReactNativeNodeShims();

  const { CometChat: RNCometChat } = require('@cometchat/chat-sdk-react-native');
  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const aliceUid = `rn-contract-alice-${suffix}`;
  const bobUid = `rn-contract-bob-${suffix}`;
  const room = `rn-contract-room-${suffix}`;

  await adminPost(request, '/users', {
    uid: aliceUid,
    name: 'RN Contract Alice',
  });
  await adminPost(request, '/users', { uid: bobUid, name: 'RN Contract Bob' });
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);
  await adminPost(request, '/groups', {
    guid: room,
    name: 'RN Contract Room',
    type: 'public',
  });
  await adminPost(request, `/groups/${room}/members`, {
    participants: [aliceUid, bobUid],
  });

  const web = await browser.newPage();
  await loadWebSdk(web, aliceAuth.authToken);

  const rnSettings = new RNCometChat.AppSettingsBuilder()
    .subscribePresenceForAllUsers()
    .setRegion('us')
    .overrideClientHost(TARGET_HOST)
    .overrideAdminHost(TARGET_HOST.replace(/\/v3\.0$/, '/v3'))
    .autoEstablishSocketConnection(true)
    .build();
  await RNCometChat.init(APP_ID, rnSettings);
  await RNCometChat.login(bobAuth.authToken);
  try {
    await RNCometChat.joinGroup(room);
  } catch (e: any) {
    if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
  }

  const rnEvents: any[] = [];
  RNCometChat.addMessageListener(
    `OPENCHAT_RN_CONTRACT_${suffix}`,
    new RNCometChat.MessageListener({
      onTextMessageReceived: (message: any) => recordRnEvent(rnEvents, 'text', message, RNCometChat),
      onMessageEdited: (message: any) => recordRnEvent(rnEvents, 'edited', message, RNCometChat),
      onMessageReactionAdded: (reaction: any) =>
        rnEvents.push({
          kind: 'reaction-added',
          messageId: reactionMessageId(reaction),
          reaction: reactionValue(reaction),
          at: Date.now(),
        }),
      onMessageReactionRemoved: (reaction: any) =>
        rnEvents.push({
          kind: 'reaction-removed',
          messageId: reactionMessageId(reaction),
          reaction: reactionValue(reaction),
          at: Date.now(),
        }),
    }),
  );

  await web.waitForTimeout(1500);

  const dmLatencies: number[] = [];
  const dmTexts: string[] = [];

  for (let i = 0; i < DM_MESSAGE_COUNT; i += 1) {
    const text = `rn-dm-${i}-${suffix}`;
    dmTexts.push(text);
    const startedAt = Date.now();

    if (i % 2 === 0) {
      await web.evaluate(
        async ({ bobUid, text }) => {
          const { CometChat } = window as any;
          await CometChat.sendMessage(new CometChat.TextMessage(bobUid, text, 'user'));
        },
        { bobUid, text },
      );
      const seenAt = await waitFor(() => rnEvents.some((event) => event.kind === 'text' && event.text === text));
      expect(seenAt, `RN did not receive web DM ${text}`).toBeTruthy();
      const dmEvent = rnEvents.find((event) => event.kind === 'text' && event.text === text);
      expect(dmEvent).toMatchObject({
        sender: aliceUid,
        receiverId: bobUid,
        receiverType: 'user',
        receiverUid: bobUid,
        receiverIsUser: true,
      });
      dmLatencies.push(Number(seenAt) - startedAt);
    } else {
      await RNCometChat.sendMessage(new RNCometChat.TextMessage(aliceUid, text, 'user'));
      const seenAt = await waitFor(() =>
        web.evaluate(
          (expected) =>
            ((window as any).__openChatEvents || []).some(
              (event: any) => event.kind === 'text' && event.text === expected,
            ),
          text,
        ),
      );
      expect(seenAt, `web did not receive RN DM ${text}`).toBeTruthy();
      dmLatencies.push(Number(seenAt) - startedAt);
    }
  }

  const dmHistory = await web.evaluate(
    async ({ bobUid, expectedCount }) => {
      const { CometChat } = window as any;
      const req = new CometChat.MessagesRequestBuilder()
        .setUID(bobUid)
        .setLimit(expectedCount + 10)
        .build();
      const messages = await req.fetchPrevious();
      return messages.map((message: any) => message.getData?.()?.text).filter(Boolean);
    },
    { bobUid, expectedCount: dmTexts.length },
  );
  expect(dmHistory).toEqual(expect.arrayContaining(dmTexts));

  await web.evaluate(
    async ({ room }) => {
      const { CometChat } = window as any;
      try {
        await CometChat.joinGroup(room);
      } catch (e: any) {
        if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
      }
    },
    { room },
  );
  await web.waitForTimeout(1000);

  const groupMessages: Array<{
    id: string;
    text: string;
    updatedAt: number;
    reacted: boolean;
  }> = [];
  const reactionLatencies: number[] = [];

  for (let i = 0; i < GROUP_MESSAGE_COUNT; i += 1) {
    const text = `rn-group-${i}-${suffix}`;
    const message = await web.evaluate(
      async ({ room, text }) => {
        const { CometChat } = window as any;
        const sent = await CometChat.sendMessage(new CometChat.TextMessage(room, text, 'group'));
        return {
          id: String(sent.getId()),
          text: sent.getData?.()?.text,
          updatedAt: sent.getUpdatedAt?.() ?? sent.updatedAt,
        };
      },
      { room, text },
    );
    groupMessages.push({ ...message, reacted: i % 2 === 0 });

    const rnTextSeen = await waitFor(() => rnEvents.some((event) => event.kind === 'text' && event.text === text));
    expect(rnTextSeen, `RN did not receive group text ${text}`).toBeTruthy();
    const groupEvent = rnEvents.find((event) => event.kind === 'text' && event.text === text);
    expect(groupEvent).toMatchObject({
      sender: aliceUid,
      receiverId: room,
      receiverType: 'group',
      receiverGuid: room,
      receiverIsGroup: true,
    });

    if (i % 2 === 0) {
      const startedAt = Date.now();
      await RNCometChat.callExtension('reactions', 'POST', 'v1/react', {
        msgId: message.id,
        emoji: '🎧',
      });

      const editedAt = await waitFor(() =>
        web.evaluate(
          ({ messageId, bobUid }) =>
            ((window as any).__openChatEvents || []).some(
              (event: any) =>
                event.kind === 'edited' && event.id === messageId && event.reactions?.['🎧']?.[bobUid]?.name,
            ),
          { messageId: message.id, bobUid },
        ),
      );
      expect(editedAt, `web did not receive RN reaction edit for ${message.id}`).toBeTruthy();
      reactionLatencies.push(Number(editedAt) - startedAt);
    }
  }

  const groupHistory = await web.evaluate(
    async ({ room, expectedCount }) => {
      const { CometChat } = window as any;
      const req = new CometChat.MessagesRequestBuilder()
        .setGUID(room)
        .setLimit(expectedCount + 10)
        .build();
      const messages = await req.fetchPrevious();
      return messages.map((message: any) => ({
        id: String(message.getId()),
        text: message.getData?.()?.text,
        updatedAt: message.getUpdatedAt?.() ?? message.updatedAt,
        reactions: message.getMetadata?.()?.['@injected']?.extensions?.reactions || {},
      }));
    },
    { room, expectedCount: groupMessages.length },
  );

  for (const message of groupMessages) {
    const historyMessage = groupHistory.find((item: any) => item.id === message.id);
    expect(historyMessage, `missing history message ${message.id}`).toBeTruthy();
    expect(historyMessage.updatedAt).toBe(message.updatedAt);

    if (message.reacted) {
      expect(historyMessage.reactions?.['🎧']?.[bobUid]?.name).toBe('RN Contract Bob');
    } else {
      expect(historyMessage.reactions?.['🎧']?.[bobUid]).toBeFalsy();
    }
  }

  expect(Math.max(...dmLatencies)).toBeLessThan(MAX_LIVE_LATENCY_MS);
  expect(Math.max(...reactionLatencies)).toBeLessThan(MAX_LIVE_LATENCY_MS);

  console.log(
    JSON.stringify(
      {
        target: TARGET_HOST,
        dmMessages: DM_MESSAGE_COUNT,
        groupMessages: GROUP_MESSAGE_COUNT,
        maxDmLatencyMs: Math.max(...dmLatencies),
        maxReactionLatencyMs: Math.max(...reactionLatencies),
        rnTextEvents: rnEvents.filter((event) => event.kind === 'text').length,
        rnEditedEvents: rnEvents.filter((event) => event.kind === 'edited').length,
      },
      null,
      2,
    ),
  );

  await web.close();
  try {
    await RNCometChat.logout();
  } catch {
    // RN SDK cleanup is noisy in the Node shim harness; the assertions above
    // are the compatibility contract.
  }
});
