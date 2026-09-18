// web 用の空実装。web ではマージしない（読むだけへ降格する方針。docs/technical/drive-geodiff-sync.md）。

/// geodiff の戻り値
abstract final class GeodiffResult {
  static const success = 0;
  static const error = 1;
  static const conflicts = 2;
  static const unsupportedChange = 3;
}

/// web では作れない。[isSupported] を先に見ること。
class Geodiff {
  Geodiff() {
    throw UnsupportedError('geodiff は web では使えない');
  }
  static bool get isSupported => false;
  static String? libraryPathOverride;

  String get version => throw UnsupportedError('geodiff は web では使えない');
  String get lastError => '';
  void dispose() {}
  int createChangeset(String base, String modified, String changeset) => GeodiffResult.error;
  int applyChangeset(String base, String changeset) => GeodiffResult.error;
  int hasChanges(String changeset) => -1;
  int changesCount(String changeset) => -1;
  int rebase(String base, String theirs, String mine, String conflictFile) => GeodiffResult.error;
  int makeCopySqlite(String src, String dst) => GeodiffResult.error;
  int listChangesSummary(String changeset, String jsonFile) => GeodiffResult.error;
  int listChanges(String changeset, String jsonFile) => GeodiffResult.error;
}
