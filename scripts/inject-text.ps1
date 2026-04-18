param(
    [Parameter(Mandatory = $true)]
    [string]$TextBase64,

    [ValidateSet("type_only", "type_and_enter")]
    [string]$Mode = "type_only",

    [ValidateSet("0", "1")]
    [string]$ForceEnter = "0"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($TextBase64))
$shouldPressEnter = ($Mode -eq "type_and_enter") -or ($ForceEnter -eq "1")

$restoreClipboard = $false
$previousClipboard = $null

try {
    $previousClipboard = Get-Clipboard -Raw -Format Text
    $restoreClipboard = $true
} catch {
    $restoreClipboard = $false
}

if (-not [string]::IsNullOrEmpty($text)) {
    Set-Clipboard -Value $text
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait("^v")
}

if ($shouldPressEnter) {
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
}

Start-Sleep -Milliseconds 180

if ($restoreClipboard) {
    try {
        Set-Clipboard -Value $previousClipboard
    } catch {
    }
}
