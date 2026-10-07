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
// こかげマップ: グローバルフォルダの置き場所を決める
//
// > [!IMPORTANT] 2026-09-06 に Android の既定を共有ストレージへ移した
// > 以前は `getApplicationDocumentsDirectory()/k_maps_global`（アプリ内部領域）で、
// > アンインストールすると GPS 軌跡ごと消えていた。開発中に debug / release を
// > 行き来するたびに履歴を失うのが直接の動機。
// > 共有ストレージ（`Documents/KokageMap/Global`）はアンインストールで消えない。
// > 全ファイルアクセス（MANAGE_EXTERNAL_STORAGE）はアプリの必須権限なので、
// > 前の install が作ったファイルも再インストール後に読み書きできる。
//
// ネイティブ専用（web にグローバルフォルダの概念は無い）。呼び出し側で
// `PlatformCapabilities.hasLocalFileSystem` を見てから使う。

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/hidden_dirs.dart';
import '../core/platform_capabilities.dart';
import '../utils/app_logger.dart';

/// パス決定の結果
class GlobalFolderResolution {
  /// 実際に使うパス
  final String path;

  /// 旧場所（アプリ内部の `k_maps_global`）から中身を移した場合はその件数（ファイル数）
  final int migratedFiles;

  /// 既定の共有ストレージが使えず内部領域に退避した理由。null なら退避していない
  final String? fallbackReason;

  const GlobalFolderResolution(
    this.path, {
    this.migratedFiles = 0,
    this.fallbackReason,
  });

  bool get migrated => migratedFiles > 0;
  bool get fellBack => fallbackReason != null;
}

class GlobalFolderLocator {
  GlobalFolderLocator._();

  /// 旧既定（アプリ内部領域）のフォルダ名
  static const String legacyDirName = 'k_maps_global';

  /// 移行後に旧フォルダへ付ける名前。中身はコピー済みなので消してよいが、
  /// 念のため1世代だけ残す（アンインストールで自然に消える）
  static const String legacyMigratedDirName = 'k_maps_global.migrated';

  /// こかげマップの置き場所（`/storage/emulated/0/` 配下）。「地図を開く」はここをそのまま開く
  static const List<String> kokageRootSegments = ['Documents', 'KokageMap'];

  /// 置き場所の中のアプリ用フォルダ（Global・練習用。点で始めて地図にもファイルアプリにも出さない）
  static const String systemDirName = '.kokage';

  /// 共有ストレージ側の相対パス（`/storage/emulated/0/` 配下）
  static const List<String> sharedRelativeSegments = [...kokageRootSegments, systemDirName, 'Global'];

  /// 2026-10-03 までの場所（`Documents/KokageMap/Global`）。初回に [sharedRelativeSegments] へ移す。
  /// ⚠ 後方互換。オープンベータに移るときに、この移行と [hiddenLegacyDirs] をまとめて消す
  static const List<String> previousSharedSegments = [...kokageRootSegments, 'Global'];


  /// 置き場所（Android は `Documents/KokageMap`、それ以外はアプリの文書フォルダの下の `KokageMap`）
  static Future<String> kokageRoot() async {
    if (PlatformCapabilities.isAndroid) {
      final root = await _sharedStorageRoot();
      if (root != null) return p.joinAll([root, ...kokageRootSegments]);
    }
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, kokageRootSegments.last);
  }

  /// 旧既定パス（アプリ内部領域）
  static Future<String> legacyPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, legacyDirName);
  }

  /// 既定パス。Android は共有ストレージ、それ以外は旧既定と同じ
  static Future<String> defaultPath() async {
    if (PlatformCapabilities.isAndroid) {
      final root = await _sharedStorageRoot();
      if (root != null) return p.joinAll([root, ...sharedRelativeSegments]);
    }
    return legacyPath();
  }

  /// 共有ストレージのルート（`/storage/emulated/0`）。
  ///
  /// path_provider に「共有ストレージのルート」を返す口は無いので、
  /// アプリ専用外部領域（`.../Android/data/<pkg>/files`）から `/Android/` より前を取る。
  ///
  /// 取れた値は覚えておく（地図を開くたびに置き場所・Global の場所決め・移行で何度も引くため）。取れなかったときは覚えない
  static Future<String?> _sharedStorageRoot() async {
    if (_sharedRootCache != null) return _sharedRootCache;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return null;
      final idx = ext.path.indexOf('/Android/');
      if (idx <= 0) return null;
      return _sharedRootCache = ext.path.substring(0, idx);
    } catch (e) {
      AppLogger.debug('[GlobalFolder] 共有ストレージのルート取得に失敗: $e');
      return null;
    }
  }

  static String? _sharedRootCache;

  /// 実際に使うパスを決める。
  ///
  /// 優先順: [customPath] → 既定（Android は共有ストレージ）→ 旧既定へ退避。
  /// 既定が共有ストレージで、そこが空（または未作成）かつ旧既定に中身があれば、
  /// 旧既定の中身をコピーして旧フォルダを [legacyMigratedDirName] に改名する。
  static Future<GlobalFolderResolution> resolve({String? customPath}) async {
    if (customPath != null) {
      return GlobalFolderResolution(customPath);
    }

    final defaultDir = await defaultPath();
    final legacyDir = await legacyPath();
    if (defaultDir == legacyDir) {
      return GlobalFolderResolution(defaultDir);
    }

    // 共有ストレージが実際に使えるか（作成・書き込み）を確かめる
    final probeError = await _probeWritable(defaultDir);
    if (probeError != null) {
      AppLogger.debug('[GlobalFolder] 共有ストレージが使えないため内部領域へ退避: $probeError');
      return GlobalFolderResolution(legacyDir, fallbackReason: probeError);
    }

    // 旧共有ストレージの場所（KokageMap/Global）から移す。移せなければ旧の場所をそのまま使う
    final usable = await _migratePrevious(defaultDir);
    if (usable != defaultDir) return GlobalFolderResolution(usable);

    final migrated = await _migrateLegacy(from: legacyDir, to: defaultDir);
    return GlobalFolderResolution(defaultDir, migratedFiles: migrated);
  }

  /// `Documents/KokageMap/Global` → `Documents/KokageMap/.kokage/Global`（同じ領域なので改名で移す）。
  /// 使うパスを返す（移せなかったら旧の場所）。旧練習用フォルダは地図に出さないだけ（中身は触らない）。
  /// ⚠ 後方互換。オープンベータに移るときに消す
  static Future<String> _migratePrevious(String newDir) async {
    final root = await _sharedStorageRoot();
    if (root == null) return newDir;
    final oldDir = Directory(p.joinAll([root, ...previousSharedSegments]));
    _hideLegacyPractice(root);
    if (!await oldDir.exists()) return newDir;
    try {
      final dst = Directory(newDir);
      final dstEmpty = !await dst.exists() || (await dst.list().take(1).toList()).isEmpty;
      if (!dstEmpty) {
        AppLogger.debug('[GlobalFolder] 新しい場所に既に中身があるので旧 Global は移さない（地図には出さない）');
        hiddenLegacyDirs.add(p.normalize(oldDir.path));
        return newDir;
      }
      if (await dst.exists()) await dst.delete();
      await dst.parent.create(recursive: true);
      await oldDir.rename(dst.path);
      AppLogger.debug('[GlobalFolder] Global を移した: ${oldDir.path} → $newDir');
      return newDir;
    } catch (e) {
      AppLogger.debug('[GlobalFolder] Global を移せない（旧の場所を使う）: $e');
      hiddenLegacyDirs.add(p.normalize(oldDir.path));
      return oldDir.path;
    }
  }

  /// 旧練習用フォルダ（`Documents/KokageMap/<練習>`）は地図に出さない。名前は言語で変わるので両方
  static void _hideLegacyPractice(String root) {
    for (final name in const ['練習', 'Practice']) {
      hiddenLegacyDirs.add(p.normalize(p.joinAll([root, ...kokageRootSegments, name])));
    }
  }

  /// ディレクトリを作って書き込みを試す。使えれば null、だめなら理由
  static Future<String?> _probeWritable(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File(p.join(dir, '.kokage_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      // 前の install が作ったファイルが読めるか（全ファイルアクセス無しだと list で落ちる）
      await d.list().take(1).toList();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 旧既定 → 新既定 へ中身を移す。移したファイル数を返す（移さなければ 0）。
  ///
  /// 新既定に既に何かあるときは触らない（別 install が既に移行済み、など）。
  static Future<int> _migrateLegacy({
    required String from,
    required String to,
  }) async {
    try {
      final src = Directory(from);
      if (!await src.exists()) return 0;
      final srcEntries = await src.list().toList();
      if (srcEntries.isEmpty) return 0;

      final dst = Directory(to);
      final dstEntries = await dst.list().toList();
      if (dstEntries.isNotEmpty) {
        AppLogger.debug(
          '[GlobalFolder] 新既定に既存データがあるため旧既定からの移行は行わない '
          '(new=${dstEntries.length} old=${srcEntries.length})',
        );
        return 0;
      }

      AppLogger.debug('[GlobalFolder] 旧既定から移行開始: $from → $to');
      final copied = await _copyTree(src, dst);

      // コピーが終わってから旧フォルダを改名（途中で落ちたら旧側は無傷のまま）
      final backup = Directory(p.join(p.dirname(from), legacyMigratedDirName));
      if (await backup.exists()) await backup.delete(recursive: true);
      await src.rename(backup.path);

      AppLogger.debug('[GlobalFolder] 移行完了: $copied ファイル');
      return copied;
    } catch (e) {
      AppLogger.debug('[GlobalFolder] 移行に失敗（旧既定はそのまま）: $e');
      return 0;
    }
  }

  /// ディレクトリを再帰コピー。コピーしたファイル数を返す
  static Future<int> _copyTree(Directory src, Directory dst) async {
    if (!await dst.exists()) await dst.create(recursive: true);
    var count = 0;
    await for (final entity in src.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final target = p.join(dst.path, name);
      if (entity is Directory) {
        count += await _copyTree(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
        count++;
      }
    }
    return count;
  }
}
