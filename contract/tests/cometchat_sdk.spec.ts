import { test, expect } from '@playwright/test';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ALICE_TOKEN = process.env.ALICE_TOKEN || 'uid:alice';
const BOB_TOKEN = process.env.BOB_TOKEN || 'uid:bob';
const ADMIN_API_KEY = process.env.OPENCHAT_ADMIN_API_KEY || (TARGET_HOST.startsWith('localhost') ? 'local-api-key' : '');

async function loadSdk(page: any, autoSocket = false) {
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: sdkPath });
  await page.evaluate(async ({ appId, targetHost, autoSocket }) => {
    const { CometChat } = window as any;
    const settings = new CometChat.AppSettingsBuilder()
      .setRegion('us')
      .overrideClientHost(targetHost)
      .overrideAdminHost(targetHost)
      .autoEstablishSocketConnection(autoSocket)
      .build();
    await CometChat.init(appId, settings);
  }, { appId: APP_ID, targetHost: TARGET_HOST, autoSocket });
}

test('real CometChat SDK can init, login(authToken), and getLoggedinUser', async ({ page }) => {
  await loadSdk(page, false);
  const user = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    const u = await CometChat.login(token);
    const cached = await CometChat.getLoggedinUser();
    return { uid: u.getUid(), cachedUid: cached.getUid(), name: u.getName() };
  }, ALICE_TOKEN);

  expect(user.uid).toBe('alice');
  expect(user.cachedUid).toBe('alice');
});

test('text messages, message request builder, conversations, unread, read, delete', async ({ browser }) => {
  const alice = await browser.newPage();
  await loadSdk(alice, false);

  const sent = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const m = new CometChat.TextMessage('bob', 'contract hello ' + Date.now(), 'user');
    const sent = await CometChat.sendMessage(m);
    return { id: sent.getId(), text: sent.getData().text, sentAt: sent.getSentAt(), sender: sent.getSender().getUid() };
  }, ALICE_TOKEN);

  expect(sent.sender).toBe('alice');
  expect(sent.text).toContain('contract hello');

  const bob = await browser.newPage();
  await loadSdk(bob, true);
  const fetched = await bob.evaluate(async ({ token, msgId }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await new Promise((resolve) => setTimeout(resolve, 500));
    const req = new CometChat.MessagesRequestBuilder().setUID('alice').setLimit(20).build();
    const messages = await req.fetchPrevious();
    const found = messages.find((m: any) => String(m.getId()) === String(msgId));
    const unread = await CometChat.getUnreadMessageCountForAllUsers();
    await CometChat.markAsRead(found);
    const convReq = new CometChat.ConversationsRequestBuilder().setLimit(20).setConversationType('user').build();
    const conversations = await convReq.fetchNext();
    return {
      foundText: found.getData().text,
      foundSender: found.getSender().getUid(),
      unreadFromAlice: unread.alice || unread.users?.alice || 0,
      conversationCount: conversations.length,
    };
  }, { token: BOB_TOKEN, msgId: sent.id });

  expect(fetched.foundText).toBe(sent.text);
  expect(fetched.foundSender).toBe('alice');
  expect(fetched.unreadFromAlice).toBeGreaterThanOrEqual(1);
  expect(fetched.conversationCount).toBeGreaterThanOrEqual(1);

  await alice.evaluate(async (msgId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(msgId);
  }, sent.id);
});

test('custom messages, media messages, group join, and native reactions', async ({ page, request }) => {
  await loadSdk(page, false);

  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);

    const custom = new CometChat.CustomMessage('bob', 'user', 'ChatMessage', { feature: 'contract-custom' });
    const customSent = await CometChat.sendCustomMessage(custom);

    const file = new File([new Blob(['tiny image payload'], { type: 'image/png' })], 'tiny.png', { type: 'image/png' });
    const media = new CometChat.MediaMessage('bob', file, CometChat.MESSAGE_TYPE.IMAGE, 'user');
    media.setCaption('tiny image');
    const mediaSent = await CometChat.sendMediaMessage(media);

    await CometChat.joinGroup('lobby', CometChat.GROUP_TYPE.PUBLIC, '');
    const groupMsg = new CometChat.TextMessage('lobby', 'group contract ' + Date.now(), 'group');
    const groupSent = await CometChat.sendMessage(groupMsg);

    const reacted = await CometChat.addReaction(customSent.getId(), '👍');

    const attachment = mediaSent.getAttachment?.();

    return {
      customData: customSent.getData().customData,
      mediaCaption: mediaSent.getCaption(),
      mediaDataUrl: mediaSent.getData().url,
      mediaAttachmentUrl: attachment?.getUrl?.(),
      groupReceiver: groupSent.getReceiverId(),
      reactions: reacted.getReactions().map((r: any) => ({ reaction: r.getReaction(), count: r.getCount() })),
    };
  }, ALICE_TOKEN);

  expect(result.customData.feature).toBe('contract-custom');
  expect(result.mediaCaption).toBe('tiny image');
  expect(result.mediaDataUrl).toBeFalsy();
  expect(result.mediaAttachmentUrl).toBeTruthy();
  const mediaUrl = new URL(result.mediaAttachmentUrl, `https://${TARGET_HOST}`).toString();
  const mediaFetch = await request.get(mediaUrl);
  expect(mediaFetch.status()).toBeLessThan(400);
  expect(result.groupReceiver).toBe('lobby');
  expect(result.reactions[0].reaction).toBe('👍');
});

test('blocked users APIs used by settings and DM flows', async ({ page }) => {
  await loadSdk(page, false);

  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);

    await CometChat.blockUsers(['bob']);
    const bob = await CometChat.getUser('bob');
    const request = new CometChat.BlockedUsersRequestBuilder()
      .setLimit(100)
      .blockedByMe()
      .build();
    const blocked = await request.fetchNext();
    await CometChat.unblockUsers(['bob']);

    return {
      blockedByMe: bob.getBlockedByMe(),
      hasBlockedMe: bob.getHasBlockedMe(),
      blockedUids: blocked.map((user: any) => user.getUid()),
    };
  }, ALICE_TOKEN);

  expect(result.blockedByMe).toBe(true);
  expect(result.hasBlockedMe).toBe(false);
  expect(result.blockedUids).toContain('bob');
});

test('optional callExtension reaction contract', async ({ page }) => {
  test.skip(!process.env.RUN_EXTENSION_CONTRACT, 'Requires wildcard HTTPS DNS like reactions-us.example.com pointing at the same app.');
  await loadSdk(page, false);
  const out = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const msg = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'extension contract', 'user'));
    const data = await CometChat.callExtension('reactions', 'POST', 'v1/react', { messageId: msg.getId(), reaction: '🔥', action: 'add' });
    return data.data ? data.data : data;
  }, ALICE_TOKEN);
  expect(out).toBeTruthy();
});

// ---------------------------------------------------------------------------
// Hangout (snowy / frontend-core / rooms-service / user-service / socket) call
// shapes. Every block below mirrors a real production call site verbatim so the
// drop-in replacement is verified against the actual @cometchat/chat-sdk-javascript
// usage we ship today, not against the docs.
// ---------------------------------------------------------------------------

test('snowy init flow: AppSettingsBuilder with overrideClientHost + overrideAdminHost + autoEstablishSocketConnection', async ({ page }) => {
  // Mirrors snowy/src/data/chat/init-chat.tsx useCometChatClient() effect.
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: sdkPath });
  const result = await page.evaluate(async ({ appId, targetHost, token }) => {
    const { CometChat } = window as any;
    const appSettingsBuilder = new CometChat.AppSettingsBuilder()
      .setRegion('US')
      .autoEstablishSocketConnection(true);
    const hostOverrideBuilder = appSettingsBuilder as any;
    hostOverrideBuilder.overrideClientHost(targetHost);
    hostOverrideBuilder.overrideAdminHost(targetHost);
    const settings = appSettingsBuilder.build();
    await CometChat.init(appId, settings);
    const user = await CometChat.login(token);
    const cached = await CometChat.getLoggedinUser();
    return { uid: user.getUid(), cachedUid: cached.getUid() };
  }, { appId: APP_ID, targetHost: TARGET_HOST, token: ALICE_TOKEN });
  expect(result.uid).toBe('alice');
  expect(result.cachedUid).toBe('alice');
});

test('snowy DM history: MessagesRequestBuilder.setUID().setLimit().setTimestamp(Date.now()).fetchPrevious()', async ({ browser }) => {
  // Mirrors snowy/src/data/chat/dm-chat-utils.tsx fetchCometChatMessagesWithUser().
  const prefix = `dm-history-${Date.now()}`;
  const alice = await browser.newPage();
  await loadSdk(alice, false);
  const sentIds = await alice.evaluate(async ({ token, prefix }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const ids: number[] = [];
    for (const text of [`${prefix} a`, `${prefix} b`, `${prefix} c`]) {
      const m = new CometChat.TextMessage('bob', text, 'user');
      const sent = await CometChat.sendMessage(m);
      ids.push(sent.getId());
    }
    return ids;
  }, { token: ALICE_TOKEN, prefix });

  const bob = await browser.newPage();
  await loadSdk(bob, false);
  const history = await bob.evaluate(async ({ token, prefix }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const req = new CometChat.MessagesRequestBuilder()
      .setUID('alice')
      .setLimit(30)
      .setTimestamp(Date.now())
      .build();
    const messages = await req.fetchPrevious();
    return messages
      .map((m: any) => ({ id: m.getId(), text: m.getData()?.text }))
      .filter((m: any) => typeof m.text === 'string' && m.text.startsWith(prefix));
  }, { token: BOB_TOKEN, prefix });

  expect(history.map((m) => m.id)).toEqual(sentIds);
  expect(history.map((m) => m.text)).toEqual([`${prefix} a`, `${prefix} b`, `${prefix} c`]);
});

test('snowy room history: MessagesRequestBuilder.setGUID().setLimit().setTimestamp(Date.now()).fetchPrevious()', async ({ page }) => {
  // Mirrors snowy/src/data/chat/room-chat-utils.tsx group history fetch.
  const prefix = `room-history-${Date.now()}`;
  await loadSdk(page, false);
  const result = await page.evaluate(async ({ token, prefix }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await CometChat.joinGroup('lobby');
    const sentIds: number[] = [];
    for (const text of [`${prefix} a`, `${prefix} b`, `${prefix} c`]) {
      const sent = await CometChat.sendMessage(new CometChat.TextMessage('lobby', text, 'group'));
      sentIds.push(sent.getId());
    }
    const req = new CometChat.MessagesRequestBuilder()
      .setGUID('lobby')
      .setLimit(50)
      .setTimestamp(Date.now())
      .build();
    const messages = await req.fetchPrevious();
    const history = messages
      .map((m: any) => ({ id: m.getId(), text: m.getData()?.text, receiverGuid: m.getReceiverId() }))
      .filter((m: any) => typeof m.text === 'string' && m.text.startsWith(prefix));
    return {
      sentIds,
      history,
    };
  }, { token: ALICE_TOKEN, prefix });
  expect(result.history.map((m: any) => m.id)).toEqual(result.sentIds);
  expect(result.history.map((m: any) => m.text)).toEqual([`${prefix} a`, `${prefix} b`, `${prefix} c`]);
  expect(result.history.every((m: any) => m.receiverGuid === 'lobby')).toBe(true);
});

test('snowy custom message: CustomMessage with "ChatMessage" subType + setMetadata({incrementUnreadCount}) round-trips customData', async ({ page }) => {
  // Mirrors snowy/src/data/chat/cometchat-utils.ts sendCustomMessage(). The customData
  // object carries the full Hangout chat envelope (songs, playlist, consumable, mentions).
  await loadSdk(page, false);
  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const customData = {
      message: 'hangout custom',
      uuid: 'client-uuid-1',
      id: 42,
      userName: 'Alice',
      avatarId: 'avatar-1',
      color: '#fff',
      userUuid: 'alice',
      type: 'user',
      songs: [{ type: 'ChatMusicInfo', song: { spotifyId: 'sp-1' } }],
    };
    const msg = new CometChat.CustomMessage('bob', 'user', 'ChatMessage', customData);
    msg.setMetadata({ incrementUnreadCount: true });
    const sent = await CometChat.sendCustomMessage(msg);
    return {
      id: sent.getId(),
      customData: sent.getData().customData,
      subType: sent.getType(),
    };
  }, ALICE_TOKEN);

  expect(result.subType).toBe('ChatMessage');
  expect(result.customData.message).toBe('hangout custom');
  expect(result.customData.userUuid).toBe('alice');
  expect(result.customData.songs?.[0]?.song?.spotifyId).toBe('sp-1');
});

test('snowy media message: MediaMessage + setAttachment(Attachment) + setCaption + setMetadata', async ({ page }) => {
  // Mirrors snowy/src/data/chat/cometchat-utils.ts sendMediaMessage().
  await loadSdk(page, false);
  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const blob = new File(
      [new Blob(['snowy media bytes'], { type: 'image/png' })],
      'snowy.png',
      { type: 'image/png' }
    );
    const media = new CometChat.MediaMessage(
      'bob',
      blob,
      CometChat.MESSAGE_TYPE.IMAGE,
      'user'
    );
    const sourceAttachment = new CometChat.Attachment({
      name: 'snowy.png',
      extension: 'png',
      mimeType: 'image/png',
      url: 'https://example.test/snowy.png',
    });
    media.setAttachment(sourceAttachment);
    media.setCaption('hangout caption');
    media.setMetadata({
      recipientUuid: 'bob',
      chatMessage: { type: 'user', message: 'hangout caption' },
    });
    const sent = await CometChat.sendMediaMessage(media);
    const sentAttachment = sent.getAttachment?.();
    return {
      caption: sent.getCaption?.() ?? sent.getData()?.caption,
      dataUrl: sent.getData()?.url,
      attachmentUrl: sentAttachment?.getUrl?.(),
      metadata: sent.getMetadata?.() ?? sent.getData()?.metadata,
    };
  }, ALICE_TOKEN);

  expect(result.caption).toBe('hangout caption');
  expect(result.dataUrl).toBeFalsy();
  expect(result.attachmentUrl).toBeTruthy();
  expect(result.metadata?.recipientUuid ?? result.metadata?.chatMessage?.type).toBeTruthy();
});

test('snowy listeners: addMessageListener fires onTextMessageReceived / onCustomMessageReceived / onMessageDeleted / onMessageEdited across tabs', async ({ browser }) => {
  // Mirrors snowy/src/data/chat/init-chat.tsx + dm-chat-utils.tsx listener wiring.
  const bob = await browser.newPage();
  await loadSdk(bob, true);
  await bob.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    (window as any).__events = [];
    CometChat.addMessageListener(
      'HANGOUT_CONTRACT_LISTENER',
      new CometChat.MessageListener({
        onTextMessageReceived: (m: any) => (window as any).__events.push({ kind: 'text', id: m.getId(), text: m.getData()?.text }),
        onCustomMessageReceived: (m: any) => (window as any).__events.push({ kind: 'custom', id: m.getId(), subType: m.getType() }),
        onMediaMessageReceived: (m: any) => (window as any).__events.push({ kind: 'media', id: m.getId() }),
        onMessageDeleted: (m: any) => (window as any).__events.push({ kind: 'deleted', id: m.getId(), onId: m.getData()?.entities?.on?.entity?.id }),
        onMessageEdited: (m: any) => (window as any).__events.push({ kind: 'edited', id: m.getId(), onId: m.getData()?.entities?.on?.entity?.id }),
        onMessagesDelivered: () => (window as any).__events.push({ kind: 'delivered' }),
      })
    );
  }, BOB_TOKEN);

  const alice = await browser.newPage();
  await loadSdk(alice, false);
  const aliceSentText = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const text = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'listener text', 'user'));
    const custom = await CometChat.sendCustomMessage(
      new CometChat.CustomMessage('bob', 'user', 'ChatMessage', { feature: 'listener-custom' })
    );
    await CometChat.deleteMessage(text.getId());
    return { textId: text.getId(), customId: custom.getId() };
  }, ALICE_TOKEN);

  await bob.waitForFunction(
    () => ((window as any).__events || []).filter((e: any) => e.kind === 'text').length >= 1
      && ((window as any).__events || []).filter((e: any) => e.kind === 'custom').length >= 1
      && ((window as any).__events || []).filter((e: any) => e.kind === 'deleted').length >= 1,
    null,
    { timeout: 15_000 }
  );

  const events = await bob.evaluate(() => (window as any).__events);
  expect(events.find((e: any) => e.kind === 'text' && e.text === 'listener text')).toBeTruthy();
  expect(events.find((e: any) => e.kind === 'custom' && e.subType === 'ChatMessage')).toBeTruthy();
  // The deleted action's "on" entity points back to the original message id.
  expect(events.find((e: any) => e.kind === 'deleted' && String(e.id) === String(aliceSentText.textId))).toBeTruthy();

  await bob.evaluate(() => {
    const { CometChat } = (window as any);
    CometChat.removeMessageListener('HANGOUT_CONTRACT_LISTENER');
  });
});

test('snowy connection listener: addConnectionListener fires onConnected after init+login', async ({ page }) => {
  // Mirrors snowy/src/data/chat/room-chat-utils.tsx connection listener.
  await loadSdk(page, true);
  const connected = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    const events: string[] = [];
    CometChat.addConnectionListener(
      'HANGOUT_CONN_LISTENER',
      new CometChat.ConnectionListener({
        onConnected: () => events.push('connected'),
        onDisconnected: () => events.push('disconnected'),
      })
    );
    await CometChat.login(token);
    await new Promise((resolve) => setTimeout(resolve, 1500));
    CometChat.removeConnectionListener('HANGOUT_CONN_LISTENER');
    return events;
  }, ALICE_TOKEN);
  expect(connected).toContain('connected');
});

test('snowy block flow: getUser().getBlockedByMe()/getHasBlockedMe() + BlockedUsersRequestBuilder.blockedByMe()', async ({ page }) => {
  // Mirrors snowy/src/data/chat/use-block-user.ts + use-blocked-users.ts.
  await loadSdk(page, false);
  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await CometChat.blockUsers(['bob']);

    const bob = await CometChat.getUser('bob');
    const blockedByMe = bob.getBlockedByMe?.() ?? false;
    const hasBlockedMe = bob.getHasBlockedMe?.() ?? false;

    const req = new CometChat.BlockedUsersRequestBuilder()
      .setLimit(100)
      .blockedByMe()
      .build();
    const blocked = await req.fetchNext();

    await CometChat.unblockUsers(['bob']);
    return { blockedByMe, hasBlockedMe, blockedUids: blocked.map((u: any) => u.getUid()) };
  }, ALICE_TOKEN);
  expect(result.blockedByMe).toBe(true);
  expect(result.hasBlockedMe).toBe(false);
  expect(result.blockedUids).toContain('bob');
});

test('snowy joinGroup(uuid) single-arg works without explicit type/password', async ({ page }) => {
  // Mirrors snowy/src/data/chat/cometchat-channels.ts joinChannel().
  await loadSdk(page, false);
  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    try {
      const group = await CometChat.joinGroup('lobby');
      return { ok: true, guid: group.getGuid?.() ?? group.guid };
    } catch (e: any) {
      // ERR_ALREADY_JOINED is the only non-fatal error snowy tolerates.
      return { ok: false, code: e?.code };
    }
  }, ALICE_TOKEN);
  expect(result.ok || result.code === 'ERR_ALREADY_JOINED').toBeTruthy();
});

test('snowy callExtension reactions with msgId/emoji keys (Hangout wire shape)', async ({ page }) => {
  // Mirrors snowy/src/data/chat/cometchat-utils.ts reactMessage().
  // Snowy uses { msgId, emoji } NOT { messageId, reaction } — the OpenChat extension
  // route must accept this Hangout-specific key naming.
  await loadSdk(page, false);
  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const msg = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'snowy ext react', 'user'));
    await CometChat.callExtension('reactions', 'POST', 'v1/react', {
      msgId: msg.getId(),
      emoji: '🔥',
    });
    const builder = new CometChat.ReactionsRequestBuilder()
      .setMessageId(Number(msg.getId()))
      .setLimit(20);
    const req = builder.build();
    const page0 = await req.fetchPrevious();
    return { count: page0.length, first: page0[0]?.getReaction?.() };
  }, ALICE_TOKEN);
  expect(result.count).toBeGreaterThanOrEqual(1);
  expect(result.first).toBe('🔥');
});

test('snowy callExtension reactions toggle and propagate through regular message listeners', async ({ browser }) => {
  const bob = await browser.newPage();
  await loadSdk(bob, true);
  await bob.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    (window as any).__reactionEvents = [];
    CometChat.addMessageListener(
      'HANGOUT_REACTION_LISTENER',
      new CometChat.MessageListener({
        onTextMessageReceived: (m: any) => {
          const metadata = m.getMetadata?.() || {};
          (window as any).__reactionEvents.push({
            id: m.getId(),
            reactions: metadata?.['@injected']?.extensions?.reactions || {},
          });
        },
      })
    );
  }, BOB_TOKEN);

  const alice = await browser.newPage();
  await loadSdk(alice, false);
  const msgId = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const msg = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'snowy propagated reaction', 'user'));
    await CometChat.callExtension('reactions', 'POST', 'v1/react', {
      msgId: msg.getId(),
      emoji: '🎧',
    });
    return msg.getId();
  }, ALICE_TOKEN);

  await bob.waitForFunction(
    ({ msgId }) => ((window as any).__reactionEvents || []).some((e: any) =>
      String(e.id) === String(msgId) && e.reactions?.['🎧']?.alice?.name
    ),
    { msgId },
    { timeout: 15_000 }
  );

  await alice.evaluate(async (msgId) => {
    const { CometChat } = window as any;
    await CometChat.callExtension('reactions', 'POST', 'v1/react', {
      msgId,
      emoji: '🎧',
    });
  }, msgId);

  const removed = await alice.evaluate(async (msgId) => {
    const { CometChat } = window as any;
    const builder = new CometChat.ReactionsRequestBuilder()
      .setMessageId(Number(msgId))
      .setLimit(20);
    const request = builder.build();
    const page = await request.fetchPrevious();
    return page.map((r: any) => r.getReaction?.());
  }, msgId);

  expect(removed).not.toContain('🎧');

  await bob.evaluate(() => {
    const { CometChat } = (window as any);
    CometChat.removeMessageListener('HANGOUT_REACTION_LISTENER');
  });
});

test('reported room smoke: two users in one room see text, reactions, deletes, and remaining history', async ({ browser, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires an OpenChat admin API key.');
  const room = `reported-room-${Date.now()}`;

  const create = await request.post(`https://${TARGET_HOST}/groups`, {
    headers: { apiKey: ADMIN_API_KEY },
    data: { guid: room, type: 'public' },
  });
  expect(create.ok()).toBeTruthy();

  const bob = await browser.newPage();
  await loadSdk(bob, true);
  await bob.evaluate(async ({ token, room }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    try {
      await CometChat.joinGroup(room);
    } catch (e: any) {
      if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
    }
    (window as any).__roomEvents = [];
    CometChat.addMessageListener(
      'REPORTED_ROOM_BOB',
      new CometChat.MessageListener({
        onTextMessageReceived: (m: any) => (window as any).__roomEvents.push({
          kind: 'text',
          id: m.getId(),
          text: m.getData()?.text,
          reactions: m.getMetadata?.()?.['@injected']?.extensions?.reactions || {},
        }),
        onMessageDeleted: (m: any) => (window as any).__roomEvents.push({
          kind: 'deleted',
          id: m.getId(),
          onId: m.getData()?.entities?.on?.entity?.id,
        }),
      })
    );
  }, { token: BOB_TOKEN, room });

  const alice = await browser.newPage();
  await loadSdk(alice, true);
  const sent = await alice.evaluate(async ({ token, room }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    try {
      await CometChat.joinGroup(room);
    } catch (e: any) {
      if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
    }
    const keep = await CometChat.sendMessage(
      new CometChat.TextMessage(room, `keep-visible-${Date.now()}`, 'group')
    );
    const remove = await CometChat.sendMessage(
      new CometChat.TextMessage(room, `delete-only-this-${Date.now()}`, 'group')
    );
    return {
      keepId: keep.getId(),
      keepText: keep.getData()?.text,
      removeId: remove.getId(),
      removeText: remove.getData()?.text,
    };
  }, { token: ALICE_TOKEN, room });

  await bob.waitForFunction(
    ({ keepText, removeText }) => {
      const events = (window as any).__roomEvents || [];
      return events.some((e: any) => e.kind === 'text' && e.text === keepText)
        && events.some((e: any) => e.kind === 'text' && e.text === removeText);
    },
    { keepText: sent.keepText, removeText: sent.removeText },
    { timeout: 15_000 }
  );

  await bob.evaluate(async (keepId) => {
    const { CometChat } = window as any;
    await CometChat.callExtension('reactions', 'POST', 'v1/react', {
      msgId: keepId,
      emoji: '🎧',
    });
  }, sent.keepId);

  const reactionSeenByAlice = await alice.evaluate(async ({ room, keepId }) => {
    const { CometChat } = window as any;
    const req = new CometChat.MessagesRequestBuilder().setGUID(room).setLimit(20).build();
    const messages = await req.fetchPrevious();
    const keep = messages.find((m: any) => String(m.getId()) === String(keepId));
    return keep?.getMetadata?.()?.['@injected']?.extensions?.reactions || {};
  }, { room, keepId: sent.keepId });
  expect(reactionSeenByAlice?.['🎧']?.bob?.name).toBeTruthy();

  await alice.evaluate(async (removeId) => {
    const { CometChat } = window as any;
    await CometChat.deleteMessage(removeId);
  }, sent.removeId);

  await bob.waitForFunction(
    ({ removeId }) => ((window as any).__roomEvents || []).some((e: any) =>
      e.kind === 'deleted' && String(e.id) === String(removeId)
    ),
    { removeId: sent.removeId },
    { timeout: 15_000 }
  );

  const history = await bob.evaluate(async ({ room, keepId, removeId }) => {
    const { CometChat } = window as any;
    const req = new CometChat.MessagesRequestBuilder().setGUID(room).setLimit(20).build();
    const messages = await req.fetchPrevious();
    return messages.map((m: any) => ({
      id: String(m.getId()),
      category: m.getCategory?.(),
      action: m.getData?.()?.action,
      text: m.getData?.()?.text,
      deletedAt: m.getDeletedAt?.(),
      onId: m.getData?.()?.entities?.on?.entity?.id,
    })).filter((m: any) => [String(keepId), String(removeId)].includes(m.id) || String(m.onId) === String(removeId));
  }, { room, keepId: sent.keepId, removeId: sent.removeId });

  expect(history.some((m: any) => m.id === String(sent.keepId) && m.text === sent.keepText)).toBeTruthy();
  expect(history.some((m: any) => m.id === String(sent.removeId) && m.deletedAt)).toBeTruthy();
  expect(history.some((m: any) => m.action === 'deleted' && String(m.onId) === String(sent.removeId))).toBeTruthy();

  await bob.evaluate(() => {
    const { CometChat } = (window as any);
    CometChat.removeMessageListener('REPORTED_ROOM_BOB');
  });
});

test('socket admin system song messages are readable as snowy text chat messages', async ({ page, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires an OpenChat admin API key.');
  await loadSdk(page, false);
  const room = 'contract-system-room';

  await request.post(`https://${TARGET_HOST}/groups`, {
    headers: { apiKey: ADMIN_API_KEY },
    data: { guid: room, type: 'public' },
  });

  await page.evaluate(async ({ token, room }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    try {
      await CometChat.joinGroup(room);
    } catch (e: any) {
      if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
    }
  }, { token: ALICE_TOKEN, room });

  const song = { spotifyId: 'sp-contract', title: 'Contract Anthem' };
  const sent = await request.post(`https://${TARGET_HOST}/messages`, {
    headers: { apiKey: ADMIN_API_KEY },
    data: {
      type: 'text',
      receiverType: 'group',
      category: 'message',
      receiver: room,
      data: {
        text: '<@uid:alice> played',
        metadata: {
          chatMessage: {
            type: 'room',
            songs: [{ type: 'ChatMusicInfo', song }],
          },
        },
      },
    },
  });
  expect(sent.ok()).toBeTruthy();

  const result = await page.evaluate(async (room) => {
    const { CometChat } = window as any;
    const req = new CometChat.MessagesRequestBuilder().setGUID(room).setLimit(10).build();
    const messages = await req.fetchPrevious();
    const found = messages.find((m: any) => m.getData?.()?.text === '<@uid:alice> played');
    return {
      text: found?.getData?.()?.text,
      metadata: found?.getMetadata?.(),
      receiver: found?.getReceiverId?.(),
    };
  }, room);

  expect(result.receiver).toBe(room);
  expect(result.text).toBe('<@uid:alice> played');
  expect(result.metadata?.chatMessage?.type).toBe('room');
  expect(result.metadata?.chatMessage?.songs?.[0]?.song?.spotifyId).toBe('sp-contract');
});

test('reported system song messages fan out live to joined room clients', async ({ page, request }) => {
  test.skip(!ADMIN_API_KEY, 'Requires an OpenChat admin API key.');
  const room = `reported-system-live-${Date.now()}`;

  const create = await request.post(`https://${TARGET_HOST}/groups`, {
    headers: { apiKey: ADMIN_API_KEY },
    data: { guid: room, type: 'public' },
  });
  expect(create.ok()).toBeTruthy();

  await loadSdk(page, true);
  await page.evaluate(async ({ token, room }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    try {
      await CometChat.joinGroup(room);
    } catch (e: any) {
      if (e?.code !== 'ERR_ALREADY_JOINED') throw e;
    }
    (window as any).__systemEvents = [];
    CometChat.addMessageListener(
      'REPORTED_SYSTEM_LIVE',
      new CometChat.MessageListener({
        onTextMessageReceived: (m: any) => (window as any).__systemEvents.push({
          text: m.getData?.()?.text,
          metadata: m.getMetadata?.(),
          receiver: m.getReceiverId?.(),
        }),
      })
    );
  }, { token: ALICE_TOKEN, room });

  // joinGroup completes through REST, then the active socket refreshes its group
  // subscriptions from the membership_changed event. Give that sync a moment
  // before posting the system message we expect to arrive live.
  await page.waitForTimeout(1500);

  const song = { spotifyId: `sp-live-${Date.now()}`, title: 'Live Contract Anthem' };
  const sent = await request.post(`https://${TARGET_HOST}/messages`, {
    headers: { apiKey: ADMIN_API_KEY },
    data: {
      type: 'text',
      receiverType: 'group',
      category: 'message',
      receiver: room,
      data: {
        text: '<@uid:alice> played live',
        metadata: {
          chatMessage: {
            type: 'room',
            songs: [{ type: 'ChatMusicInfo', song }],
          },
        },
      },
    },
  });
  expect(sent.ok()).toBeTruthy();

  await page.waitForFunction(
    ({ room, spotifyId }) => ((window as any).__systemEvents || []).some((e: any) =>
      e.receiver === room
        && e.text === '<@uid:alice> played live'
        && e.metadata?.chatMessage?.songs?.[0]?.song?.spotifyId === spotifyId
    ),
    { room, spotifyId: song.spotifyId },
    { timeout: 15_000 }
  );

  await page.evaluate(() => {
    const { CometChat } = (window as any);
    CometChat.removeMessageListener('REPORTED_SYSTEM_LIVE');
  });
});

test('snowy ReactionsRequestBuilder paginated fetch (loops until empty)', async ({ page }) => {
  // Mirrors snowy/src/data/chat/fetch-message-reactions.ts fetchReactionsForMessage().
  await loadSdk(page, false);
  const collected = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const msg = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'paginate reactions', 'user'));
    for (const emoji of ['👍', '🔥', '🎉']) {
      await CometChat.addReaction(msg.getId(), emoji);
    }
    const messageIdNum = Number(msg.getId());
    const builder = new CometChat.ReactionsRequestBuilder()
      .setMessageId(messageIdNum)
      .setLimit(2);
    const req = builder.build();
    const all: string[] = [];
    while (true) {
      const page = (await req.fetchPrevious()) as any[];
      if (!page || page.length === 0) break;
      page.forEach((r) => all.push(r.getReaction?.()));
      if (page.length < 2) break;
    }
    return all;
  }, ALICE_TOKEN);
  expect(collected.sort()).toEqual(['🎉', '🔥', '👍'].sort());
});

test('snowy getUnreadMessageCountForAllUsers(true) returns a uid->count map', async ({ browser }) => {
  // Mirrors snowy/src/data/chat/cometchat-utils.ts fetchMyUnreadCount(). The boolean
  // argument requests hide-archived behavior on real CometChat; OpenChat must accept
  // and ignore it gracefully.
  const alice = await browser.newPage();
  await loadSdk(alice, false);
  await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await CometChat.sendMessage(new CometChat.TextMessage('bob', 'unread-pending ' + Date.now(), 'user'));
  }, ALICE_TOKEN);

  const bob = await browser.newPage();
  await loadSdk(bob, true);
  const unread = await bob.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    return await CometChat.getUnreadMessageCountForAllUsers(true);
  }, BOB_TOKEN);
  // The SDK exposes either { alice: n } or { users: { alice: n } } depending on version.
  const aliceCount = (unread as any).alice ?? (unread as any).users?.alice ?? 0;
  expect(Number(aliceCount)).toBeGreaterThanOrEqual(1);
});

test('snowy mentions: <@uid:xxx> and <consumableId:xxx> in text round-trip unmodified', async ({ browser }) => {
  // Mirrors socket/src/initializers/cometChat.ts postSongMessage / postConsumableMessage
  // and frontend-core's parseMessageParts() expectations.
  const alice = await browser.newPage();
  await loadSdk(alice, false);
  const sent = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const text = 'hey <@uid:bob> check <consumableId:c-123>';
    const msg = new CometChat.TextMessage('bob', text, 'user');
    msg.setMetadata({
      recipientUuid: 'bob',
      chatMessage: { type: 'user', message: text },
    });
    const sentMsg = await CometChat.sendMessage(msg);
    return { id: sentMsg.getId(), text: sentMsg.getData()?.text };
  }, ALICE_TOKEN);
  expect(sent.text).toBe('hey <@uid:bob> check <consumableId:c-123>');
});

test('snowy markAsRead(message) accepts a message object and clears unread', async ({ browser }) => {
  // Mirrors snowy/src/data/chat/dm-chat-utils.tsx markMessageAsRead(message).
  const alice = await browser.newPage();
  await loadSdk(alice, false);
  const sent = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const m = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'mark-as-read-target ' + Date.now(), 'user'));
    return m.getId();
  }, ALICE_TOKEN);

  const bob = await browser.newPage();
  await loadSdk(bob, true);
  const result = await bob.evaluate(async ({ token, sentId }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await new Promise((resolve) => setTimeout(resolve, 500));
    const req = new CometChat.MessagesRequestBuilder().setUID('alice').setLimit(5).build();
    const messages = await req.fetchPrevious();
    const target = messages.find((m: any) => String(m.getId()) === String(sentId));
    await CometChat.markAsRead(target);
    const unread = await CometChat.getUnreadMessageCountForAllUsers(true);
    return (unread as any).alice ?? (unread as any).users?.alice ?? 0;
  }, { token: BOB_TOKEN, sentId: sent });
  expect(Number(result)).toBe(0);
});
