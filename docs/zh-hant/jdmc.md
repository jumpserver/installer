# 企業版 JDMC

[English](../jdmc.md) · [简体中文](../zh-hans/jdmc.md) · [繁體中文](jdmc.md)

JDMC 是企業版元件。在 `/opt/jumpserver/config/config.txt` 中設定 `USE_XPACK=1` 啟用。它以主機 systemd 服務安裝，不加入 Docker Compose。社群版不會下載或安裝 JDMC；企業版始終安裝 JDMC，不提供個別的啟用或停用開關。

## 鏡像與安裝

安裝器依 `IMAGE_PULL_PREFIX` 拉取 JDMC artifact 鏡像（未設定時使用 `jumpserver/jdmc:${VERSION}`），視需要標記為 `${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，從 `/dist` 提取並執行其內建的 `scripts/install.sh` 或 `scripts/upgrade.sh`。

JDMC 與 Core 等自有元件使用相同的拉取和重新標記規則。企業版離線包始終包含該鏡像。

安裝或升級時會嘗試安裝 JDMC 的 HA 主機依賴。依賴安裝失敗或依賴腳本缺少時，安裝器只輸出警告，單機安裝或升級繼續。啟用 HA 前必須補齊依賴；JDMC 的 HA `setup`、`prepare` 和 `install` 流程會再次檢查並安裝依賴，失敗時中止 HA 部署。

服務跟隨 `jmsctl.sh start/stop/restart/status` 管理。透過 `./jmsctl.sh tail jdmc` 查看日誌。安裝器會為 Core 設定 `JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock`，Core 在企業版中自動啟用 JDMC 整合。

## 資料路徑

安裝或升級時，安裝器會將目前 `VOLUME_DIR` 傳遞給 JDMC artifact 腳本。JDMC 據此設定主機上的 Core Unix Socket、日誌和備份路徑，因此可以繼續使用既有的自訂持久化目錄，不需要為了升級遷移到 `/data/jumpserver`。

JDMC 啟動時也會直接讀取 `/opt/jumpserver/config/config.txt` 中的 `VOLUME_DIR`。修改後執行 `systemctl restart jdmc` 重新載入 JDMC 路徑。修改已安裝環境的 `VOLUME_DIR` 不會自動搬遷原有 JDMC 資料，必須先停止服務並明確遷移同級的 `jdmc` 目錄。

## 從 KOTL 遷移

從 KOTL 升級時，安裝器會辨識 `/opt/kotl` 和 `kotl.service`，並呼叫新 JDMC artifact 的升級腳本完成資料、設定和 systemd 服務遷移。安裝或升級成功後會清理舊的 `KOTL_ENABLED`、`JDMC_HOST_ENABLED` 和 `JDMC_ENABLED` 設定，歷史停用值不再生效。

命令列使用 `jdmc` 作為 JDMC 服務目標。`--skip-jdmc` 僅供 JDMC 發起 JumpServer 重啟時避免停止自身，不是元件開關。

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
