# PostgreSQL 18 遷移

[English](../postgresql-18-upgrade.md) · [简体中文](../zh-hans/postgresql-18-upgrade.md) · [繁體中文](postgresql-18-upgrade.md)

新安裝預設使用 `postgres:18.7-trixie`。

## Compose 配置

統一的 `compose/postgresql.yml` 明確設定 `PGDATA=/var/lib/postgresql/data`，繼續將 `${VOLUME_DIR}/postgresql/data` 掛載到該目錄，以相容 JDMC 的主備重建、回切和啟動寫入隔離。

同時明確掛載 `${VOLUME_DIR}/postgresql:/var/lib/postgresql`，避免 PostgreSQL 18 鏡像自動建立額外匿名卷，導致 JDMC 的 Compose 掛載一致性檢查失敗。

主 Compose 固定為 `postgres:18.7-trixie`，不需要資料庫鏡像設定項。舊版本依實際資料版本選擇鏡像，僅在遷移前自動產生 `${CONFIG_DIR}/postgresql/image-<tag>.yml` 執行期鏡像覆寫檔案，使用相同的 `PGDATA`；遷移完成後使用主 Compose 中的 18 鏡像。

執行期檔案會保留，避免影響 JDMC 已記錄的 Compose 綁定。JDMC 升級既有主備時繼續使用已綁定的舊 Compose 檔案，在協調遷移切換時更新資料庫設定和綁定，不改寫舊檔案。

單機產生資料庫 Compose 命令時會補齊父目錄的可穿越權限，避免舊目錄為 `700` 時容器無法存取；資料目錄 `postgresql/data` 的權限保持不變。

## 從舊版本升級

從 JumpServer 5.0 等舊應用版本升級時，內建 PostgreSQL 10–17 會在同一次維護中遷移到 `postgres:18.7-trixie`。

安裝器會：

1. 載入舊鏡像和 18 鏡像。
2. 停止應用寫入並停用自動重啟。
3. 使用 18 用戶端匯出全部資料庫和角色。
4. 在隔離目錄還原並驗證結果。
5. 切換資料目錄。
6. 更新業務表結構並還原原先執行的應用。

遷移前仍依 `PG_VERSION` 選擇舊鏡像；不能讓 18 直接開啟舊資料。外部資料庫不會被升級。

舊目錄、邏輯備份和進度保存在 `${VOLUME_DIR}/postgresql/data.upgrade18/`：

- `original/` 是原始資料。
- `cluster.sql` 包含全庫及角色憑證。

目錄和檔案必須保持私有。遷移備份是必要步驟，不受 `SKIP_BACKUP_DB` 影響。中斷時應用保持停止，重試同一升級繼續處理；完成遷移前一般啟動會被拒絕。

恢復業務後新產生的資料不會寫回舊目錄，不能直接把舊目錄切回去。空間預檢依舊資料三倍加 1 GiB 估算；大型物件或高壓縮資料可能需要更多空間。

自動遷移要求可驗證的管理員帳號、標準資料路徑和設定；自訂表空間、外部設定或 SSL 檔案、邏輯複製、非 libc 範本區域設定等自訂部署在預檢時中止，需要單獨遷移。原鏡像及舊資料不會自動清理。

## JDMC 主備

JDMC 主備由兩台協調維護：停止業務和選舉，遷移主庫，重新建立 18 備庫，驗證串流複製、同步提交和啟動寫入隔離，再更新應用並退出維護。

兩台 JDMC 必須先具備此遷移能力。新的完整升級包宣告 `maintenance-pg18-v1`，舊 JDMC 會拒絕該包，避免跳過資料庫遷移。`pg_rewind` 不承擔資料庫大版本遷移。

參考 PostgreSQL 的 [升級說明](https://www.postgresql.org/docs/18/upgrading.html) 和 [主備版本要求](https://www.postgresql.org/docs/18/warm-standby.html)。
