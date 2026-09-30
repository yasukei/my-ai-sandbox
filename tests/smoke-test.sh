#!/usr/bin/env bash
# ビルド済みイメージのスモークテスト。
# README に書いてある主要な機能が、ひととおり使える状態かを確かめる。
#
# 使い方:
#   tests/smoke-test.sh [イメージ名]
#
# - イメージ名を省略すると、docker-compose.yml の image: を使う。
# - 使い捨てのコンテナで実行する。ホストのディレクトリはマウントしないので、
#   リポジトリ直下の .my-ai-* には触らない。
# - uv でパッケージを入れるテストがあるので、ネットワークが必要。
#
# 環境変数:
#   SMOKE_GPU      GPU のテストをするかどうか。
#                    auto（既定）: ホストに nvidia-smi があるときだけ実行する
#                    1: 必ず実行する
#                    0: スキップする
#   SMOKE_TIMEOUT  検査 1 つあたりの制限時間（秒）。既定は 120。

# コンテナ内で展開させたい変数やコマンド置換を、わざと単一引用符で渡している
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="my-ai-sandbox-smoke-$$"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
ERR_FILE="$(mktemp)"

pass=0
fail=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -f "$ERR_FILE"
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

# failure_detail <終了コード> <stdout>
# 失敗した検査の詳細（終了コード、stdout、stderr）を組み立てる。
failure_detail() {
    local status="$1" out="$2"
    if [[ $status -eq 124 ]]; then
        printf 'タイムアウト（%s 秒）\n' "$TIMEOUT"
    elif [[ $status -ne 0 ]]; then
        printf '終了コード: %s\n' "$status"
    fi
    if [[ -n $out ]]; then
        printf 'stdout: %s\n' "$out"
    fi
    if [[ -s $ERR_FILE ]]; then
        printf 'stderr: %s\n' "$(cat "$ERR_FILE")"
    fi
}

# run_in <ユーザー> <コマンド>
# コンテナ内でコマンドを実行する。stdout はそのまま返し、stderr は $ERR_FILE に入れる。
# ユーザーが default のときは -u を付けず、イメージの既定のユーザーで実行する。
run_in() {
    local user="$1" cmd="$2"
    local -a opts=()
    if [[ $user != default ]]; then
        opts=(-u "$user")
    fi
    docker exec "${opts[@]}" "$CONTAINER" timeout "$TIMEOUT" bash -c "$cmd" 2>"$ERR_FILE"
}

# check <ユーザー> <説明> <コマンド>
# コンテナ内でコマンドを実行し、終了コードが 0 なら成功。
check() {
    local user="$1" desc="$2" cmd="$3" out status=0
    out=$(run_in "$user" "$cmd") || status=$?
    if [[ $status -eq 0 ]]; then
        report ok "$desc"
    else
        report ng "$desc" "$(failure_detail "$status" "$out")"
    fi
}

# check_eq <ユーザー> <説明> <期待する出力> <コマンド>
# コンテナ内でコマンドを実行し、stdout が期待どおりなら成功。stderr は比べない。
check_eq() {
    local user="$1" desc="$2" expected="$3" cmd="$4" out status=0
    out=$(run_in "$user" "$cmd") || status=$?
    if [[ $status -eq 0 && $out == "$expected" ]]; then
        report ok "$desc"
    else
        report ng "$desc" "期待: $expected
$(failure_detail "$status" "$out")"
    fi
}

gpu="${SMOKE_GPU:-auto}"
gpu_skip_reason=""
case "$gpu" in
    1) ;;
    0)
        gpu_skip_reason="SMOKE_GPU=0 が指定されたのでスキップ"
        ;;
    auto)
        if command -v nvidia-smi >/dev/null 2>&1; then
            gpu=1
        else
            gpu=0
            gpu_skip_reason="ホストに nvidia-smi が無いのでスキップ（SMOKE_GPU=1 で強制）"
        fi
        ;;
    *)
        echo "SMOKE_GPU には auto / 1 / 0 のどれかを指定してください（指定された値: $gpu）" >&2
        exit 2
        ;;
esac

if [[ $# -ge 1 ]]; then
    IMAGE="$1"
else
    # docker-compose.yml の image: と二重に持たないよう、compose から取る
    if ! images=$(docker compose -f "$REPO_ROOT/docker-compose.yml" config --images 2>"$ERR_FILE"); then
        echo "docker-compose.yml からイメージ名を取得できません:" >&2
        sed 's/^/  /' "$ERR_FILE" >&2
        exit 1
    fi
    IMAGE="${images%%$'\n'*}"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>"$ERR_FILE"; then
    echo "イメージ $IMAGE を確認できません:" >&2
    sed 's/^/  /' "$ERR_FILE" >&2
    echo "（まだビルドしていないイメージなら、先に docker compose build を実行してください）" >&2
    exit 1
fi

echo "イメージ: $IMAGE"
docker run -d --init --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null

section "ユーザーと作業ディレクトリ"
check_eq default "既定の実行ユーザーは ubuntu" "ubuntu" 'whoami'
check_eq default "UID は 1000" "1000" 'id -u'
check_eq default "HOME は /home/ubuntu" "/home/ubuntu" 'echo "$HOME"'
check_eq default "作業ディレクトリは /work" "/work" 'pwd'
check_eq root "root で入ると HOME は /root" "/root" 'echo "$HOME"'

section "マウントポイント"
for dir in /work /models; do
    check default "$dir に書き込める" "touch $dir/.smoke-test && rm $dir/.smoke-test"
done

section "入っているツール"
for tool in python3 git curl gcc g++ make node npm uv uvx codex claude; do
    check default "$tool が動く" "$tool --version"
done
for tool in codex uv claude; do
    check_eq default "$tool は ~/.local/bin にある" "/home/ubuntu/.local/bin/$tool" "command -v $tool"
done

section "環境変数"
check_eq default "LANG" "C.UTF-8" 'echo "$LANG"'
check_eq default "ロケールが UTF-8 になっている" "C.UTF-8" 'locale | sed -n "s/^LC_CTYPE=//p" | tr -d \"'
check_eq default "UV_TORCH_BACKEND" "auto" 'echo "$UV_TORCH_BACKEND"'
check_eq default "UV_CACHE_DIR" "/work/.cache/uv" 'echo "$UV_CACHE_DIR"'
check_eq default "HF_HOME" "/models/huggingface" 'echo "$HF_HOME"'
check_eq default "TORCH_HOME" "/models/torch" 'echo "$TORCH_HOME"'
check_eq default "CLAUDE_CONFIG_DIR" "/home/ubuntu/.claude" 'echo "$CLAUDE_CONFIG_DIR"'

section "Python"
check default "python3 -m pip が動く（python3-pip）" 'python3 -m pip --version'
check default "python3 -m venv で venv を作れる（python3-venv）" \
    'python3 -m venv /tmp/smoke-venv && /tmp/smoke-venv/bin/python -c "import sys"'
check default "Python.h を使ってコンパイルできる（python3-dev）" \
    'echo "#include <Python.h>" | gcc -fsyntax-only $(python3-config --includes) -x c -'
check default "uv で venv を作り、パッケージを入れて import できる" \
    'cd /work && uv venv -q smoke-venv && uv pip install -q --python smoke-venv/bin/python six && smoke-venv/bin/python -c "import six"'
check default "uv のキャッシュが /work/.cache/uv に書かれている" 'test -n "$(ls -A /work/.cache/uv)"'

section "GPU"
if [[ $gpu == 1 ]]; then
    status=0
    out=$(timeout "$TIMEOUT" docker run --rm --gpus all "$IMAGE" \
        nvidia-smi --query-gpu=name --format=csv,noheader 2>"$ERR_FILE") || status=$?
    if [[ $status -eq 0 ]]; then
        # GPU が複数あると 1 行に 1 つずつ出るので、1 行にまとめる
        report ok "コンテナから GPU が見える（${out//$'\n'/, }）"
    else
        report ng "コンテナから GPU が見える" "$(failure_detail "$status" "$out")
ヒント: イメージではなく、ホスト側の設定が原因のことがある。
        NVIDIA Container Toolkit が入っていて、docker から GPU を使える状態かを確認する。"
    fi
else
    printf '  skip  %s\n' "$gpu_skip_reason"
fi

printf '\n結果: %d 件成功、%d 件失敗\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
