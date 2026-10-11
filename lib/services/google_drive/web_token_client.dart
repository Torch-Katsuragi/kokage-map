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
/// web で、Driveのアクセストークンを**画面を出さずに**取り直す。
///
/// ⚠ `google_sign_in_web` を通さず GIS を直に叩く。理由はこれ一点:
/// ライブラリが `prompt: userHint == null ? '' : 'select_account'` としており、
/// **`login_hint` を渡すと必ずアカウント選択画面が出る**ようになっている。
///
/// 2026-08-28 に実測した結果（同一ブラウザ・同意済み・Googleにログイン済み）:
///
/// | 設定 | 結果 |
/// | --- | --- |
/// | `prompt:''` のみ | ポップアップが開いたまま10秒待っても返らない |
/// | `prompt:'' + login_hint` | **858ms でトークン。ポップアップは自動で閉じる** |
///
/// つまり無音化の決め手は `prompt` ではなく **`login_hint`**。これが無いと
/// Googleは「どのアカウントか」を決められず選択画面で止まる。
///
/// ⚠ それでもGISはポップアップを開くので、**クリックの直下から呼ぶこと**。
/// 操作から切り離された文脈だとブラウザに潰される。
library;

import 'web_token_client_io.dart'
    if (dart.library.js_interop) 'web_token_client_web.dart' as impl;

/// GIS が返したアクセストークンと、その寿命（`expires_in`。返らなければ null）
typedef WebTokenGrant = ({String token, Duration? expiresIn});

/// 無音でアクセストークンを取り直す。取れなければ null
///
/// [loginHint] は前回サインインしたメールアドレス。**これが要**で、
/// 無いと画面が出るので、呼び出し側は null なら呼ばないこと。
Future<WebTokenGrant?> requestTokenSilently({
  required String clientId,
  required List<String> scopes,
  required String loginHint,
  Duration timeout = const Duration(seconds: 8),
}) =>
    impl.requestTokenSilently(
      clientId: clientId,
      scopes: scopes,
      loginHint: loginHint,
      timeout: timeout,
    );
