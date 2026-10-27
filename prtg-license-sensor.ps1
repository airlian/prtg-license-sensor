# prtg-license-sensor.ps1 —— PRTG「EXE/Script Advanced」自訂感測器：把授權計量數變成**通道**長期記錄
#
# 為什麼要這樣做：計量數本來是「此刻快照」，而原廠計費口徑是「每個 UTC 日的最高小時級 active sensor 數」。
# 變成通道之後：PRTG 每個輪詢間隔記一次 → 直接看曲線、查每日高峰、超過門檻自動告警。
#
# 計量口徑：計量數 = sensortree 全部 −（狀態碼 7（PausedbyUser）暫停 ∪ 狀態碼 11（PausedbyLicense） ∪ 建立未滿 N 小時），聯集不重複扣。
#           額度：能解析 MaxSensorCount 才算得出來；F／C 直接用該值，S（訂閱制）÷ SubscriptionDivisor（預設 2）。
#           解析不到就當上限未知（不猜），改由 -LicenseLimit 提供。
#
# 建立方式（摘要；完整步驟見 README.md / README.zh-TW.md）
#   1) 本檔放到「執行探測器的那台機器」的 PRTG 程式安裝目錄下、給會回 XML/JSON 的資料夾：
#        C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\
#      （原廠：EXE/Script Advanced 用 Custom Sensors\EXEXML；Custom Sensors\EXE 是標準版用的。
#        遠端探測器要放到探測器那台、集群則每個節點都要放）
#   2) 新增感測器 → 類型 EXE/Script Advanced → 在 EXE/Script 欄選這支腳本（清單讀自 EXEXML，有快取延遲）
#      解譯器留預設＝走 powershell.exe＝Windows PowerShell 5.1；腳本若未簽章，要放寬執行策略
#   3) Parameters 例：-BaseUri http://127.0.0.1 -TokenFile "C:\ProgramData\prtg-license\token.txt"
#      ⚠ 不要把 apitoken／passhash 寫進 Parameters —— 它會在感測器設定與 API 回應裡明文可見
#   4) 間隔建議 ≥300 秒（本機 127.0.0.1 負載很低）；注意**這個感測器本身也算 1 顆 sensor**
#
# 輸出：PRTG 自訂感測器 XML。**stdout 只能出現這一份**，其餘訊息一律走 stderr（函式 Log）。
#   <prtg><result><channel>..</channel><value>..</value><unit>Count</unit></result><text>..</text></prtg>
# 失敗：輸出 <prtg><error>原因</error></prtg> 後 exit 0 → PRTG 將感測器標為 Down 並顯示原因。
#
# 通道名與 <text> 一律用 ASCII：感測器由 PRTG 服務帳號執行，主控台的 stdout 編碼在 Windows PowerShell
# 5.1 上是 OEM 代碼頁，中文會變成亂碼進到歷史紀錄裡。
param(
    [string] $BaseUri = 'http://127.0.0.1',
    [string] $ApiToken       = '',
    [string] $TokenFile      = '',      # 檔內一行 apitoken（建議）
    [string] $Username       = '',
    [string] $Passhash       = '',
    [string] $PasshashFile   = '',      # 檔內一行 username:passhash
    [int]    $LicenseLimit   = 0,       # 實際額度；訂閱制填「顯示上限 ÷ 2」後的那個數
    [int]    $SubscriptionDivisor = 2,
    [double] $AgeHours       = 24,
    [int]    $WarnPercent    = 80,
    [int]    $ErrorPercent   = 100,
    [int]    $TimeoutSec     = 30,
    [switch] $NoAgeCheck,
    [switch] $AllowSelfSigned,          # 非本機位趾的自簽／名稱不符憑證（本機 127.0.0.1 自動信任）
    [switch] $Limits,                   # 預設關：改在感測器的 Channel Limits 分頁設門檻（見下方說明）
    [switch] $LogStderr
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
function Log([string]$m) { if ($LogStderr) { [Console]::Error.WriteLine($m) } }
function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }
function Fail([string]$m) { [Console]::Out.WriteLine('<prtg><error>' + (Esc $m) + '</error></prtg>'); exit 0 }

# ---------- 憑證 ----------
# 金鑰檔的讀取要很寬容：BOM（UTF-8/UTF-16）、CRLF、尾部空行、手滑加的引號，
# 都是客戶用記事本/PowerShell 存檔時常出現的東西，不該因此把正確的金鑰當成錯。
function Clean-Secret([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s = $s.Replace([string][char]0xFEFF, '')          # BOM / ZWNBSP（.NET Framework 的 Trim() 不把它當作空白）
    $s = $s.Replace("`t", ' ').Trim()
    if ($s.Length -ge 2) {
        $f = $s.Substring(0,1); $l = $s.Substring($s.Length-1)
        if (($f -eq '"' -and $l -eq '"') -or ($f -eq "'" -and $l -eq "'")) { $s = $s.Substring(1, $s.Length-2).Trim() }
    }
    return $s
}
# 驗證只擋「真的不可能對」的東西：空白／控制字元／非 ASCII（BOM 遺留），以及看起來根本是文件而非金鑰。
# 金鑰字元集由 PRTG 決定，**不得用白名單去猜**（實測本站金鑰 48 碼、含 `=`）。
function Test-Secret([string]$v, [string]$what) {
    if ($v.Length -lt 8) { Fail ("{0} looks too short (length={1}) - check the file content" -f $what, $v.Length) }
    if ($v -match '[\r\n]')  { Fail "$what contains a line break - the file must hold ONE line only" }
    if ($v -match ' ')       { Fail "$what contains a space - remove quotes and spaces (do not wrap it in quotes)" }
    if ($v -match '^[<{]')   { Fail "$what does not look like a credential - it starts with '<' or '{' (looks like an HTML/JSON body?)" }
    $m = [regex]::Matches($v, '[^\x21-\x7E]')
    if ($m.Count -gt 0) {
        $c = [int][char]$m[0].Value
        Fail ('{0} rejected: character #{1} is U+{2:X4} (non-printable/non-ASCII, usually a BOM or wrong file encoding). Value not shown.' -f $what, ($m[0].Index+1), $c)
    }
}
function Read-SecretFile([string]$path, [string]$what) {
    if (-not (Test-Path -LiteralPath $path)) { Fail "$what file not found: $path" }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $path) }     # 不指定 -Encoding：BOM 自動判別 UTF-16/UTF-8
    catch { Fail "Cannot read $what file: $path" }
    foreach ($l in $lines) {
        $t = Clean-Secret $l
        if ($t -and -not $t.StartsWith('#')) { return $t }
    }
    Fail "$what file has no usable line: $path (expected one line with the credential, # lines are comments)"
}
if ($TokenFile)    { $ApiToken = Read-SecretFile $TokenFile 'TokenFile' }
if ($PasshashFile) {
    $p = Read-SecretFile $PasshashFile 'PasshashFile'
    $i = $p.IndexOf(':')
    if ($i -lt 1) { Fail 'PasshashFile must contain one line: username:passhash' }
    $Username = Clean-Secret $p.Substring(0, $i); $Passhash = Clean-Secret $p.Substring($i + 1)
}
if ($BaseUri -match '/api$') { $BaseUri = $BaseUri -replace '/api$', '' }
$Base = $BaseUri.TrimEnd('/')
$ApiToken = Clean-Secret $ApiToken; $Username = Clean-Secret $Username; $Passhash = Clean-Secret $Passhash
if ($ApiToken)  { Test-Secret $ApiToken 'apitoken' }
if ($Passhash -and $Passhash -notmatch '^\d+$') { Test-Secret $Passhash 'passhash' }   # passhash 是數字，但不硬擋
if (-not $ApiToken -and -not ($Username -and $Passhash)) { Fail 'no credentials: use -TokenFile (preferred) or -ApiToken / -Username + -Passhash' }
$auth = if ($ApiToken) { @{ apitoken = $ApiToken } } else { @{ username = $Username; passhash = $Passhash } }
$aq   = ($auth.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [uri]::EscapeDataString($_.Value) }) -join '&'
$logoff = ('{0}/api/?{1}' -f $Base, (($auth.Keys | ForEach-Object { "$_=***" }) -join '&'))

# ---------- HTTP ----------
# 本機（127.0.0.1/localhost）的 HTTPS 幾乎一定是自簽或名稱不符（憑證簽的是伺服器名稱），
# 這是正常部署形態 → 本機自動信任；打遠端站台就要明確給 -AllowSelfSigned。
$loopback   = ($Base -match '^https?://(127\.0\.0\.1|\[::1\]|localhost)(:|/|$)')
$certBypass = ($loopback -or [bool]$AllowSelfSigned)
$PSMajor    = [int]$PSVersionTable.PSVersion.Major
if ($PSMajor -lt 6) {
    # TLS 協定：**明確指定一組乾淨的值**，不要覆寫成 SystemDefault、也不要用 -bor 補位。
    #   * `SecurityProtocolType.SystemDefault` 在 .NET Framework 上是 -1（所有位元）；賦值當下不檢查，
    #     交握時內部的 SslProtocolType 驗證才失敗 →「指定值在 'SslProtocolType' 列舉中是無效的
    #     (sslProtocolType)」＋「基礎連接已關閉」。
    #   * `-bor` 補位在同一台機器「現值就是 SystemDefault(-1)」時等於沒改（-1 -bor x 仍是 -1）。
    #   所以要的是「直接換成 Tls12(+Tls11)」這種每位元都合法的組合。需要 TLS 1.3 請改用 PowerShell 7。
    try {
        $tlsPrev = [string][Net.ServicePointManager]::SecurityProtocol
        $tls = [Net.SecurityProtocolType]::Tls12
        if ([Enum]::IsDefined([Net.SecurityProtocolType], 'Tls11')) { $tls = $tls -bor [Net.SecurityProtocolType]::Tls11 }
        [Net.ServicePointManager]::SecurityProtocol = $tls
        Log ('TLS protocols: ' + $tlsPrev + ' -> ' + [Net.ServicePointManager]::SecurityProtocol)
        Log ('.NET ' + [Environment]::Version + ' / OS build ' + [Environment]::OSVersion.Version.Build)
    } catch { Log ('could not set the TLS protocol list, keeping the default: ' + $_.Exception.Message) }
    # 環境可能已經在本程序註冊了 scriptblock 版的憑證驗證回呼（常見的來源：$PROFILE 裡貼過的
    # 「忽略自簽憑證」那一行、或某個載入的模組）。那種回呼在 .NET 的 TLS 執行緒上跑不起來
    # （需要 DefaultRunspace），會讓這個程序的**任何** HTTPS 要求直接失敗。
    # 所以我們一律先清掉它，再自己接管信任判定：嚴格驗證＝維持 $null（.NET 預設）；要信任全部就安裝編譯版政策。
    if ($null -ne [Net.ServicePointManager]::ServerCertificateValidationCallback) {
        Log 'environment already registered a certificate validation callback - clearing it (a PowerShell scriptblock cannot run on the .NET TLS thread)'
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    }
    if ($certBypass) {
        # ⚠ 絕對不要再把 PowerShell scriptblock 交給 .NET 的憑證回呼：.NET 是在**非 PowerShell 執行緒**
        #   上叫用它，需要 DefaultRunspace；PRTG 跑腳本的方式就沒有 → 整個 HTTPS 要求直接死在
        #   「基礎連接已關閉 … 沒有 Runspace 可在這個執行緒中用來執行指令碼」。
        #   改用 compiled 的 ICertificatePolicy（純 .NET，不需要任何 Runspace）。
        if (-not ('PrtgTrustAllCertificate' -as [type])) {
            try {
                Add-Type -ErrorAction Stop -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class PrtgTrustAllCertificate : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate,
                                      WebRequest request, int certificateProblem) { return true; }
}
"@
            } catch {
                Fail ('cannot install the TLS trust helper (Add-Type failed: {0}) - use a valid certificate, or run this sensor with PowerShell 7' -f $_.Exception.Message)
            }
        }
        try { [Net.ServicePointManager]::CertificatePolicy = New-Object PrtgTrustAllCertificate }
        catch { Fail 'cannot set ServicePointManager.CertificatePolicy - use a valid certificate instead' }
    }
}
function Get-Json {
    param([string]$Path, [string]$ExtraQuery)
    $url = '{0}/api/{1}?output=json&{2}&{3}' -f $Base, $Path, $ExtraQuery, $aq
    $p = @{ Uri = $url; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
    if ($certBypass -and $PSMajor -ge 6) { $p['SkipCertificateCheck'] = $true }
    try { $r = Invoke-WebRequest @p } catch {
        $ex = $_.Exception
        $why = if ($ex.Message) { $ex.Message } elseif ($ex.InnerException) { $ex.InnerException.Message } else { 'no message' }
        throw "$Path : $why"
    }
    $b = [string]$r.Content
    if ($b -notmatch '^[\{\[]') { throw "$Path returned non-JSON (usually invalid credentials: this host answers HTTP 200 + HTML)" }
    return ($b | ConvertFrom-Json)
}
function Get-XmlDoc {
    param([string]$ExtraQuery)
    $url = '{0}/api/table.xml?{1}&{2}' -f $Base, $ExtraQuery, $aq
    $p = @{ Uri = $url; TimeoutSec = [math]::Max($TimeoutSec, 60); UseBasicParsing = $true }
    if ($certBypass -and $PSMajor -ge 6) { $p['SkipCertificateCheck'] = $true }
    $r = Invoke-WebRequest @p
    $c = $r.Content
    if ($c -is [xml]) { return $c }                 # 5.1 對 text/xml 直接給 XmlDocument（7 給字串）
    $x = New-Object xml; $x.LoadXml([string]$c); return $x
}
function Get-Num {                                   # PRTG 用「點」小數 → 必須 InvariantCulture
    param($Node, [string]$Name)
    if ($null -eq $Node) { return 0.0 }
    $n = $Node.SelectSingleNode($Name); if ($null -eq $n) { return 0.0 }
    $d = 0.0
    [void][double]::TryParse($n.InnerText, [System.Globalization.NumberStyles]::Float,
                             [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)
    return $d
}
function Get-Txt {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return '' }
    $n = $Node.SelectSingleNode($Name); if ($null -eq $n) { return '' }
    return [string]$n.InnerText
}

try {
    # ---------- 1) 一次 sensortree：數量＋逐碼＋暫停拆分＋「存在滿 N 小時」單邊界 ----------
    $x = Get-XmlDoc -ExtraQuery 'content=sensortree&count=100000'
    $nodes = $x.GetElementsByTagName('sensor')
    if ($null -eq $nodes -or $nodes.Count -eq 0) { throw 'sensortree has no <sensor> nodes (credential cannot see anything?)' }
    $epoch    = New-Object datetime(1899, 12, 30)
    $cutoff   = [datetime]::UtcNow.AddHours(-$AgeHours)
    $limitSec = $AgeHours * 3600.0
    $byCode = @{ }; $c7 = 0; $c7direct = 0; $proven = 0; $susp = 0; $suspCounted = 0
    foreach ($n in $nodes) {
        $sc = 0; [void][int]::TryParse((Get-Txt $n 'status_raw'), [ref]$sc)
        if ($byCode.ContainsKey([string]$sc)) { $byCode[[string]$sc] = $byCode[[string]$sc] + 1 } else { $byCode[[string]$sc] = 1 }
        if ($sc -eq 7) { $c7++; if ((Get-Txt $n 'active') -eq 'false') { $c7direct++ } }
        $upd  = Get-Num $n 'cumulateduptime_raw'; $sday = Get-Num $n 'statussince_raw_utc'
        $ok = ($upd -ge $limitSec)
        if (-not $ok -and $sday -gt 0) { $ok = ($epoch.AddDays($sday) -lt $cutoff) }   # 0＝無值，不是 1899
        if ($ok) { $proven++ } else { $susp++; if ($sc -ne 7 -and $sc -ne 11) { $suspCounted++ } }
    }
    $total    = $nodes.Count
    $code11   = if ($byCode.ContainsKey('11')) { [int]$byCode['11'] } else { 0 }
    $licensed = $total - $c7 - $code11
    Log "tree=$total code7=$c7 (direct $c7direct) code11=$code11 suspects=$susp"

    # ---------- 2) 計量數 = 總數 −（狀態碼 7 ∪ 狀態碼 11 ∪ 建立未滿 N 小時）[owner 2026-10-27 指定] ----------
    # 「建立未滿」只計沒被狀態碼 7／狀態碼 11 抓到的那些 → 聯集不會重複扣。
    $licensed = $total - $c7 - $code11                       # 不做年齡扣除時的參考值
    $newUnder = 0
    if (-not $NoAgeCheck) { $newUnder = $suspCounted }
    $metered  = $total - $c7 - $code11 - $newUnder

    # ---------- 3) 上限：判準＝MaxSensorCount 能不能解析成數字 ----------
    # 解析得到 → 這台能設定 sensor 數量上限；解析不到 → 上限未知（不猜，Freeware 的 100 也不自動套）。
    # 換算：F／C 就是該值；S（訂閱制）÷ SubscriptionDivisor（預設 2）才是客戶實際訂閱的數量。
    $edition = ''; $rawMax = 0; $maintDays = $null
    try {
        $st = Get-Json -Path 'getstatus.htm' -ExtraQuery 'id=0'
        $edition = [string]$st.EditionType
        $d = 0
        if ([int]::TryParse([string]$st.MaxSensorCount, [ref]$d)) { $rawMax = $d }
        if ([int]::TryParse([string]$st.MaintExpiryDays, [ref]$d)) { $maintDays = $d }
    } catch { Log "getstatus unavailable: $($_.Exception.Message)" }
    $ceilingOK = ($rawMax -gt 0)
    $quota = 0; $quotaSrc = 'MaxSensorCount not readable -> ceiling unknown (pass -LicenseLimit)'
    if ($LicenseLimit -gt 0) { $quota = $LicenseLimit; $quotaSrc = '-LicenseLimit' }
    elseif ($ceilingOK) {
        if ($edition -eq 'S') { $quota = [int][math]::Ceiling($rawMax / $SubscriptionDivisor); $quotaSrc = "MaxSensorCount $rawMax / $SubscriptionDivisor (subscription)" }
        else                  { $quota = $rawMax; $quotaSrc = "MaxSensorCount $rawMax ($edition)" }
    }
    $quotaUnknown = ($quota -le 0)
    $usage = 0.0
    if (-not $quotaUnknown) { $usage = [math]::Round((100.0 * $metered / $quota), 1) }

    # ---------- 4) 輸出 XML ----------
    $parts = New-Object System.Collections.ArrayList
    function Add-Channel {
        param([string]$Name, $Value, [string]$Unit, [int]$Mode = 0, [int]$Float = 0, [int]$Warn = 0, [int]$Err = 0)
        $s = '<result><channel>' + (Esc $Name) + '</channel><value>' + $Value + '</value>' +
            '<unit>' + $Unit + '</unit><mode>' + $Mode + '</mode><float>' + $Float + '</float>'
        # 限值元素名稱依 PRTG 版本有差異，所以預設**不輸出**（用 -Limits 開啟），建議改在
        # 感測器的 Channel Limits 分頁設定，那裡永遠吃得對、也不會因為驗證失敗整個感測器 Down。
        if ($Limits -and ($Warn -gt 0 -or $Err -gt 0)) {
            if ($Warn -gt 0) { $s += '<limitmaxwarning>' + $Warn + '</limitmaxwarning>' }
            if ($Err  -gt 0) { $s += '<limitmaxerror>'   + $Err  + '</limitmaxerror>'   }
            $s += '<limitmode>1</limitmode>'
        }
        $s += '</result>'
        [void]$parts.Add($s)
    }
    Add-Channel 'Licensed sensors'        $metered 'Count'
    Add-Channel 'PRTG total sensors'      $total   'Count'
    Add-Channel 'Paused (code 7)'         $c7      'Count'
    Add-Channel 'Not licensed (code 11)'  $code11  'Count'
    Add-Channel 'Created under age limit' $newUnder 'Count'
    Add-Channel 'License quota'           $quota   'Count' 1
    Add-Channel 'Ceiling readable'        $(if ($ceilingOK) { 1 } else { 0 }) 'Count' 1
    $wQ = 0; $eQ = 0
    if (-not $quotaUnknown) { $wQ = $WarnPercent; $eQ = $ErrorPercent }
    Add-Channel 'Quota usage %' $usage 'Percent' 0 1 $wQ $eQ

    $txt = 'metered={0} = total {1} -7:{2} -11:{3} new<{4}h:{5}' -f $metered, $total, $c7, $code11, [int]$AgeHours, $newUnder
    $txt += (' | quota={0} ({1})' -f $quota, $quotaSrc)
    $edName = @{ 'F' = 'Freeware'; 'C' = 'Commercial'; 'S' = 'Subscription' }[[string]$edition]
    if ($edName) { $txt += (' edition={0}' -f $edName) }
    if ($quotaUnknown) { $txt = 'CEILING UNKNOWN (MaxSensorCount not parseable and no -LicenseLimit) | ' + $txt }
    if ($code11 -gt 0)   { $txt += (' | CODE 11: {0} sensors paused by license' -f $code11) }
    if ($NoAgeCheck)     { $txt += ' | age rule skipped by -NoAgeCheck' }
    if ($maintDays -ne $null) { $txt += (' | maintenance expires in {0} days' -f $maintDays) }
    [Console]::Out.WriteLine('<prtg>' + ($parts -join '') + '<text>' + (Esc $txt) + '</text></prtg>')
    exit 0
} catch {
    $ex = $_.Exception
    $m = if ($ex.Message) { $ex.Message } else { 'unknown error' }
    if ($ex.InnerException) { $m += (' | ' + $ex.InnerException.Message) }
    # 5.1 上 TLS 沒談成會是這一類訊息（訊息內容跟 Windows 語系有關）→ 補一句可動的下一步
    if ($m -match 'Runspace|基礎連接已關閉|underlying connection|SSL|TLS') {
        $m += ' | hint: TLS failed on Windows PowerShell 5.1 - the trust helper is compiled by Add-Type (needs write access to %TEMP%); or set the Script type of this sensor to PowerShell 7'
    }
    Fail ('prtg-license-sensor: ' + $m + ' | target ' + $logoff)
}
