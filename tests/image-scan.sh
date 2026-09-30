#!/usr/bin/env bash
# ビルド済みイメージを trivy でスキャンする。
#
# 使い方:
#   tests/image-scan.sh [イメージ名]
#
# - イメージ名を省略すると、docker-compose.yml の image: を使う。
# - trivy は公式の Docker イメージで動かす。使う版は tests/trivy/Dockerfile の FROM で決まる。
# - trivy のスキャナはすべて使う。
#     イメージ内: 脆弱性（vuln）、設定の問題（misconfig）、秘密情報（secret）、ライセンス（license）
#     イメージの設定（環境変数、ビルドの履歴）: 設定の問題、秘密情報
# - 失敗させるのは、秘密情報と、修正版がある CRITICAL の脆弱性だけ。
#   それ以外は集計と一覧を表示するだけにする（判定は tests/trivy/report.py）。
# - イメージは docker save で tar にしてから trivy に渡す。trivy のコンテナに
#   Docker のソケットを渡さずに済む。tar はイメージの大きさぶん（圧縮後で 700MB 程度）の
#   一時ファイルになる。
# - 脆弱性の DB をダウンロードするので、ネットワークが必要。
# - ホストに python3 が必要（結果の集計に使う）。
#
# 終了コード: 0 = 成功 / 1 = 失敗させる条件に当たった / 2 = スキャンできなかった

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "$1" >&2
    if [[ -s $WORK_DIR/err ]]; then
        sed 's/^/  /' "$WORK_DIR/err" >&2
    fi
    exit 2
}

TRIVY_IMAGE=$(sed -n 's/^FROM[[:space:]]\{1,\}//p' "$REPO_ROOT/tests/trivy/Dockerfile")
if [[ $TRIVY_IMAGE != *@sha256:* ]]; then
    fail "tests/trivy/Dockerfile の FROM から、ダイジェスト付きの trivy のイメージ名を読み取れません（読み取った値: ${TRIVY_IMAGE:-なし}）"
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 が見つかりません（結果の集計に使います）"
fi

if [[ $# -ge 1 ]]; then
    IMAGE="$1"
else
    # docker-compose.yml の image: と二重に持たないよう、compose から取る
    if ! images=$(docker compose -f "$REPO_ROOT/docker-compose.yml" config --images 2>"$WORK_DIR/err"); then
        fail "docker-compose.yml からイメージ名を取得できません:"
    fi
    IMAGE="${images%%$'\n'*}"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>"$WORK_DIR/err"; then
    fail "イメージ $IMAGE を確認できません（まだビルドしていないなら、先に docker compose build を実行してください）:"
fi

echo "イメージ: $IMAGE"
echo "trivy:    $TRIVY_IMAGE"

if ! docker save "$IMAGE" -o "$WORK_DIR/image.tar" 2>"$WORK_DIR/err"; then
    fail "docker save に失敗しました:"
fi

# 結果の JSON は stdout で受け取る。trivy のコンテナからホストへは書き込ませない
# （trivy は root で動くので、書かせると root 所有のファイルが残る）
if ! docker run --rm -v "$WORK_DIR/image.tar:/scan/image.tar:ro" "$TRIVY_IMAGE" image \
    --input /scan/image.tar \
    --scanners vuln,misconfig,secret,license \
    --image-config-scanners misconfig,secret \
    --format json \
    --no-progress \
    --skip-version-check \
    >"$WORK_DIR/result.json" 2>"$WORK_DIR/err"; then
    fail "trivy でスキャンできませんでした:"
fi

python3 "$REPO_ROOT/tests/trivy/report.py" "$WORK_DIR/result.json"
