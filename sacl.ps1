# ============================================================
#  sacl.ps1 —— 目录审计(SACL) 公共逻辑
#  供 install.ps1 与 export.ps1 共用。幂等：已存在的规则不重复写入。
#  用于「防绕开」：每轮重新补上被移除的审计规则，并覆盖新建的顶层目录。
# ============================================================

if (-not ('FileAuditPriv' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FileAuditPriv {
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
}
[void][FileAuditPriv]::Enable('SeSecurityPrivilege')
[void][FileAuditPriv]::Enable('SeBackupPrivilege')

$script:AuditAccount = [System.Security.Principal.NTAccount]'Everyone'
$script:AuditInherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$script:AuditProp    = [System.Security.AccessControl.PropagationFlags]::None
$script:AuditFlags   = [System.Security.AccessControl.AuditFlags]::Success
$script:AuditRights  = [System.Security.AccessControl.FileSystemRights]::ReadData -bor
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

$script:CExcludeTop = @('Windows','System Volume Information','$Recycle.Bin','Recovery','PerfLogs','Documents and Settings','$WinREAgent','$Windows.~WS','system.sav','found.000','XmpCache')
$script:DExcludeTop = @('SteamLibrary','System Volume Information','$RECYCLE.BIN','FileAudit','DeliveryOptimization','WUDownloadCache','WpSystem','Temp','tmp','ToolsTemp')

function Ensure-AuditOn([string]$path) {
    if (-not (Test-Path $path)) { return }
    try {
        $rule = New-Object System.Security.AccessControl.FileSystemAuditRule($script:AuditAccount, $script:AuditRights, $script:AuditInherit, $script:AuditProp, $script:AuditFlags)
        $acl  = Get-Acl -Path $path
        $exists = $false
        foreach ($ar in $acl.Audit) {
            if ($ar.IdentityReference -eq $script:AuditAccount -and
                $ar.FileSystemRights  -eq $script:AuditRights  -and
                $ar.InheritanceFlags  -eq $script:AuditInherit -and
                $ar.PropagationFlags  -eq $script:AuditProp    -and
                $ar.AuditFlags        -eq $script:AuditFlags) { $exists = $true; break }
        }
        if (-not $exists) {
            $acl.SetAuditRule($rule)
            Set-Acl -Path $path -AclObject $acl
            Write-Host ("   (补)已审计: {0}" -f $path)
        }
    } catch {
        Write-Host ("   跳过(失败): {0} -> {1}" -f $path, $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Add-FileAuditSacls {
    foreach ($d in Get-ChildItem 'C:\' -Directory -Force -ErrorAction SilentlyContinue) {
        if ($script:CExcludeTop -contains $d.Name) { continue }
        if ($d.Name -eq 'Program Files (x86)') {
            foreach ($c in Get-ChildItem $d.FullName -Directory -Force -ErrorAction SilentlyContinue) {
                if ($c.Name -eq 'Steam') { continue }
                Ensure-AuditOn $c.FullName
            }
        } else {
            Ensure-AuditOn $d.FullName
        }
    }
    foreach ($d in Get-ChildItem 'D:\' -Directory -Force -ErrorAction SilentlyContinue) {
        if ($script:DExcludeTop -contains $d.Name) { continue }
        Ensure-AuditOn $d.FullName
    }
}
