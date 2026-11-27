# 企業版 JDMC

[English](../jdmc.md) · [简体中文](../zh-hans/jdmc.md) · [繁體中文](jdmc.md)

設定 `USE_XPACK=1` 的企業版節點使用同版本的 JDMC 執行鏡像。安裝器從鏡像擷取 Compose 檔案，以獨立的 `jdmc` 專案啟動容器。企業版離線安裝包包含此鏡像。社群版略過 JDMC，解除安裝時保留同機的 JDMC 和 KOTL 資料。

## 啟動與 Core 通訊

安裝器在 Core 資料庫遷移前啟動 JDMC。Core 尚未啟動或回呼憑證尚未就緒時，主機 root 仍可透過 PAM 登入。Core 透過 JDMC 的 HTTPS 管理連接埠（預設 `9898`）回呼，驗證伺服器憑證並使用 Bearer Token 認證。JDMC 使用本機節點金鑰簽署請求，透過 `http://core.host.internal:8080` 呼叫 Core。安裝器將 Core 發布至主機的 `127.0.0.1:8080`。

節點名稱、金鑰和回呼設定位於唯讀掛載目錄，供 JDMC 和執行 Core 程式碼的容器使用。輪替金鑰時保留 `node-name`，以 root 擁有、權限為 `0400` 的檔案原子替換 `config/core/enrollment-secret`。變更 `JDMC_WEB_ADDR` 後執行 `./jmsctl.sh start jdmc` 更新回呼連接埠。主備兩個節點各自使用本機身分和本機 Core。

透過 `./jmsctl.sh status jdmc` 檢視狀態，`./jmsctl.sh tail jdmc` 檢視日誌。`./jmsctl.sh stop` 停止業務後仍可登入 JDMC。單獨停止管理容器用 `./jmsctl.sh stop jdmc`。主機重新啟動時，Docker 依 `unless-stopped` 策略恢復先前執行的容器。JDMC 使用主機 Docker socket，自訂路徑可透過 `JDMC_DOCKER_SOCK` 設定。

## 資料與升級

主機將 JDMC 資料存放於與 `VOLUME_DIR` 同層的 `jdmc` 目錄中。`config`、`state`、`management`、`backup` 分別掛載到容器的 `/data/jdmc` 下。備份節點身分與 TLS 憑證及金鑰時，一併保存 `config/core/` 和 `.installer/`。既有的獨立備份磁碟繼續在原處使用。

從單機主機版 JDMC 或 v4 KOTL 升級時，安裝器先檢查鏡像與 Compose 設定，再停用舊服務並遷移資料。切換後若容器啟動失敗，請修正提示的問題，再從同一目標安裝包重試。舊主機版主備叢集須先用原版本完成備份和退役，再全新安裝容器主備。

KOTL 的 SFTP 目標、加密憑證、備份排程、歷史紀錄、增量進度及封存檔隨備份目錄保留。從 V4 升級後手動匯入 V5 授權。舊 SFTP 目標缺少主機指紋時，在「資料備份」核對並儲存伺服器的 SHA256 指紋後再傳輸。自訂日誌與錄影目錄可分別透過 `JDMC_HOST_BACKUP_LOG_DIRS` 及 `JDMC_HOST_BACKUP_REPLAY_DIRS` 指定，多個絕對路徑以逗號分隔。

## 服務準備

元件的目錄、權限和金鑰初始化統一由安裝器負責：

```bash
./jmsctl.sh prepare ansible-executor video-worker
./jmsctl.sh prepare --containers jms_ansible_executor jms_video-worker
```

不指定服務時準備所有已啟用服務。`--containers` 必須指定已停止的容器，依容器實際使用的鏡像和執行使用者準備，適用於 JDMC 主備及元件修補後的啟動。此命令不啟動或重建業務容器，不改寫設定或執行資料庫操作。JDMC 在兩端維護升級及拉起應用前呼叫它，繼續負責主備啟停。

## Video Worker

video-worker 的 Compose service、容器名稱和設定鍵統一使用該名稱。設定 `VIDEO_WORKER_ENABLED=0` 可停用本機容器，但不會關閉 KoKo 的錄影轉碼提交；還需要同時設定 `ENABLE_VIDEO_WORKER=true`，KoKo 才會提交錄影。容器內預設位址為 `VIDEO_WORKER_HOST=http://video-worker:9000`。

如果 worker 獨立部署，設定 `VIDEO_WORKER_ENABLED=0`、`ENABLE_VIDEO_WORKER=true`，並將 `VIDEO_WORKER_HOST` 設定為 KoKo 容器可存取的外部位址。安裝器僅在 `USE_XPACK=1` 時啟用此功能；`USE_XPACK=0` 時會強制關閉 KoKo 的 worker 投遞。`USE_XPACK` 是元件部署模式，不代表授權驗證。舊版的 `VIDEO_ENABLED`、`VIDEO_ENABLE` 以及 `${VOLUME_DIR}/video` 資料目錄會在升級時遷移。

單獨管理 worker：

```bash
./jmsctl.sh video-worker {start|stop|restart|status}
```
