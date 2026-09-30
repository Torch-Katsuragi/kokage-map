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
/// プロジェクトフォルダの選択。
///
/// native は OS のフォルダピッカー、web は File System Access API と、
/// 中身は別物だが呼び出し側からは同じ「フォルダを選ばせてパスを得る」に見せる。
library;

import 'project_folder_picker_io.dart'
    if (dart.library.js_interop) 'project_folder_picker_web.dart' as impl;

/// このプラットフォーム／ブラウザでフォルダを選べるか。
///
/// ⚠ web は Chrome / Edge のみ true（Firefox / Safari には
/// `showDirectoryPicker` が無い）。false のときは選択UIを出さないこと。
bool get canPickProjectFolder => impl.canPickProjectFolder;

/// フォルダを選ばせ、そのパスを返す。キャンセル・非対応なら null。
///
/// web が返すのはOSのパスではなく、`WebFileSystem` が解決できる**仮想パス**。
Future<String?> pickProjectFolder() => impl.pickProjectFolder();

/// 前回開いたフォルダの名前。無ければ null。
///
/// web のみ意味がある。native は毎回OSのピッカーを出せばよく、
/// 「最近開いたもの」は別途 `SettingsStore` が持つ話なのでここでは null を返す。
Future<String?> lastProjectFolderName() => impl.lastProjectFolderName();

/// 前回のフォルダを開き直し、そのパスを返す。開けなければ null。
///
/// > [!IMPORTANT] ボタン押下などの**ユーザー操作の中から呼ぶこと**。
/// > web ではブラウザの再許可プロンプトが要り、それはユーザー操作起点でしか出せない。
Future<String?> reopenLastProjectFolder() => impl.reopenLastProjectFolder();

/// 起動ルート `/map?project=…` で指示されたフォルダを開き、そのパスを返す。開けなければ null。
///
/// native は絶対パス（在れば開く）。web は `opfs:<名前>`（ブラウザのサイト専用領域の中のフォルダ。
/// 開発・自動テスト用で、中身は `tool/web_opfs.py` で流し込む）。選択画面も許可の確認も出ない
Future<String?> openRequestedProjectFolder(String spec) => impl.openRequestedProjectFolder(spec);

/// web の起動ルートで OPFS のフォルダを指す接頭辞
const kOpfsPrefix = 'opfs:';
