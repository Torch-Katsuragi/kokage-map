#!/usr/bin/env bash
# 2 台の実機で Drive 同期（geodiff の行単位マージ）を往復させる。Git Bash / MSYS 前提。
#
#   tool/sync_relay/run_two_device.sh <端末A> <端末B>
#
# - Drive は PC 上の偽物（relay_server.dart）。端末の Drive・アプリの設定には触らない
# - テスト用ビルドは applicationId に `.geodifftest` を付けて入れる。既存のアプリ
#   （開発・普段使いのデータ）を置き換えないため。終わったら flutter test が消す
# - そのために build.gradle.kts と google-services.json を一時的に書き換え、終了時に必ず戻す
# 設計: docs/technical/drive-geodiff-sync.md
set -euo pipefail

A="${1:?端末 A の id}"
B="${2:?端末 B の id}"
PORT="${PORT:-8799}"
RUN="geodiff-2dev-$(date +%s)"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
LOGDIR="$REPO/build/two_device"; mkdir -p "$LOGDIR"
cd "$REPO"

RELAY_PID=""
cleanup() {
  git checkout -- android/app/build.gradle.kts android/app/google-services.json 2>/dev/null || true
  for d in "$A" "$B"; do
    "$ADB" -s "$d" reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true
    "$ADB" -s "$d" uninstall com.k_root.k_maps.geodifftest >/dev/null 2>&1 || true
  done
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
  # dart run は子プロセスで VM を立てるので、PID ではなく待ち受けているポートで止める
  for pid in $(netstat -ano 2>/dev/null | grep ":$PORT .*LISTENING" | awk '{print $NF}' | sort -u); do
    taskkill //PID "$pid" //F >/dev/null 2>&1 || true
  done
  echo "== 後片付け済み（ビルド設定を戻し、テスト用パッケージを消した）"
}
trap cleanup EXIT

if ! git diff --quiet -- android/app/build.gradle.kts android/app/google-services.json; then
  echo "android/app の設定に未コミットの変更がある。先に片付けて" >&2; exit 1
fi

# テスト用のパッケージ名で並べて入れる
python - <<'PY'
import io, json, copy
p = "android/app/build.gradle.kts"; s = io.open(p, encoding="utf-8").read()
old = '        applicationId = "com.k_root.k_maps"\n'
assert old in s
io.open(p, "w", encoding="utf-8", newline="\n").write(s.replace(old, old + '        applicationIdSuffix = ".geodifftest"\n', 1))
p = "android/app/google-services.json"; j = json.load(io.open(p, encoding="utf-8"))
c = copy.deepcopy(j["client"][0])
c["client_info"]["android_client_info"]["package_name"] = "com.k_root.k_maps.geodifftest"
for oc in c.get("oauth_client", []):
    if "android_info" in oc: oc["android_info"]["package_name"] = "com.k_root.k_maps.geodifftest"
j["client"].append(c)
io.open(p, "w", encoding="utf-8", newline="\n").write(json.dumps(j, indent=2, ensure_ascii=False) + "\n")
PY

dart run tool/sync_relay/relay_server.dart "$PORT" >"$LOGDIR/relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 60); do grep -q listening "$LOGDIR/relay.log" 2>/dev/null && break; sleep 2; done
for d in "$A" "$B"; do "$ADB" -s "$d" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null; done

# A を先に（ビルドして push し、B を待つ）。A が push を終えたら B
flutter test integration_test/geodiff_two_device_test.dart -d "$A" --dart-define=ROLE=A --dart-define=RUN="$RUN" >"$LOGDIR/A.log" 2>&1 &
PA=$!
for _ in $(seq 1 300); do grep -q "done 1-pushed" "$LOGDIR/relay.log" && break; kill -0 $PA 2>/dev/null || break; sleep 2; done
flutter test integration_test/geodiff_two_device_test.dart -d "$B" --dart-define=ROLE=B --dart-define=RUN="$RUN" >"$LOGDIR/B.log" 2>&1 &
PB=$!
RA=0; RB=0
wait $PA || RA=$?
wait $PB || RB=$?

grep "\[relay\]" "$LOGDIR/relay.log" || true
grep -h "\[2dev" "$LOGDIR/A.log" "$LOGDIR/B.log" || true
echo "== A: $( [ $RA -eq 0 ] && echo 通過 || echo 失敗 )  B: $( [ $RB -eq 0 ] && echo 通過 || echo 失敗 )  （ログ: $LOGDIR）"
[ $RA -eq 0 ] && [ $RB -eq 0 ]
