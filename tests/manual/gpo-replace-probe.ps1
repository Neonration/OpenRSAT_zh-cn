$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GpoReplaceProbe {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool ReplaceFileW(string oldFile, string newFile, string backup, uint flags, IntPtr exclude, IntPtr reserved);
}
'@
$dir = Join-Path ([IO.Path]::GetTempPath()) ('openrsat-replace-probe-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($dir) | Out-Null
$old = Join-Path $dir 'original.dat'
$new = Join-Path $dir 'candidate.dat'
$backup = Join-Path $dir 'backup.dat'
function Save-Bytes($path, [byte[]]$bytes) { [IO.File]::WriteAllBytes($path, $bytes) }
function Bytes-Hex([byte[]]$bytes) { [BitConverter]::ToString($bytes) }
function Security-Hex($path) { Bytes-Hex ((Get-Acl -LiteralPath $path).GetSecurityDescriptorBinaryForm()) }
try {
  Save-Bytes $old ([byte[]](1,2,3))
  Save-Bytes $new ([byte[]](4,5,6))
  $sd = Security-Hex $old
  $ok = [GpoReplaceProbe]::ReplaceFileW($old,$new,$backup,0,[IntPtr]::Zero,[IntPtr]::Zero)
  $err = if ($ok) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
  [pscustomobject]@{Case='replace'; Success=$ok; Error=$err; Target=(Bytes-Hex ([IO.File]::ReadAllBytes($old))); Backup=(Bytes-Hex ([IO.File]::ReadAllBytes($backup))); OwnerDaclUnchanged=($sd -eq (Security-Hex $old)); CandidateExists=[IO.File]::Exists($new)} | ConvertTo-Json -Compress
  [IO.File]::Delete($backup)
  Save-Bytes $new ([byte[]](7,8,9))
  $before = Bytes-Hex ([IO.File]::ReadAllBytes($old)); $sd = Security-Hex $old
  $lock = [IO.File]::Open($old,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try {
    $ok = [GpoReplaceProbe]::ReplaceFileW($old,$new,$backup,0,[IntPtr]::Zero,[IntPtr]::Zero)
    $err = if ($ok) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
  } finally { $lock.Dispose() }
  [pscustomobject]@{Case='exclusive-handle'; Success=$ok; Error=$err; TargetUnchanged=($before -eq (Bytes-Hex ([IO.File]::ReadAllBytes($old)))); OwnerDaclUnchanged=($sd -eq (Security-Hex $old)); CandidateExists=[IO.File]::Exists($new); BackupExists=[IO.File]::Exists($backup)} | ConvertTo-Json -Compress
  if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
  if (-not [IO.File]::Exists($new)) { Save-Bytes $new ([byte[]](7,8,9)) }
  $stream = [IO.File]::Open($old,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $map = $null; $view = $null
  try {
    $mapName = 'Local\openrsat-probe-' + [guid]::NewGuid().ToString('N')
    $map = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($stream,$mapName,0,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite,[IO.HandleInheritability]::None,$true)
    $view = $map.CreateViewAccessor(0,0,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $stream.Dispose(); $stream=$null
    $exclusiveOpened=$false; $guard=$null
    try { $guard=[IO.File]::Open($old,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $exclusiveOpened=$true }
    catch [IO.IOException] { }
    finally { if ($guard) {$guard.Dispose()} }
    $ok = [GpoReplaceProbe]::ReplaceFileW($old,$new,$backup,0,[IntPtr]::Zero,[IntPtr]::Zero)
    $err = if ($ok) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    $view.Write(0,[byte]42); $view.Flush()
  } finally { if ($view) {$view.Dispose()}; if ($map) {$map.Dispose()}; if ($stream) {$stream.Dispose()} }
  [pscustomobject]@{Case='existing-write-mapping'; ExclusiveOpenWithMapping=$exclusiveOpened; Success=$ok; Error=$err; Target=(Bytes-Hex ([IO.File]::ReadAllBytes($old))); BackupExists=[IO.File]::Exists($backup); Backup=$(if ([IO.File]::Exists($backup)) {Bytes-Hex ([IO.File]::ReadAllBytes($backup))} else {''}); CandidateExists=[IO.File]::Exists($new)} | ConvertTo-Json -Compress
  if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
  Save-Bytes $old ([byte[]](1,2,3)); Save-Bytes $new ([byte[]](4,5,6))
  $observed=Bytes-Hex ([IO.File]::ReadAllBytes($old))
  Save-Bytes $old ([byte[]](99,2,3))
  $ok=[GpoReplaceProbe]::ReplaceFileW($old,$new,$backup,0,[IntPtr]::Zero,[IntPtr]::Zero)
  $err=if ($ok) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
  [pscustomobject]@{Case='changed-after-read'; Observed=$observed; Success=$ok; Error=$err; Target=(Bytes-Hex ([IO.File]::ReadAllBytes($old))); Backup=$(if ([IO.File]::Exists($backup)) {Bytes-Hex ([IO.File]::ReadAllBytes($backup))} else {''})} | ConvertTo-Json -Compress
} finally {
  foreach ($path in @($old,$new,$backup)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
  [IO.Directory]::Delete($dir)
  Write-Output 'CLEANUP isolated files and directory removed'
}
