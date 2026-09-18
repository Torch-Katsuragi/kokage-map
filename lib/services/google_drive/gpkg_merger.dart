// GeoPackage の行単位 3-way マージ（geodiff の rebase の薄い皮）。
//
// [rebase] は `mine`（ローカル）をその場で「base → theirs（リモート）」の上に載せ直す。
// 同じ行・同じ列を両方が変えたときだけ衝突で、geodiff は mine 優先で解いて JSON に残す。
// それを [GpkgConflict] に読み替えて返す。Drive のやり取りはここには無い（テストしやすいように）。
import 'dart:convert';

import '../../core/fs/k_file_system.dart';
import '../../utils/app_logger.dart';
import '../geodiff/geodiff.dart';

/// 同じ行・同じ列を両方が変えていた記録（mine の値が残っている）
class GpkgConflict {
  const GpkgConflict({
    required this.table,
    required this.fid,
    required this.column,
    this.base,
    this.theirs,
    this.mine,
  });

  final String table;
  final String fid;

  /// 列番号（テーブル定義の順、0 始まり）
  final int column;
  final Object? base;
  final Object? theirs;
  final Object? mine;

  @override
  String toString() => '$table#$fid col$column: theirs=$theirs mine=$mine (base=$base)';
}

class GpkgMergeResult {
  const GpkgMergeResult.success(this.conflicts) : error = null;
  const GpkgMergeResult.failure(this.error) : conflicts = const [];

  final String? error;
  final List<GpkgConflict> conflicts;
  bool get success => error == null;
}

class GpkgMerger {
  GpkgMerger(this._geodiff);

  final Geodiff _geodiff;

  /// [mine] を書き換える。[base] と [theirs] は読むだけ。
  Future<GpkgMergeResult> rebase({
    required String base,
    required String theirs,
    required String mine,
  }) async {
    final conflictFile = '$mine.conflict.json';
    try {
      if (await fs.exists(conflictFile)) await fs.delete(conflictFile);
      final rc = _geodiff.rebase(base, theirs, mine, conflictFile);
      if (rc == GeodiffResult.error || rc == GeodiffResult.unsupportedChange) {
        final msg = 'rebase rc=$rc ${_geodiff.lastError}';
        AppLogger.debug('[GpkgMerger] $msg');
        return GpkgMergeResult.failure(msg);
      }
      final conflicts = await _readConflicts(conflictFile);
      return GpkgMergeResult.success(conflicts);
    } catch (e) {
      AppLogger.debug('[GpkgMerger] 例外: $e');
      return GpkgMergeResult.failure(e.toString());
    } finally {
      try {
        if (await fs.exists(conflictFile)) await fs.delete(conflictFile);
      } catch (_) {}
    }
  }

  /// base からの変更があるか（-1 は判定不能）
  Future<int> hasChanges({required String base, required String modified}) async {
    final cs = '$modified.changes.diff';
    try {
      final rc = _geodiff.createChangeset(base, modified, cs);
      if (rc != GeodiffResult.success) return -1;
      return _geodiff.hasChanges(cs);
    } finally {
      try {
        if (await fs.exists(cs)) await fs.delete(cs);
      } catch (_) {}
    }
  }

  /// geodiff の conflict JSON:
  /// {"geodiff":[{"table":"trees","fid":"1","type":"conflict",
  ///              "changes":[{"column":2,"base":"a","old":"b","new":"c"}]}]}
  /// `old` が theirs、`new` が mine（geodiff は mine を残す）。
  static Future<List<GpkgConflict>> _readConflicts(String path) async {
    if (!await fs.exists(path)) return const [];
    final text = utf8.decode(await fs.readAsBytes(path));
    if (text.trim().isEmpty) return const [];
    final json = jsonDecode(text) as Map<String, dynamic>;
    final entries = json['geodiff'] as List? ?? const [];
    final out = <GpkgConflict>[];
    for (final e in entries) {
      final m = e as Map<String, dynamic>;
      final table = m['table'] as String? ?? '';
      final fid = '${m['fid'] ?? ''}';
      for (final c in m['changes'] as List? ?? const []) {
        final cm = c as Map<String, dynamic>;
        out.add(GpkgConflict(
          table: table,
          fid: fid,
          column: (cm['column'] as num?)?.toInt() ?? -1,
          base: cm['base'],
          theirs: cm['old'],
          mine: cm['new'],
        ));
      }
    }
    return out;
  }
}
