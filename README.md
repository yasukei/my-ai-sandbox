# my-ai-sandbox

GPU を使うAIツールを、ホストから隔離して試すための Docker イメージ。

- ベース: `nvidia/cuda:13.3.1-base-ubuntu26.04`（CUDA の最小ランタイムのみ）
- 入っているもの: Python3 / venv / git / curl / build-essential / uv / Node.js 26 / Codex CLI / Claude Code
- 入っていないもの: PyTorch などのAIツール本体（`/work` 以下で venv を作って入れる）、モデル、APIキー・ログイン情報
- 実行ユーザー: `ubuntu`（UID 1000）

以下、イメージ名の `yasukei` は自分の Docker Hub ユーザー名に読み替える（`docker-compose.yml` の `image:` も同様）。

`docker compose` のコマンドは、このリポジトリのディレクトリで実行する。

## 事前確認

```bash
# ホストのGPUとドライバ
nvidia-smi

# コンテナからGPUが見えるか（NVIDIA Container Toolkit が必要）
docker run --rm --gpus all nvidia/cuda:13.3.1-base-ubuntu26.04 nvidia-smi
```

CUDA のバージョンについて:

- `nvidia-smi` 右上の `CUDA Version` は、ホストのドライバが対応する CUDA の版。ベースイメージのタグと一致している必要はない（同じ 13.x 系なら動く）。
- PyTorch が使う CUDA / cuDNN はイメージのものではなく、`uv pip install` で venv に入るもの。イメージで `UV_TORCH_BACKEND=auto` を設定しているので、uv がドライバに合うビルドを選ぶ。
- そのためベースは `base` で足りる。CUDA のコードを自分でコンパイルするツール（CUDA 有効の `llama-cpp-python` など）を使う場合だけ、`Dockerfile` の `FROM` を `devel` / `cudnn-devel` に変えて再ビルドする。

## イメージのビルド

```bash
docker compose build

# 最新のベースイメージ / apt / npm / uv / Claude Code を取り直したいとき
# （--pull でベースイメージを取り直し、--no-cache でキャッシュを使わずに作り直す）
docker compose build --pull --no-cache

# ビルドした日付のタグも付けておく（前のビルドに戻せるようにするため）
docker tag yasukei/my-ai-sandbox:latest yasukei/my-ai-sandbox:$(date +%Y%m%d)
```

タグは `latest` と日付（`YYYYMMDD`）の2種類だけを使う。

- `latest`: `docker compose build` が作るタグで、`docker compose up` が使うタグ（`docker-compose.yml` の `image:`）。再ビルドのたびに上書きされる。
- 日付: そのビルドを残しておくためのタグ。各ツールはビルド時点の最新版が入るので、`latest` の中身はビルドのたびに変わる。

前のビルドに戻すとき:

```bash
docker tag yasukei/my-ai-sandbox:20260930 yasukei/my-ai-sandbox:latest
docker compose up -d    # イメージが変わっていればコンテナを作り直す
```

ツールの更新はこのイメージの再ビルドで行う。Codex CLI / uv / Claude Code は `ubuntu` の `~/.local` 以下に入っているので、コンテナ内でも更新できる（`npm install -g @openai/codex@latest`、`uv self update`、`claude update`）。ただしコンテナを削除すると元に戻る。

## Docker Hub へのアップロード

```bash
docker login

# ローカルにあるタグ（latest と日付）をすべて push する
docker push --all-tags yasukei/my-ai-sandbox
```

別マシンで使うときは `docker pull yasukei/my-ai-sandbox:latest`。

## コンテナの起動

```bash
docker compose up -d                # バックグラウンドで起動
docker compose exec sandbox bash    # コンテナに入る（複数のシェルで同時に入れる）
docker compose down                 # 停止してコンテナを削除（データはマウント先に残る）
```

ホスト側のディレクトリ（すべてこのリポジトリ直下にあり、clone した時点で存在する）:

| ホスト | コンテナ | 中身 |
| --- | --- | --- |
| `.my-ai-models/` | `/models` | モデル |
| `.my-ai-work/` | `/work` | 作業データ、各ツールの venv、uv のキャッシュ（`.cache/uv`） |
| `.my-ai-agent-config/claude/` | `/home/ubuntu/.claude` | Claude Code の設定・認証情報 |
| `.my-ai-agent-config/codex/` | `/home/ubuntu/.codex` | Codex CLI の設定・認証情報 |

中身（モデル・作業データ・認証情報）は、リポジトリ直下の `.gitignore` で除外していて、コミットされない。このファイルはコンテナにマウントされないので、コンテナ内からは書き換えられない。

各ディレクトリ内にも `.gitignore` がある。こちらは空のディレクトリを git に残すためのもので、同じ除外も書いてある（除外は二重になっている）。ビルドコンテキストからは `.dockerignore` で除外している。

`docker-compose.yml` の設定:

| 設定 | 意味 |
| --- | --- |
| `gpus: all` | ホストのNVIDIA GPUを使う |
| `stdin_open` / `tty` | bash を起動したままにして、`exec` で入れるようにする |
| `volumes` | ディレクトリをマウント。コンテナを消してもデータが残る |
| `ports: 127.0.0.1:8188:8188` | ComfyUI などのポートを、ホスト自身にだけ公開 |

補足:

- ポートは `127.0.0.1` に限定している。`8188:8188` と書くと LAN の他の端末からも接続でき、ファイアウォール（ufw）でも止まらない。ComfyUI には認証が無いので、限定を外さない。
- マウント先が root 所有になると `ubuntu` から書き込めない。その場合はホスト側で `sudo chown -R 1000:1000 .my-ai-work` などを実行する。

compose を使わずに起動する場合（同じく、このリポジトリのディレクトリで実行する）:

```bash
docker run --gpus all -it --name sandbox \
  -v "$PWD/.my-ai-models":/models \
  -v "$PWD/.my-ai-work":/work \
  -v "$PWD/.my-ai-agent-config/claude":/home/ubuntu/.claude \
  -v "$PWD/.my-ai-agent-config/codex":/home/ubuntu/.codex \
  -p 127.0.0.1:8188:8188 \
  yasukei/my-ai-sandbox:latest
```

## コンテナ内での使い方

```bash
# ツールごとに /work 以下で venv を作る（例: ComfyUI）
cd /work
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
uv venv
source .venv/bin/activate
uv pip install torch torchvision    # ドライバに合う CUDA ビルドが自動で選ばれる
uv pip install -r requirements.txt
python main.py --listen 0.0.0.0    # ホストのブラウザから http://localhost:8188

# GPUが使えているか
nvidia-smi
python -c "import torch; print(torch.cuda.is_available())"

# エージェントCLI（初回はログインが必要。認証情報はマウント先に保存される）
claude
codex
```

torch 系のパッケージ（`torchaudio` など）を追加するときは、`uv pip install torch torchvision torchaudio` のように torch と同じコマンドでまとめて入れる。別々に入れると CUDA ビルドが食い違い、import でエラーになることがある。

`--listen 0.0.0.0` が無いと、ポートを公開してもホストから接続できない。これはコンテナ内の待ち受け設定で、ホスト側の公開先は `127.0.0.1` のままなので、LAN には公開されない。

### システムのパッケージ（apt）を追加する

コンテナ内の `ubuntu` は root になれない（sudo は入れていない）。apt でパッケージを入れるときは、ホスト側から root でコンテナに入る。

```bash
docker compose exec -u root sandbox bash

# ここからコンテナ内（root）
apt-get update && apt-get install -y ffmpeg
```

入れたパッケージは `docker compose down` でコンテナごと消える。常に必要なものは `Dockerfile` の apt の行に足して再ビルドする。

## コンテナ・イメージの管理

```bash
docker compose ps                  # 起動中のコンテナ
docker compose ps -a               # 停止中も含む
docker compose stop                # 停止（コンテナは残る）
docker compose start               # 停止したコンテナを再開
docker compose down                # 停止してコンテナを削除

docker images                      # イメージ一覧
docker images yasukei/my-ai-sandbox            # このイメージのタグ一覧
docker rmi yasukei/my-ai-sandbox:20260930      # 古い日付タグを削除
docker system df                   # ディスク使用量
docker system prune                # 不要なコンテナ・イメージ・キャッシュを削除
```

## 注意

- APIキーやログイン情報はイメージに含めない。`~/.claude` と `~/.codex` はマウントで渡す。
- 認証情報の実体は `.my-ai-agent-config/` にある。リポジトリ直下の `.gitignore` から該当の行を消したり、`git add -f` でコミットしたりしない。
- イメージは Docker Hub に push するため、機密情報を `Dockerfile` に書かない。
