# AGENTS.md

## 会話ルール

- 日本語で会話・ドキュメント作成
- 質問がある場合は推測せず確認

## プロジェクト概要

Flutter製の地図アプリ（RootMap GIS）。**Android と web** の2プラットフォーム。

> [!IMPORTANT] デスクトップ版（Windows / macOS / Linux）は 2026-08-25 に撤去した
> 事務所側の役割は web版が引き継いでいる。経緯は [[docs/features/concept#プラットフォームの役割分担]]。

## 開発フロー

1. 作業前: `TODO.md`、`docs/` を確認
2. 実装: できるだけ計画を立ててから実装に移る
3. 作業後: `TODO.md` を更新

## 優先順位

1. バグ修正・リンターエラー
2. 既存機能の改善
3. 新機能
4. ドキュメント

## ファイル操作

- 作成: 実装に必要なファイルのみ
- 削除: 一時ファイル、テスト用ダミー
- 一時ファイル出力: `.temp/` に配置（`.gitignore` 済み）
- .md系はObsidian記法（フロントマター、`[[リンク]]`）
- commitの前にchangelog/内の更新履歴を全言語分更新

## 参照

- `TODO.md` - タスク管理
- `docs/` - 設計書・技術資料（[[docs/index|目次]]）
- `.agent/skills/` - エージェントスキル

## コード生成

`*.g.dart` はリポジトリに入っていない（`.gitignore` 済み）。
`flutter pub get` のあとに回すこと。`dart run slang` を先に回さない
（build_runner 2.16 以降は既存の `strings*.g.dart` があると落ちる → [[docs/technical/testing#コード生成]]）。

```powershell
dart run build_runner build --delete-conflicting-outputs
```

## テスト

- **Android と web の両方で通すこと**。片方だけ緑の変更は入れない
  （web対応作業では「webを直したらAndroidが壊れた」が最大のリスク）
- 一発で回す: `pwsh tool/test_matrix.ps1`（端末不要の段だけなら `-Only analyze,unit`）
- **Androidの検証は実機で行う。エミュレータは不可**（Pixel 9 が常時接続されている）
- webの検証は `flutter build web --release` → ローカルHTTPサーバ → Chrome（`flutter run -d chrome` は不安定）
- 詳細・落とし穴は [[docs/technical/testing|テスト構成]] を読む
- 地図まわりを触ったら `integration_test/map_contract_test.dart` を回す

## よく使うパターン

- UI更新: [[docs/technical/ui-layer-tree|レイヤツリー更新ガイド]] - `updateChildren()` の使い方

## UI規約

- **SnackBar禁止**: ユーザーへの通知は `ScaffoldMessenger` / `SnackBar` を使わず、必ず通知センター（`NotificationCenter`）を使用すること。詳細は [[.agent/skills/notification/SKILL.md]] を参照。
