# ============================================================
#  FileAudit 卸载脚本 —— 必须以管理员身份运行
#  关闭审计、移除 SACL、删除计划任务。
#  加 -DeleteAll 可连同日志目录 D:\FileAudit 一起删除。
# ============================================================
param([switch]$DeleteAll)
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限，正在请求提权...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath), $(if ($DeleteAll) { '-DeleteAll' } else { '' })
    exit
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FileAuditPriv2 {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TOKEN_PRIVILEGES ns, uint len, IntPtr prev, IntPtr retLen);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  public static bool Enable(string priv) {
    IntPtr tok; LUID luid;
    if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0020, out tok)) return false;
    if (!LookupPrivilegeValue(null, priv, out luid)) return false;
    TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
    tp.PrivilegeCount = 1; tp.Privileges.Luid = luid; tp.Privileges.Attributes = 2;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
[void][FileAuditPriv2]::Enable('SeSecurityPrivilege')

# ---- 关闭审计子类别 ----
$fsGuid = '{0CCE921D-69AE-11D9-BED3-505054503030}'
auditpol /set /subcategory:$fsGuid /success:disable | Out-Null
Write-Host '已关闭「文件系统」审计。'

# ---- 移除 SACL ----
$auditAccount = [System.Security.Principal.NTAccount]'Everyone'
$inheritance  = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$propagation  = [System.Security.AccessControl.PropagationFlags]::None
$auditFlags   = [System.Security.AccessControl.AuditFlags]::Success
$rights       = [System.Security.AccessControl.FileSystemRights]::ReadData -bor
                [System.Security.AccessControl.FileSystemRights]::WriteData -bor
                [System.Security.AccessControl.FileSystemRights]::AppendData -bor
                [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
                [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
                [System.Security.AccessControl.FileSystemRights]::ExecuteFile -bor
                [System.Security.AccessControl.FileSystemRights]::ListDirectory -bor
                [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
                [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [System.Security.AccessControl.FileSystemRights]::Delete -bor
                [System.Security.AccessControl.FileSystemRights]::ChangePermissions

function Remove-Audit([string]$path) {
    if (-not (Test-Path $path)) { return }
    try {
        $rule = New-Object System.Security.AccessControl.FileSystemAuditRule($auditAccount, $rights, $inheritance, $propagation, $auditFlags)
        $acl  = Get-Acl -Path $path
        if ($acl.RemoveAuditRule($rule)) {
            Set-Acl -Path $path -AclObject $acl
            Write-Host "   已移除审计: $path"
        }
    } catch { Write-Host ("   跳过: {0}" -f $path) -ForegroundColor DarkYellow }
}

$cExcludeTop = @('Windows','System Volume Information','$Recycle.Bin','Recovery','PerfLogs','Documents and Settings','$WinREAgent','$Windows.~WS','system.sav','found.000','XmpCache')
$dExcludeTop = @('SteamLibrary','System Volume Information','$RECYCLE.BIN','FileAudit','DeliveryOptimization','WUDownloadCache','WpSystem','Temp','tmp','ToolsTemp')

foreach ($d in Get-ChildItem 'C:\' -Directory -Force -ErrorAction SilentlyContinue) {
    if ($cExcludeTop -contains $d.Name) { continue }
    if ($d.Name -eq 'Program Files (x86)') {
        foreach ($c in Get-ChildItem $d.FullName -Directory -Force -ErrorAction SilentlyContinue) {
            if ($c.Name -eq 'Steam') { continue }
            Remove-Audit $c.FullName
        }
    } else { Remove-Audit $d.FullName }
}
foreach ($d in Get-ChildItem 'D:\' -Directory -Force -ErrorAction SilentlyContinue) {
    if ($dExcludeTop -contains $d.Name) { continue }
    Remove-Audit $d.FullName
}

# ---- 删除计划任务 ----
schtasks /Delete /TN 'FileAuditExport' /F 2>$null | Out-Null
Write-Host '已删除计划任务 FileAuditExport。'

if ($DeleteAll) {
    Remove-Item -Path 'D:\FileAudit' -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '已删除 D:\FileAudit 目录。'
} else {
    Write-Host '日志与脚本保留在 D:\FileAudit，如需彻底删除请运行:  .\uninstall.ps1 -DeleteAll'
}
Write-Host '卸载完成。' -ForegroundColor Green
