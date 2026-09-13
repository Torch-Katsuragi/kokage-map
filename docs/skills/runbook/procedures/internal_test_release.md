# テストリリース手順（内部テスト / クローズドテスト）

AAB のアップロードとトラックへの割り当ては **Android Publisher API**（`tool/play/play.py`）で行う。
Play Console の画面を触るのは API に無い項目だけ。

## ステップ1: バージョンを上げる

- `pubspec.yaml` の `version: X.Y.Z+N` の **N（versionCode）は Play に一度上げた値を再利用できない**。
  既に使った値は `python tool/play/play.py status` の `bundles:` に出る。
- `assets/changelog/ja.md` / `en.md` の `## 未リリース` を **`## vX.Y.Z — YYYY/MM/DD` に切る**。
  内容は前リリースとの差分の**最終形**にまとめ直す（打ち消された旧仕様・開発ログ粒度の項目は落とす。目安 50 行）。
  ⚠ 2026-09-07 に、4 月から切らずに 266 行積み上がって旧仕様と矛盾していたのを整理した
- Play のリリースノートは 500 字上限。changelog の先頭エントリをそのまま渡すと途中で切れるので、
  `.temp/release/notes_ja.md` / `notes_en.md` に短く書いて `--notes-ja/--notes-en` に渡す（見出し無しなら全文が使われる）

## ステップ2: AAB の出力

```powershell
flutter build appbundle --release
```

出力: `build/app/outputs/bundle/release/app-release.aab`（署名は `android/key.properties`）。

## ステップ3: アップロードとトラック割り当て

```bash
# dry-run（edit を作って最後まで通し、commit 前に捨てる）
python tool/play/play.py upload build/app/outputs/bundle/release/app-release.aab \
    --track alpha --name 0.6.1+18 --notes-ja assets/changelog/ja.md --notes-en assets/changelog/en.md

# 本番。commit = 審査に送信
python tool/play/play.py upload ... --apply
# 保存だけして送信は Play Console の「公開の概要」から本人が押す場合
python tool/play/play.py upload ... --apply --hold
```

- ⚠ `--hold`（保存だけ）は **このアプリでは API が 400 で拒む**（「Changes are sent for review automatically. changesNotSentForReview must not be set」、2026-09-13）。
  送るか送らないかの二択。実機確認を済ませてから `--apply`
- `--track`: `internal`（内部テスト）/ `alpha`（クローズドテスト）/ `beta` / `production`
- 国の指定（countryTargeting）は同じトラックの直前リリースから引き継ぐ
- 結果は `python tool/play/play.py status` で確認する

## ステップ4: Play Console でしかできないこと

以下は API に無い。`claude-in-chrome` で Play Console を開いて行う（本人のクリックが必要な操作は交代する）。

- 「アプリのコンテンツ」の宣言（権限宣言・データセーフティ・プライバシーポリシーURL・対象ユーザー）
- テスターの一覧（メールアドレス一覧・Google グループとも）とオプトイン状況の確認。API の `edits.testers` は新方式のクローズドテストでは 403 になる（2026-09-07 実測）
- 本番環境へのアクセス申請
- 深いURLは `.../app/<appId>/tracks/<trackId>` `.../app-content/overview` `.../publishing` なら直接開ける

---

## 掲載情報・スクリーンショットも API から

```bash
python tool/play/play.py status                                    # トラック・掲載・画像枚数
python tool/play/play.py listing --lang ja-JP --short "..." --full desc.txt --apply
python tool/play/play.py images phoneScreenshots --lang ja-JP --replace --add a.png b.png --apply
python tool/play/play.py images sevenInchScreenshots --lang ja-JP --add t1.png --apply
```

- スクショの要件: JPEG/24bit PNG、320〜3840px、縦横比 16:9〜2:1、1言語あたり最大8枚
- 掲載名の変更は審査に入る。アプリ内の表示名（`android:label`）とは別物

## サービスアカウント

- `play-console@nemurigi-kobo.iam.gserviceaccount.com`。鍵は `~/.gcp-keys/nemurigi-play-console.json`（Drive外・リポジトリ外）
- Play Console → ユーザーと権限 で招待し、アプリ `com.k_root.k_maps` に
  **「テスト版トラックとしてのアプリのリリース」**（commit に必要）と「ストアでの表示の管理」を付ける。
  API を有効化しただけでは 403、「ストアでの表示の管理」だけでは commit が 403 になる（2026-08-28 に踏んだ）
