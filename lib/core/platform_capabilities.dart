// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'fs/project_folder_picker.dart';

/// プラットフォーム差異を capability として集約する。
///
/// > [!IMPORTANT] web では `dart:io` の `Platform` を**呼んだ瞬間に** `UnsupportedError`
/// > が飛ぶ（コンパイルは通るスタブとして出力されるため、静的には気づけない）。
/// > そのため `Platform.isXxx` は必ず `kIsWeb` の後ろに置き、`&&` の短絡評価で
/// > web から到達させないこと。この規約を守る場所をこのファイル1枚に閉じ込める。
class PlatformCapabilities {
  const PlatformCapabilities._();

  // =============================================
  // プラットフォーム判定（web安全）
  // =============================================
  // 「機能」ではなく素のプラットフォーム判定が必要な場所（ネイティブAPIの直叩き等）
  // のために公開する。判定で分岐したい内容が機能なら下の capability を足すこと。

  /// ブラウザ上で動いているか
  static bool get isWeb => kIsWeb;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  // 2026-08-25: isWindows / isMacOS / isLinux / isDesktop を削除した。
  // デスクトップ版を撤去し、その役割は web 版が担う
  // （[[docs/features/concept#プラットフォームの役割分担]]）。
  // ⚠ 復活させるなら、まず対象プラットフォームのビルドを戻すこと。

  /// モバイル（Android / iOS）
  static bool get isMobile => isAndroid || isIOS;

  /// プラットフォーム名。ログ・フィードバック送信等の表示用
  static String get operatingSystem =>
      kIsWeb ? 'web' : Platform.operatingSystem;

  // =============================================
  // ファイル・ストレージ
  // =============================================

  /// `dart:io` の `File` / `Directory` が使えるか。
  ///
  /// web は false。ファイルシステム抽象（段2）が入るまで、web では
  /// ローカルファイルに触る処理を**丸ごとスキップ**する。
  static bool get hasLocalFileSystem => !kIsWeb;

  /// OSのランタイム権限（ストレージ・位置情報・Bluetooth）を要求する必要があるか
  static bool get needsRuntimePermissions => isMobile;

  /// 背景地図タイルをローカルにキャッシュできるか（MBTiles / キャッシュディレクトリ）。
  ///
  /// web は false（ブラウザのHTTPキャッシュに任せる）。
  static bool get hasTileCache => hasLocalFileSystem;

  /// ギャラリー取り込みで content URI からネイティブ実ファイルコピー（EXIF保持）ができるか
  static bool get supportsNativeGalleryCopy => isAndroid;

  // =============================================
  // 地図
  // =============================================

  // =============================================
  // センサー・デバイス
  // =============================================

  static bool get supportsCompass => isMobile;

  static bool get supportsDriveSyncStatusCheck => isMobile;

  static bool get supportsGpsTracking => isMobile;

  /// GPS位置取得（マーカー・初回ジャンプ）— 全プラットフォーム対応
  static bool get supportsGpsLocation => true;

  /// 位置情報の権限・サービス有効状態をランタイムに問い合わせる必要があるか。
  ///
  /// web はブラウザが取得時に自前でプロンプトを出すので問い合わせない。
  static bool get needsLocationPermissionCheck => !kIsWeb;

  /// GNSS受信機による高精度測位（`enableHighAccuracy`）を要求してよいか。
  ///
  /// ⚠ web は false。ブラウザ経由のWi-Fi/IP測位しか無いので、高精度を要求しても
  /// 精度は上がらないまま**初回フィックスだけが伸びる**。
  /// 2026-08-24 実測（同一PC・同一ブラウザ）:
  /// high は初回まで60〜90秒で精度1500m、medium は0.2秒で精度369m。
  static bool get supportsHighAccuracyGps => !kIsWeb;

  /// Bluetooth経由の外部GNSS機器 — モバイルのみ
  static bool get supportsBluetoothGnss => isMobile;

  /// GPSをフォアグラウンドサービスに委譲できるか（delegatedモード）
  static bool get supportsForegroundGpsService => isMobile;

  // =============================================
  // 機能単位
  // =============================================

  /// 位置共有（パーティ）— Firebase の設定があるプラットフォームのみ
  ///
  /// 2026-08-27 に web を足した（`firebase_options.dart` に web を追加済み）。
  /// ルーム機能は RTDB しか触らず `dart:io` に依存しないので、設定さえあれば動く。
  ///
  /// ⚠ web で位置を配信するには、ブラウザの位置情報許可が要る。
  /// 精度は端末のGPSより粗い（[supportsHighAccuracyGps] 参照）。
  static bool get supportsPartySharing => isMobile || isWeb;

  /// Google Drive連携
  /// Google Drive連携（フォルダの同期）
  ///
  /// 2026-08-27 に `lib/services/google_drive/` から `dart:io` を撤去し、
  /// web でも動く形にした。
  ///
  /// ⚠ **web でログインするには web用のOAuthクライアントIDが要る。**
  /// 未設定のうちは `google_sign_in` の初期化で失敗するので、
  /// クライアントIDが入るまでは web を false のままにしておくこと。
  static bool get supportsDriveSync => isMobile || (isWeb && _hasWebOAuthClient);

  /// web用のOAuthクライアントIDが設定されているか。
  ///
  /// GCPコンソールでしか発行できない（gcloud にもFirebase CLIにも口が無い）。
  /// 承認済みJavaScript生成元に配信元のオリジンを登録すること。
  static bool get _hasWebOAuthClient => kWebOAuthClientId.isNotEmpty;

  /// web用のOAuthクライアントID（`....apps.googleusercontent.com`）。
  ///
  /// 空の間は web の Drive連携UIを出さない。
  static const String kWebOAuthClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// カメラでのQRコードスキャン
  static bool get supportsQrScan => isMobile;

  /// Androidのナビゲーションバー（◁□○）を隠す制御を行うか
  static bool get hidesSystemNavigationBar => isAndroid;

  /// 初回起動オンボーディング（権限説明）を出すか
  static bool get showsOnboarding => needsRuntimePermissions;

  /// ローカルのプロジェクトフォルダを開けるか。
  ///
  /// ⚠ web は**ブラウザによる**。File System Access API を持つ
  /// Chrome / Edge だけ true で、Firefox / Safari は false。
  /// false のときは「プロジェクト無しで地図だけ見る」経路になる。
  static bool get canOpenLocalProject => canPickProjectFolder;
}
