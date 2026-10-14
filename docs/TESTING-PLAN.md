# 実機試験計画（feature/wings-layout-isolation）

自動テスト（モック／使い捨てコンテナ）で確認できない部分を、実サーバーで確認するための手順です。
**本番ノードの前に、必ず使い捨てまたは検証用のVPSで全項目を通してください。**

## 0. 共通事項

### 対象環境

| ID | OS | 用途 |
| --- | --- | --- |
| E1 | Ubuntu 24.04（新規VPS） | 新規導入・切り替え・削除 |
| E2 | Debian 12（新規VPS） | MariaDB／ソケット起動の確認 |
| E3 | 既存Hydrodactyl（旧レイアウト：`/etc/pterodactyl`, `wings.service`）のスナップショット複製 | 互換・更新・移行・復旧 |
| E4 | Pelican Wings 導入済みVPS | 外部Wings保護 |

### 実行方法（ブランチを指定）

```bash
export GITHUB_BASE_URL=https://raw.githubusercontent.com/kazaminosuke/hydro-install
export GITHUB_SOURCE=feature/wings-layout-isolation
bash <(curl -fsSL "$GITHUB_BASE_URL/$GITHUB_SOURCE/install.sh")
```

`GITHUB_BASE_URL`/`GITHUB_SOURCE` は子スクリプト・Wings更新スクリプトにも引き継がれます（引き継がれず `main` を取得していたら不具合）。

### 毎回の事前・事後記録

```bash
# 事前（スナップショットの代わりにもなる記録）
mkdir -p /root/hydro-test && cd /root/hydro-test
systemctl list-units --all '*wings*' --no-pager > units.before
docker ps -a --format '{{.Names}} {{.Status}} {{.Mounts}}' > containers.before
docker network ls > networks.before; ip -br link > links.before
ss -ltnp > ports.before
find /etc/pterodactyl /etc/pelican /etc/hydrodactyl /var/lib/pterodactyl /var/lib/pelican \
     -maxdepth 2 -printf '%p %m %u\n' 2>/dev/null > tree.before
sha256sum /usr/local/bin/wings /etc/pterodactyl/config.yml /etc/pelican/config.yml 2>/dev/null > sums.before
```

事後も同じコマンドで `*.after` を取り、`diff` で意図しない変化がないことを確認します。

**ロールバックの基本**：試験前にVPSのスナップショットを取得。スクリプト側の復旧手順で戻らない場合はスナップショットに戻します。

---

## 1. 正常系

### N1 新規導入（Go Wings）— E1

1. パネルでノードを作成し、APIキーとノードIDを用意。
2. メニューから Wings を選び、variant `go` で導入。
3. 期待結果
   - `systemctl is-active hydrodactyl-wings` → `active`、`is-enabled` → `enabled`
   - `/usr/local/bin/hydrodactyl-wings version` に Go Wings のバージョン
   - `/etc/hydrodactyl/wings/config.yml`（権限600）、`root_directory: /var/lib/hydrodactyl/wings`
   - `docker network inspect hydrodactyl_nw` のブリッジ名が `hydro0`、サブネット 172.22.0.0/16（重なる場合は次の空き）
   - `/etc/pterodactyl`, `/var/lib/pterodactyl`, `wings.service` が**作られていない**
   - パネル上でノードが緑（ハートビートOK）
4. サーバーを1台作成→インストール→起動→コンソール表示→SFTP（2022）でログイン→ファイル作成。
5. 確認：`ls /var/lib/hydrodactyl/wings/volumes/<uuid>` にファイルがある。

### N2 新規導入（Wings-RS）— E1（N1を削除後、またはスナップショットから）

N1と同じ。バイナリは `hydrodactyl-wings --version` に `calagopus-wings`。config の `docker.network.mode` も `hydrodactyl_nw`。

### N3 更新 — E1（N1後）

1. `echo v1.11.0 > /etc/hydrodactyl/wings-version`（古い版に見せかける）
2. メニューの Wings 更新、または `bash installers/auto-update-wings.sh --force` 相当。
3. 期待結果：バイナリ更新、`wings-version` が最新タグ、サービス active、稼働中サーバーがパネルから操作可能、`/var/backups` 配下の新規バックアップディレクトリが `700`。

### N4 Go ⇄ Wings-RS 切り替え — E1

1. N1 の状態で variant `rs` を選んで再インストールし、置き換え確認に `y`。
2. 期待結果：`configure` が対話で止まらず完了、サービス active、パネルでノード緑、既存サーバーのファイルが残る。
3. 逆方向（rs→go）も実施。
4. **注意**：切り替え後に既存サーバーが起動できるかを必ず確認（変種間で状態ファイル形式が違う可能性あり、自動テスト未確認）。

### N5 既存Hydrodactyl（旧レイアウト）の互換 — E3

1. 更新を実行（移行はしない）。
2. 期待結果：`/usr/local/bin/wings`, `/etc/pterodactyl/config.yml`, `wings.service` のまま更新される。`/etc/hydrodactyl/wings` は作られない。サーバー稼働継続。

### N6 移行（任意機能）— E3（メンテナンス時間内）

1. メニューの移行を実行（「稼働中のゲームサーバーは停止する」確認が出る）。
2. 期待結果
   - 旧 `/etc/pterodactyl`, `/var/lib/pterodactyl` は**残る**（コピー）
   - `hydrodactyl-wings` active、`wings.service` は disabled
   - 全サーバーがパネルから起動でき、ワールド等のデータが移行前と一致（`diff -r` を数サーバーで）
   - 新しいサーバーのコンテナのマウント元が `/var/lib/hydrodactyl/wings/volumes/...`（`docker inspect`）
3. 移行後、数日問題なければ旧データの削除は手動判断。

### N7 アンインストール — E1

1. メニューの削除で Wings のみ削除。
2. 期待結果：`hydrodactyl-wings` サービス・バイナリ・`/etc/hydrodactyl/wings`・データが消える。Hydrodactyl のデータを使うコンテナだけが消える。

---

## 2. 外部Wings保護（E4: Pelican）

| ID | 手順 | 期待結果 |
| --- | --- | --- |
| P1 | Pelican稼働中にHydrodactyl Wingsを新規導入 | Pelicanの `wings.service`・`/etc/pelican`・`/var/lib/pelican`・コンテナ・ネットワーク無変更（事前記録とdiff）。`hydrodactyl-wings` はポート競合のため**起動せず**、警告表示 |
| P2 | P1後に修復メニュー「全サービス再起動」 | Pelican稼働中は `hydrodactyl-wings` を起動しない旨の警告。Pelicanは再起動されない |
| P3 | Pelicanを停止→`systemctl enable --now hydrodactyl-wings` | `hydro0` ブリッジで起動（Pelican/Pterodactylのブリッジ `pterodactyl0` が残っていても失敗しない） |
| P4 | Hydrodactyl Wings を削除 | Pelicanの全ファイル・コンテナ・ネットワーク・`pterodactyl`ユーザーが残る |
| P5 | 移行を実行 | Pelicanのパスが含まれるため拒否、何も作られない |

---

## 3. MariaDB（E2: Debian 12）

| ID | 手順 | 期待結果 |
| --- | --- | --- |
| M1 | パネル導入（リモートDBホスト指定なし） | `ss -ltnp \| grep 3306` が `127.0.0.1:3306` のみ。`systemctl is-enabled mariadb.socket` が enabled なら `/etc/systemd/system/mariadb.socket.d/99-hydrodactyl.conf` がある |
| M2 | 導入中に別端末で `ps -eo args \| grep -i mysql` を繰り返す | rootパスワードが表示されない |
| M3 | `DB_REMOTE_HOSTS=<ノードIP>` で導入 | `SELECT user,host FROM mysql.user WHERE user='dbhost'` が 127.0.0.1/localhost/<ノードIP> のみ（`%` なし）。外部から他IPで3306に接続できない（ファイアウォール） |
| M4 | 1GB RAMのVPSで導入 | MariaDBが起動し `@@innodb_buffer_pool_size` が約256MB |
| M5 | `/var/backups/hydrodactyl` の権限 | `700`、中の `.sql`・`.env` を一般ユーザーが読めない |

---

## 4. 異常系・失敗注入

| ID | 手順 | 期待結果 | 確認・復旧 |
| --- | --- | --- | --- |
| F1 | 導入中にパネルURLを誤る（到達不能） | 「Failed to configure Wings」で停止、成功表示にならない | 再実行で導入可 |
| F2 | 切り替え（N4）中、パネルのAPIキーを失効させておく | configure 失敗、**元の config.yml が復元**される | `diff` で旧configと一致、`systemctl start hydrodactyl-wings` で旧状態に戻る |
| F3 | 更新時にGitHubへ到達不能（`/etc/hosts` で api.github.com を 127.0.0.1 に） | 更新失敗、バイナリ・サービス変化なし | hosts を戻す |
| F4 | メニュー実行中にネットワーク切断（スクリプト取得失敗） | メニューがエラー終了（「成功」にならない） | 再実行 |
| F5 | 移行中に `docker stop` が失敗するコンテナ（例：`docker update --restart` と保護設定など）がある | 移行中止→自動ロールバック、旧 `wings` が active/enabled に戻る、`/etc/hydrodactyl/wings` は消える | `systemctl status wings`、サーバー起動確認 |
| F6 | 空き容量不足で移行 | 事前チェックで拒否、何も変更なし | — |
| F7 | `/tmp/hydrodactyl-lib.sh` を一般ユーザーで作成してからrootでインストーラーを直接実行 | そのファイルは読み込まれず、GitHubから取得し直す | 一般ユーザーのファイルを削除 |
| F8 | Docker停止中にアンインストール | **既知のリスク**：コンテナ検出できず削除が進む。実施する場合は事前にDocker起動を確認 | — |

---

## 5. 復旧

| ID | 手順 | 期待結果 |
| --- | --- | --- |
| R1 | `chmod -x /usr/local/bin/hydrodactyl-wings` 後に修復メニュー「Wings権限修正」 | 実行権限が戻り、再起動で active |
| R2 | 移行後に問題が出た場合の手動切り戻し：`systemctl disable --now hydrodactyl-wings; systemctl enable --now wings` | 旧レイアウトで起動（旧データは移行時に残してある）。移行後に作られたデータは旧側にないことに注意 |
| R3 | サーバー再起動 | `hydrodactyl-wings` のみ自動起動（Pelican共存時はどちらが有効か警告どおり） |

---

## 6. 合否判定

- N1–N7, P1–P5, M1–M5 がすべて期待どおり → 本番の既存ノードへ（まず1ノード）。
- F/R 系で期待と違う場合は、ログ（`journalctl -u hydrodactyl-wings`, `/var/log/hydrodactyl-installer.log`）と事前・事後の記録を添えて報告。

## 7. 自動テストとの対応

| 区分 | スクリプト | 内容 |
| --- | --- | --- |
| モック | `tests/wings-layout-test.sh` ほか3本 | パス判定・設定書換・移行/ロールバック・安全設定 |
| ミューテーション | `tests/mutation-check.py` | 安全ルールを1つずつ壊し、モックテストが検出するか |
| 実環境（コンテナ） | `tests/integration/*.sh` | 本物の systemd/Docker/MariaDB、本物の Go Wings・Wings-RS ＋簡易パネル |
| 実機のみ | 本書 | 本物のパネル、ゲームサーバー稼働、SFTP、Pelican実物、再起動、各OS |
