// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License v2 or later.
// See the LICENSE file at the repository root for details.

// purgeExpiredRooms の対象選び。エミュレータのテスト（tool/rules_test）からも呼ぶので
// firebase-functions に依存させず、ここに切り出している。

/**
 * purge対象のルームキーを集める。
 * - meta.expiresAt <= now（失効した。meta や expiresAt が無いものも null として先頭に並ぶので拾う）
 * - meta.active === false（hostが終了した。現行アプリは終了時に expiresAt も now に縮めるので
 *   上の条件で拾えるが、expiresAt を縮めない v0.11.0 以前の終了分もすぐ消すために別に引く）
 * どちらも `database.rules.json` の `rooms/.indexOn` を使う（全件 get しない）。
 *
 * @param {import("firebase-admin/database").Database} db
 * @param {number} now epoch ms
 * @return {Promise<Set<string>>} ルームコードの集合
 */
async function collectPurgeTargets(db, now) {
  const rooms = db.ref("rooms");
  const [expired, ended] = await Promise.all([
    rooms.orderByChild("meta/expiresAt").endAt(now).get(),
    rooms.orderByChild("meta/active").equalTo(false).get(),
  ]);
  const keys = new Set();
  expired.forEach((room) => {
    keys.add(room.key);
  });
  ended.forEach((room) => {
    keys.add(room.key);
  });
  return keys;
}

module.exports = {collectPurgeTargets};
