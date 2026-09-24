// GeoPackage の行単位 3-way マージ（geodiff の rebase の薄い皮）。
//
// [rebase] は `mine`（ローカル）をその場で「base → theirs（リモート）」の上に載せ直す。
// 同じ行・同じ列を両方が変えたときだけ衝突で、geodiff は mine 優先で解いて JSON に残す。
// それを [GpkgConflict] に読み替えて返す。Drive のやり取りはここには無い（テストしやすいように）。
import 'dart:convert';

import '../../core/fs/k_file_system.dart';
import '../../utils/app_logger.dart';
import '../geodiff/geodiff.dart';

/// 同じ行を両方が変えていた記録。
///
/// - ふつうは同じ列を両方が直した場合で、mine（後から合わせた側）の値が残っている
/// - [theirsDeleted] なら、相手がその行を消していて、こちらの直しは捨てられて行は消えている
///   （geodiff は削除と更新がぶつかると削除を採る）
/// - [mineDeleted] なら、相手が直した行をこちらが消していて、相手の直しは捨てられて行は消えている。
///   geodiff はこれを記録しないので、rebase の前に両側の変更集合を突き合わせて拾う
class GpkgConflict {
  const GpkgConflict({
    required this.table,
    required this.fid,
    required this.column,
    this.base,
    this.theirs,
    this.mine,
    this.theirsDeleted = false,
    this.mineDeleted = false,
    this.filePath,
  });

  final String table;
  final String fid;

  /// 列番号（テーブル定義の順、0 始まり）
  final int column;
  final Object? base;
  final Object? theirs;
  final Object? mine;

  /// 相手がこの行を消していた（行は消えている）
  final bool theirsDeleted;

  /// 相手が直したこの行を、こちらが消していた（行は消えている）
  final bool mineDeleted;

  /// どの gpkg の衝突か（端末上の絶対パス）。[ConflictRestorer] が使う
  final String? filePath;

  GpkgConflict withFile(String path) => GpkgConflict(
        table: table,
        fid: fid,
        column: column,
        base: base,
        theirs: theirs,
        mine: mine,
        theirsDeleted: theirsDeleted,
        mineDeleted: mineDeleted,
        filePath: path,
      );

  /// 相手の値に戻せるか（削除がらみは行全体が要るので戻せない）
  bool get restorable => !theirsDeleted && !mineDeleted && filePath != null && column >= 0;

  @override
  String toString() => theirsDeleted
      ? '$table#$fid col$column: theirs=削除 mine=$mine (base=$base)'
      : mineDeleted
          ? '$table#$fid col$column: theirs=$theirs mine=削除 (base=$base)'
          : '$table#$fid col$column: theirs=$theirs mine=$mine (base=$base)';
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
      // geodiff が記録しない「相手が直した行をこちらが消した」を、書き換える前に拾っておく
      final lost = await _updatesLostToMyDeletes(base: base, theirs: theirs, mine: mine);
      final rc = _geodiff.rebase(base, theirs, mine, conflictFile);
      if (rc == GeodiffResult.error || rc == GeodiffResult.unsupportedChange) {
        final msg = 'rebase rc=$rc ${_geodiff.lastError}';
        AppLogger.debug('[GpkgMerger] $msg');
        return GpkgMergeResult.failure(msg);
      }
      final conflicts = [...await _readConflicts(conflictFile), ...lost];
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

  /// 相手（base → theirs）が直した行のうち、こちら（base → mine）が消した行。
  ///
  /// geodiff の listChanges JSON: {"geodiff":[{"table":"t","type":"update","changes":[{"column":0,"old":1},
  /// {"column":2,"old":"a","new":"b"}]}]}。更新では主キーの列だけ `new` が無く、削除は全列の `old` を持つ。
  /// 失敗しても merge は止めない（拾えないだけ）。
  Future<List<GpkgConflict>> _updatesLostToMyDeletes({
    required String base,
    required String theirs,
    required String mine,
  }) async {
    final out = <GpkgConflict>[];
    final files = ['$mine.t.diff', '$mine.t.json', '$mine.m.diff', '$mine.m.json'];
    try {
      if (_geodiff.createChangeset(base, theirs, files[0]) != GeodiffResult.success) return out;
      if (_geodiff.listChanges(files[0], files[1]) != GeodiffResult.success) return out;
      if (_geodiff.createChangeset(base, mine, files[2]) != GeodiffResult.success) return out;
      if (_geodiff.listChanges(files[2], files[3]) != GeodiffResult.success) return out;
      Future<List<Map<String, dynamic>>> entries(String path, String type) async {
        final json = jsonDecode(utf8.decode(await fs.readAsBytes(path))) as Map<String, dynamic>;
        return [
          for (final e in json['geodiff'] as List? ?? const [])
            if ((e as Map<String, dynamic>)['type'] == type) e,
        ];
      }

      // 相手の更新: (テーブル, 主キーの値) → 最初に変わった列
      final updated = <String, Map<String, dynamic>>{};
      final pkColumns = <String, List<int>>{};
      for (final e in await entries(files[1], 'update')) {
        final table = e['table'] as String;
        final changes = (e['changes'] as List).cast<Map<String, dynamic>>();
        final pk = changes.where((c) => !c.containsKey('new')).toList();
        final changed = changes.where((c) => c.containsKey('new')).toList();
        if (pk.isEmpty || changed.isEmpty) continue;
        pkColumns[table] = [for (final c in pk) (c['column'] as num).toInt()];
        updated['$table\u0000${pk.map((c) => c['old']).join('\u0000')}'] = changed.first;
      }
      if (updated.isEmpty) return out;
      for (final e in await entries(files[3], 'delete')) {
        final table = e['table'] as String;
        final cols = pkColumns[table];
        if (cols == null) continue;
        final byColumn = {
          for (final c in (e['changes'] as List).cast<Map<String, dynamic>>()) (c['column'] as num).toInt(): c['old'],
        };
        final key = '$table\u0000${cols.map((i) => byColumn[i]).join('\u0000')}';
        final c = updated[key];
        if (c == null) continue;
        out.add(GpkgConflict(
          table: table,
          fid: cols.map((i) => '${byColumn[i]}').join(','),
          column: (c['column'] as num?)?.toInt() ?? -1,
          base: c['old'],
          theirs: c['new'],
          mineDeleted: true,
        ));
      }
    } catch (e) {
      AppLogger.debug('[GpkgMerger] 消した行と相手の更新の突き合わせに失敗: $e');
    } finally {
      for (final f in files) {
        try {
          if (await fs.exists(f)) await fs.delete(f);
        } catch (_) {}
      }
    }
    return out;
  }

  /// geodiff の conflict JSON:
  /// {"geodiff":[{"table":"trees","fid":"1","type":"conflict",
  ///              "changes":[{"column":2,"base":"a","old":"b","new":"c"}]}]}
  /// `old` が theirs、`new` が mine（geodiff は mine を残す）。
  /// 相手が行を消していたときは `old` が無い（2026-09-24 に pygeodiff で確認）。
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
          theirsDeleted: !cm.containsKey('old'),
        ));
      }
    }
    return out;
  }
}
