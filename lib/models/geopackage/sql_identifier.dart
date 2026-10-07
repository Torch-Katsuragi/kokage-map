/// SQL の識別子（テーブル名・カラム名・インデックス名など）を二重引用符で囲む。
///
/// QGIS 由来のレイヤは "Survey points" のように空白や記号を含むことが多い。
/// ⚠ sqflite の `db.insert` / `update` / `delete` / `query` はテーブル名・カラム名を
///   予約語のときしか囲まないので、識別子を渡す口では使わず rawXxx にこれを通す。
String quoteIdent(String name) => '"${name.replaceAll('"', '""')}"';

/// 主キー [pk] を SQL で指す式。`rowid`（主キーの無いテーブルの最後の手段）は囲まない。
String pkRef(String pk) => pk == 'rowid' ? 'rowid' : quoteIdent(pk);

/// 主キー [pk] で 1 行を選ぶ WHERE 句（値は `?` で渡す）
String pkEquals(String pk) => '${pkRef(pk)} = ?';

/// 全列を読む SELECT の列。`rowid` が主キーのときは列に出てこないので先頭に足す
String selectAllColumns(String pk) => pk == 'rowid' ? 'rowid, *' : '*';
