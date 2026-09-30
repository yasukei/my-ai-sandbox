# my-ai-sandbox

GPU を使うAIツールを、ホストから隔離して試すための Docker イメージ。

- ベース: `nvidia/cuda:13.3.1-base-ubuntu26.04`（CUDA の最小ランタイムのみ）
- 入っているもの: Python3（venv / pip / 開発用ヘッダー）/ git / curl / build-essential / uv / Node.js 26 / Codex CLI / Claude Code
- 入っていないもの: PyTorch などのAIツール本体（`/work` 以下で venv を作って入れる）、モデル、APIキー・ログイン情報
- 実行ユーザー: `ubuntu`（UID 1000）
- 前提: ホスト側のユーザーも UID 1000 であること（`id -u` で確認）。rootless Docker には対応していない

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

- `nvidia-smi` 右上の `CUDA Version` は、ホストのドライバが対応する CUDA の版。ベースイメージのタグ（13.3.1）と一致している必要はない。
- ベースイメージは起動条件（13.3.1 時点）として「CUDA 13.3 以上、またはドライバーが 535 / 570 / 580 / 590 / 595 系」を要求する。このホストのドライバー（595.91）は CUDA 13.2 表示だが、595 系なので条件を満たす。条件を満たさないホストでは、コンテナが `unsatisfied condition: cuda>=13.3` で起動に失敗することがある。
- PyTorch が使う CUDA / cuDNN はイメージのものではなく、`uv pip install` で venv に入るもの。イメージで `UV_TORCH_BACKEND=auto` を設定しているので、`uv pip install` はドライバに合うビルドを選ぶ（素の `pip` や `uv sync` には効かない）。
- そのためベースは `base` で足りる。CUDA のコードを自分でコンパイルするツール（CUDA 有効の `llama-cpp-python` など）を使う場合だけ、`Dockerfile` の `FROM` を `devel` / `cudnn-devel` に変えて再ビルドする。

## イメージのビルド

```bash
docker compose build

# apt / npm / uv / Claude Code を最新にしたいとき（キャッシュを使わずに作り直す）
docker compose build --no-cache

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

## イメージのテスト

ビルドしたイメージが使える状態かを、スモークテストで確かめる。

```bash
# docker-compose.yml の image: に書いてあるイメージをテストする
tests/smoke-test.sh

# 別のタグをテストするとき
tests/smoke-test.sh yasukei/my-ai-sandbox:20260930
```

確かめる内容:

- 認証情報や識別子が入るファイル（Claude Code / Codex CLI の設定、Hugging Face のトークン、git / npm / uv / pip / ssh / docker / gh の認証情報や設定ファイル）がイメージに無いこと
- イメージの環境変数に、認証情報らしい名前のものや、値に認証情報を含む URL（`https://user:pass@host` など）が無いこと。見つかったときは名前だけを表示する
- イメージの既定の実行ユーザー（`ubuntu`、UID 1000）と作業ディレクトリ
- `/work` と `/models` に書き込めること
- 入っているツール（Python3 / git / curl / gcc / g++ / make / Node.js / uv / Codex CLI / Claude Code）が動くこと
- 環境変数（`LANG`、`UV_TORCH_BACKEND`、`HF_HOME` など）
- `python3 -m pip`、`python3 -m venv`、Python のヘッダーを使ったコンパイル
- uv での venv 作成・パッケージのインストールと、キャッシュが `/work/.cache/uv` に書かれること
- コンテナから GPU が見えること

GPU のテストは、ホストに `nvidia-smi` があるときだけ実行する。`SMOKE_GPU=1` で必ず実行、`SMOKE_GPU=0` でスキップできる。検査 1 つあたりの制限時間は 120 秒で、`SMOKE_TIMEOUT` で変えられる。

使い捨てのコンテナで実行し、ホストのディレクトリはマウントしない。`.my-ai-*` の中身には触らない。PyTorch のインストールや、Claude Code / Codex CLI へのログインは対象外。

### イメージのスキャン（trivy）

イメージを [trivy](https://trivy.dev/) でスキャンする。

```bash
tests/image-scan.sh

# 別のタグを調べるとき
tests/image-scan.sh yasukei/my-ai-sandbox:20260930
```

trivy のスキャナはすべて使う。失敗させる（終了コード 1）のは、秘密情報と、修正版がある CRITICAL の脆弱性だけ。ほかは集計と一覧を表示するだけ。

| スキャナ | 調べるもの | 扱い |
| --- | --- | --- |
| 秘密情報（`secret`） | イメージ内のファイルと、イメージの設定（環境変数、ビルドの履歴）の中のトークンや鍵 | 1 件でもあれば失敗 |
| 脆弱性（`vuln`） | OS と言語のパッケージの既知の脆弱性 | 修正版がある CRITICAL があれば失敗。HIGH 以上は一覧を表示し、それ以外は件数だけ |
| 設定の問題（`misconfig`） | イメージの設定の、Dockerfile の書き方の問題 | 表示のみ |
| ライセンス（`license`） | パッケージのライセンスの種類 | 件数だけ表示 |

- trivy は公式の Docker イメージ（`aquasec/trivy`）で動かす。使う版は `tests/trivy/Dockerfile` の `FROM` で決まる（ビルドはせず、この行だけを読む）。
- イメージを `docker save` で一時的な tar にしてから、trivy に渡す。tar の大きさは Docker のイメージストアで変わり、700MB〜2.8GB 程度。trivy のコンテナには Docker のソケットを渡さない。
- 脆弱性の DB をダウンロードするので、ネットワークが必要。結果の集計（`tests/trivy/report.py`）に、ホストの `python3` を使う。
- スキャンできなかったときは終了コード 2 で終わる。

結果の読み方:

- 脆弱性の件数のほとんどは `linux-libc-dev`（カーネルのヘッダー）。カーネルの脆弱性だが、コンテナが使うのはホストのカーネルなので、ほぼ関係ない。
- 脆弱性の DB は日々更新される。イメージを変えていなくても、新しい脆弱性が公開されると結果が変わり、CI が失敗するようになることがある。修正版がある CRITICAL が出たら、`docker compose build --no-cache` での作り直しや、ベースイメージの更新で直す。
- ライセンスの「restricted」は GPL などのこと。Ubuntu のパッケージには必ず含まれるので、問題ではない。

trivy が見つける秘密情報は、既知の形式のトークンや鍵（GitHub のトークン、秘密鍵など）。形式を知らないトークンや、Claude Code の `machineID` のような識別子は見逃すので、認証情報が入るファイルそのものが無いことは、スモークテストで別に確かめている。

### CI

スモークテストとイメージのスキャンは、GitHub Actions でも実行している（`.github/workflows/ci.yml`）。`main` への push と pull request のたびに、イメージをビルドして両方を流す。GitHub のランナーには GPU が無いので、GPU のテストだけはスキップされる。

ワークフロー自体は [zizmor](https://docs.zizmor.sh/) で静的解析している（`.github/workflows/zizmor.yml`）。指摘があるとジョブが失敗する。ワークフローで使うアクションは、タグではなくコミットのハッシュで指定する（`uses: actions/checkout@<ハッシュ> # v7.0.1` の形）。権限はワークフロー全体では `permissions: {}` にして、ジョブごとに必要なものだけを付ける。

手元で zizmor を実行するとき:

```bash
GH_TOKEN=$(gh auth token) uvx zizmor .
```

- `GH_TOKEN` を渡すと、CI と同じくオンラインの検査（既知の脆弱性があるアクションの検出など）も実行される。渡さないと、これらの検査は実行されない。
- CI で使う zizmor は、zizmor-action に同梱されたバージョン（ダイジェストで固定）。`uvx zizmor` は実行した時点の最新版を使うので、バージョンが違うと結果が変わることがある。CI の結果を正とする。

## 依存の更新

依存は、更新のされ方で 3 種類に分かれる。

| 依存 | 更新のされ方 |
| --- | --- |
| ワークフローのアクション、ベースイメージ（`Dockerfile` の `FROM`）、trivy のイメージ（`tests/trivy/Dockerfile` の `FROM`） | Dependabot が月に 1 回確認して、PR を作る（`.github/dependabot.yml`） |
| Codex CLI、uv、Claude Code、apt のパッケージ（Node.js 26.x の中での更新を含む） | 版を固定していない。`docker compose build --no-cache` で作り直すと、その時点の最新が入る |
| Node.js のメジャー版（`Dockerfile` の `setup_26.x`）、Ubuntu の版（`FROM` のタグの `ubuntu26.04`） | Dependabot は変えないので、手で上げる |

Dependabot の設定:

- major の更新は 1 つずつ個別の PR、minor / patch はまとめて 1 つの PR になる。
- 通常の更新では、公開から 7 日たっていない版は提案しない。セキュリティ更新には、この待ち期間は効かない。
- ベースイメージと trivy のイメージは、タグとダイジェストの両方で固定している。同じタグのまま作り直された場合も、ダイジェストだけが変わる PR として届く。
- trivy のイメージの更新は、ベースイメージとは別の PR になる（ベースイメージの PR だけ、下の GPU での確認が要るため）。trivy の PR は CI が通ればマージしてよい。

ベースイメージの更新 PR の扱い:

- **タグが変わる PR（CUDA が上がる）**: CI が通っても、そのままマージしない。CI のランナーには GPU が無く、ホストのドライバで起動できるかは確かめられない。CUDA が上がると起動条件（`NVIDIA_REQUIRE_CUDA`）も変わるので、手元で次を実行して通ってからマージする。

  ```bash
  gh pr checkout <PR の番号>
  docker compose build
  SMOKE_GPU=1 tests/smoke-test.sh
  ```

  - `tests/smoke-test.sh` はイメージをビルドしないので、先に PR のブランチでビルドし直す。手元の古い `latest` のままだと、古い CUDA のイメージを検査して合格してしまう。
  - `SMOKE_GPU=1` を付けると、GPU を使えないときに GPU の検査が飛ばされず、失敗として止まる。
  - Dependabot は README を書き換えないので、README のタグの記述を新しいタグに直す（冒頭の「ベース」、「事前確認」の `docker run` の例、「CUDA のバージョンについて」の「ベースイメージのタグ」）。
  - 起動条件が変わっていたら、`Dockerfile` の `FROM` の上のコメントと、この README の「CUDA のバージョンについて」の条件も新しい内容に直す。
  - どちらの修正も、PR のブランチにコミットする。
  - 確かめたあと、手元の `latest` は PR のイメージになっている。マージしなかったときは、`main` に戻ってビルドし直す。
- **ダイジェストだけが変わる PR（同じタグの作り直し）**: CI が通ればマージしてよい。

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
| `.my-ai-models/` | `/models` | モデル。Hugging Face と torch hub のダウンロードは自動でここに入る（`huggingface/`、`torch/`） |
| `.my-ai-work/` | `/work` | 作業データ、各ツールの venv、uv のキャッシュ（`.cache/uv`） |
| `.my-ai-agent-config/claude/` | `/home/ubuntu/.claude` | Claude Code の設定・認証情報 |
| `.my-ai-agent-config/codex/` | `/home/ubuntu/.codex` | Codex CLI の設定・認証情報 |

`docker compose down` の後も残るのは、この4つのディレクトリに書かれたものだけ。それ以外の場所（ホームディレクトリの `~/.cache` など）に書かれたものは、コンテナと一緒に消える。

中身（モデル・作業データ・認証情報）は、リポジトリ直下の `.gitignore` で除外していて、コミットされない。このファイルはコンテナにマウントされないので、コンテナ内からは書き換えられない。

各ディレクトリ内にも `.gitignore` がある。こちらは空のディレクトリを git に残すためのもので、同じ除外も書いてある（除外は二重になっている）。ビルドコンテキストからは `.dockerignore` で除外している。

`docker-compose.yml` の設定:

| 設定 | 意味 |
| --- | --- |
| `gpus: all` | ホストのNVIDIA GPUを使う |
| `shm_size: "8gb"` | 共有メモリ（`/dev/shm`）の上限。既定の 64MB では学習系のツールが落ちることがある |
| `command: sleep infinity` | コンテナを起動したままにして、`exec` で入れるようにする |
| `init: true` | `stop` / `down` がすぐ終わるようにする（無いと毎回 10 秒待たされる） |
| `volumes` | ディレクトリをマウント。コンテナを消してもデータが残る |
| `ports: 127.0.0.1:8188:8188` | ComfyUI などのポートを、ホスト自身にだけ公開 |

補足:

- ポートは `127.0.0.1` に限定している。`8188:8188` と書くと LAN の他の端末からも接続でき、ファイアウォール（ufw）でも止まらない。ComfyUI には認証が無いので、限定を外さない。
- `docker compose stop` / `down` は、`exec` で動かしているツールを強制終了する。先にツール側を終了させておく。
- マウント先の権限は UID の数値で決まり、コンテナの `ubuntu` は UID 1000 固定。ホストのユーザーが UID 1000 でないと、コンテナからマウント先に書き込めない。
- マウント先に root 所有のファイルができると（root で入って作った場合など）、`ubuntu` から書き込めない。その場合はホスト側で `sudo chown -R "$(id -u):$(id -g)" .my-ai-work` などを実行して、自分の所有に戻す。

compose を使わずに起動する場合（同じく、このリポジトリのディレクトリで実行する）。compose と同じ形で、コンテナを起動したままにして `exec` で入る:

```bash
docker run -d --init --gpus all --name sandbox \
  --shm-size=8g \
  -v "$PWD/.my-ai-models":/models \
  -v "$PWD/.my-ai-work":/work \
  -v "$PWD/.my-ai-agent-config/claude":/home/ubuntu/.claude \
  -v "$PWD/.my-ai-agent-config/codex":/home/ubuntu/.codex \
  -p 127.0.0.1:8188:8188 \
  yasukei/my-ai-sandbox:latest sleep infinity

docker exec -it sandbox bash    # コンテナに入る
docker stop sandbox             # 停止（コンテナは残る）
docker rm sandbox               # コンテナを削除
```

`--init` と `sleep infinity` は、`docker stop` をすぐ終わらせるためのもの。bash を直接起動する形（`docker run -it ... yasukei/my-ai-sandbox:latest`）だと、停止のたびに 10 秒待たされる。

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
codex --sandbox danger-full-access    # 理由は下の「Codex CLI のサンドボックス」
```

torch 系のパッケージ（`torchaudio` など）を追加するときは、`uv pip install torch torchvision torchaudio` のように torch と同じコマンドでまとめて入れる。別々に入れると CUDA ビルドが食い違い、import でエラーになることがある。

`--listen 0.0.0.0` が無いと、ポートを公開してもホストから接続できない。これはコンテナ内の待ち受け設定で、ホスト側の公開先は `127.0.0.1` のままなので、LAN には公開されない。

### Codex CLI のサンドボックス

Codex CLI は `--sandbox danger-full-access` を付けて起動する。

- Codex CLI は、Linux では bubblewrap（bwrap）でコマンドを隔離して実行する。Docker の既定の設定ではコンテナ内でこの隔離を作れず、付けずに起動するとコマンドの実行が `bwrap: No permissions to create a new namespace` で失敗する。
- このオプションは Codex 自身の隔離を切る。Codex が実行するコマンドは、`ubuntu` の権限でコンテナ内のすべて（`/work`、`/models`、マウントした Claude Code / Codex の認証情報、ネットワーク）に届く。
- 隔離はコンテナが受け持つ。ホスト側で届くのは、マウントした4つのディレクトリだけ。
- 毎回付けたくないときは、`.my-ai-agent-config/codex/config.toml` に `sandbox_mode = "danger-full-access"` と書く。

### システムのパッケージ（apt）を追加する

コンテナ内の `ubuntu` は root になれない（sudo は入れていない）。apt でパッケージを入れるときは、ホスト側から root でコンテナに入る。

```bash
docker compose exec -u root sandbox bash

# ここからコンテナ内（root）
apt-get update && apt-get install -y ffmpeg
```

入れたパッケージは `docker compose down` でコンテナごと消える。常に必要なものは `Dockerfile` の apt の行に足して再ビルドする。

root で使うのは apt だけにする。`npm install -g` と `uv` は `ubuntu` で実行する。これらの書き込み先（`/home/ubuntu/.local` と `/work/.cache/uv`）は root でも同じなので、root で実行すると root 所有のファイルができ、`ubuntu` から更新できなくなる。`/work/.cache/uv` の実体はホスト側の `.my-ai-work/.cache/uv` なので、ホストでも sudo なしでは消せなくなる。

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
- 例外として、コンテナ内で Hugging Face にログインすると、トークンは `.my-ai-models/huggingface/token` に保存される（`HF_HOME` が `/models/huggingface` のため）。git には入らないが、`.my-ai-models/` をコピーしたり人に渡したりするとトークンも一緒に渡る。ファイルに残したくないときは、ログインせずに環境変数 `HF_TOKEN` で渡す。
- イメージは Docker Hub に push するため、機密情報を `Dockerfile` に書かない。
