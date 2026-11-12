param([Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
  [switch]$ExecuteIsolatedDomainWrite)
$ErrorActionPreference='Stop'
if(-not $ExecuteIsolatedDomainWrite){throw 'This is a domain-writing lab prototype; explicit execution switch and required platform approvals are necessary.'}
. (Join-Path $PSScriptRoot 'gpo-com-local-functions.ps1')
$dc='ORSAT-DC01.openrsat.test'
$domain='openrsat.test'
$run=[guid]::NewGuid().ToString('N')
$name='Codex-COMSave-'+$run.Substring(0,12)
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$evidence=Join-Path $root ('.tools\gpo-com-lab-'+$run)
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$state=[ordered]@{ Name=$name; DC=$dc; Domain=$domain; Id=$null; Phase='initial'; Cleanup='not-started'; Error=$null }
function Save-State { $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evidence 'state.json') -Encoding UTF8 }
function Save-Json($value,$file) { $value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $evidence $file) -Encoding UTF8 }
Save-State
$session=$null; $targetId=$null; $baselineObjectGuid=$null; $beforeDefaults=$null; $enteredWrite=$false; $writeReturned=$false; $verified=$false; $createRequested=$false
try {
  $session=New-PSSession -VMName 'ORSAT-DC01' -Credential $Credential
  Invoke-Command -Session $session -ScriptBlock {
    $ErrorActionPreference='Stop'; Import-Module ActiveDirectory; Import-Module GroupPolicy
    if ((Get-ADDomain).DNSRoot -ne 'openrsat.test' -or (Get-ADDomainController -Identity $env:COMPUTERNAME).HostName -ne 'ORSAT-DC01.openrsat.test') { throw 'Unexpected lab domain or DC' }
    function global:Get-CodexComSnapshot([guid]$Id,[bool]$IncludeBytes) {
      $server='ORSAT-DC01.openrsat.test'; $guid='{'+$Id.ToString().ToUpperInvariant()+'}'
      $dn='CN='+$guid+',CN=Policies,CN=System,DC=openrsat,DC=test'
      $a=Get-ADObject -Server $server -Identity $dn -Properties displayName,versionNumber,flags,gPCFileSysPath,gPCMachineExtensionNames,gPCUserExtensionNames,nTSecurityDescriptor,objectGUID
      $p=Join-Path $env:SystemRoot ('SYSVOL\sysvol\openrsat.test\Policies\'+$guid)
      $files=[ordered]@{}
      foreach($entry in @(@('GPT','GPT.INI'),@('Machine','Machine\Registry.pol'),@('User','User\Registry.pol'))) {
        $path=Join-Path $p $entry[1]
        $item=$null
        try { $item=Get-Item -LiteralPath $path -ErrorAction Stop }
        catch { if($_.Exception -isnot [System.Management.Automation.ItemNotFoundException]){throw} }
        if($null -ne $item) {
          if($item.PSIsContainer -or $item.Length -gt 16777216){throw 'Unexpected file type or size'}
          $bytes=[IO.File]::ReadAllBytes($path); if($bytes.Length -ne $item.Length){throw 'File length changed during read'}
          $hash=[Security.Cryptography.SHA256]::Create()
          try { $hex=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','') } finally { $hash.Dispose() }
          $files[$entry[0]]=[ordered]@{Exists=$true; Length=$bytes.Length; SHA256=$hex; Bytes=if($IncludeBytes){[Convert]::ToBase64String($bytes)}else{$null}}
        } else { $files[$entry[0]]=[ordered]@{Exists=$false; Length=0; SHA256=$null; Bytes=$null} }
      }
      $sddl=$a.nTSecurityDescriptor.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Owner -bor [System.Security.AccessControl.AccessControlSections]::Group -bor [System.Security.AccessControl.AccessControlSections]::Access)
      [pscustomobject][ordered]@{Guid=$guid; ObjectGuid=$a.ObjectGUID.ToString(); DN=$a.DistinguishedName; Name=$a.DisplayName; Version=[int64]$a.versionNumber; Flags=$a.flags; FilePath=$a.gPCFileSysPath; MachineExtension=$a.gPCMachineExtensionNames; UserExtension=$a.gPCUserExtensionNames; OwnerGroupDacl=$sddl; Files=$files}
    }
    function global:Get-CodexComLinks([guid]$Id) {
      $needle='{'+$Id.ToString().ToUpperInvariant()+'}'; $server='ORSAT-DC01.openrsat.test'
      $bases=@('DC=openrsat,DC=test','CN=Configuration,DC=openrsat,DC=test')
      @($bases | ForEach-Object { Get-ADObject -Server $server -SearchBase $_ -LDAPFilter '(gPLink=*)' -Properties gPLink } | Where-Object { $_.gPLink -like ('*'+$needle+'*') } | Select-Object -ExpandProperty DistinguishedName)
    }
  }
  $beforeDefaults=Invoke-Command -Session $session -ScriptBlock {
    @(Get-CodexComSnapshot ([guid]'31B2F340-016D-11D2-945F-00C04FB984F9') $false; Get-CodexComSnapshot ([guid]'6AC1786C-016F-11D2-945F-00C04FB984F9') $false)
  }
  Save-Json $beforeDefaults 'defaults-before.json'; $state.Phase='defaults-recorded'; Save-State
  $prior=Invoke-Command -Session $session -ArgumentList $name -ScriptBlock {param($n) @(Get-GPO -All -Server 'ORSAT-DC01.openrsat.test' | Where-Object DisplayName -eq $n).Count}
  if($prior -ne 0) { throw 'Unique test name already exists' }
  $state.Phase='create-requested'; Save-State; $createRequested=$true
  $created=Invoke-Command -Session $session -ArgumentList $name -ScriptBlock {param($n) New-GPO -Name $n -Server 'ORSAT-DC01.openrsat.test' | Select-Object Id,DisplayName}
  $parsedId=[guid]::Empty
  if($null -eq $created -or $created.DisplayName -cne $name -or
    -not [guid]::TryParse([string]$created.Id,[ref]$parsedId) -or $parsedId -eq [guid]::Empty -or
    $parsedId -eq [guid]'31B2F340-016D-11D2-945F-00C04FB984F9' -or
    $parsedId -eq [guid]'6AC1786C-016F-11D2-945F-00C04FB984F9'){throw 'Creation response identity invalid'}
  $targetId=$parsedId; $state.Id=$targetId.ToString(); $state.Phase='created'; Save-State
  $baseline=Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComSnapshot $id $true}
  Save-Json $baseline 'test-before.json'
  if($baseline.Name -ne $name -or @(Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComLinks $id}).Count -ne 0) { throw 'Test object identity or unlinked check failed' }
  $objectGuid=[guid]::Empty
  if(-not [guid]::TryParse([string]$baseline.ObjectGuid,[ref]$objectGuid) -or $objectGuid -eq [guid]::Empty -or
    $baseline.Guid -ine ('{'+$targetId.ToString().ToUpperInvariant()+'}')){throw 'Test object GUID could not be established'}
  $baselineObjectGuid=$objectGuid.ToString()
  $src=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gpo-com-probe.cs') -Raw
  Invoke-Command -Session $session -ArgumentList $src -ScriptBlock {param($s) Add-Type -TypeDefinition $s -Language CSharp}
  Add-Type -TypeDefinition $src -Language CSharp
  if(-not (Test-CodexComFreshBaseline $baseline $targetId $name)){throw 'Fresh test GPO baseline is invalid or not empty'}
  $inspect=Invoke-Command -Session $session -ArgumentList $targetId.ToString(),$name -ScriptBlock {param($id,$n) [OpenRsatLabGpoComProbe]::Run($id,$n,$false)}
  $state.Inspect=$inspect; $state.Phase='read-only-open-confirmed'; Save-State
  if(@(Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComLinks $id}).Count -ne 0) { throw 'Test object became linked' }
  $rechecked=Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComSnapshot $id $true}
  if(-not (Test-CodexComSameBaseline $baseline $rechecked)){throw 'Test baseline changed before save'}
  $state.Phase='save-requested'; Save-State; $enteredWrite=$true
  $save=Invoke-Command -Session $session -ArgumentList $targetId.ToString(),$name -ScriptBlock {param($id,$n) [OpenRsatLabGpoComProbe]::Run($id,$n,$true)}
  $writeReturned=$true; $state.Save=$save; $state.Phase='save-returned'; Save-State
  $after=Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComSnapshot $id $true}
  Save-Json $after 'test-after.json'
  $checks=Get-CodexComChecks $baseline $after $writeReturned
  $state.Checks=$checks; Save-State
  if(@($checks.Values | Where-Object { -not $_ }).Count -ne 0){ throw 'One or more verification checks failed' }
  $state.Phase='readback-verified'; Save-State; $verified=$true
} catch {
  $state.FailedAt=$state.Phase; $state.Error=$_.Exception.GetType().FullName
  $state.Phase=if($enteredWrite -and -not $writeReturned){'save-outcome-unknown'}
    elseif($enteredWrite -and -not $verified){'post-save-unverified'}else{'stopped'}; Save-State
  if($session -and $targetId) { try { Save-Json (Invoke-Command -Session $session -ArgumentList $targetId -ScriptBlock {param($id) Get-CodexComSnapshot $id $true}) 'test-after-error.json' } catch {} }
} finally {
  if($session -and -not $targetId -and $createRequested) {
    try {
      $found=@(Invoke-Command -Session $session -ArgumentList $name -ScriptBlock {param($n) Get-GPO -All -Server 'ORSAT-DC01.openrsat.test' | Where-Object DisplayName -eq $n | Select-Object Id,DisplayName})
      if($found.Count -eq 1){$targetId=[guid]$found[0].Id;$state.Id=$targetId.ToString();$state.Phase='create-outcome-unknown';$state.Cleanup='deferred: creation response unknown'}
      elseif($found.Count -gt 1){$state.Cleanup='deferred: ambiguous test identity'}
    } catch { $state.Cleanup='deferred: cannot query uncertain creation' }
  }
  $cleanupDisposition=Get-CodexComCleanupDisposition ([bool]$session) $targetId $state.Phase
  if($cleanupDisposition -eq 'identity-and-link-check-required' -and -not $baselineObjectGuid){$cleanupDisposition='identity-unavailable'}
  if($cleanupDisposition -eq 'identity-and-link-check-required') {
    try {
      $result=Invoke-Command -Session $session -ArgumentList $targetId,$name,$baselineObjectGuid -ScriptBlock {
        param($id,$expected,$expectedObjectGuid)
        if($id -eq [guid]::Empty -or $id -eq [guid]'31B2F340-016D-11D2-945F-00C04FB984F9' -or
          $id -eq [guid]'6AC1786C-016F-11D2-945F-00C04FB984F9'){throw 'Protected GPO cannot be cleaned'}
        $g=Get-GPO -Guid $id -Server 'ORSAT-DC01.openrsat.test'
        $dn='CN={'+$id.ToString().ToUpperInvariant()+'},CN=Policies,CN=System,DC=openrsat,DC=test'
        $object=Get-ADObject -Server 'ORSAT-DC01.openrsat.test' -Identity $dn -Properties objectGUID
        if($g.DisplayName -cne $expected -or $object.ObjectGUID.ToString() -ine $expectedObjectGuid -or
          @(Get-CodexComLinks $id).Count -ne 0){throw 'Cleanup identity or link check failed'}
        Remove-GPO -Guid $id -Server 'ORSAT-DC01.openrsat.test' -Confirm:$false
        $remaining=Get-ADObject -Server 'ORSAT-DC01.openrsat.test' -LDAPFilter ('(distinguishedName='+$dn+')') -ErrorAction Stop
        $p=Join-Path $env:SystemRoot ('SYSVOL\sysvol\openrsat.test\Policies\{'+$id.ToString().ToUpperInvariant()+'}')
        [pscustomobject]@{GpcAbsent=($null -eq $remaining); SysvolAbsent=(-not (Test-Path -LiteralPath $p)); LinksAbsent=(@(Get-CodexComLinks $id).Count -eq 0)}
      }
      $state.Cleanup=$result; if(-not $result.GpcAbsent -or -not $result.SysvolAbsent -or -not $result.LinksAbsent){throw 'Cleanup verification failed'}
    } catch { $state.Cleanup='failed: '+$_.Exception.GetType().FullName }
  } elseif($targetId -and $state.Phase -in @('save-outcome-unknown','post-save-unverified')) { $state.Cleanup='deferred: write outcome or verification uncertain' }
  elseif($cleanupDisposition -eq 'protected-target') { $state.Cleanup='deferred: protected target' }
  elseif($cleanupDisposition -eq 'identity-unavailable') { $state.Cleanup='deferred: original object identity unavailable' }
  elseif($createRequested -and -not $targetId) { $state.Cleanup='deferred: creation state or identity unavailable' }
  elseif($targetId -and -not $session) { $state.Cleanup='deferred: session unavailable' }
  if($session -and $beforeDefaults) {
    try {
      $afterDefaults=Invoke-Command -Session $session -ScriptBlock {@(Get-CodexComSnapshot ([guid]'31B2F340-016D-11D2-945F-00C04FB984F9') $false; Get-CodexComSnapshot ([guid]'6AC1786C-016F-11D2-945F-00C04FB984F9') $false)}
      Save-Json $afterDefaults 'defaults-after.json'
      $state.DefaultsUnchanged=((ConvertTo-Json -InputObject $beforeDefaults -Depth 16 -Compress) -eq (ConvertTo-Json -InputObject $afterDefaults -Depth 16 -Compress))
    } catch { $state.DefaultsUnchanged='verification-failed: '+$_.Exception.GetType().FullName }
  }
  if($session){Remove-PSSession $session}; Save-State
  [pscustomobject]@{Evidence=$evidence; State=$state} | ConvertTo-Json -Depth 12
}
if($state.Error -or ($state.Cleanup -is [string]) -or $state.DefaultsUnchanged -ne $true){exit 1}
