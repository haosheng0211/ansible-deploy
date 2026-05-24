# ansible-deploy

使用 Ansible 將 Ubuntu (阿里雲 ECS / 一般 VPS) 一次性建置為**正式環境基礎伺服器**的 playbook。

> 使用情境：把整個 repo 丟到目標機上、在目標機本機跑 `ansible-playbook`，快速完成環境建置。**不需要遠端控制機、不需要 inventory IP**。

此專案**只負責伺服器基礎環境**（OS 加固、Web/PHP/Node/DB/Cache/監控），不含任何特定專案的部署設定。

---

## 目錄結構

```
infra/
├── ansible.cfg                 # 預設設定 (become root)
├── inventory/
│   ├── production.ini          # (本情境用不到)
│   └── local.ini               # localhost 本機執行 ★ 用這個
├── group_vars/
│   └── production.yml          # 全域變數 (密碼、版本、白名單)
├── playbooks/
│   └── setup-server.yml        # 一鍵建置入口
└── roles/
    ├── common         # 系統更新、deploy user、SSH 加固、sysctl
    ├── ufw            # 防火牆 (22/80/443/9100)
    ├── fail2ban       # SSH 暴力破解防護
    ├── nginx          # Nginx + 優化過的 nginx.conf
    ├── php            # PHP-FPM 8.2 + 常用擴充 + Composer
    ├── nodejs         # Node.js 22 (透過 NodeSource)
    ├── mariadb        # MariaDB 10.11 + 安全設定
    ├── redis          # Redis (bind 127.0.0.1)
    ├── supervisor     # 行程管理
    ├── node-exporter  # Prometheus :9100
    └── promtail       # Loki log shipper (預設關閉)
```

---

## 前置需求

- Ubuntu 22.04 LTS 以上（建議 22.04 或 24.04），全新機器
- root 權限（或可 sudo 的使用者）
- 機器可對外連網（apt、Composer、Node Exporter 下載）
- **你個人的 SSH 公鑰**（之後要用它從外面登入 `deploy` 使用者）

---

## 使用流程

### Step 1. SSH 登入目標機

```bash
ssh root@<your-server-ip>
```

> 後面所有指令都在目標機上執行。

### Step 2. 安裝 Ansible 與 git

> ⚠️ **不要直接 `apt install ansible`** — Ubuntu 20.04 預設 repo 給的是 Ansible 2.9.6（2020 年版），沒有 collection 機制，跑這個 playbook 會在 `mysql_query` 那步爆掉。改用官方 PPA 裝最新版。

```bash
apt update
apt install -y software-properties-common git
apt-add-repository --yes --update ppa:ansible/ansible
apt install -y ansible
```

確認版本：

```bash
ansible --version    # 需要 2.14+，PPA 通常給 2.16+
```

> Ubuntu 22.04 / 24.04 預設 repo 的 ansible 已經夠新（2.14 / 2.16），可以省略 PPA 那兩行直接 `apt install -y ansible git`。但加 PPA 不會出錯，當 fallback 也行。

### Step 3. 把這個 repo 放到機器上

```bash
cd /root
git clone git@github.com:haosheng0211/ansible-deploy.git
cd ansible-deploy/infra
```

> 若不用 git，也可以從本機 `scp -r ansible-deploy root@server:/root/` 上傳。

### Step 4. 放好你的 SSH 公鑰

playbook 的 `common` role 會把 **目標機上** `~/.ssh/id_ed25519.pub` 寫入 `deploy` 使用者的 `authorized_keys`，讓你之後可以用 `deploy` user SSH 進來。

所以**執行前**，請把你個人電腦的公鑰放到目標機的 `/root/.ssh/id_ed25519.pub`：

```bash
mkdir -p ~/.ssh
vi ~/.ssh/id_ed25519.pub    # 貼上你本機 ~/.ssh/id_ed25519.pub 的內容
chmod 644 ~/.ssh/id_ed25519.pub
```

> 想用其他金鑰檔名，改 `group_vars/production.yml` 裡的 `deploy_ssh_public_key`。

### Step 5. 調整全域變數

編輯 `group_vars/production.yml`，**至少要改**：

| 變數 | 說明 |
|---|---|
| `mariadb_root_password` | **務必改掉**，不要用預設的 `CHANGE_ME_root` |
| `ssh_allowed_ips` | SSH 來源白名單；留空 = 開放所有 IP（不推薦） |
| `monitoring_allowed_ips` | 允許抓 Node Exporter `:9100` 的內網 IP |
| `php_version` / `nodejs_major_version` / `mariadb_version` | 依專案需求 |
| `mariadb_innodb_buffer_pool_size` | 2C4G 機器 256M，4C8G 可開到 1G |

**SSH 加固先別開**：

```yaml
ssh_hardening_enabled: false   # 第一次建置請保持 false
```

### Step 6. 執行建置

```bash
cd /root/ansible-deploy/infra
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini
```

> `local.ini` 內容是 `localhost ansible_connection=local`，Ansible 不會走 SSH，直接在本機執行所有任務。

可選參數：

```bash
# 先 dry-run 看會做什麼
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini --check

# 只跑特定 role
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini --tags nginx
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini --tags mariadb

# 跑慢一點看詳細輸出
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini -vvv
```

整段跑完約 5–15 分鐘（看網路與機器規格）。

> 💡 想偷懶不打 `-i inventory/local.ini`，可以把 `ansible.cfg` 第 2 行改成 `inventory = inventory/local.ini`。

### Step 7. 驗證 deploy 使用者能從外面登入

回到你**自己電腦**：

```bash
ssh deploy@<your-server-ip>
```

能登入代表 `deploy` user、SSH 金鑰、sudoer 設定都正確。

### Step 8. 開啟 SSH 加固（重要）

確認 `deploy` 可登入後，**保留現在這條已登入的 SSH 連線不要關**（萬一鎖死可以救），然後在目標機上：

```bash
vi /root/ansible-deploy/infra/group_vars/production.yml
# 把 ssh_hardening_enabled 改為 true

cd /root/ansible-deploy/infra
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini --tags common
```

加固項目：
- 禁用密碼登入（只允許金鑰）
- 禁用空密碼
- `MaxAuthTries 3`
- 禁用 X11 forwarding
- 5 分鐘 idle timeout
- 只允許 `root` 和 `deploy` 登入

加固完開**新的 terminal** 測一次 `ssh deploy@<ip>`，能上代表 OK，原本那條保命連線才能關。

---

## Promtail（可選）

要把 log 集中到 Loki，編輯 `group_vars/production.yml`：

```yaml
promtail_enabled: true
loki_push_url: "http://10.0.0.x:3100/loki/api/v1/push"
```

再跑：

```bash
ansible-playbook playbooks/setup-server.yml -i inventory/local.ini --tags promtail
```

---

## 建置完成後伺服器狀態

| 項目 | 內容 |
|---|---|
| 使用者 | `root`、`deploy`（部署用，可免密 reload php-fpm / supervisorctl） |
| 防火牆 | UFW 啟用，只開 22/80/443/9100 |
| SSH | 加固後僅允許金鑰登入 |
| Nginx | 已裝，預設站點已移除（等專案 role 加 site） |
| PHP | `php8.2-fpm` 已起，Composer 在 `/usr/local/bin/composer` |
| Node.js | `node`、`npm` 已裝 |
| MariaDB | 已裝、root 密碼已設、移除匿名/test/遠端 root |
| Redis | bind 127.0.0.1，maxmemory 256mb、LRU |
| Supervisor | 已起 |
| Node Exporter | `:9100`（僅允許白名單 IP） |
| 自動更新 | unattended-upgrades 已啟用 |

---

## 常見問題

**Q: 重跑會不會把資料庫洗掉？**
不會。所有 role 都是 idempotent，重跑只會補齊缺漏項目。**但 `mariadb_root_password` 改了之後重跑**，會用新密碼覆蓋舊密碼。

**Q: 想加新的 PHP 擴充？**
編輯 `infra/roles/php/tasks/main.yml` 的套件清單，重跑 `--tags php`。

**Q: 想改 Nginx worker 數量？**
編輯 `infra/roles/nginx/templates/nginx.conf.j2`，重跑 `--tags nginx`。

**Q: 跑到一半失敗怎麼辦？**
直接再跑一次同樣指令即可。Ansible 會跳過已完成的步驟，從失敗那步繼續。失敗訊息通常會印出具體哪個 task — 看訊息對應到 `roles/<name>/tasks/main.yml` 處理。

**Q: 部署專案應該寫在哪？**
**不要寫在這裡**。這個 repo 只負責伺服器基礎建置。專案部署（git pull、composer install、migrate、Nginx site、Supervisor program）另開一個 `deploy-{project}` repo 或 role。

---

## 安全注意事項

- `mariadb_root_password` 不要 commit 明碼，建議用 Ansible Vault：
  ```bash
  ansible-vault encrypt_string 'YourStrongPassword' --name 'mariadb_root_password'
  ```
  執行時加 `--ask-vault-pass`。
- `ssh_allowed_ips` 與 `monitoring_allowed_ips` 在正式環境**一定要設**，不要全開。
- 第一次跑完、驗證 `deploy` 能登入後，盡快開 `ssh_hardening_enabled: true` 再跑一次。
- 跑完建議把 `/root/ansible-deploy` 刪掉或搬走，避免明碼變數留在機器上：
  ```bash
  rm -rf /root/ansible-deploy
  ```
