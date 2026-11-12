# Pure helpers for a future isolated lab run; no I/O, COM activation or domain access.
function Get-CodexComCleanupDisposition([bool]$hasSession,$targetId,[string]$phase) {
  if(-not $hasSession){return 'unavailable'}
  $id=[guid]::Empty
  if($null -eq $targetId -or -not [guid]::TryParse([string]$targetId,[ref]$id) -or $id -eq [guid]::Empty){return 'no-target'}
  if($id -eq [guid]'31B2F340-016D-11D2-945F-00C04FB984F9' -or
    $id -eq [guid]'6AC1786C-016F-11D2-945F-00C04FB984F9'){return 'protected-target'}
  if($phase -in @('save-outcome-unknown','create-outcome-unknown','post-save-unverified')){return 'deferred'}
  return 'identity-and-link-check-required'
}
function Get-CodexGptVersion([byte[]]$bytes) {
  if($null -eq $bytes -or $bytes.Length -eq 0){return $null}
  $start=0
  if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){$start=3}
  for($i=$start;$i -lt $bytes.Length;$i++){if($bytes[$i] -gt 127 -or $bytes[$i] -eq 0){return $null}}
  $text=[Text.Encoding]::ASCII.GetString($bytes,$start,$bytes.Length-$start)
  $inside=$false; $generalCount=0; $versionCount=0; $number=[uint32]0
  foreach($line in [regex]::Split($text,"\r\n|\r|\n")) {
    $trim=$line.Trim()
    if($trim -match '^\[([^\]]+)\]$') {
      $inside=($Matches[1] -ieq 'General'); if($inside){$generalCount++}; continue
    }
    if($inside -and $trim -match '(?i)^Version\s*=') {
      $versionCount++; if($trim -notmatch '(?i)^Version\s*=\s*([0-9]+)\s*$'){return $null}
      if(-not [uint32]::TryParse($Matches[1],[ref]$number)){return $null}
    }
  }
  if($generalCount -ne 1 -or $versionCount -ne 1){return $null}
  return $number
}
function Test-CodexFileSnapshot($file) {
  if($null -eq $file -or $file.Exists -isnot [bool]){return $false}
  if(-not $file.Exists){return $file.Length -eq 0 -and $null -eq $file.SHA256 -and $null -eq $file.Bytes}
  if($file.Length -lt 0 -or $file.Length -gt 16777216 -or [string]$file.SHA256 -notmatch '^[0-9A-Fa-f]{64}$' -or $null -eq $file.Bytes){return $false}
  try {
    $bytes=[Convert]::FromBase64String($file.Bytes); if($bytes.Length -ne $file.Length){return $false}
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
    return $hash -ieq $file.SHA256
  } catch {return $false}
}
function Test-CodexComSameBaseline($before,$after) {
  if($null -eq $before -or $null -eq $after){return $false}
  foreach($field in @('Guid','ObjectGuid','DN','Name','Version','Flags','FilePath','OwnerGroupDacl')) {
    if($null -eq $before.$field -or $null -eq $after.$field -or [string]$before.$field -eq ''){return $false}
  }
  foreach($field in @('Guid','ObjectGuid','DN','Name','Version','Flags','FilePath','MachineExtension','UserExtension','OwnerGroupDacl')) {
    if([string]$before.$field -cne [string]$after.$field){return $false}
  }
  foreach($side in @('GPT','Machine','User')) {
    $a=$before.Files.$side; $b=$after.Files.$side
    if(-not (Test-CodexFileSnapshot $a) -or -not (Test-CodexFileSnapshot $b) -or $a.Exists -ne $b.Exists -or
       $a.Length -ne $b.Length -or [string]$a.SHA256 -cne [string]$b.SHA256){return $false}
  }
  return $true
}
function Test-CodexComFreshBaseline($baseline,[guid]$id,[string]$name) {
  if(-not [OpenRsatLabGpoComProbe]::ValidTarget($id.ToString(),$name) -or
     -not (Test-CodexComSameBaseline $baseline $baseline)){return $false}
  $canonical='{'+$id.ToString().ToUpperInvariant()+'}'
  $objectId=[guid]::Empty
  if(-not [guid]::TryParse([string]$baseline.ObjectGuid,[ref]$objectId) -or $objectId -eq [guid]::Empty){return $false}
  $dn='CN='+$canonical+',CN=Policies,CN=System,DC=openrsat,DC=test'
  if($baseline.Guid -ine $canonical -or $baseline.DN -ine $dn -or $baseline.Name -cne $name){return $false}
  if([string]$baseline.MachineExtension -ne '' -or [string]$baseline.UserExtension -ne ''){return $false}
  $emptyPol=[Convert]::ToBase64String([byte[]](80,82,101,103,1,0,0,0))
  foreach($side in @('Machine','User')) {
    $file=$baseline.Files.$side; if($file.Exists -and $file.Bytes -ne $emptyPol){return $false}
  }
  if(-not $baseline.Files.GPT.Exists){return $false}
  $version=Get-CodexGptVersion ([Convert]::FromBase64String($baseline.Files.GPT.Bytes))
  if($null -eq $version){return $false}
  return $version -eq [uint32]([int64]$baseline.Version -band 0xffffffffL)
}
function Get-CodexComChecks($baseline,$after,[bool]$saveReturned) {
  $checks=[ordered]@{SaveReturned=$saveReturned; TargetIdentity=$false; MachinePolicyPresent=$false;
    ExactSyntheticPolicy=$false; GpcGptAgree=$false; MachineVersionIncrement=$false;
    UserVersionUnchanged=$false; ExtensionRegistered=$false; UserPolicyUnchanged=$false;
    UserExtensionUnchanged=$false; GpcMetadataUnchanged=$false}
  try {
    if($null -eq $baseline -or $null -eq $after){return $checks}
    $checks.TargetIdentity=($baseline.Guid -and $baseline.ObjectGuid -and $baseline.DN -and $baseline.Name -and
      $baseline.Guid -ceq $after.Guid -and $baseline.ObjectGuid -ceq $after.ObjectGuid -and
      $baseline.DN -ceq $after.DN -and $baseline.Name -ceq $after.Name)
    $checks.MachinePolicyPresent=[bool]$after.Files.Machine.Exists
    if($checks.MachinePolicyPresent -and (Test-CodexFileSnapshot $after.Files.Machine)) {
      $pol=[Convert]::FromBase64String($after.Files.Machine.Bytes)
      $checks.ExactSyntheticPolicy=[OpenRsatLabGpoComProbe]::ValidSyntheticPolicy($pol)
    }
    if(-not (Test-CodexFileSnapshot $after.Files.GPT)){return $checks}
    $gptVersion=Get-CodexGptVersion ([Convert]::FromBase64String($after.Files.GPT.Bytes))
    if($null -ne $gptVersion) {
      $baseBits=[uint32]([int64]$baseline.Version -band 0xffffffffL)
      $afterBits=[uint32]([int64]$after.Version -band 0xffffffffL)
      $lowBefore=$baseBits -band 0xffff; $lowAfter=$afterBits -band 0xffff
      $nextLow=($lowBefore+1) -band 0xffff; if($nextLow -eq 0){$nextLow=1}
      $checks.GpcGptAgree=($afterBits -eq $gptVersion)
      $checks.MachineVersionIncrement=($lowAfter -eq $nextLow)
      $checks.UserVersionUnchanged=(($afterBits -shr 16) -eq ($baseBits -shr 16))
    }
    $pair='[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
    $checks.ExtensionRegistered=([string]$after.MachineExtension -ieq $pair)
    $checks.UserPolicyUnchanged=((Test-CodexFileSnapshot $after.Files.User) -and (Test-CodexFileSnapshot $baseline.Files.User) -and
      $after.Files.User.SHA256 -eq $baseline.Files.User.SHA256 -and
      $after.Files.User.Exists -eq $baseline.Files.User.Exists)
    $checks.UserExtensionUnchanged=([string]$after.UserExtension -ceq [string]$baseline.UserExtension)
    $checks.GpcMetadataUnchanged=($after.Flags -eq $baseline.Flags -and $after.FilePath -ceq $baseline.FilePath -and
      $after.OwnerGroupDacl -ceq $baseline.OwnerGroupDacl)
  } catch { return $checks }
  return $checks
}
