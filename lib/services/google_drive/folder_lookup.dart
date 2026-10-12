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
/// Drive フォルダの確認（URL・QR・共有リンクから）の結果と、失敗の分け方。
///
/// ⚠ 以前は失敗をすべて「共有設定を確認してください」にしていた。名前解決が一瞬落ちただけでも
/// そう出て、直す必要のない共有設定を触りに行かせてしまう（2026-10-12、Pixel 9）。
library;

import 'package:googleapis/drive/v3.dart' as drive;

import '../../i18n/strings.g.dart';
import 'network_error.dart';

/// フォルダを確かめられなかった理由
enum FolderLookupFailure {
  /// 通信できない（圏外・名前解決の失敗・時間切れ）。電波のある所で取り直せば済む
  offline,

  /// 403: 見る権限が無い。共有設定の問題
  forbidden,

  /// 404: 無い。URL の間違い（Drive は共有されていないフォルダもこう返す）
  notFound,

  /// それ以外。短い文言にコードを添える
  other,
}

/// フォルダの確認結果。取れたら [folder]、だめなら [failure] と [code]（サポート用）
class FolderLookup {
  final drive.File? folder;
  final FolderLookupFailure? failure;
  final String? code;

  const FolderLookup.found(drive.File this.folder)
      : failure = null,
        code = null;

  const FolderLookup.failed(FolderLookupFailure this.failure, [this.code]) : folder = null;

  /// [error] から作る
  factory FolderLookup.fromError(Object error) {
    final failure = classifyFolderLookupError(error);
    return FolderLookup.failed(failure, folderLookupErrorCode(error));
  }

  bool get isFound => folder != null;

  /// 取り直せば直りうるか（再試行のボタンを出すか）
  bool get canRetry => failure == FolderLookupFailure.offline || failure == FolderLookupFailure.other;

  /// 利用者に見せる一文
  String get message => switch (failure) {
        null => '',
        FolderLookupFailure.offline => t.drive.folderOffline,
        FolderLookupFailure.forbidden => t.drive.accessDenied,
        FolderLookupFailure.notFound => t.drive.folderNotFound,
        FolderLookupFailure.other => t.drive.folderLookupFailed(code: code ?? '?'),
      };
}

/// フォルダ確認の失敗を分ける。API の応答（4xx/5xx）は状態コードで、そうでなければ通信の失敗かどうかで見る
FolderLookupFailure classifyFolderLookupError(Object error) {
  if (error is drive.DetailedApiRequestError) {
    return switch (error.status) {
      403 => FolderLookupFailure.forbidden,
      404 => FolderLookupFailure.notFound,
      _ => FolderLookupFailure.other,
    };
  }
  if (error is drive.ApiRequestError) return FolderLookupFailure.other;
  if (isNetworkError(error)) return FolderLookupFailure.offline;
  return FolderLookupFailure.other;
}

/// サポート用の短いコード（HTTP の状態コード、無ければ例外の型名）
String folderLookupErrorCode(Object error) {
  if (error is drive.DetailedApiRequestError && error.status != null) {
    return 'HTTP ${error.status}';
  }
  return error.runtimeType.toString();
}
