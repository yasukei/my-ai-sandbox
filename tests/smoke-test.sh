#!/usr/bin/env bash
# ビルド済みイメージのスモークテスト。
# README に書いてある主要な機能が、ひととおり使える状態かを確かめる。
#
# 使い方:
#   tests/smoke-test.sh [イメージ名]
#
# - イメージ名を省略すると yasukei/my-ai-sandbox:latest を使う。
# - 使い捨てのコンテナで実行する。ホストのディレクトリはマウントしないので、
#   リポジトリ直下の .my-ai-* には触らない。
# - uv でパッケージを入れるテストがあるので、ネットワークが必要。
# - GPU のテストは、ホストに nvidia-smi があるときだけ実行する。
#   SMOKE_GPU=1 で強制、SMOKE_GPU=0 でスキップできる。

# コンテナ内で展開させたい変数やコマンド置換を、わざと単一引用符で渡している
# shellcheck disable=SC2016

set -euo pipefail

IMAGE="${1:-yasukei/my-ai-sandbox:latest}"
CONTAINER="my-ai-sandbox-smoke-$$"

pass=0
fail=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

section() {
    printf '\n== %s\n' "$1"
}

report() {
    local result="$1" desc="$2" detail="${3:-}"
    if [[ $result == ok ]]; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "$desc"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n' "$desc"
        if [[ -n $detail ]]; then
            printf '%s\n' "$detail" | sed 's/^/          /'
        fi
    fi
}

# check <ユーザー> <説明> <コマンド>
# コンテナ内でコマンドを実行し、終了コードが 0 なら成功。
check() {
    local user="$1" desc="$2" cmd="$3" out
    if out=$(docker exec -u "$user" "$CONTAINER" bash -c "$cmd" 2>&1); then
        report ok "$desc"
    else
        report ng "$desc" "$out"
    fi
}

# check_eq <ユーザー> <説明> <期待する出力> <コマンド>
# コンテナ内でコマンドを実行し、出力が期待どおりなら成功。
check_eq() {
    local user="$1" desc="$2" expected="$3" cmd="$4" out
    out=$(docker exec -u "$user" "$CONTAINER" bash -c "$cmd" 2>&1) || true
    if [[ $out == "$expected" ]]; then
        report ok "$desc"
    else
        report ng "$desc" "期待: $expected / 実際: $out"
    fi
}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "イメージ $IMAGE がありません。先に docker compose build を実行してください。" >&2
    exit 1
fi

echo "イメージ: $IMAGE"
docker run -d --init --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null

section "ユーザーと作業ディレクトリ"
check_eq ubuntu "実行ユーザーは ubuntu" "ubuntu" 'whoami'
check_eq ubuntu "UID は 1000" "1000" 'id -u'
check_eq ubuntu "HOME は /home/ubuntu" "/home/ubuntu" 'echo "$HOME"'
check_eq ubuntu "作業ディレクトリは /work" "/work" 'pwd'
check_eq root "root で入ると HOME は /root" "/root" 'echo "$HOME"'

section "マウントポイント"
for dir in /work /models; do
    check ubuntu "$dir に ubuntu で書き込める" "touch $dir/.smoke-test && rm $dir/.smoke-test"
done

section "入っているツール"
for tool in python3 git curl gcc node npm uv uvx codex claude; do
    check ubuntu "$tool が動く" "$tool --version"
done
for tool in codex uv claude; do
    check_eq ubuntu "$tool は ~/.local/bin にある" "/home/ubuntu/.local/bin/$tool" "command -v $tool"
done

section "環境変数"
check_eq ubuntu "LANG" "C.UTF-8" 'echo "$LANG"'
check_eq ubuntu "ロケールが UTF-8 になっている" "C.UTF-8" 'locale | sed -n "s/^LC_CTYPE=//p" | tr -d \"'
check_eq ubuntu "UV_TORCH_BACKEND" "auto" 'echo "$UV_TORCH_BACKEND"'
check_eq ubuntu "UV_CACHE_DIR" "/work/.cache/uv" 'echo "$UV_CACHE_DIR"'
check_eq ubuntu "HF_HOME" "/models/huggingface" 'echo "$HF_HOME"'
check_eq ubuntu "TORCH_HOME" "/models/torch" 'echo "$TORCH_HOME"'
check_eq ubuntu "CLAUDE_CONFIG_DIR" "/home/ubuntu/.claude" 'echo "$CLAUDE_CONFIG_DIR"'

section "Python"
check ubuntu "Python.h を使ってコンパイルできる（python3-dev）" \
    'echo "#include <Python.h>" | gcc -fsyntax-only $(python3-config --includes) -x c -'
check ubuntu "uv で venv を作り、パッケージを入れて import できる" \
    'cd /work && uv venv -q smoke-venv && uv pip install -q --python smoke-venv/bin/python six && smoke-venv/bin/python -c "import six"'
check_eq ubuntu "uv のキャッシュは /work/.cache/uv に入る" "/work/.cache/uv" 'uv cache dir'

section "GPU"
gpu="${SMOKE_GPU:-auto}"
if [[ $gpu == auto ]]; then
    if command -v nvidia-smi >/dev/null 2>&1; then gpu=1; else gpu=0; fi
fi
if [[ $gpu == 1 ]]; then
    if out=$(docker run --rm --gpus all "$IMAGE" nvidia-smi --query-gpu=name --format=csv,noheader 2>&1); then
        report ok "コンテナから GPU が見える（$out）"
    else
        report ng "コンテナから GPU が見える" "$out"
    fi
else
    echo "  skip  ホストに nvidia-smi が無いのでスキップ（SMOKE_GPU=1 で強制）"
fi

printf '\n結果: %d 件成功、%d 件失敗\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
