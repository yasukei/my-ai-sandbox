# ローカルAI実験用ベースイメージ
# - PyTorchやAIツール本体は入れない（/work 以下で venv を作って入れる）
# - モデル・作業データは入れない（ボリュームでマウントする）
# - APIキー・ログイン情報は入れない（Docker Hub に push するため）

# base（CUDA の最小ランタイムのみ）を使う。
# PyTorch は CUDA / cuDNN を venv 内に自前で持つので、これで足りる。
# CUDA のコードをコンパイルするツール（CUDA 有効の llama-cpp-python など）を使うなら
# devel / cudnn-devel に変える。
#
# ubuntu26.04 用のタグは 13.3.x しか無い。ホストのドライバは CUDA 13.2 表示（nvidia-smi）
# だが、CUDA 13.x 内はマイナーバージョン互換があるので動く。
FROM nvidia/cuda:13.3.1-base-ubuntu26.04

ENV DEBIAN_FRONTEND=noninteractive

# `curl ... | bash` で curl が失敗したときに、ビルドも失敗させる
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- システムパッケージ ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        git \
        curl \
        ca-certificates \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 26 (Codex CLI 用) ---
# NodeSource のセットアップスクリプトでリポジトリを追加してから入れる
RUN curl -fsSL https://deb.nodesource.com/setup_26.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- 作業ディレクトリ・マウントポイント ---
# ubuntu ユーザー (UID 1000) はベースイメージに最初から存在する
RUN mkdir -p /work /models \
    && chown ubuntu:ubuntu /work /models

# --- ここから一般ユーザー ---
# apt 以外のツールはすべて ~/.local 以下に入れる（コンテナ内で root なしに更新できる）
USER ubuntu
ENV HOME=/home/ubuntu
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

# OpenAI Codex CLI（npm のグローバルインストール先を ~/.local にする）
ENV NPM_CONFIG_PREFIX=/home/ubuntu/.local
RUN npm install -g @openai/codex

# uv（スタンドアロンインストーラー。~/.local/bin に入る）
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
# torch 系のパッケージを、常にホストのドライバに合う CUDA ビルドで入れる
ENV UV_TORCH_BACKEND=auto
# キャッシュを /work（マウント先）に置く。venv と同じファイルシステムなので
# ハードリンクでき、コンテナを作り直してもダウンロードし直さずに済む
ENV UV_CACHE_DIR=/work/.cache/uv

# Claude Code（ネイティブインストーラー。~/.local/bin に入る）
# ~/.claude.json も ~/.claude/ の中に置く（マウント先に残り、コンテナを作り直しても消えない）
ENV CLAUDE_CONFIG_DIR=/home/ubuntu/.claude
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /work

CMD ["bash"]
