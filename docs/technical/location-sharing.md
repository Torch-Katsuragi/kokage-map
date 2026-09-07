---
title: 位置共有（パーティ機能）設計
tags: [technical, location-sharing, firebase, realtime, design]
---


> [!NOTE] 2026-08-27 に web でも使えるようにした
> `firebase apps:create WEB` で web アプリを登録し、`firebase_options.dart` に
> 追加しただけ。ルーム機能は RTDB しか触らず `dart:io` に依存しないので、
> 設定以外のコード変更はほぼ不要だった。
>
> web固有で手を入れたのは2点:
>
> - `setPersistenceEnabled` は web 未対応なので呼ばない
>   （タブが生きている間しか保たないので、そもそも意味が薄い）
> - **App Check に web のプロバイダを渡していない。**
>   web は reCAPTCHA のサイトキーが要り、それはコンソール発行のもの。
>   App Check API はプロジェクトで有効化すらされていないので現状は素通りする。
>   強制に切り替えるときは `providerWeb: ReCaptchaV3Provider(<siteKey>)` を足すこと
>
> ⚠ **`onDisconnect` の仕掛けどころに罠がある。**
> `live/$uid` の書き込みは RTDBルールが `members/$uid` の存在を要求する。
> web では `members/$uid` の書き込みが終わる前に `.info/connected` が立つことが
> あり、そのとき `PERMISSION_DENIED` になる（Androidでは表面化しなかった）。
> いまは初回の位置送信が通った時点で仕掛け直している
> （`RtdbPeerSource._armDisconnectHandler`）。

# 位置共有（パーティ機能）設計

## 1. 目的・ユースケース

ホストがルームを作り、ゲストがコードで参加し、**全員のGPS位置を地図上でリアルタイム共有しながら山を移動する**機能。目印のない山中で別行動すると互いの居場所が分からなくなる問題を解決する。

- ホストは**論理的な役割**（部屋作成・キック・終了）であって、物理的なサーバーを立てる人ではない。
- **非エンジニアでも「ホスト」できる**こと＝ユーザーが立てるサーバーは存在しない（バックエンドは開発者が一度だけデプロイ）。
- 参加は**ルームコード**方式（マイクラの「部屋＋合言葉」メンタルモデル。自前サーバー運用＝ポート開放等は真似しない）。

## 2. 前提となる通信環境の思想

山中は**常に圏外**と考える。トンネル・サーバー障害も同様。これらを区別せず**統合的に**扱う。

- **途絶中はほっとく**：無駄なリトライをせず電池を温存する。
- **復帰の瞬間を的確に察知して再開**する。
- 将来の Starlink 普及を見込み、**トランスポート非依存**に設計する（cell / wifi / 衛星のいずれで復帰しても同じ経路で動く）。

## 3. バックエンド選定：Firebase Realtime Database

| 選定理由 | 内容 |
|---|---|
| コスト | [[user-google-ai-ultra]] の **$100/月 GCPクレジット**が Firebase に適用される。小規模パーティの位置pingは誤差レベル。 |
| `.info/connected` | 「インターフェイスがある」ではなく「**実サーバーとWebSocketが繋がった瞬間**」を通知。**“復帰の瞬間”の権威ある検出器**。 |
| `onDisconnect()` | 切断をサーバー側が検知したら自動で `/live/{uid}` を offline 扱いに。 |
| オフラインキュー | 圏外中の書込みをローカルに溜め、再接続時に自動フラッシュ（store-and-forward 標準装備）。 |

- リージョンは RTDB の `asia-southeast1`（シンガポール）。日本から遅延50〜80msで本用途は問題なし。
- Firebase 公式もプレゼンス検知は Firestore ではなく **RTDB 推奨**。
- 認証は **匿名認証**（端末ごとに uid）。再参加はルームコードで可能。

> EOS（Epic Online Services）は却下。Dart公式SDKが無くFFI実装が重い／ゲーム向けプラットフォームでToS適合がグレー／マッチメイキングモデルが既知チームの現場用途と不一致。

## 4. 地図描画：エフェメラル・オーバーレイ方式

**共有位置 = 「他人の "現在地マーカー"」**。既存の「自分の現在地マーカー」パターンをそのまま増殖させる。

```
PartyLocationStore（シングルトン, InternalGpsLocationStore の双子）
  └─ Stream<Map<uid, PeerPosition>>
       └─ map_page の _buildOverlayWidgetMarkers() にピアごとのマーカー追加
          （_buildLocationMarkerWithCompass の兄弟 _buildPeerMarker：
            名前ラベル + 方位 + 鮮度表示）
```

**採用しない案：PointLayerNode 継承のダミーレイヤをプロジェクトツリーに置く**

- `LayerNode` は全て GeoPackage バック前提（インメモリ専用レイヤ型が存在しない）。エフェメラルなのに無理やり乗せると**誤って .gpkg に永続化されるリスク**とライフサイクル管理が増える。
- レイヤツリーに揮発する人の位置が混ざるのは概念的に汚い。

メンバー一覧・表示ON/OFFは**偽レイヤノードではなく専用「メンバー」パネル**で持つ。

### 関連する既存実装

| 概念 | ファイル |
|---|---|
| 自分の現在地ストア（双子の参照元） | `lib/services/internal_gps_location_store.dart:84`（positionStream） |
| 現在地マーカー描画（流儀の参照元） | `lib/screens/map_page/map_page.dart`（`_buildOverlayWidgetMarkers` の末尾。ml.Marker / WidgetLayer） |
| 仲間のマーカー・圏外区間の軌跡 | `lib/screens/map_page/widgets/party_map_layers.dart`（`buildPartyPeerMarkers` / `buildPartyTrackPolylines` / `PeerMarker`。2026-09-07 に map_page から切り出し） |
| 軌跡記録（gap backfill のソース） | `lib/services/gps_history_recorder.dart` |
| 内蔵+外部GNSS統合（マージ点パターン） | `lib/services/gps_manager_service.dart` |

## 5. 接続ステートマシン

```
        connectivity_plus(IF復帰イベント)        .info/connected = true
OFFLINE ───────────────────────────────► CONNECTING ──────────────────► ONLINE
  ▲   \                                                                    │
  │    \__ goOffline() で SDK を眠らせる                                   │ 書込成功
  │        (圏外中は一切リトライさせない＝電池温存)                        │
  └────────────────────────────────────────────────────────────────────┘
                    .info/connected = false / IF喪失
```

- **「ほっとく」**：圏外が一定時間続いたら `FirebaseDatabase.goOffline()` を呼び、SDKの再接続リトライ自体を止める。あとは OS発火の `connectivity_plus`（ポーリング無し・イベント駆動）だけを監視。
- **「復帰検出」**：インターフェイスが戻ったら `goOnline()` → `.info/connected` が true に跳ねる＝復帰確定。
- **統合性**：サーバー障害・トンネル・圏外いずれも `.info/connected=false` という同一経路で扱われる。

### 復帰時フロー（gap backfill）

圏外中も `GpsHistoryRecorder` が自分の軌跡を録り続けている（既存資産）。復帰時：

1. 最新位置を最優先で1発送信（地図に即反映）。
2. 圏外中に歩いた軌跡を **Douglas-Peucker で間引き**（既存実装を再利用）→ `/tracks/{uid}` に送信。仲間が「ブラックアウト中どこを通ったか」を見られる。
3. 通常配信に復帰。

### Starlink時代への布石

復帰経路は `.info/connected` で一本化されているため、復帰手段（cell / wifi / 衛星）を問わない。Starlink普及時は「ONLINEな時間が増える」だけで**コード変更不要**。狭い衛星ウィンドウでも流し切れるよう**ペイロードは極小に保つ**。

## 6. データモデル（RTDB）

```
/rooms/{roomCode}/
  meta/    { hostUid, name, active, createdAt, expiresAt }
  members/{uid}/   { name, color, role: host|guest }
  live/{uid}/                       # 揮発する現在位置
    { lat, lng, alt, acc, bearing, speed,
      ts: ServerValue.timestamp,    # サーバー時刻（端末時計ズレ・改ざん回避）
      battery?, connected }
    └ onDisconnect → connected:false に自動セット
  tracks/{uid}/{pushId}/  { pts(encoded polyline), from, to }   # 間引き済み圏外区間
```

## 7. セキュリティ（3層）

> **ルームコードは "鍵（capability）" そのもの。** 守りは3層で考える。

### 層1：コードの推測困難性
- **8文字・曖昧文字除外**（0/O/1/l/I を抜いた32種）＋ `expiresAt`。
- `active=false` か期限切れの部屋は参加reject＝失効後の総当たり無効化。

### 層2：RTDB セキュリティルール（`database.rules.json`）

```json
{
  "rules": {
    "rooms": {
      "$roomCode": {
        ".read": "auth != null && data.child('members').child(auth.uid).exists()",

        "meta": {
          ".write": "auth != null && (!data.exists() ? newData.child('hostUid').val() === auth.uid : data.child('hostUid').val() === auth.uid)",
          ".validate": "newData.hasChildren(['hostUid','active','createdAt'])",
          "hostUid":   { ".validate": "newData.isString()" },
          "active":    { ".validate": "newData.isBoolean()" },
          "createdAt": { ".validate": "newData.isNumber()" },
          "expiresAt": { ".validate": "newData.isNumber()" },
          "name":      { ".validate": "newData.isString() && newData.val().length <= 60" },
          "$other":    { ".validate": false }
        },

        "members": {
          "$uid": {
            ".write": "auth != null && ( ($uid === auth.uid && root.child('rooms/'+$roomCode+'/meta/active').val() === true && root.child('rooms/'+$roomCode+'/meta/expiresAt').val() > now) || root.child('rooms/'+$roomCode+'/meta/hostUid').val() === auth.uid )",
            ".validate": "newData.hasChildren(['name','role'])",
            "name":  { ".validate": "newData.isString() && newData.val().length <= 40" },
            "role":  { ".validate": "newData.val() === 'host' || newData.val() === 'guest'" },
            "color": { ".validate": "newData.isString() && newData.val().length <= 16" },
            "$other": { ".validate": false }
          }
        },

        "live": {
          "$uid": {
            ".write": "auth != null && $uid === auth.uid && root.child('rooms/'+$roomCode+'/members/'+auth.uid).exists()",
            ".validate": "newData.hasChildren(['lat','lng','ts'])",
            "lat": { ".validate": "newData.isNumber() && newData.val() >= -90  && newData.val() <= 90" },
            "lng": { ".validate": "newData.isNumber() && newData.val() >= -180 && newData.val() <= 180" },
            "ts":  { ".validate": "newData.val() === now" },
            "alt": { ".validate": "newData.isNumber()" },
            "acc": { ".validate": "newData.isNumber() && newData.val() >= 0" },
            "bearing":  { ".validate": "newData.isNumber() && newData.val() >= 0 && newData.val() < 360" },
            "speed":    { ".validate": "newData.isNumber() && newData.val() >= 0" },
            "battery":  { ".validate": "newData.isNumber() && newData.val() >= 0 && newData.val() <= 100" },
            "connected":{ ".validate": "newData.isBoolean()" },
            "$other":   { ".validate": false }
          }
        },

        "tracks": {
          "$uid": {
            ".write": "auth != null && $uid === auth.uid && root.child('rooms/'+$roomCode+'/members/'+auth.uid).exists()",
            "$pushId": {
              ".validate": "newData.hasChildren(['pts','from','to'])",
              "pts":  { ".validate": "newData.isString() && newData.val().length <= 8000" },
              "from": { ".validate": "newData.isNumber() && newData.val() <= now" },
              "to":   { ".validate": "newData.isNumber() && newData.val() <= now" },
              "$other": { ".validate": false }
            }
          }
        },

        "$other": { ".validate": false }
      }
    }
  }
}
```

**守りどころ**

- **書込みは本人のみ**：`/live/{uid}`・`/tracks/{uid}` は `$uid === auth.uid`。なりすまし不可。
- **読取りはメンバーのみ**：room直下 `.read` を継承。非メンバーは一切見れない。
- **host特権**：meta編集・キック（members削除）はhostのみ。
- **時刻偽装防止**：`ts === now` で ServerValue.timestamp を強制（鮮度表示の信頼性に直結）。
- **スキーマ固定**：各階層 `$other: false` ＋長さ/範囲 validate でゴミ投入・ストレージ肥大攻撃を遮断。
- **期限**：`expiresAt > now` の時のみ新規参加可。

### 層3：Firebase App Check
正規アプリ以外（curl/スクリプト）からのDBアクセスを遮断。RTDBはルールでレート制限できないため、**叩ける主体を絞る**のが本命のコスト攻撃・荒らし対策。

> 機微度を上げる場合は **host承認モード**（`/pending/{uid}` に入りhostが `/members` へ昇格）を後付けオプションに。MVPは「コード＝合言葉」のオープン参加。

## 8. 運用方針（各論）

| 項目 | 方針 |
|---|---|
| **プライバシー/同意** | ルーム参加＝共有同意。常時「📡共有中」インジケータ＋ワンタップ退出。hostが他人の共有を勝手にONにはできない（ルールで担保）。「在室するが配信停止」のゴーストモードを用意。 |
| **鮮度表示** | サーバー`ts`基準で3段階：`<30s`実線／`<5分`淡色＋「N分前」／閾値超（既定15分・設定可）→「最終既知地点」ピンに降格（消さない）。 |
| **isolate境界** | Firebase I/Oはメインisolate固定（positionStream経由で受け取る）。前景サービス(別isolate)からは触らない（Bluetoothと同じ制約）。 |
| **電池** | 距離主導（移動20〜30mごと）＋ハートビート上限（移動中60〜90秒／停止中は数分）。`/live/{uid}` は上書き（中間点を溜めない）。圏外＝送信ゼロ。低電池時は閾値を広げる。 |
| **コスト/クリーンアップ** | host終了で即room削除＋定期Cloud Functionで孤児purge（active=false / 期限切れ）。極小ペイロード＋スキーマ固定でstorage肥大を根絶。 |
| **ルームライフサイクル** | 8文字コード＋`expiresAt`（既定24h or host終了まで）。host終了で `active=false`→cleanup。 |
| **将来拡張** | `PartyLocationStore` を `PeerSource` インターフェイスで抽象化（RTDB＝一実装）。将来 BLEメッシュ等を別ソースとして `GpsManagerService` 同様のマージ点で合流。 |
| **テスト** | デバッグ用「強制オフライン」トグル（`goOffline/goOnline`直叩き）でトンネル遷移を再現。接続ステートマシンは単体テスト対象。 |

## 9. 招待リンク（URL参加）

「ルーム参加がURLで済む」＝web版の主力（`docs/features/concept` の差別化1位の強化）。
2026-08-28 実装。

- 形式: `https://kokage-map.sleeptree.jp/?room=CODE`（`lib/services/party/party_invite.dart`）
- **出す側**: ステータスシートの「招待リンク」コピーと「QRコード」表示。
  QRは招待URLを載せる（スマホカメラ→ブラウザ参加、アプリ内スキャナ→コード充填の両対応）
- **受け側（web）**: 起動時に `?room=` を検出すると HomeScreen がフォルダ選択を
  飛ばして地図へ直行し、MapPage が参加ダイアログをコード充填済みで開く
- **受け側（アプリ）**: 参加欄が生コード・招待URLの両方を受ける（読むときは寛容に）。
  カメラのある端末は参加欄のQRスキャンからも入れる

## 10. ステータス

**実装済み（2026-08-28 時点）。** コア（作成/参加/退出/終了・live共有・鮮度3段階・
ゴースト・バッテリー・gap backfill送受信・キック・招待リンク/QR）まで完了。
Android実機×webのクロスプラットフォームで通し確認済み（参加・メンバー同期・
キック時の自動退出通知・tracks受信描画）。

残り:

- App Check の web プロバイダ（reCAPTCHA サイトキー・強制切替時に対応）
- ~~クリーンアップ~~ → `functions/index.js` の `purgeExpiredRooms`（24時間ごと）実装済み

> [!NOTE] キックの仕様
> `members/{uid}` の削除は host 特権（ルールが担保）。`live/{uid}` は本人以外
> 消せないため残るが、UI側でメンバー外の live は描かず、実体は定期purgeが回収。
> 蹴られた側は members 購読（自分の消失 or `.read` 失効エラー）で自動退出し、
> 通知センターに表示する（`PartySession._onKicked`）。
