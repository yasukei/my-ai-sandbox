#!/usr/bin/env bash
# ビルド済みイメージに、認証情報などの秘密情報が入っていないかを trivy で調べる。
#
# 使い方:
#   tests/secret-scan.sh [イメージ名]
#
# - イメージ名を省略すると、docker-compose.yml の image: を使う。
# - trivy は公式の Docker イメージで動かす。使う版は tests/trivy/Dockerfile の FROM で決まる。
# - 調べるのは、イメージ内のファイルと、イメージの設定（環境変数、ビルドの履歴）。
# - イメージは docker save で tar にしてから trivy に渡す。trivy のコンテナに
#   Docker のソケットを渡さずに済み、ネットワークも切って実行できる。
#   tar はイメージの大きさぶん（圧縮後で 700MB 程度）の一時ファイルになる。
#
# 終了コード: 0 = 見つからなかった / 1 = 見つかった / 2 = スキャンできなかった

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

# 秘密情報が見つかったときだけ終了コード 3 にして、trivy 自体のエラーと区別する
status=0
docker run --rm --network none -v "$WORK_DIR:/scan:ro" "$TRIVY_IMAGE" image \
    --input /scan/image.tar \
    --scanners secret \
    --image-config-scanners secret \
    --exit-code 3 \
    --no-progress \
    --skip-version-check \
    --table-mode detailed || status=$?

case "$status" in
    0)
        echo "結果: 秘密情報は見つかりませんでした"
        ;;
    3)
        echo "結果: 秘密情報が見つかりました（上の一覧を参照）" >&2
        exit 1
        ;;
    *)
        echo "結果: trivy でスキャンできませんでした（終了コード $status）" >&2
        exit 2
        ;;
esac
