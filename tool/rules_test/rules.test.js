// パーティ位置共有の RTDB セキュリティルール（database.rules.json）のテスト。
//
// Firebase Local Emulator（RTDB）に対して、アプリが実際に送る書き込み
// （lib/services/party/rtdb_room_repository.dart / rtdb_peer_source.dart の形をそのまま写したもの）が
// 通ること、攻撃の書き込み・読み取りが弾かれることを確かめる。
// v0.11.0（Play クローズドテスト配布版）の書き込み形式も「旧版」として確かめる。
//
// 回し方: tool/rules_test で `npm install` → `npm test`
// （firebase emulators:exec が RTDB エミュレータを立てて node --test を流す。Java 17 が要る）

const {test, before, beforeEach, after, describe} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {collectPurgeTargets} = require('../../functions/purge');

const SERVER_TS = {'.sv': 'timestamp'};
const HOUR = 3600 * 1000;
const CODE = 'AB23CD45';

let env;

before(async () => {
  const [host, port] = (process.env.FIREBASE_DATABASE_EMULATOR_HOST || '127.0.0.1:9000').split(':');
  env = await initializeTestEnvironment({
    projectId: 'demo-kokage-map',
    database: {
      rules: fs.readFileSync(path.join(__dirname, '../../database.rules.json'), 'utf8'),
      host,
      port: Number(port),
    },
  });
});

beforeEach(async () => {
  await env.clearDatabase();
});

after(async () => {
  await env?.cleanup();
});

const db = (uid) => env.authenticatedContext(uid).database();
const anon = () => env.unauthenticatedContext().database();

// ── アプリの書き込みを写したもの ─────────────────────────────

/** RtdbRoomRepository.createRoom（meta → members の順次書き込み） */
async function appCreateRoom(uid, code = CODE, {name = '山の班', ttl = 24 * HOUR} = {}) {
  await db(uid).ref(`rooms/${code}/meta`).set({
    hostUid: uid,
    active: true,
    createdAt: SERVER_TS,
    expiresAt: Date.now() + ttl,
    ...(name ? {name} : {}),
  });
  await db(uid).ref(`rooms/${code}/members/${uid}`).set({
    name: name || 'host',
    role: 'host',
  });
}

/** RtdbRoomRepository.joinRoom */
const appJoin = (uid, code = CODE, name = 'ゲスト') =>
  db(uid).ref(`rooms/${code}/members/${uid}`).set({name, role: 'guest'});

/** RtdbPeerSource.publishPosition（PeerPosition.toLiveMap + ts） */
const appPublish = (uid, code = CODE) =>
  db(uid).ref(`rooms/${code}/live/${uid}`).set({
    lat: 33.9312,
    lng: 135.9633,
    alt: 412.5,
    acc: 4.2,
    bearing: 271.0,
    speed: 1.1,
    battery: 76,
    connected: true,
    ts: SERVER_TS,
  });

/** RtdbPeerSource._armDisconnectHandler の onDisconnect と同じ部分更新 */
const appDisconnectMark = (uid, code = CODE) =>
  db(uid).ref(`rooms/${code}/live/${uid}/connected`).set(false);

/** RtdbPeerSource.publishTrack */
const appPublishTrack = (uid, code = CODE) =>
  db(uid).ref(`rooms/${code}/tracks/${uid}`).push().set({
    pts: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
    from: Date.now() - 60000,
    to: Date.now() - 1000,
  });

/** RtdbRoomRepository.leaveRoom */
async function appLeave(uid, code = CODE) {
  await db(uid).ref(`rooms/${code}/live/${uid}`).remove();
  await db(uid).ref(`rooms/${code}/members/${uid}`).remove();
}

/** RtdbRoomRepository.endRoom（現行: active=false と expiresAt=いま） */
const appEnd = (uid, code = CODE) =>
  db(uid).ref(`rooms/${code}/meta`).update({active: false, expiresAt: SERVER_TS});

/** v0.11.0 の endRoom（active=false だけ） */
const oldEnd = (uid, code = CODE) => db(uid).ref(`rooms/${code}/meta/active`).set(false);

/** RtdbRoomRepository.kickMember（現行: members 削除と banned を同時に） */
const appKick = (hostUid, uid, code = CODE) =>
  db(hostUid).ref(`rooms/${code}`).update({[`members/${uid}`]: null, [`banned/${uid}`]: true});

/** v0.11.0 の kickMember（members 削除だけ） */
const oldKick = (hostUid, uid, code = CODE) => db(hostUid).ref(`rooms/${code}/members/${uid}`).remove();

/** ルールを素通しで任意の状態を置く */
const seed = (p, v) => env.withSecurityRulesDisabled((ctx) => ctx.database().ref(p).set(v));

/** 期限切れのルームを置く（host と guest がメンバー） */
async function seedExpiredRoom(code = CODE) {
  await seed(`rooms/${code}`, {
    meta: {hostUid: 'host', active: true, createdAt: Date.now() - 25 * HOUR, expiresAt: Date.now() - 1000},
    members: {host: {name: 'h', role: 'host'}, guest: {name: 'g', role: 'guest'}},
  });
}

// ── 正常系 ───────────────────────────────────────────────

describe('正常系（現行アプリの書き込み）', () => {
  test('作成（部屋名あり・なし）', async () => {
    await assertSucceeds(appCreateRoom('host'));
    await assertSucceeds(appCreateRoom('host2', 'ZZ98XY76', {name: null}));
  });

  test('参加 → 読み取り → 位置送信 → 切断マーク → 軌跡送信', async () => {
    await appCreateRoom('host');
    await assertSucceeds(appJoin('guest'));
    await assertSucceeds(db('guest').ref(`rooms/${CODE}`).get());
    await assertSucceeds(db('guest').ref(`rooms/${CODE}/meta`).get());
    await assertSucceeds(appPublish('guest'));
    await assertSucceeds(appDisconnectMark('guest'));
    await assertSucceeds(appPublishTrack('guest'));
    await assertSucceeds(appPublish('host'));
  });

  test('ゲストの退出', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appPublish('guest');
    await assertSucceeds(appLeave('guest'));
  });

  test('キック（members 削除と banned を同時に）', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appPublish('guest');
    await assertSucceeds(appKick('host', 'guest'));
    // 蹴られた側の後始末（自分の live を消す・members の削除）は通す
    await assertSucceeds(appLeave('guest'));
  });

  test('ホストの退出（leaveRoom → endRoom の順）と、その後のゲストの退出', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appPublish('host');
    await appPublish('guest');
    await assertSucceeds(appLeave('host'));
    await assertSucceeds(appEnd('host'));
    // 終了後もゲストは自分の live/members を消せる（自動退出の後始末）
    await assertSucceeds(appLeave('guest'));
  });

  test('期限切れの後でもホストは終了できる（expiresAt を いま に寄せる）', async () => {
    await seedExpiredRoom();
    await assertSucceeds(appEnd('host'));
  });

  test('tool/party_fake_peer.js の書き込み（作成・参加・位置・終了）', async () => {
    // create
    await assertSucceeds(db('fake').ref(`rooms/${CODE}/meta`).set({
      hostUid: 'fake', active: true, createdAt: SERVER_TS, expiresAt: Date.now() + 24 * HOUR, name: 'FakeHost',
    }));
    await assertSucceeds(db('fake').ref(`rooms/${CODE}/members/fake`).set({name: 'FakeHost', role: 'host'}));
    // join + live
    await assertSucceeds(db('peer').ref(`rooms/${CODE}/members/peer`).set({name: 'FakeGuest', role: 'guest'}));
    await assertSucceeds(db('peer').ref(`rooms/${CODE}/live/peer`).set({
      lat: 33.93, lng: 135.96, speed: 1.3, bearing: 18, battery: 88, connected: true, ts: SERVER_TS,
    }));
    // cleanup（host は meta を PATCH で閉じる）
    await assertSucceeds(db('fake').ref(`rooms/${CODE}/live/fake`).remove());
    await assertSucceeds(db('fake').ref(`rooms/${CODE}/members/fake`).remove());
    await assertSucceeds(db('fake').ref(`rooms/${CODE}/meta`).update({active: false, expiresAt: SERVER_TS}));
  });
});

describe('旧版（v0.11.0）の書き込み形式', () => {
  test('作成・参加・位置・軌跡・退出は同じ形なので通る', async () => {
    await assertSucceeds(appCreateRoom('host'));
    await assertSucceeds(appJoin('guest'));
    await assertSucceeds(appPublish('guest'));
    await assertSucceeds(appPublishTrack('guest'));
    await assertSucceeds(appLeave('guest'));
  });

  test('旧版の終了（active=false だけ）は通る', async () => {
    await appCreateRoom('host');
    await assertSucceeds(oldEnd('host'));
  });

  test('旧版のキック（members 削除だけ）は通るが、banned が付かないので再参加を防げない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await assertSucceeds(oldKick('host', 'guest'));
    await assertSucceeds(appJoin('guest'));
  });

  test('旧版のゲストは終了後に位置を送ろうとして弾かれる（送信失敗はログだけ）', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await oldEnd('host');
    await assertFails(appPublish('guest'));
    await assertFails(appPublishTrack('guest'));
  });
});

// ── 攻撃系 ───────────────────────────────────────────────

describe('攻撃: キック後の再参加', () => {
  test('蹴られた uid は同じコードで members を書き直せない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appKick('host', 'guest');
    await assertFails(appJoin('guest'));
    await assertFails(appPublish('guest'));
    await assertFails(appPublishTrack('guest'));
    await assertFails(db('guest').ref(`rooms/${CODE}`).get());
  });

  test('ゲストは banned を書けない・消せない（自分の BAN を外す）', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await assertFails(db('guest').ref(`rooms/${CODE}/banned/other`).set(true));
    await appKick('host', 'guest');
    await assertFails(db('guest').ref(`rooms/${CODE}/banned/guest`).remove());
  });

  test('banned は true だけ', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref(`rooms/${CODE}/banned/x`).set(false));
    await assertFails(db('host').ref(`rooms/${CODE}/banned/x`).set({a: 1}));
  });
});

describe('攻撃: 終了・失効後の送信', () => {
  test('ホスト終了後はゲストの位置・軌跡が弾かれ、新規参加もできない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appEnd('host');
    await assertFails(appPublish('guest'));
    await assertFails(appDisconnectMark('guest'));
    await assertFails(appPublishTrack('guest'));
    await assertFails(appJoin('newcomer'));
  });

  test('失効後はゲストの位置・軌跡が弾かれ、新規参加もできない', async () => {
    await seedExpiredRoom();
    await assertFails(appPublish('guest'));
    await assertFails(appPublishTrack('guest'));
    await assertFails(appJoin('newcomer'));
  });

  test('ホストは終了後に寿命を延ばして復活させられない', async () => {
    await appCreateRoom('host');
    await appEnd('host');
    await assertFails(db('host').ref(`rooms/${CODE}/meta/expiresAt`).set(Date.now() + HOUR));
  });
});

describe('攻撃: 寿命なし・寿命過大のルーム作成', () => {
  test('expiresAt なしは作れない', async () => {
    await assertFails(db('a').ref(`rooms/${CODE}/meta`).set({hostUid: 'a', active: true, createdAt: SERVER_TS}));
  });

  test('上限（24h + 2h）を超える expiresAt は作れない。25h は通る', async () => {
    await assertFails(appCreateRoom('a', CODE, {ttl: 27 * HOUR}));
    await assertFails(appCreateRoom('a', 'ZZ98XY76', {ttl: 10 * 365 * 24 * HOUR}));
    await assertSucceeds(appCreateRoom('a', 'QQ98XY76', {ttl: 25 * HOUR}));
  });

  test('createdAt はサーバー時刻だけ・以後変えられない', async () => {
    await assertFails(db('a').ref(`rooms/${CODE}/meta`).set({
      hostUid: 'a', active: true, createdAt: Date.now() - HOUR, expiresAt: Date.now() + HOUR,
    }));
    await appCreateRoom('a');
    await assertFails(db('a').ref(`rooms/${CODE}/meta/createdAt`).set(Date.now()));
  });

  test('ホストは寿命を延ばせない（縮めるのは可）', async () => {
    await appCreateRoom('a', CODE, {ttl: HOUR});
    await assertFails(db('a').ref(`rooms/${CODE}/meta/expiresAt`).set(Date.now() + 20 * HOUR));
    await assertSucceeds(db('a').ref(`rooms/${CODE}/meta/expiresAt`).set(Date.now() + HOUR / 2));
  });
});

describe('攻撃: 不正なルームコード', () => {
  for (const bad of ['ab23cd45', 'AB23CD4O', 'AB23CD41', 'AB23CDIL', 'AB23CD4', 'AB23CD456', 'AB23-D45']) {
    test(`${bad} にはルームを作れない`, async () => {
      await assertFails(appCreateRoom('a', bad));
    });
  }

  test('不正コードの下に members/live を置けない', async () => {
    const bad = 'xxxxxxxx';
    await seed(`rooms/${bad}/meta`, {hostUid: 'h', active: true, createdAt: Date.now(), expiresAt: Date.now() + HOUR});
    await assertFails(appJoin('a', bad));
    await assertFails(appPublish('a', bad));
  });
});

describe('攻撃: role の偽装', () => {
  test('ゲストは role=host で参加できない', async () => {
    await appCreateRoom('host');
    await assertFails(db('guest').ref(`rooms/${CODE}/members/guest`).set({name: 'x', role: 'host'}));
  });

  test('参加後に自分の role を host に書き換えられない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await assertFails(db('guest').ref(`rooms/${CODE}/members/guest/role`).set('host'));
  });

  test('role は host/guest 以外を受けない', async () => {
    await appCreateRoom('host');
    await assertFails(db('guest').ref(`rooms/${CODE}/members/guest`).set({name: 'x', role: 'admin'}));
  });
});

describe('攻撃: meta の削除 → 乗っ取り', () => {
  test('ホストでも meta を消せない', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref(`rooms/${CODE}/meta`).remove());
    await assertFails(db('host').ref(`rooms/${CODE}/meta`).set(null));
  });

  test('meta の必須項目を消せない', async () => {
    await appCreateRoom('host');
    for (const k of ['hostUid', 'active', 'createdAt', 'expiresAt']) {
      await assertFails(db('host').ref(`rooms/${CODE}/meta/${k}`).remove());
    }
  });

  test('他人は既存ルームの meta を自分名義で書けない', async () => {
    await appCreateRoom('host');
    await assertFails(appCreateRoom('attacker'));
    await assertFails(db('attacker').ref(`rooms/${CODE}/meta`).update({hostUid: 'attacker'}));
  });

  test('ホストは hostUid を書き換えられない', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref(`rooms/${CODE}/meta/hostUid`).set('someone'));
  });

  test('ルームごと消せない', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref(`rooms/${CODE}`).remove());
  });
});

describe('攻撃: 他人の領域への書き込み', () => {
  test('他人の live / tracks に書けない・消せない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appPublish('host');
    await assertFails(db('guest').ref(`rooms/${CODE}/live/host`).set({lat: 0, lng: 0, ts: SERVER_TS}));
    await assertFails(db('guest').ref(`rooms/${CODE}/live/host`).remove());
    await assertFails(db('guest').ref(`rooms/${CODE}/tracks/host`).push().set({pts: 'a', from: 1, to: 2}));
  });

  test('ゲストは他のメンバーを消せない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appJoin('guest2');
    await assertFails(db('guest').ref(`rooms/${CODE}/members/guest2`).remove());
    await assertFails(db('guest').ref(`rooms/${CODE}/members/host`).remove());
  });

  test('ホストは他人の members を書き換えられない（消すだけ）', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await assertFails(db('host').ref(`rooms/${CODE}/members/guest`).set({name: 'x', role: 'guest'}));
    await assertFails(db('host').ref(`rooms/${CODE}/members/ghost`).set({name: 'x', role: 'guest'}));
  });

  test('非メンバーは live を書けない', async () => {
    await appCreateRoom('host');
    await assertFails(appPublish('stranger'));
  });

  test('スキーマ外のキーを置けない', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref(`rooms/${CODE}/junk`).set('x'));
    await assertFails(db('host').ref(`rooms/${CODE}/meta/junk`).set('x'));
    await appJoin('guest');
    await assertFails(db('guest').ref(`rooms/${CODE}/live/guest`).set({lat: 0, lng: 0, ts: SERVER_TS, junk: 1}));
  });

  test('範囲外の座標・偽の時刻は送れない', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await assertFails(db('guest').ref(`rooms/${CODE}/live/guest`).set({lat: 95, lng: 0, ts: SERVER_TS}));
    await assertFails(db('guest').ref(`rooms/${CODE}/live/guest`).set({lat: 0, lng: 0, ts: Date.now() + HOUR}));
  });
});

describe('攻撃: 非メンバーの読み取り', () => {
  test('非メンバー・未認証はルームを読めない', async () => {
    await appCreateRoom('host');
    await appPublish('host');
    for (const p of ['', '/meta', '/members', '/live', '/live/host', '/tracks']) {
      await assertFails(db('stranger').ref(`rooms/${CODE}${p}`).get());
      await assertFails(anon().ref(`rooms/${CODE}${p}`).get());
    }
  });

  test('rooms 一覧は誰も読めない', async () => {
    await appCreateRoom('host');
    await assertFails(db('host').ref('rooms').get());
  });

  test('退出したメンバーは読めなくなる', async () => {
    await appCreateRoom('host');
    await appJoin('guest');
    await appLeave('guest');
    await assertFails(db('guest').ref(`rooms/${CODE}`).get());
  });
});

describe('定期purge（functions/purge.js）', () => {
  test('失効・終了・meta なしを拾い、生きている部屋は残す', async () => {
    const now = Date.now();
    const meta = (o) => ({hostUid: 'h', active: true, createdAt: now - HOUR, expiresAt: now + HOUR, ...o});
    await seed('rooms', {
      ALIVE234: {meta: meta({})},
      EXPRD234: {meta: meta({expiresAt: now - 1})},
      ENDED234: {meta: meta({active: false, expiresAt: now})}, // 現行の終了
      OLDEND23: {meta: meta({active: false})}, // v0.11.0 の終了（expiresAt は先のまま）
      NOMETA23: {live: {x: {lat: 0, lng: 0, ts: now}}},
    });
    let keys;
    await env.withSecurityRulesDisabled(async (ctx) => {
      keys = await collectPurgeTargets(ctx.database(), now);
    });
    const got = [...keys].sort();
    require('node:assert').deepStrictEqual(got, ['ENDED234', 'EXPRD234', 'NOMETA23', 'OLDEND23']);
  });
});
