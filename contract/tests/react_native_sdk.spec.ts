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
const RN_WS_SOAK_MS = Number(process.env.OPENCHAT_RN_WS_SOAK_MS || 180_000);
const RN_WS_SOAK_INTERVAL_MS = Number(process.env.OPENCHAT_RN_WS_SOAK_INTERVAL_MS || 45_000);

if (TARGET_HOST.startsWith('localhost') || TARGET_HOST.startsWith('127.0.0.1')) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED ||= '0';
}

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
    category: message?.getCategory?.() || message?.category,
    type: message?.getType?.() || message?.type,
    action: data.action,
    id: String(entity?.getId?.() || entity?.id || message?.getId?.() || message?.id || ''),
    onId: String(data.entities?.on?.entity?.id || ''),
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
    metadataChatMessage: metadata?.chatMessage,
    at: Date.now(),
  });
}

function recordRnReceiptEvent(events: any[], kind: string, receipt: any) {
  const sender = receipt?.getSender?.() || receipt?.sender || receipt?.user;
  events.push({
    kind,
    messageId: String(receipt?.getMessageId?.() || receipt?.messageId || ''),
    sender: sender?.getUid?.() || sender?.uid || sender,
    receiver: receipt?.getReceiver?.() || receipt?.receiver,
    receiverType: receipt?.getReceiverType?.() || receipt?.receiverType,
    deliveredAt: receipt?.getDeliveredAt?.() || receipt?.deliveredAt,
    readAt: receipt?.getReadAt?.() || receipt?.readAt,
    at: Date.now(),
  });
}

function appChatMetadata(uid: string, name: string, text: string, suffix: string) {
  return {
    incrementUnreadCount: true,
    chatMessage: {
      message: text,
      uuid: `rn-app-msg-${uid}-${suffix}-${Date.now()}`,
      id: -1,
      avatarId: 'lovable-figgy',
      userName: name,
      userUuid: uid,
      replies: undefined,
      color: '#5B7CFA',
      badges: undefined,
      media: undefined,
      imageBase64: undefined,
      imageUrls: undefined,
      type: 'user',
    },
  };
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
    metadata: {
      avatarId: 'lovable-figgy',
      color: '#5B7CFA',
    },
  });
  await adminPost(request, '/users', {
    uid: bobUid,
    name: 'RN Contract Bob',
    metadata: {
      avatarId: 'lovable-figgy',
      color: '#EB5757',
    },
  });
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
      onMessageDeleted: (message: any) => recordRnEvent(rnEvents, 'deleted', message, RNCometChat),
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
      onMessagesDelivered: (receipt: any) => recordRnReceiptEvent(rnEvents, 'delivered', receipt),
      onMessagesRead: (receipt: any) => recordRnReceiptEvent(rnEvents, 'read', receipt),
    }),
  );

  await web.waitForTimeout(1500);

  const dmLatencies: number[] = [];
  const dmTexts: string[] = [];
  const webSentDmMessages: Array<{ id: string; text: string }> = [];

  for (let i = 0; i < DM_MESSAGE_COUNT; i += 1) {
    const text = `rn-dm-${i}-${suffix}`;
    dmTexts.push(text);
    const startedAt = Date.now();

    if (i % 2 === 0) {
      const sent = await web.evaluate(
        async ({ bobUid, text, aliceUid, suffix }) => {
          const { CometChat } = window as any;
          const message = new CometChat.TextMessage(bobUid, text, 'user');
          message.setMetadata({
            incrementUnreadCount: true,
            chatMessage: {
              message: text,
              uuid: `rn-web-app-msg-${suffix}-${Date.now()}`,
              id: -1,
              avatarId: 'lovable-figgy',
              userName: 'RN Contract Alice',
              userUuid: aliceUid,
              color: '#5B7CFA',
              type: 'user',
            },
          });
          const sent = await CometChat.sendMessage(message);
          return { id: String(sent.getId()), text };
        },
        { bobUid, text, aliceUid, suffix },
      );
      webSentDmMessages.push(sent);
      const seenAt = await waitFor(() => rnEvents.some((event) => event.kind === 'text' && event.text === text));
      expect(seenAt, `RN did not receive web DM ${text}`).toBeTruthy();
      const dmEvent = rnEvents.find((event) => event.kind === 'text' && event.text === text);
      expect(dmEvent).toMatchObject({
        sender: aliceUid,
        receiverId: bobUid,
        receiverType: 'user',
        receiverUid: bobUid,
        receiverIsUser: true,
        metadataChatMessage: expect.objectContaining({
          message: text,
          userUuid: aliceUid,
          userName: 'RN Contract Alice',
          avatarId: expect.any(String),
          type: 'user',
        }),
      });
      dmLatencies.push(Number(seenAt) - startedAt);
    } else {
      const message = new RNCometChat.TextMessage(aliceUid, text, 'user');
      message.setMetadata(appChatMetadata(bobUid, 'RN Contract Bob', text, suffix));
      await RNCometChat.sendMessage(message);
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

  const deletedDm = webSentDmMessages[0];
  await web.evaluate(async (messageId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(messageId);
  }, deletedDm.id);

  const dmDeleteSeenAt = await waitFor(() =>
    rnEvents.some((event) => event.kind === 'deleted' && event.id === deletedDm.id),
  );
  expect(dmDeleteSeenAt, `RN did not receive DM delete ${deletedDm.id}`).toBeTruthy();

  const rnDmHistoryAfterDelete = await new RNCometChat.MessagesRequestBuilder()
    .setUID(aliceUid)
    .setLimit(dmTexts.length + 10)
    .build()
    .fetchPrevious();
  expect(rnDmHistoryAfterDelete.map((message: any) => message.getData?.()?.text).filter(Boolean)).not.toContain(
    deletedDm.text,
  );

  const webConversations = await web.evaluate(
    async ({ bobUid }) => {
      const { CometChat } = window as any;
      const req = new CometChat.ConversationsRequestBuilder().setLimit(15).setConversationType('user').build();
      const conversations = await req.fetchNext();

      return conversations.map((conversation: any) => ({
        conversationType: conversation.getConversationType?.(),
        withUid: conversation.getConversationWith?.()?.getUid?.(),
        unread: conversation.getUnreadMessageCount?.(),
        lastText: conversation.getLastMessage?.()?.getData?.()?.text,
        isExpectedPeer: conversation.getConversationWith?.()?.getUid?.() === bobUid,
      }));
    },
    { bobUid },
  );

  expect(webConversations).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        conversationType: 'user',
        withUid: bobUid,
        lastText: dmTexts.at(-1),
        isExpectedPeer: true,
      }),
    ]),
  );

  const rnConversations = await new RNCometChat.ConversationsRequestBuilder()
    .setLimit(15)
    .setConversationType('user')
    .build()
    .fetchNext();
  expect(
    rnConversations.map((conversation: any) => ({
      conversationType: conversation.getConversationType?.(),
      withUid: conversation.getConversationWith?.()?.getUid?.(),
      metadata: conversation.getConversationWith?.()?.getMetadata?.(),
      unread: conversation.getUnreadMessageCount?.(),
      lastText: conversation.getLastMessage?.()?.getData?.()?.text,
    })),
  ).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        conversationType: 'user',
        withUid: aliceUid,
        metadata: expect.objectContaining({
          avatarId: expect.any(String),
          color: expect.any(String),
        }),
        lastText: dmTexts.at(-1),
      }),
    ]),
  );

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

  const deletedGroup = groupMessages.find((message) => !message.reacted) || groupMessages[0];
  await web.evaluate(async (messageId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(messageId);
  }, deletedGroup.id);

  const groupDeleteSeenAt = await waitFor(() =>
    rnEvents.some((event) => event.kind === 'deleted' && event.id === deletedGroup.id),
  );
  expect(groupDeleteSeenAt, `RN did not receive group delete ${deletedGroup.id}`).toBeTruthy();

  const rnGroupHistoryAfterDelete = await new RNCometChat.MessagesRequestBuilder()
    .setGUID(room)
    .setLimit(groupMessages.length + 10)
    .build()
    .fetchPrevious();
  expect(rnGroupHistoryAfterDelete.map((message: any) => message.getData?.()?.text).filter(Boolean)).not.toContain(
    deletedGroup.text,
  );

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
    RNCometChat.removeMessageListener(`OPENCHAT_RN_CONTRACT_${suffix}`);
  } catch {
    // RN SDK cleanup is noisy in the Node shim harness; the assertions above
    // are the compatibility contract.
  }
});

test('real React Native SDK receives app-shaped DMs from a web peer', async ({ browser, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user setup.');
  test.setTimeout(60_000);
  installReactNativeNodeShims();

  const { CometChat: RNCometChat } = require('@cometchat/chat-sdk-react-native');
  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const aliceUid = `rn-mobile-alice-${suffix}`;
  const bobUid = `rn-web-bob-${suffix}`;

  await adminPost(request, '/users', {
    uid: aliceUid,
    name: 'RN Mobile Alice',
    metadata: { avatarId: 'lovable-figgy', color: '#5B7CFA' },
  });
  await adminPost(request, '/users', {
    uid: bobUid,
    name: 'RN Web Bob',
    metadata: { avatarId: 'lovable-figgy', color: '#EB5757' },
  });
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);

  const rnSettings = new RNCometChat.AppSettingsBuilder()
    .subscribePresenceForAllUsers()
    .setRegion('us')
    .overrideClientHost(TARGET_HOST)
    .overrideAdminHost(TARGET_HOST.replace(/\/v3\.0$/, '/v3'))
    .autoEstablishSocketConnection(true)
    .build();
  await RNCometChat.init(APP_ID, rnSettings);
  await RNCometChat.login(aliceAuth.authToken);

  const rnEvents: any[] = [];
  RNCometChat.addMessageListener(
    `OPENCHAT_RN_MOBILE_RECEIVER_${suffix}`,
    new RNCometChat.MessageListener({
      onTextMessageReceived: (message: any) => recordRnEvent(rnEvents, 'text', message, RNCometChat),
      onCustomMessageReceived: (message: any) => recordRnEvent(rnEvents, 'custom', message, RNCometChat),
      onMediaMessageReceived: (message: any) => recordRnEvent(rnEvents, 'media', message, RNCometChat),
      onMessageEdited: (message: any) => recordRnEvent(rnEvents, 'edited', message, RNCometChat),
      onMessagesDelivered: (receipt: any) => recordRnReceiptEvent(rnEvents, 'delivered', receipt),
      onMessagesRead: (receipt: any) => recordRnReceiptEvent(rnEvents, 'read', receipt),
    }),
  );

  const web = await browser.newPage();
  await loadWebSdk(web, bobAuth.authToken);
  await web.waitForTimeout(1500);

  const text = `rn-mobile-receive-dm-${suffix}`;
  const startedAt = Date.now();
  const sent = await web.evaluate(
    async ({ aliceUid, bobUid, text, suffix }) => {
      const { CometChat } = window as any;
      const message = new CometChat.TextMessage(aliceUid, text, 'user');
      message.setMetadata({
        incrementUnreadCount: true,
        chatMessage: {
          message: text,
          uuid: `rn-mobile-receive-${suffix}`,
          id: -1,
          avatarId: 'lovable-figgy',
          userName: 'RN Web Bob',
          userUuid: bobUid,
          color: '#EB5757',
          type: 'user',
        },
      });
      const sent = await CometChat.sendMessage(message);
      return {
        id: String(sent.getId?.() || sent.id),
        metadata: sent.getMetadata?.() || sent.metadata,
      };
    },
    { aliceUid, bobUid, text, suffix },
  );

  const seenAt = await waitFor(() => rnEvents.some((event) => event.kind === 'text' && event.text === text));
  expect(seenAt, `RN mobile receiver did not receive app-shaped DM ${text}`).toBeTruthy();
  const event = rnEvents.find((item) => item.kind === 'text' && item.text === text);
  expect(event).toMatchObject({
    id: sent.id,
    sender: bobUid,
    receiverId: aliceUid,
    receiverType: 'user',
    receiverUid: aliceUid,
    receiverIsUser: true,
    metadataChatMessage: expect.objectContaining({
      message: text,
      userUuid: bobUid,
      userName: 'RN Web Bob',
      avatarId: 'lovable-figgy',
      type: 'user',
    }),
  });
  expect(Number(seenAt) - startedAt).toBeLessThan(MAX_LIVE_LATENCY_MS);

  const deliveredAt = await waitFor(() =>
    rnEvents.some((event) => event.kind === 'delivered' && event.messageId === sent.id),
  );
  expect(deliveredAt, `RN mobile receiver did not receive delivered refresh for ${sent.id}`).toBeTruthy();
  expect(rnEvents.find((event) => event.kind === 'delivered' && event.messageId === sent.id)).toMatchObject({
    sender: aliceUid,
    receiver: bobUid,
    receiverType: 'user',
  });

  const rnHistory = await new RNCometChat.MessagesRequestBuilder()
    .setUID(bobUid)
    .setLimit(10)
    .setTimestamp(Date.now())
    .build()
    .fetchPrevious();
  const historyMessage = rnHistory.find((message: any) => String(message.getId?.()) === sent.id);
  expect(historyMessage?.getMetadata?.()?.chatMessage).toMatchObject({
    message: text,
    userUuid: bobUid,
    userName: 'RN Web Bob',
    avatarId: 'lovable-figgy',
    type: 'user',
  });

  await web.close();
  try {
    RNCometChat.removeMessageListener(`OPENCHAT_RN_MOBILE_RECEIVER_${suffix}`);
  } catch {
    // RN SDK cleanup is noisy in the Node shim harness; the assertions above
    // are the compatibility contract.
  }
});

test('real React Native SDK stays live across websocket idle periods', async ({ browser, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires OPENCHAT_ADMIN_API_KEY for staging user/group setup.');
  test.setTimeout(RN_WS_SOAK_MS + 90_000);
  installReactNativeNodeShims();

  const { CometChat: RNCometChat } = require('@cometchat/chat-sdk-react-native');
  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
  const aliceUid = `rn-soak-alice-${suffix}`;
  const bobUid = `rn-soak-bob-${suffix}`;
  const room = `rn-soak-room-${suffix}`;

  await adminPost(request, '/users', { uid: aliceUid, name: 'RN Soak Alice' });
  await adminPost(request, '/users', { uid: bobUid, name: 'RN Soak Bob' });
  const aliceAuth = await adminPost(request, `/users/${aliceUid}/auth_tokens`);
  const bobAuth = await adminPost(request, `/users/${bobUid}/auth_tokens`);
  await adminPost(request, '/groups', { guid: room, name: 'RN Soak Room', type: 'public' });
  await adminPost(request, `/groups/${room}/members`, { participants: [aliceUid, bobUid] });

  const web = await browser.newPage();
  await loadWebSdk(web, aliceAuth.authToken);
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
  const connectionEvents: any[] = [];
  const listenerId = `OPENCHAT_RN_SOAK_${suffix}`;
  const connectionListenerId = `OPENCHAT_RN_SOAK_CONNECTION_${suffix}`;

  RNCometChat.addConnectionListener(
    connectionListenerId,
    new RNCometChat.ConnectionListener({
      onConnected: () => connectionEvents.push({ kind: 'connected', at: Date.now() }),
      onDisconnected: () => connectionEvents.push({ kind: 'disconnected', at: Date.now() }),
    }),
  );

  RNCometChat.addMessageListener(
    listenerId,
    new RNCometChat.MessageListener({
      onTextMessageReceived: (message: any) => recordRnEvent(rnEvents, 'text', message, RNCometChat),
      onMessageEdited: (message: any) => recordRnEvent(rnEvents, 'edited', message, RNCometChat),
    }),
  );

  await web.waitForTimeout(1500);

  const iterations = Math.max(2, Math.floor(RN_WS_SOAK_MS / RN_WS_SOAK_INTERVAL_MS) + 1);
  const texts: string[] = [];
  const latencies: number[] = [];

  for (let i = 0; i < iterations; i += 1) {
    if (i > 0) {
      await web.waitForTimeout(RN_WS_SOAK_INTERVAL_MS);
    }

    const text = `rn-soak-${i}-${suffix}-${Date.now()}`;
    texts.push(text);
    const startedAt = Date.now();

    await web.evaluate(
      async ({ room, text }) => {
        const { CometChat } = window as any;
        await CometChat.sendMessage(new CometChat.TextMessage(room, text, 'group'));
      },
      { room, text },
    );

    const seenAt = await waitFor(() => rnEvents.some((event) => event.kind === 'text' && event.text === text), 30_000);
    expect(seenAt, `RN did not receive group text after idle: ${text}`).toBeTruthy();
    latencies.push(Number(seenAt) - startedAt);
  }

  expect(rnEvents.filter((event) => event.kind === 'text').map((event) => event.text)).toEqual(
    expect.arrayContaining(texts),
  );
  expect(connectionEvents.filter((event) => event.kind === 'disconnected')).toEqual([]);
  expect(Math.max(...latencies)).toBeLessThan(MAX_LIVE_LATENCY_MS);

  console.log(
    JSON.stringify(
      {
        target: TARGET_HOST,
        durationMs: RN_WS_SOAK_MS,
        intervalMs: RN_WS_SOAK_INTERVAL_MS,
        iterations,
        maxLatencyMs: Math.max(...latencies),
        disconnects: connectionEvents.filter((event) => event.kind === 'disconnected').length,
      },
      null,
      2,
    ),
  );

  await web.close();
  try {
    RNCometChat.removeMessageListener(listenerId);
    RNCometChat.removeConnectionListener(connectionListenerId);
  } catch {
    // The assertions above are the compatibility contract.
  }
});
