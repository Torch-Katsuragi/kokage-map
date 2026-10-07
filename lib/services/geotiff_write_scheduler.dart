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
/// GeoTIFF書き込みスケジューラ
///
/// オーバーレイのパラメータ変更時にGeoTIFFファイルへの書き込みを
/// デバウンスで遅延実行する。10秒間変更がなければ書き出し、
/// ツール変更時に flush() で即座に全保留を実行する。
library;

import 'dart:async';

import '../models/nodes/overlay_image_node.dart';
import '../utils/app_logger.dart';
import 'geotiff_service.dart';

/// デバウンス付きGeoTIFF書き込みスケジューラ
///
/// ノードごとにタイマーを管理し、最後の変更から [_debounceDelay] 後に
/// GeoTIFFタグを書き出す。[flush] で全保留をまとめて即時実行。
class GeoTiffWriteScheduler {
  static const Duration _debounceDelay = Duration(seconds: 10);

  /// ファイルパス → 遅延タイマー
  final Map<String, Timer> _timers = {};

  /// ファイルパス → 書き込み待ちノード情報
  final Map<String, _PendingWrite> _pending = {};

  /// 書き込み中フラグ（flush中の排他）
  bool _flushing = false;

  /// パラメータ変更時に呼ばれる。既存タイマーをリセットして再スケジュール。
  void scheduleWrite(OverlayImageNode node) {
    final path = node.getAbsoluteFilePath();
    if (path == null) return;

    // GeoTIFF以外（.jpg等）の場合はスキップ
    final lp = path.toLowerCase();
    if (!lp.endsWith('.tif') && !lp.endsWith('.tiff')) return;

    _pending[path] = _PendingWrite(
      filePath: path,
      params: node.overlayParams,
    );

    _timers[path]?.cancel();
    _timers[path] = Timer(_debounceDelay, () => _executeSingle(path));
  }

  /// 保留中の全書き込みを即座に実行する
  ///
  /// ツール変更時やアプリ終了時に呼ばれる。
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;

    try {
      // 全タイマーキャンセル
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();

      // 保留中を一括実行
      final entries = Map<String, _PendingWrite>.from(_pending);
      _pending.clear();

      for (final entry in entries.values) {
        await _writeGeoTiff(entry);
      }
    } finally {
      _flushing = false;
    }
  }

  /// リソース解放。残りの書き込みを実行してタイマーを解放。
  Future<void> dispose() async {
    await flush();
  }

  // ── 内部 ──

  Future<void> _executeSingle(String path) async {
    _timers.remove(path);
    final pending = _pending.remove(path);
    if (pending == null) return;
    await _writeGeoTiff(pending);
  }

  Future<void> _writeGeoTiff(_PendingWrite pending) async {
    try {
      await GeoTiffService.updateGeoTiffTags(
        pending.filePath,
        pending.params,
      );
      // タグ更新でTIFFの更新日時が変わるため、
      // PNGキャッシュのタイムスタンプも更新して「古い」判定を回避
      // ピクセルデータは不変なので再変換は不要
      await GeoTiffService.touchPngCacheTimestamp(pending.filePath);
      AppLogger.debug(
        '[GeoTiffWriteScheduler] flushed: ${pending.filePath}',
      );
    } catch (e) {
      AppLogger.debug(
        '[GeoTiffWriteScheduler] write error: ${pending.filePath}: $e',
      );
    }
  }
}

/// 書き込み待ち情報
class _PendingWrite {
  final String filePath;
  final dynamic params; // KMetaImageOverlay

  const _PendingWrite({required this.filePath, required this.params});
}
