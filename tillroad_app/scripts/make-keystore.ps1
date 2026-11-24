# 生成 Android release 签名用的 keystore，并写出 android/key.properties。
#
# 用法（在仓库根 D:\DSH\TillRoads 下执行）：
#   pwsh -File tillroad_app/scripts/make-keystore.ps1 -StorePassword "你的口令" -KeyPassword "你的口令"
#
# 说明：
#   - 生成的文件 tillroad_app/android/tillroad-release.jks 与 android/key.properties
#     都已在 android/.gitignore 里排除，不会入库；也请不要手工复制进仓库。
#   - **务必另行备份这两个文件**：Android 的升级安装要求签名一致，
#     丢了 keystore 就再也无法给老用户发升级包（只能换 applicationId 重新上架）。
#   - 口令自己记住，不要写进本文件或任何提交物。
#   - 不想用脚本时，等价的 keytool 命令见 README「打包分发」一节。

param(
    [Parameter(Mandatory = $true)][string]$StorePassword,
    [Parameter(Mandatory = $true)][string]$KeyPassword,
    [string]$Alias = 'tillroad',
    [int]$ValidityDays = 10000,
    [string]$DName = 'CN=TillRoad, OU=Mobile, O=TillRoad, L=Shanghai, S=Shanghai, C=CN'
)

$ErrorActionPreference = 'Stop'

$androidDir = Join-Path $PSScriptRoot '..\android' | Resolve-Path -ErrorAction Stop
$keystorePath = Join-Path $androidDir 'tillroad-release.jks'
$propsPath = Join-Path $androidDir 'key.properties'

if (Test-Path $keystorePath) {
    Write-Warning "keystore 已存在，将覆盖：$keystorePath"
    Remove-Item $keystorePath -Force
}

$keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
if (-not (Test-Path $keytool)) {
    $keytool = (Get-Command keytool -ErrorAction Stop).Source
}

Write-Host "使用 keytool: $keytool"

# 原生命令（keytool）会把提示信息写到 stderr；PowerShell 在 $ErrorActionPreference='Stop'
# 下会把它当成终止错误（NativeCommandError）。这里临时改为 Continue，只以退出码判定成败。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $keytool -genkeypair `
    -keystore $keystorePath `
    -storetype PKCS12 `
    -keyalg RSA `
    -keysize 2048 `
    -validity $ValidityDays `
    -alias $Alias `
    -storepass $StorePassword `
    -keypass $KeyPassword `
    -dname $DName 2>&1 | ForEach-Object { Write-Host $_ }
$keytoolExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($keytoolExit -ne 0) { throw "keytool 失败，退出码 $keytoolExit" }

# storeFile 用相对 android/app 的路径（build.gradle.kts 里是 file(...) 相对 app 模块解析）
$props = @"
storePassword=$StorePassword
keyPassword=$KeyPassword
keyAlias=$Alias
storeFile=../tillroad-release.jks
"@
# 必须用无 BOM 的 UTF8：Gradle 的 Properties.load 会把 BOM 当成 key 的一部分。
[System.IO.File]::WriteAllText($propsPath, $props, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "已生成："
Write-Host "  keystore : $keystorePath"
Write-Host "  配置     : $propsPath"
Write-Host ""
Write-Host "下一步：flutter build apk --release --dart-define=API_BASE_URL=... --dart-define=API_TOKEN=..."
Write-Host "校验签名：apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk"
Write-Host ""
Write-Host "提醒：keystore 与 key.properties 一旦丢失，就无法再发升级包；请立即离线备份。"
