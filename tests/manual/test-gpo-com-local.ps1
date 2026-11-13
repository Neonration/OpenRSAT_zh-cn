$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'gpo-com-probe.cs'
Add-Type -Path $path
. (Join-Path $PSScriptRoot 'gpo-com-local-functions.ps1')
$count=0
function Assert([bool]$condition,[string]$message) {
  $script:count++
  if(-not $condition){throw "Assertion failed: $message"}
}
$id='8b5b4b93-9a12-4f76-a8b9-f2de40a67de8'
$canon='{'+$id.ToUpperInvariant()+'}'
$name='Codex-COMSave-0123456789ab'
$ad='LDAP://orsat-dc01.openrsat.test/CN='+$canon+',CN=Policies,CN=System,DC=openrsat,DC=test'
$files='\\orsat-dc01.openrsat.test\SYSVOL\openrsat.test\Policies\'+$canon
Assert ([OpenRsatLabGpoComProbe]::ValidTarget($id,$name)) 'fresh test target'
Assert ([OpenRsatLabGpoComProbe]::CheckApartmentDispatch() -eq 'STA') 'COM operations dispatch to an STA thread'
Assert (-not [OpenRsatLabGpoComProbe]::ValidTarget('00000000-0000-0000-0000-000000000000',$name)) 'empty GUID'
Assert (-not [OpenRsatLabGpoComProbe]::ValidTarget('31B2F340-016D-11D2-945F-00C04FB984F9',$name)) 'default domain policy'
Assert (-not [OpenRsatLabGpoComProbe]::ValidTarget('6AC1786C-016F-11D2-945F-00C04FB984F9',$name)) 'default DC policy'
Assert (-not [OpenRsatLabGpoComProbe]::ValidTarget($id,$null)) 'missing name'
Assert (-not [OpenRsatLabGpoComProbe]::ValidTarget($id,'Codex-COMSave-abcdefghijkl')) 'invalid suffix'
Assert ((Get-CodexComCleanupDisposition $true $id 'save-outcome-unknown') -eq 'deferred') 'unknown save blocks cleanup'
Assert ((Get-CodexComCleanupDisposition $true $id 'create-outcome-unknown') -eq 'deferred') 'unknown creation blocks cleanup'
Assert ((Get-CodexComCleanupDisposition $true $id 'post-save-unverified') -eq 'deferred') 'unverified save blocks cleanup'
Assert ((Get-CodexComCleanupDisposition $true '31B2F340-016D-11D2-945F-00C04FB984F9' 'stopped') -eq 'protected-target') 'default domain cannot be deleted'
Assert ((Get-CodexComCleanupDisposition $true '6AC1786C-016F-11D2-945F-00C04FB984F9' 'stopped') -eq 'protected-target') 'default DC cannot be deleted'
Assert ((Get-CodexComCleanupDisposition $false $id 'stopped') -eq 'unavailable') 'lost session blocks cleanup'
Assert ((Get-CodexComCleanupDisposition $true $id 'stopped') -eq 'deferred') 'unverified errors block cleanup'
Assert ((Get-CodexComCleanupDisposition $true $id 'readback-verified') -eq 'identity-and-link-check-required') 'verified cleanup still requires fresh snapshot, identity and link checks'
Assert ((Get-CodexComFailurePhase 'baseline-conflict' $false $false $false) -eq 'baseline-conflict') 'baseline conflict is not rewritten as stopped'
Assert ((Get-CodexComCleanupDisposition $true $id (Get-CodexComFailurePhase 'baseline-conflict' $false $false $false)) -eq 'deferred') 'baseline conflict preserves object'
Assert ((Get-CodexComFailurePhase 'read-only-open-confirmed' $false $false $false) -eq 'stopped') 'pre-save read error classified'
Assert ((Get-CodexComFailurePhase 'save-requested' $true $false $false) -eq 'save-outcome-unknown') 'lost save response classified'
Assert ((Get-CodexComFailurePhase 'save-returned' $true $true $false) -eq 'post-save-unverified') 'failed readback classified'
Assert ([OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,$name,$ad,$files)) 'exact DC and target'
Assert (-not [OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,$name,$ad,($files+'\other'))) 'path extension'
Assert (-not [OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,$name,$ad,$files.Replace('SYSVOL','other'))) 'different share'
Assert (-not [OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,$name,$ad,$files.Replace('orsat-dc01','other'))) 'different DC'
Assert (-not [OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,$name,($ad+'-other'),$files)) 'different DN'
Assert (-not [OpenRsatLabGpoComProbe]::ValidObservedTarget($id,$name,$canon,'Codex-COMSave-ffffffffffff',$ad,$files)) 'different display name'
$m=[IO.MemoryStream]::new(); $w=[IO.BinaryWriter]::new($m,[Text.Encoding]::Unicode)
try {
  $w.Write([uint32]0x67655250); $w.Write([uint32]1); $w.Write([uint16][char]'[')
  $w.Write([Text.Encoding]::Unicode.GetBytes('Software\Policies\OpenRSAT-Isolated-Probe')); $w.Write([uint16]0)
  $w.Write([uint16][char]';'); $w.Write([Text.Encoding]::Unicode.GetBytes('SyntheticValue')); $w.Write([uint16]0)
  $w.Write([uint16][char]';'); $w.Write([uint32]4); $w.Write([uint16][char]';'); $w.Write([uint32]4)
  $w.Write([uint16][char]';'); $w.Write([uint32]0x01020304); $w.Write([uint16][char]']'); $w.Flush(); $bytes=$m.ToArray()
} finally { $w.Dispose(); $m.Dispose() }
Assert ([OpenRsatLabGpoComProbe]::ValidSyntheticPolicy($bytes)) 'exact synthetic record'
$bad=[byte[]]$bytes.Clone(); $bad[$bad.Length-4]=99
Assert (-not [OpenRsatLabGpoComProbe]::ValidSyntheticPolicy($bad)) 'corrupt value'
Assert (-not [OpenRsatLabGpoComProbe]::ValidSyntheticPolicy([byte[]]($bytes[0..($bytes.Length-2)]))) 'truncated record'
Assert (-not [OpenRsatLabGpoComProbe]::ValidSyntheticPolicy([byte[]]($bytes+[byte]0))) 'trailing data'
Assert (-not [OpenRsatLabGpoComProbe]::ValidSyntheticPolicy($null)) 'missing policy'
function Gpt([string]$text) { return [Text.Encoding]::ASCII.GetBytes($text) }
Assert ((Get-CodexGptVersion (Gpt "[General]`r`nVersion=1`r`n")) -eq 1) 'GPT version'
Assert ((Get-CodexGptVersion (Gpt "[General]`nVersion=0")) -eq 0) 'zero version'
$unicodeText="[General]`r`nVersion=0`r`ndisplayName=$([char]0x6d4b)$([char]0x8bd5)`r`n"
$cp936=[Text.Encoding]::GetEncoding(936,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
Assert ((Get-CodexGptVersion ($cp936.GetBytes($unicodeText))) -eq 0) 'CP936 display name preserves version'
Assert ((Get-CodexGptVersion ([Text.Encoding]::UTF8.GetBytes($unicodeText))) -eq 0) 'UTF-8 display name preserves version'
Assert ($null -eq (Get-CodexGptVersion ([byte[]](91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,48,10,129)))) 'incomplete codepage sequence rejected'
Assert ($null -eq (Get-CodexGptVersion ([byte[]](239,187,191,91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,48,10,129)))) 'invalid BOM UTF-8 cannot fall back'
Assert ($null -eq (Get-CodexGptVersion ($cp936.GetBytes($unicodeText+"Version=1`r`n")))) 'localized duplicate version rejected'
Assert ($null -eq (Get-CodexGptVersion ($cp936.GetBytes($unicodeText+[char]0)))) 'embedded NUL rejected'
Assert ($null -eq (Get-CodexGptVersion (Gpt "[Other]`nVersion=1"))) 'version outside General'
Assert ($null -eq (Get-CodexGptVersion (Gpt "[General]`nVersion=1`nVersion=1"))) 'duplicate version'
Assert ($null -eq (Get-CodexGptVersion (Gpt "[General]`nVersion=1`n[General]`nX=2"))) 'duplicate General'
Assert ($null -eq (Get-CodexGptVersion ([byte[]](255,254,91,0)))) 'unsupported encoding'
Assert ($null -eq (Get-CodexGptVersion (Gpt "[General]`nVersion=4294967296"))) 'version overflow'
$empty=[pscustomobject]@{Exists=$false;Length=0;SHA256=$null;Bytes=$null}
function SampleFile([byte[]]$data) {
  $sha=[Security.Cryptography.SHA256]::Create()
  try {$hash=([BitConverter]::ToString($sha.ComputeHash($data))).Replace('-','')} finally {$sha.Dispose()}
  return [pscustomobject]@{Exists=$true;Length=$data.Length;SHA256=$hash;Bytes=[Convert]::ToBase64String($data)}
}
$base=[pscustomobject]@{Guid=$canon;ObjectGuid='ecf0cbe4-3448-4a1d-baa5-8f0b40972fa2';DN=('CN='+$canon+',CN=Policies,CN=System,DC=openrsat,DC=test');Name=$name;Version=0;Flags=0;
  FilePath='sysvol';MachineExtension='';UserExtension='';OwnerGroupDacl='test-sddl';USN=10;Description='';
  Files=[pscustomobject]@{GPT=(SampleFile (Gpt "[General]`nVersion=0"));Machine=$empty;User=$empty}}
function Clone($value) { return $value | ConvertTo-Json -Depth 12 | ConvertFrom-Json }
$after=Clone $base; $after.Version=1
$after.Files.GPT=SampleFile (Gpt "[General]`nVersion=1")
$after.Files.Machine=SampleFile $bytes
$after.MachineExtension='[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
Assert (Test-CodexComSameBaseline $base (Clone $base)) 'baseline comparison'
Assert (Test-CodexComFreshBaseline $base ([guid]$id) $name) 'fresh baseline'
$changed=Clone $base; $changed.Version=2
Assert (-not (Test-CodexComFreshBaseline $changed ([guid]$id) $name)) 'mismatched baseline versions'
$changed=Clone $base; $changed.UserExtension='unexpected'
Assert (-not (Test-CodexComFreshBaseline $changed ([guid]$id) $name)) 'unexpected extension'
$changed=Clone $base; $changed.OwnerGroupDacl='different'
Assert (-not (Test-CodexComSameBaseline $base $changed)) 'changed descriptor'
$changed=Clone $base; $changed.USN=11
Assert (-not (Test-CodexComSameBaseline $base $changed)) 'changed USN'
$changed=Clone $base; $changed.Description='other writer'
Assert (-not (Test-CodexComSameBaseline $base $changed)) 'changed description'
$baselinePhase=if(Test-CodexComSameBaseline $base $changed){'readback-verified'}else{'baseline-conflict'}
Assert ((Get-CodexComCleanupDisposition $true $id (Get-CodexComFailurePhase $baselinePhase $false $false $false)) -eq 'deferred') 'changed baseline cannot lead to cleanup'
Assert (Test-CodexComCleanupSnapshot 'readback-verified' $base (Clone $base)) 'matching final snapshot comparison'
Assert (-not (Test-CodexComCleanupSnapshot 'baseline-conflict' $base (Clone $base))) 'conflict cannot pass cleanup comparison'
Assert (-not (Test-CodexComCleanupSnapshot 'readback-verified' $base $changed)) 'changed final snapshot blocks cleanup'
Assert (-not (Test-CodexComCleanupSnapshot 'readback-verified' $base $null)) 'missing final snapshot blocks cleanup'
$changed=Clone $base; $changed.Files.Machine.Exists=$true
Assert (-not (Test-CodexComSameBaseline $base $changed)) 'changed file presence'
$changed=Clone $base; $changed.Files.GPT.Bytes=[Convert]::ToBase64String((Gpt "[General]`nVersion=9"))
Assert (-not (Test-CodexComSameBaseline $base $changed)) 'snapshot bytes do not match hash'
$changed=Clone $base; $changed.ObjectGuid=$null
Assert (-not (Test-CodexComSameBaseline $changed $changed)) 'missing identity fails closed'
$checks=Get-CodexComChecks $base $after $true
Assert (@($checks.Values | Where-Object { -not $_ }).Count -eq 0) 'all simulated verification checks'
$wrapBase=Clone $base; $wrapBase.Version=65535
$wrapChecks=Get-CodexComChecks $wrapBase $after $true
Assert ($wrapChecks.MachineVersionIncrement) 'machine version wrap skips zero'
$changed=Clone $after; $changed.ObjectGuid='different'
Assert (-not (Get-CodexComChecks $base $changed $true).TargetIdentity) 'changed object identity'
$changed=Clone $after; $changed.OwnerGroupDacl='different'
Assert (-not (Get-CodexComChecks $base $changed $true).GpcMetadataUnchanged) 'changed security descriptor'
$changed=Clone $after; $changed.Files.GPT=SampleFile (Gpt "[General]`nVersion=1`nVersion=1")
Assert (-not (Get-CodexComChecks $base $changed $true).GpcGptAgree) 'ambiguous GPT blocked'
$changed=Clone $after; $changed.MachineExtension='{35378EAC-683F-11D2-A89A-00C04FBBCFA2} unrelated {D02B1F72-3407-48AE-BA88-E8213C6761F1}'
Assert (-not (Get-CodexComChecks $base $changed $true).ExtensionRegistered) 'unpaired extension GUIDs'
$changed=Clone $after; $changed.MachineExtension+='[unexpected]'
Assert (-not (Get-CodexComChecks $base $changed $true).ExtensionRegistered) 'unexpected extension changes rejected'
$changed=Clone $after; $changed.Files.Machine=SampleFile $bad
Assert (-not (Get-CodexComChecks $base $changed $true).ExactSyntheticPolicy) 'altered policy not verified'
Assert (-not (Get-CodexComChecks $base $after $false).SaveReturned) 'unknown save cannot pass'
$tokens=$null; $errors=$null
$labAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'gpo-com-lab.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'lab script parses'
$topLevelThrows=@($labAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.ThrowStatementAst]})
$remoteCalls=@($labAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-PSSession'},$true))
Assert ($topLevelThrows.Count -eq 1 -and $remoteCalls.Count -gt 0 -and $topLevelThrows[0].Extent.StartOffset -lt $remoteCalls[0].Extent.StartOffset) 'unverified DC path blocks lab before remote access'
"LOCAL_ONLY_PASS $count assertions; no COM methods or domain operations called"
