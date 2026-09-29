# 依存の最新化手順（Flutter / Dart / パッケージ）

方針: **常に最新を使い続ける**（松本 2026-09-10）。上げるかどうかを判断事項にしない。
壊れたら pin で逃げずに直す。直せない・更新が止まっているパッケージは乗り換え候補として TODO.md に書く。

## ステップ1: 現状を見る

```powershell
flutter --version
flutter pub outdated
```

- Flutter が stable の最新でない、または `pub outdated` の直接依存（Direct dependencies）に更新があれば続ける。無ければ終了
- 3D ブランチ（worktree `kokage-map-3d`）で作業中なら、そちらでも同じ手順を回す（`pubspec.lock` は worktree ごと）

## ステップ2: 上げる

```powershell
flutter upgrade
flutter pub upgrade --major-versions
flutter pub outdated
```

- 2 回目の `pub outdated` で残ったものは推移的依存の制約で止まっている。止めているパッケージを特定し、そちらも上げる
- `pubspec.yaml` の `environment.sdk` は上げた Dart に合わせて引き上げてよい（下限を古いままにしない）

## ステップ3: コード生成（順番に意味がある）

```powershell
dart run slang
dart run build_runner build --delete-conflicting-outputs
```

## ステップ4: 壊れたところを直す

```powershell
pwsh tool/test_matrix.ps1 -Only analyze,unit
```

- 非推奨 API の警告もこの段で潰す（次の版で消えるものを残さない）
- 直し方が分からないときは changelog / migration guide を読む。回避策で旧 API に留めない

## ステップ5: 実機と web

- Android は実機で `flutter run` のホットリロード確認。release は最後に 1 回（R8 の確認）
- web は `flutter build web --release` → ローカル HTTP サーバ → Chrome
- 地図まわりの依存（maplibre 等）が上がったら `integration_test/map_contract_test.dart` も回す
- Android の target SDK / Gradle / Kotlin / AGP が Flutter 側の要求で上がることがある。`android/` の差分も見る

## ステップ6: 記録して commit

- 利用者に見える変化があれば `assets/changelog/` の `## 未リリース` に全言語分
- 上げられなかったもの・乗り換え候補は `TODO.md` に理由つきで
- commit メッセージは `chore: Flutter X.Y.Z / 依存更新`。動作確認済みなら確認せず進めてよい
