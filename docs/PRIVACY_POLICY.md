# プライバシーポリシー (Privacy Policy)

正典は `web/privacy/index.html`（日英併記）。公開URLは **https://kokage-map.sleeptree.jp/privacy/**。
アプリ紹介ページは `web/about/index.html` → https://kokage-map.sleeptree.jp/about/ （OAuth同意画面のホームページ）。

2026-09-03 に全面改訂した。旧版（Root Maps 名義・2026-04-09）は位置共有パーティ（Firebase RTDB への送信）と
Google API の Limited Use 表明が無く、OAuth 検証の要件を満たしていなかった。

変更するときは `web/privacy/index.html` を直し、`flutter build web` → `firebase deploy --only hosting:kokage-map` で公開する
（[[docs/technical/web-hosting]]）。
