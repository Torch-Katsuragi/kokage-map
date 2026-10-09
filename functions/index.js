// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License v2 or later.
// See the LICENSE file at the repository root for details.

// こかげマップ パーティ位置共有のメンテナンス用 Cloud Functions。
//
// 目的: 失効・終了したルームを定期削除し、RTDBのstorage肥大とコストを抑える
// （設計: docs/technical/location-sharing.md §8 コスト/クリーンアップ）。

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {logger} = require("firebase-functions");
// firebase-admin 14 で名前空間 API（admin.database()）が無くなったので、モジュール形式で読む
const {initializeApp} = require("firebase-admin/app");
const {getDatabase} = require("firebase-admin/database");
const {collectPurgeTargets} = require("./purge");

initializeApp();

/**
 * 失効/終了ルームの定期purge。
 * - meta.active === false（hostが終了した）
 * - meta.expiresAt <= now（失効した）
 * のいずれかに該当するルームをまとめて削除する。
 */
exports.purgeExpiredRooms = onSchedule(
    {
      schedule: "every 24 hours",
      timeZone: "Asia/Tokyo",
      region: "asia-southeast1",
    },
    async () => {
      const db = getDatabase();
      const keys = await collectPurgeTargets(db, Date.now());

      const updates = {};
      for (const key of keys) {
        updates[key] = null; // null書込みで削除
      }
      if (keys.size > 0) {
        await db.ref("rooms").update(updates);
      }
      logger.info(`purgeExpiredRooms: ${keys.size} 件のルームを削除`);
    },
);
