#!/usr/bin/env node
// 位置共有パーティ: 偽装ピア（テスト用クライアント）
//
// 2台目の端末/エミュを用意せずに、RTDB と直接やり取りする「動くピア」を作る。
// 匿名サインイン → ルーム参加(or作成) → live/{uid} に移動する位置を publish。
// 実機アプリ側の地図に、このピアのマーカーが動いて見える。
//
// 依存なし（Node 18+ の global fetch を使用）。
//
// 使い方:
//   node tool/party_fake_peer.js join <ROOMCODE> [name] [centerLat] [centerLng]
//   node tool/party_fake_peer.js create [name]        # 自分でルームを作ってホストになる
//
// 例（実機が作ったルーム ABCD2345 に、端末のGPS(33.931,135.963)付近で参加）:
//   node tool/party_fake_peer.js join ABCD2345 Fake太郎 33.9312 135.9633
//
// Ctrl+C で live/members を掃除して退出する（create で作った部屋は終了させる）。
// ホストに退出させられた・ルームが終了/失効したら、送信がルールで弾かれた時点で終わる。
//
// 接続先は lib/firebase_options.dart の値（プロジェクト nemurigi-kobo）。
// エミュレータに向けるときは環境変数で切り替える:
//   FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9000 \
//     node tool/party_fake_peer.js create

const crypto = require('node:crypto');

// android client key（機密ではない。lib/firebase_options.dart の android.apiKey）。
// キー制限で弾かれるときは PARTY_API_KEY で web 側（web.apiKey）などに差し替える。
const API_KEY = process.env.PARTY_API_KEY || 'AIzaSyABB0YHs-KSUE7_t047WFkQ8v9GRe3LQjs';
const DB_NAMESPACE = 'nemurigi-kobo-default-rtdb';
const AUTH_EMU = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const DB_EMU = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
const DB = DB_EMU
  ? `http://${DB_EMU}`
  : `https://${DB_NAMESPACE}.asia-southeast1.firebasedatabase.app`;
const AUTH_BASE = AUTH_EMU
  ? `http://${AUTH_EMU}/identitytoolkit.googleapis.com`
  : 'https://identitytoolkit.googleapis.com';
const SERVER_TS = { '.sv': 'timestamp' };
const CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; // 0/O/1/I/L を除外（RoomCodeGeneratorと一致）
// ルームの寿命（アプリの RtdbRoomRepository.createRoom と同じ 24h。ルールの上限は 26h）
const ROOM_TTL_MS = 24 * 3600 * 1000;

/** RTDB の REST URL（エミュレータなら ns を付ける） */
function dbUrl(path, idToken) {
  const ns = DB_EMU ? `&ns=${DB_NAMESPACE}` : '';
  return `${DB}/${path}.json?auth=${idToken}${ns}`;
}

const args = process.argv.slice(2);
const mode = args[0];

function die(msg) {
  console.error('ERROR:', msg);
  process.exit(1);
}

async function anonSignIn() {
  const res = await fetch(
    `${AUTH_BASE}/v1/accounts:signUp?key=${API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const json = await res.json();
  if (!res.ok) die(`匿名サインイン失敗: ${JSON.stringify(json)}`);
  return { idToken: json.idToken, uid: json.localId };
}

async function write(method, path, body, idToken) {
  const res = await fetch(dbUrl(path, idToken), {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}

async function put(path, body, idToken) {
  const r = await write('PUT', path, body, idToken);
  if (!r.ok) die(`PUT ${path} 失敗 (${r.status}): ${r.text}`);
  return r.text;
}

async function del(path, idToken) {
  await fetch(dbUrl(path, idToken), { method: 'DELETE' });
}

async function get(path, idToken) {
  const res = await fetch(dbUrl(path, idToken));
  if (!res.ok) return null;
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function randomCode(len = 8) {
  let s = '';
  for (let i = 0; i < len; i++) {
    s += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
  }
  return s;
}

async function main() {
  const { idToken, uid } = await anonSignIn();
  console.log(`匿名サインインOK uid=${uid}`);

  let code;
  let name;
  let centerLat = 33.9312;
  let centerLng = 135.9633;
  let follow = false; // ホスト（ユーザー）の位置を毎tick読み直して中心にする
  let hostUid = null;

  if (mode === 'create') {
    name = args[1] || 'FakeHost';
    code = randomCode();
    // meta を先に書く（root は書き込み前状態のため members と分ける）。
    await put(
      `rooms/${code}/meta`,
      {
        hostUid: uid,
        active: true,
        createdAt: SERVER_TS,
        expiresAt: Date.now() + ROOM_TTL_MS,
        name,
      },
      idToken,
    );
    await put(`rooms/${code}/members/${uid}`, { name, role: 'host' }, idToken);
    console.log(`ルーム作成: コード = ${code} （このコードで参加できます）`);
  } else if (mode === 'join') {
    code = args[1];
    if (!code) die('ルームコードを指定してください: join <CODE> [name] [lat] [lng]');
    code = code.toUpperCase();
    name = args[2] || 'FakeGuest';
    // join <CODE> <name> follow  … ホスト位置を追従して周回
    // join <CODE> <name> <lat> <lng> … 固定中心で周回
    if (args[3] === 'follow') {
      follow = true;
    } else {
      if (args[3]) centerLat = parseFloat(args[3]);
      if (args[4]) centerLng = parseFloat(args[4]);
    }
    await put(`rooms/${code}/members/${uid}`, { name, role: 'guest' }, idToken);
    console.log(`ルーム ${code} に参加: ${name}`);
    if (follow) {
      hostUid = await get(`rooms/${code}/meta/hostUid`, idToken);
      const hp = hostUid ? await get(`rooms/${code}/live/${hostUid}`, idToken) : null;
      if (hp && typeof hp.lat === 'number') {
        centerLat = hp.lat;
        centerLng = hp.lng;
      }
      console.log(`follow モード: host=${hostUid} の周りを周回`);
    }
  } else {
    die('mode は create か join。例: node tool/party_fake_peer.js join ABCD2345 Fake太郎');
  }

  // クリーンアップ
  let stopping = false;
  const cleanup = async () => {
    if (stopping) return;
    stopping = true;
    console.log('\n退出中（live/members を削除）...');
    await del(`rooms/${code}/live/${uid}`, idToken);
    await del(`rooms/${code}/members/${uid}`, idToken);
    if (mode === 'create') {
      // アプリの endRoom と同じ。meta は消さず（ルールが禁止）、終了フラグと失効時刻で閉じる
      await write('PATCH', `rooms/${code}/meta`, { active: false, expiresAt: SERVER_TS }, idToken);
    }
    console.log('退出しました。');
    process.exit(0);
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  // 位置を publish するループ（中心の周りを円運動で周回）。
  let t = 0;
  let battery = 88;
  const R = follow ? 0.0005 : 0.0009; // 度。follow時は約55mで近くを周回。
  const tick = async () => {
    t++;
    // follow: 毎tickでホスト（ユーザー）の最新位置を読み直して中心にする。
    if (follow && hostUid) {
      const hp = await get(`rooms/${code}/live/${hostUid}`, idToken);
      if (hp && typeof hp.lat === 'number' && typeof hp.lng === 'number') {
        centerLat = hp.lat;
        centerLng = hp.lng;
      }
    }
    const lat = centerLat + R * Math.sin(t / 6);
    // 経度は緯度で縮むので cos(lat) で割って画面上で真円にする。
    const lng =
      centerLng + (R * Math.cos(t / 6)) / Math.cos((centerLat * Math.PI) / 180);
    const bearing = (t * 18) % 360;
    if (t % 20 === 0 && battery > 5) battery--;
    const r = await write(
      'PUT',
      `rooms/${code}/live/${uid}`,
      {
        lat,
        lng,
        speed: 1.3,
        bearing,
        battery,
        connected: true,
        ts: SERVER_TS,
      },
      idToken,
    );
    if (!r.ok) {
      // ルールに弾かれた＝退出させられたか、ルームが終了・失効した
      console.log(`\n送信が拒否されました (${r.status})。退出させられたか、ルームが終了/失効しています。`);
      await del(`rooms/${code}/live/${uid}`, idToken);
      process.exit(0);
    }
    process.stdout.write(
      `\r[${t}] publish lat=${lat.toFixed(6)} lng=${lng.toFixed(6)} bearing=${bearing} batt=${battery}%   `,
    );
  };
  await tick();
  setInterval(tick, 3000);
  console.log('位置を3秒ごとに送信中。Ctrl+C で退出。');
}

main().catch((e) => die(e.stack || String(e)));
