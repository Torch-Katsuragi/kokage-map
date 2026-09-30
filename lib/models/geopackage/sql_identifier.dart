/// SQL の識別子（テーブル名・カラム名・インデックス名など）を二重引用符で囲む。
///
/// QGIS 由来のレイヤは "Survey points" のように空白や記号を含むことが多い。
/// ⚠ sqflite の `db.insert` / `update` / `delete` / `query` はテーブル名・カラム名を
///   予約語のときしか囲まないので、識別子を渡す口では使わず rawXxx にこれを通す。
String quoteIdent(String name) => '"${name.replaceAll('"', '""')}"';
