---
title: 位置共有 Firebase セットアップ手順
tags: [technical, location-sharing, firebase, setup, runbook]
---

# 位置共有 Firebase セットアップ手順

[[location-sharing]] のバックエンド（Firebase RTDB）を有効化するための手順書。
**コンソール操作とアカウント認証が必要なため、これは開発者（プロジェクトオーナー）が手動で行う。**

実装側は Firebase を [PeerSource] 1点に隔離してあるので、この手順が済めば
`RtdbPeerSource` を差し込むだけで動く（コア・テストは Firebase 非依存で完成済み）。

> **プラットフォーム制約**: `firebase_database` は **Windows デスクトップ未対応**。
> このため位置共有機能は **Android/iOS 限定**で有効化し、Windows では無効化する
> （`PartyLocationStore` のコアは全プラットフォームで動くが、RTDBトランスポートが無い）。

---

## 0. 前提

- [[user-google-ai-ultra]] の **$100/月 GCPクレジット**が Firebase に適用される。
- リージョンは RTDB の **`asia-southeast1`（シンガポール）**を使用（日本から遅延50〜80ms）。

## 1. Firebaseプロジェクト作成と課金

1. [Firebase Console](https://console.firebase.google.com/) で新規プロジェクト作成（既存GCPプロジェクトに紐付け可）。
2. **Blazeプラン**にアップグレード（Cloud Functions に必須）。Cloud Billing アカウントを紐付け、Developer Program の $100/月クレジットが効いていることを確認。

## 2. 各サービスの有効化（コンソール）

1. **Realtime Database** を作成。ロケーションは `asia-southeast1`。最初はロックモードでOK（ルールは手順4で配信）。
2. **Authentication** → Sign-in method → **匿名（Anonymous）** を有効化。
3. **App Check** を有効化（Android: Play Integrity / iOS: App Attest）。RTDBで App Check を Enforce する。
   - これがコスト攻撃・荒らし対策の本命（RTDBはルールでレート制限不可）。

## 3. Flutterアプリへの接続設定

```bash
# FlutterFire CLI（未導入なら）
dart pub global activate flutterfire_cli

# 対象プラットフォームのみ（Windowsは除外）
flutterfire configure --platforms=android,ios
```

- これで `lib/firebase_options.dart` と Android `google-services.json` 等が生成される。
- 依存パッケージを追加:

```bash
flutter pub add firebase_core firebase_database firebase_auth
```

> `google-services.json` はリポジトリにコミットしない方針なら `.gitignore` に追加。
> （APIキーは制限付き公開情報だが、プロジェクト方針に合わせる。）

## 4. セキュリティルールの配信

ルールはリポジトリ管理済み（[`database.rules.json`](../../database.rules.json)）。

```bash
firebase deploy --only database
```

変える前に `tool/rules_test` のエミュレータテストを回す（[[testing#パーティ位置共有の RTDB ルール]]）。
⚠ purge（手順5）は `rooms/.indexOn` を使うので、**ルールを先に**配信する。

## 5. クリーンアップ関数のデプロイ

失効/終了ルームの定期purge（[`functions/index.js`](../../functions/index.js)）。

```bash
cd functions
npm install
firebase deploy --only functions
```

## 6. 実装側の残作業（コード）

provisioning後に行う配線。すべて Android/iOS 限定で。

- [ ] `RtdbPeerSource implements PeerSource`（`.info/connected` 監視・`publishPosition`/`publishTrack`・`goOnline`/`goOffline`・匿名認証・onDisconnect設定）
- [ ] `main.dart` で `Firebase.initializeApp`（**Android/iOS のみ**・機能フラグでガード）
- [ ] Riverpod provider 化（`PartyLocationStore` を提供、ライフサイクル管理）
- [ ] 地図描画: `PartyLocationStore.peersStream` → `_buildOverlayWidgetMarkers()` にピアマーカー追加（鮮度3段階表示）
- [ ] ルーム作成/参加UI（8文字コード生成・コード入力）
- [ ] メンバーパネル（参加者一覧・表示ON/OFF・共有停止＝ゴーストモード・hostキック）
- [ ] connectivity_plus → `hasInterface` ブール変換アダプタ
- [ ] バッテリー残量取得（`battery_plus` 追加 or 既存手段）

## 7. コスト確認

- 小規模パーティ（数人が数秒おきに位置ping）の帯域・接続・storageは $100枠に対し誤差。
- storage肥大はルールのスキーマ固定＋手順5のpurgeで抑制。
- App Check で非正規クライアントを遮断し、想定外の課金を防ぐ。
