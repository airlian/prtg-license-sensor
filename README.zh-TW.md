# PRTG License Sensor — 真正會被計量的 sensor 數

> 英文版：[README.md](README.md)
>
> 一句話：PRTG 顯示的是「全部 sensor 數」，**不是**計量數；訂閱制（`EditionType=S`）畫面上那個上限還是你實際訂閱數的 **2 倍**。
> 這個自訂感測器（EXE/Script Advanced）算出真正佔用授權的數量，並把它變成 **PRTG 通道**，
> 於是有了時間軸、每日高峰與告警。

## 先認三個名詞

PRTG 裡每一個**物件**（感測器、裝置、群組…）都帶一個**狀態碼**：API 欄位叫 `status_raw`，
官方文件給的正式名稱如下（完整清單 1~14：`Unknown=1`、`Collecting=2`、`Up=3`、`Warning=4`、
`Down=5`、`NoProbe=6`、`PausedbyUser=7`、`PausedbyDependency=8`、`PausedbySchedule=9`、
`Unusual=10`、`PausedbyLicense=11`、`PausedUntil=12`、`DownAcknowledged=13`、`DownPartial=14`）。

| 狀態碼 | 官方名稱 | 白話說 | 這個工具怎麼處理 |
|---|---|---|---|
| **7** | `PausedbyUser` | 被暫停。包含你直接按暫停的，也包含**上層物件被暫停而連帶暫停**的 | **不佔授權 → 扣除** |
| **11** | `PausedbyLicense` | PRTG 判定已超過授權上限，自己把多出來的暫停掉了 | **不佔授權 → 扣除**；只要大於 0 就代表已經碰到上限 |
| **3** | `Up` | 正常在收資料 | 佔授權（不扣） |

另外兩個名詞：

* **額度（quota）**：你買的 sensor 數量。**訂閱制（`EditionType=S`）PRTG 顯示的那個上限是額度的 2 倍**，本工具會自動換算。
* **計量數（metered）**：真正會算進授權、也就是廠商據此計費的數量。**PRTG 介面上不會顯示這個數字**，它顯示的是全部物件數。

## 公式

```
計量數 = 全部物件數 −（狀態碼 7 已暫停 ∪ 狀態碼 11 已超授權 ∪ 建立未滿 24 小時）
```

| 扣除項 | 為什麼扣 |
|---|---|
| **狀態碼 7**（`PausedbyUser`，已暫停） | 暫停中的 sensor 不佔授權；直接暫停與連帶暫停都算 |
| **狀態碼 11**（`PausedbyLicense`，已超授權） | 已被 PRTG 暫停，不佔授權 |
| **建立未滿 24 小時** | 剛加入的還不算計量（原廠《Sensor Overage Policy》）。門檻可用 `-AgeHours` 調整 |

三者取**聯集**：同一個物件不會被扣兩次。

### 授權上限怎麼解讀

工具唯一的判準是 **`/api/getstatus.htm` 的 `MaxSensorCount` 能不能解析成數字**：

| `MaxSensorCount` | 代表 | 行為 |
|---|---|---|
| 解析得到 | 這台願意揭露可設定的 sensor 上限 | `EditionType=F`／`C`：該值**就是**額度；`EditionType=S`（訂閱制）：**÷ 2**（`-SubscriptionDivisor`）才是實際訂閱數量 |
| `(Tag maxsensorcount unknown)` 或端點讀不到 | 上限未知 | **不猜**——計量數照算；額度請用 `-LicenseLimit` 給 |

實務上只有**管理員**帳號會回實際數字，唯讀帳號與 API 金鑰都回 `(Tag maxsensorcount unknown)`。
訂閱制超過額度是**追溯計費**，期間不會擋、也不暫停，狀態碼 11 要到額度的 2 倍才會出現 ——
所以**狀態碼 11＝0 不是「沒超用」的證據**。

## 檔案

| 檔案 | 用途 |
|---|---|
| `prtg-license-sensor.ps1` | PRTG **EXE/Script Advanced** 自訂感測器，輸出通道 XML，每個輪詢記錄一次。整個工具就是這一支檔案。 |

## 在 PRTG 上建立感測器

1. 把 `prtg-license-sensor.ps1` 放到**執行探測器那台機器**的 PRTG **程式安裝目錄**下、給「會回 XML/JSON 的腳本」的
   資料夾 `Custom Sensors\EXEXML\`（一般為 `C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\`）。
   原廠原文：會回 XML/JSON 的要用 EXE/Script Advanced，檔案放 `Custom Sensors\EXEXML`；`Custom Sensors\EXE`
   是**標準版** EXE/Script 用的（它不解析 XML）。**是程式安裝目錄、不是 `ProgramData`**，也沒有 `excel\` 這種資料夾。
   遠端探測器要放探測器那台、集群則每個節點都放；放好後類型清單會快取數十秒才看到新檔。
2. **新增感測器** → 類型 **EXE/Script Advanced**。在 *EXE/Script* 欄清單裡選這支腳本（清單讀自
   `Custom Sensors\EXEXML`，有快取延遲）；你的版本若可手動輸入，就填檔名。解譯器保持預設，
   讓它走 `powershell.exe`（也就是 Windows PowerShell 5.1）。
3. 要讓 PowerShell 真的跑得動這個檔：幫檔簽章，或放寬 PRTG 執行帳號的執行策略。原廠註記：
   「**PowerShell 腳本要確保能被執行，必須簽章，或相對應地調整 Powershell.exe 的安全性原則**」。
   在控制台可以用 `-ExecutionPolicy Bypass` 覆蓋，**但 PRTG 不會幫你加這個參數** ——
   所以「控制台跑得到、感測器跑不到」是正常的，先從這裡查。
4. **Parameters 只放路徑，絕對不要放金鑰** —— 參數會明文存在感測器設定裡，也會出現在 API 回應：
   ```
   -BaseUri http://127.0.0.1 -TokenFile "C:\ProgramData\prtg-license\token.txt" -LicenseLimit 500
   ```
   `-TokenFile` 內放一行 API 金鑰；`-PasshashFile` 內放一行 `username:passhash`。
   檔案權限縮到只有 PRTG 探測器服務帳號讀得到。
5. 輪詢間隔（polling interval，感測器多久抓一次）設 300 秒就很夠用：數千顆的規模，
   從本機打 API 大約 1~3 秒。
6. ⚠ **這個感測器本身也算 1 顆 sensor**，會進計量數。

**看歷史**：對 `Licensed sensors`（或 `Quota usage %`）看 **近 24 小時的最大值**。原廠計費取的是
「每天的最高值」，不是當下快照 —— 這正是把數字做成通道的好處。

## 通道

| 通道 | 意義 |
|---|---|
| `Licensed sensors` | ★ 計量數（上面的公式） |
| `PRTG total sensors` | 全部物件數 |
| `Paused (code 7)` | 狀態碼 7（已暫停）的數量 |
| `Not licensed (code 11)` | 狀態碼 11（已超授權）的數量，`> 0` 就是已碰到上限 |
| `Created under age limit` | 按「建立未滿 N 小時」扣掉的顆數 |
| `License quota` | 額度（訂閱制已換算）；讀不到時為 0 |
| `Ceiling readable` | `1`＝`MaxSensorCount` 解析到了、`0`＝讀不到 |
| `Quota usage %` | 計量數 ÷ 額度 |

腳本預設**不輸出**通道限值（限值元素名稱依 PRTG 版本有差異），請在感測器的 **Channel Limits**
分頁設 80%／100% 門檻；一定要由腳本輸出再加 `-Limits`。

## 參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `-BaseUri` | `http://127.0.0.1` | 網站根，**不要附 `/api`** |
| `-TokenFile` / `-PasshashFile` | 空 | **建議**：放金鑰／`username:passhash` 的檔案路徑 |
| `-ApiToken` / `-Username` `-Passhash` | 空 | 直接傳值（會明文存在感測器設定裡） |
| `-LicenseLimit` | `0` | 實際額度（訂閱制填訂閱數量，不是畫面上那個數） |
| `-SubscriptionDivisor` | `2` | 訂閱制「顯示上限 ÷ 額度」的倍數；買斷制填 `1` |
| `-AgeHours` | `24` | 「建立滿 N 小時才計量」的門檻 |
| `-NoAgeCheck` | 關 | 不扣這一項 |
| `-TimeoutSec` | `30` | 對應感測器 Timeout |
| `-Limits` | 關 | 改由腳本輸出限值（見上） |
| `-LogStderr` | 關 | 除錯訊息走 stderr（PRTG 不會顯示） |

## 只讀一次 PRTG

全部資料來自**一次**請求：`GET /api/table.xml?content=sensortree&count=100000`
（`content=sensortree` 是 Table Query 的一種，會把整棵裝置樹連同每個感測器的欄位一次回給你）。
這份回應裡會用到：

* `status_raw` —— 每個感測器的**狀態碼**。把它逐筆統計成各碼數量，與官方逐碼查詢
  （`content=sensors&filter_status=<狀態碼>`）的計數**完全一致**。
* `active` —— 這個感測器是不是啟用中；搭配狀態碼 7 可分辨「直接暫停」與「上層連帶暫停」。
* 下面兩個欄位，用來判斷「是不是剛建立」：

| 欄位 | 判據 |
|---|---|
| `cumulateduptime_raw` | 累計「上線（Up）」秒數 ≧ N 小時 → 這顆必然已存在滿 N 小時 |
| `statussince_raw_utc` | 這個狀態開始的時間，比「現在 − N 小時」還早 → 那個時候這顆就已經存在 |

兩個都是**單邊**判斷：只能證明「不是剛新增」。證不了的一律按「建立未滿 N 小時」扣除（可用
`-NoAgeCheck` 停用）。要 100% 確切判定建立時間，需要管理員憑證讀該物件的 `content=history`
（`Created.` 那一筆），唯讀憑證讀不到。

`content=sensortree` 讀不到時，感測器回 `<prtg><error>…</error></prtg>`，PRTG 會把它標成 Down
**並在畫面上顯示原因** —— 這是刻意設計：報一個看不出問題的錯數字，比一顆紅紅的感測器危險得多。

## PRTG 的幾個坑

* **憑證無效時回 `HTTP 200` + HTML `OK`，不是 401**。腳本要求「必須解析出含整數 `treesize` 的 JSON」，
  只看狀態碼一定會誤判成功。
* **`statussince_raw_utc = 0` 是「沒有值」**，不是 1899 年。
* 數字用**點**當小數點 → 一律 `InvariantCulture` 解析，否則德文／法文 Windows 上會整批判錯。
* Windows PowerShell 5.1 對 `text/xml` 的 `Invoke-WebRequest` 回的是 `XmlDocument`（PowerShell 7 回字串），
  兩種都處理了。
* **stdout 就是感測器協定**：不能用 `Write-Host`、進度列要關、除錯走 stderr、
  通道名與 `<text>` 用 ASCII（5.1 主控台代碼頁會把中文變成亂碼進歷史），
  任何失敗都回 `<prtg><error>…</error></prtg>`。
* **API 金鑰不是純數字**，可能是很長、還含 `=` 的字串 —— 別用「純數字」去驗證它。

## 環境需求

* Windows PowerShell **5.1**（PRTG 跑這類感測器用的就是它）或 PowerShell **7**。
* 任何能讀裝置樹的憑證即可；只有額度與確切建立時間需要管理員。
* **純唯讀**，不會對 PRTG 做任何寫入。

**建感測器之前**，先在核心伺服器的控制台手動跑一次，確認 stdout **只有一份** `<prtg>` 文件
（8 條 `<result>` 通道＋`<text>`）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\prtg-license-sensor.ps1 -BaseUri http://127.0.0.1 -TokenFile C:\ProgramData\prtg-license\token.txt
```

## 授權

[MIT](LICENSE)。
