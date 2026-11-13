unit ugpodiagnostic;

{$mode ObjFPC}{$H+}

interface

uses SysUtils, mormot.net.ldap, ugpoformats, ugposysvol;

const
  GpoDiagnosticMaxBytes = 128 * 1024 * 1024;

type
  TGpoDiagnosticResource = (gdrMachinePolicy, gdrUserPolicy, gdrGptIni,
    gdrGpcVersion, gdrFlags, gdrMachineExtensions, gdrUserExtensions,
    gdrLdapSecurity, gdrUsn, gdrMachineMetadata, gdrUserMetadata, gdrGptMetadata);
  TGpoDiagnosticState = (gdsNotCollected, gdsUnreadable, gdsMissing, gdsPresent);
  TGpoDiagnosticValue = record
    State: TGpoDiagnosticState;
    Data: TBytes;
    ReadStatus: TGpoReadStatus;
    FileObservation: TGpoFileObservation;
    ExtensionStatus: TGpoExtensionStatus;
  end;
  TGpoDiagnosticValues = array[TGpoDiagnosticResource] of TGpoDiagnosticValue;
  TGpoDiagnosticMatch = (gdmIncomplete, gdmBaseline, gdmCandidate, gdmBoth, gdmOther);
  TGpoDiagnosticItem = record
    Baseline, Candidate, Observed: TGpoDiagnosticValue;
    Match: TGpoDiagnosticMatch;
    ObservedDiffersFromBaseline: Boolean;
  end;
  TGpoDiagnosticSummary = (gduIncomplete, gduComparable);
  TGpoDiagnosticReport = record
    Items: array[TGpoDiagnosticResource] of TGpoDiagnosticItem;
    Summary: TGpoDiagnosticSummary;
    HasOther: Boolean;
  end;
  TGpoDiagnosticStatus = (gdtOk, gdtInvalid, gdtTooLarge, gdtSessionInvalid, gdtTargetMismatch,
    gdtReadUnavailable, gdtChangedDuringCapture);
  TGpoLdapCaptureState = (glcNotAttempted, glcUnreadable, glcCaptured);

// Inputs and outputs must be distinct. A result never authorizes retry, rollback or writing.
function GpoDiagnoseObservations(const Expected, ObservedTarget: TGpoPreflightTarget;
  const Baseline, Candidate, Observed: TGpoDiagnosticValues; out Report: TGpoDiagnosticReport): TGpoDiagnosticStatus;
function GpoDiagnosticPlanValues(const Plan: TGpoOfflinePlan;
  out Baseline, Candidate: TGpoDiagnosticValues): TGpoDiagnosticStatus;
function GpoDiagnosticEvidenceValues(const Expected: TGpoPreflightTarget;
  LdapState: TGpoLdapCaptureState; const Ldap: TGpoLdapEvidence;
  const Files: TGpoObservedFiles; out Values: TGpoDiagnosticValues): TGpoDiagnosticStatus;
function GpoDiagnoseObservedDraft(Client: TLdapClient; const DN,Guid:string; Draft:TGpoObservedDraft;
  const User,Machine:TGpoPolicyImage; Control:TGpoReadControl; out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
function GpoDiagnoseCapturedDraft(Draft:TGpoObservedDraft; const User,Machine:TGpoPolicyImage;
  const Before,After:TGpoLdapEvidence; const Files:TGpoObservedFiles; Control:TGpoReadControl;
  out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;

implementation

function ValidTarget(const T: TGpoPreflightTarget): Boolean;
var I: Integer; Nonzero: Boolean; Path: string;
begin
  Nonzero:=False;
  for I:=0 to High(T.ObjectGuid) do if T.ObjectGuid[I]<>0 then Nonzero:=True;
  Result:=Nonzero and (Length(T.ObjectGuid)=16) and (T.DN<>'') and
    not SameText(T.Domain,T.DC) and
    (GpoBuildSafePath(T.FileSysPath,T.Domain,T.DC,T.Guid,gfGptIni,Path)=grsOk);
end;

function CheckTarget(const Expected, Actual: TGpoPreflightTarget): TGpoDiagnosticStatus;
var A,B: ILdapSessionToken;
begin
  if not Assigned(Expected.Session) or not Supports(Expected.Session,ILdapSessionToken,A) or
    not Assigned(Actual.Session) or not Supports(Actual.Session,ILdapSessionToken,B) or
    not A.IsValid or not B.IsValid or (Expected.Session<>Actual.Session) then Exit(gdtSessionInvalid);
  if not ValidTarget(Expected) or not ValidTarget(Actual) then Exit(gdtInvalid);
  if not SameText(Expected.Domain,Actual.Domain) or not SameText(Expected.DC,Actual.DC) or
    not SameText(Expected.DN,Actual.DN) or not SameText(Expected.Guid,Actual.Guid) or
    not SameText(Expected.FileSysPath,Actual.FileSysPath) or
    not CompareMem(@Expected.ObjectGuid[0],@Actual.ObjectGuid[0],16) then Exit(gdtTargetMismatch);
  if not A.IsValid or not B.IsValid then Exit(gdtSessionInvalid);
  Result:=gdtOk;
end;

function TargetSupplied(const T:TGpoPreflightTarget):Boolean;
begin
  Result:=Assigned(T.Session) or (T.Domain<>'') or (T.DC<>'') or (T.DN<>'') or
    (T.Guid<>'') or (T.FileSysPath<>'') or (Length(T.ObjectGuid)<>0);
end;

function Read32(const B:TBytes; P:SizeInt):Cardinal;
begin Result:=Cardinal(B[P]) or (Cardinal(B[P+1]) shl 8) or
  (Cardinal(B[P+2]) shl 16) or (Cardinal(B[P+3]) shl 24); end;
procedure Put32(var B:TBytes; var P:SizeInt; V:Cardinal);
var I:Integer;
begin for I:=0 to 3 do begin B[P]:=Byte(V shr (I*8)); Inc(P); end; end;

function ValidValue(Resource:TGpoDiagnosticResource; const V:TGpoDiagnosticValue):Boolean;
var P:SizeInt; N,I,Size:Cardinal;
begin
  Result:=False;
  if Ord(V.State)>Ord(High(TGpoDiagnosticState)) then Exit;
  if V.State<>gdsPresent then begin
    if Length(V.Data)<>0 then Exit;
    Exit((V.State<>gdsMissing) or (Resource in [gdrMachinePolicy,gdrUserPolicy]));
  end;
  if Length(V.Data)>GpoMaxFileBytes then Exit;
  case Resource of
    gdrGpcVersion,gdrFlags: Exit(Length(V.Data)=4);
    gdrUsn: Exit(Length(V.Data)=8);
    gdrMachineMetadata,gdrUserMetadata,gdrGptMetadata:
      begin
        if Length(V.Data)<32 then Exit;
        if (Read32(V.Data,0)=Ord(gekUnavailable)) or
          (Read32(V.Data,0)>Ord(High(TGpoEvidenceKind))) then Exit;
        Exit(Read32(V.Data,28)=Cardinal(Length(V.Data)-32));
      end;
    gdrMachineExtensions,gdrUserExtensions:
      begin
        if Length(V.Data)<4 then Exit;
        N:=Read32(V.Data,0); if N>256 then Exit; P:=4;
        if N>0 then for I:=1 to N do begin
          if P>Length(V.Data)-4 then Exit;
          Size:=Read32(V.Data,P); Inc(P,4);
          if Size>Cardinal(Length(V.Data)-P) then Exit;
          Inc(P,Size);
        end;
        Exit(P=Length(V.Data));
      end;
  end;
  Result:=True;
end;

function SameValue(const A,B:TGpoDiagnosticValue):Boolean;
begin
  Result:=(A.State=B.State) and (Length(A.Data)=Length(B.Data));
  if Result and (Length(A.Data)>0) then Result:=CompareMem(@A.Data[0],@B.Data[0],Length(A.Data));
end;

function GpoDiagnoseObservations(const Expected, ObservedTarget:TGpoPreflightTarget;
  const Baseline,Candidate,Observed:TGpoDiagnosticValues; out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
var R:TGpoDiagnosticResource; Total:QWord; SameBase,SameCandidate:Boolean; Temp:TGpoDiagnosticReport;
begin
  Report:=Default(TGpoDiagnosticReport); Temp:=Default(TGpoDiagnosticReport);
  Result:=CheckTarget(Expected,ObservedTarget); if Result<>gdtOk then Exit;
  Total:=0;
  for R:=Low(R) to High(R) do begin
    if (Length(Baseline[R].Data)>GpoMaxFileBytes) or (Length(Candidate[R].Data)>GpoMaxFileBytes) or
      (Length(Observed[R].Data)>GpoMaxFileBytes) then Exit(gdtTooLarge);
    Inc(Total,QWord(Length(Baseline[R].Data))+QWord(Length(Candidate[R].Data))+QWord(Length(Observed[R].Data)));
    if Total>GpoDiagnosticMaxBytes then Exit(gdtTooLarge);
    if not ValidValue(R,Baseline[R]) or not ValidValue(R,Candidate[R]) or
      not ValidValue(R,Observed[R]) then Exit(gdtInvalid);
  end;
  Temp.Summary:=gduComparable;
  for R:=Low(R) to High(R) do begin
    Result:=CheckTarget(Expected,ObservedTarget); if Result<>gdtOk then Exit;
    Temp.Items[R].Baseline:=Baseline[R]; Temp.Items[R].Baseline.Data:=Copy(Baseline[R].Data);
    Temp.Items[R].Candidate:=Candidate[R]; Temp.Items[R].Candidate.Data:=Copy(Candidate[R].Data);
    Temp.Items[R].Observed:=Observed[R]; Temp.Items[R].Observed.Data:=Copy(Observed[R].Data);
    Temp.Items[R].ObservedDiffersFromBaseline:=
      (Baseline[R].State in [gdsMissing,gdsPresent]) and
      (Observed[R].State in [gdsMissing,gdsPresent]) and not SameValue(Baseline[R],Observed[R]);
    if (Baseline[R].State in [gdsNotCollected,gdsUnreadable]) or
       (Candidate[R].State in [gdsNotCollected,gdsUnreadable]) or
       (Observed[R].State in [gdsNotCollected,gdsUnreadable]) then begin
      Temp.Items[R].Match:=gdmIncomplete; Temp.Summary:=gduIncomplete; Continue;
    end;
    SameBase:=SameValue(Baseline[R],Observed[R]); SameCandidate:=SameValue(Candidate[R],Observed[R]);
    if SameBase and SameCandidate then Temp.Items[R].Match:=gdmBoth
    else if SameBase then Temp.Items[R].Match:=gdmBaseline
    else if SameCandidate then Temp.Items[R].Match:=gdmCandidate
    else begin Temp.Items[R].Match:=gdmOther; Temp.HasOther:=True; end;
  end;
  Result:=CheckTarget(Expected,ObservedTarget); if Result<>gdtOk then Exit;
  Report:=Temp; Result:=gdtOk;
end;

function NumberValue(V:QWord; Count:Integer):TGpoDiagnosticValue;
var I:Integer;
begin
  Result:=Default(TGpoDiagnosticValue); Result.State:=gdsPresent; SetLength(Result.Data,Count);
  for I:=0 to Count-1 do Result.Data[I]:=Byte(V shr (I*8));
end;

function GpoDiagnosticPlanValues(const Plan:TGpoOfflinePlan;
  out Baseline,Candidate:TGpoDiagnosticValues):TGpoDiagnosticStatus;
  procedure Policy(R:TGpoDiagnosticResource; const Old:TGpoPolicyImage; NewExists:Boolean; const NewData:TBytes);
  begin
    if Old.Exists then begin Baseline[R].State:=gdsPresent; Baseline[R].Data:=Copy(Old.Data); end
    else Baseline[R].State:=gdsMissing;
    if NewExists then begin Candidate[R].State:=gdsPresent; Candidate[R].Data:=Copy(NewData); end
    else Candidate[R].State:=gdsMissing;
  end;
begin
  Baseline:=Default(TGpoDiagnosticValues); Candidate:=Default(TGpoDiagnosticValues);
  if GpoCheckOfflinePlan(Plan,Plan.Baseline.GpcVersion,Plan.Baseline.GptIni,
    Plan.Baseline.UserPolicy,Plan.Baseline.MachinePolicy)<>gbcMatch then Exit(gdtInvalid);
  Policy(gdrMachinePolicy,Plan.Baseline.MachinePolicy,Plan.MachineExists,Plan.MachinePolicy);
  Policy(gdrUserPolicy,Plan.Baseline.UserPolicy,Plan.UserExists,Plan.UserPolicy);
  Baseline[gdrGptIni].State:=gdsPresent; Baseline[gdrGptIni].Data:=Copy(Plan.Baseline.GptIni);
  Candidate[gdrGptIni].State:=gdsPresent; Candidate[gdrGptIni].Data:=Copy(Plan.GptIni);
  Baseline[gdrGpcVersion]:=NumberValue(Plan.Baseline.GpcVersion,4);
  Candidate[gdrGpcVersion]:=NumberValue(Plan.Version.Version,4);
  Result:=gdtOk;
end;

function ExtensionValue(const E:TGpoExtensionEvidence; out V:TGpoDiagnosticValue):Boolean;
var I:Integer; Size:QWord; P:SizeInt;
begin
  V:=Default(TGpoDiagnosticValue); V.ExtensionStatus:=E.Status; Result:=True;
  if Ord(E.Status)>Ord(High(TGpoExtensionStatus)) then Exit(False);
  if E.Status<>gexReturned then begin V.State:=gdsUnreadable; Exit; end;
  if Length(E.Values)>256 then Exit(False);
  Size:=4;
  for I:=0 to High(E.Values) do Inc(Size,4+QWord(Length(E.Values[I])));
  if Size>GpoMaxFileBytes then Exit(False);
  V.State:=gdsPresent; SetLength(V.Data,Size); P:=0; Put32(V.Data,P,Length(E.Values));
  for I:=0 to High(E.Values) do begin
    Put32(V.Data,P,Length(E.Values[I]));
    if Length(E.Values[I])>0 then begin Move(E.Values[I][1],V.Data[P],Length(E.Values[I])); Inc(P,Length(E.Values[I])); end;
  end;
end;

function MetadataValue(const M:TGpoFileEvidence; out V:TGpoDiagnosticValue):Boolean;
var P:SizeInt;
begin
  V:=Default(TGpoDiagnosticValue); Result:=True;
  if not M.Available then begin V.State:=gdsUnreadable; Exit; end;
  if (M.Kind=gekUnavailable) or (Length(M.SecurityDescriptor)>GpoMaxFileBytes-32) then Exit(False);
  V.State:=gdsPresent; SetLength(V.Data,32+Length(M.SecurityDescriptor)); P:=0;
  Put32(V.Data,P,Ord(M.Kind)); Put32(V.Data,P,M.VolumeSerial); Put32(V.Data,P,M.FileIndexHigh);
  Put32(V.Data,P,M.FileIndexLow); Put32(V.Data,P,M.Attributes); Put32(V.Data,P,M.LastWriteHigh);
  Put32(V.Data,P,M.LastWriteLow); Put32(V.Data,P,Length(M.SecurityDescriptor));
  if Length(M.SecurityDescriptor)>0 then Move(M.SecurityDescriptor[0],V.Data[P],Length(M.SecurityDescriptor));
end;

function GpoDiagnosticEvidenceValues(const Expected:TGpoPreflightTarget;
  LdapState:TGpoLdapCaptureState; const Ldap:TGpoLdapEvidence;
  const Files:TGpoObservedFiles; out Values:TGpoDiagnosticValues):TGpoDiagnosticStatus;
const FileResources:array[TGpoFile] of TGpoDiagnosticResource=(gdrGptIni,gdrMachinePolicy,gdrUserPolicy);
  MetaResources:array[TGpoFile] of TGpoDiagnosticResource=(gdrGptMetadata,gdrMachineMetadata,gdrUserMetadata);
var Temp:TGpoDiagnosticValues; A:TGpoFile; R:TGpoDiagnosticResource; Side:TGpoExtensionSide;
  I:Integer; AnyFile:Boolean; Total,Size:QWord;
begin
  Values:=Default(TGpoDiagnosticValues); Temp:=Default(TGpoDiagnosticValues);
  if Ord(LdapState)>Ord(High(TGpoLdapCaptureState)) then Exit(gdtInvalid);
  Result:=CheckTarget(Expected,Expected); if Result<>gdtOk then Exit;
  if (LdapState=glcCaptured) or TargetSupplied(Ldap.Target) then begin
    Result:=CheckTarget(Expected,Ldap.Target); if Result<>gdtOk then Exit;
  end;
  AnyFile:=Files.Captured or TargetSupplied(Files.Target);
  for A:=Low(A) to High(A) do AnyFile:=AnyFile or Files.Items[A].Attempted;
  if AnyFile then begin Result:=CheckTarget(Expected,Files.Target); if Result<>gdtOk then Exit; end;
  Total:=0;
  if LdapState=glcCaptured then begin
    if Length(Ldap.SecurityDescriptor)>GpoMaxFileBytes then Exit(gdtTooLarge);
    Inc(Total,Length(Ldap.SecurityDescriptor)+16);
    for Side:=Low(Side) to High(Side) do if Ldap.Extensions[Side].Status=gexReturned then begin
      if Length(Ldap.Extensions[Side].Values)>256 then Exit(gdtInvalid);
      Size:=4;
      for I:=0 to High(Ldap.Extensions[Side].Values) do Inc(Size,4+QWord(Length(Ldap.Extensions[Side].Values[I])));
      if Size>GpoMaxFileBytes then Exit(gdtTooLarge);
      Inc(Total,Size);
    end;
  end;
  for A:=Low(A) to High(A) do if Files.Items[A].Attempted then begin
    if (Length(Files.Items[A].Data)>GpoMaxFileBytes) or
       (Length(Files.Items[A].Metadata.SecurityDescriptor)>GpoMaxFileBytes-32) then Exit(gdtTooLarge);
    Inc(Total,QWord(Length(Files.Items[A].Data))+QWord(Length(Files.Items[A].Metadata.SecurityDescriptor))+32);
  end;
  if Total>GpoDiagnosticMaxBytes then Exit(gdtTooLarge);
  if LdapState=glcCaptured then begin
    Temp[gdrGpcVersion]:=NumberValue(Ldap.Version,4); Temp[gdrFlags]:=NumberValue(Ldap.Flags,4);
    Temp[gdrUsn]:=NumberValue(Ldap.USNChanged,8);
    if Ldap.SecurityStatus=gseUnverified then begin Temp[gdrLdapSecurity].State:=gdsPresent;
      Temp[gdrLdapSecurity].Data:=Copy(Ldap.SecurityDescriptor); end
    else Temp[gdrLdapSecurity].State:=gdsUnreadable;
    if not ExtensionValue(Ldap.Extensions[gesMachine],Temp[gdrMachineExtensions]) or
       not ExtensionValue(Ldap.Extensions[gesUser],Temp[gdrUserExtensions]) then Exit(gdtInvalid);
  end else if LdapState=glcUnreadable then begin
    for R:=gdrGpcVersion to gdrUsn do begin Temp[R].State:=gdsUnreadable; Temp[R].ReadStatus:=grsIoError; end;
  end;
  for A:=Low(A) to High(A) do begin
    Result:=CheckTarget(Expected,Expected); if Result<>gdtOk then Exit;
    if not Files.Items[A].Attempted then Continue;
    if Length(Files.Items[A].Data)>GpoMaxFileBytes then Exit(gdtTooLarge);
    if (Files.Items[A].Status=grsOk) and (Files.Items[A].Observation=gfoPresent) and
      (Files.Items[A].Metadata.Kind=gekFile) and ((Files.Items[A].Metadata.Attributes and $410)=0) and
      (GpoCompareFileEvidence(Files.Items[A].Metadata,Files.Items[A].Metadata)=gprEvidenceIncomplete) then begin
      Temp[FileResources[A]].State:=gdsPresent; Temp[FileResources[A]].Data:=Copy(Files.Items[A].Data);
    end else if (A<>gfGptIni) and (Files.Items[A].Status=grsMissing) and
      (Files.Items[A].Observation=gfoLeafAbsent) and (Length(Files.Items[A].Data)=0) and
      (Files.Items[A].Metadata.Kind=gekParent) and
      ((Files.Items[A].Metadata.Attributes and $410)=$10) and
      (GpoCompareFileEvidence(Files.Items[A].Metadata,Files.Items[A].Metadata)=gprEvidenceIncomplete) then
      Temp[FileResources[A]].State:=gdsMissing
    else Temp[FileResources[A]].State:=gdsUnreadable;
    Temp[FileResources[A]].ReadStatus:=Files.Items[A].Status;
    Temp[FileResources[A]].FileObservation:=Files.Items[A].Observation;
    if not MetadataValue(Files.Items[A].Metadata,Temp[MetaResources[A]]) then Exit(gdtInvalid);
  end;
  Total:=0;
  for R:=Low(R) to High(R) do begin
    if Length(Temp[R].Data)>GpoMaxFileBytes then Exit(gdtTooLarge);
    Inc(Total,Length(Temp[R].Data)); if Total>GpoDiagnosticMaxBytes then Exit(gdtTooLarge);
    if not ValidValue(R,Temp[R]) then Exit(gdtInvalid);
  end;
  Result:=CheckTarget(Expected,Expected); if Result<>gdtOk then Exit;
  Values:=Temp; Result:=gdtOk;
end;

function GpoDiagnoseCapturedDraft(Draft:TGpoObservedDraft; const User,Machine:TGpoPolicyImage;
  const Before,After:TGpoLdapEvidence; const Files:TGpoObservedFiles; Control:TGpoReadControl;
  out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
var Target:TGpoPreflightTarget; Plan:TGpoOfflinePlan; Initial:TGpoLdapEvidence;
  InitialFiles,NoFiles:TGpoObservedFiles; Baseline,Candidate,InitialValues,Observed,AfterValues:TGpoDiagnosticValues;
  R:TGpoDiagnosticResource;
  function Ready:Boolean;
  begin Result:=Assigned(Control) and (Control.Status=grsOk); end;
begin
  Report:=Default(TGpoDiagnosticReport);
  if not Assigned(Draft) or not Ready then Exit(gdtReadUnavailable);
  if not Draft.DiagnosticInputs(User,Machine,Target,Plan,Initial,InitialFiles) then Exit(gdtSessionInvalid);
  Result:=GpoDiagnosticPlanValues(Plan,Baseline,Candidate); if Result<>gdtOk then Exit;
  Result:=GpoDiagnosticEvidenceValues(Target,glcCaptured,Initial,InitialFiles,InitialValues); if Result<>gdtOk then Exit;
  for R:=gdrFlags to High(R) do Baseline[R]:=InitialValues[R];
  Result:=GpoDiagnosticEvidenceValues(Target,glcCaptured,Before,Files,Observed); if Result<>gdtOk then Exit;
  NoFiles:=Default(TGpoObservedFiles);
  Result:=GpoDiagnosticEvidenceValues(Target,glcCaptured,After,NoFiles,AfterValues); if Result<>gdtOk then Exit;
  for R:=gdrGpcVersion to gdrUsn do
    if not SameValue(Observed[R],AfterValues[R]) or
      (Observed[R].ExtensionStatus<>AfterValues[R].ExtensionStatus) then Exit(gdtChangedDuringCapture);
  if not Ready then Exit(gdtSessionInvalid);
  Result:=GpoDiagnoseObservations(Target,After.Target,Baseline,Candidate,Observed,Report);
  if not Ready then begin Report:=Default(TGpoDiagnosticReport); Exit(gdtSessionInvalid); end;
end;

function GpoDiagnoseObservedDraft(Client:TLdapClient; const DN,Guid:string; Draft:TGpoObservedDraft;
  const User,Machine:TGpoPolicyImage; Control:TGpoReadControl; out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
var Target:TGpoPreflightTarget; Plan:TGpoOfflinePlan; Initial,Before,After:TGpoLdapEvidence;
  InitialFiles,Files:TGpoObservedFiles; Capture:TGpoPreflightResult;
  function Ready:Boolean;
  begin Result:=Assigned(Control) and (Control.Status=grsOk); end;
begin
  Report:=Default(TGpoDiagnosticReport);
  if not Assigned(Draft) or not Assigned(Client) or not Ready then Exit(gdtReadUnavailable);
  if not Draft.DiagnosticInputs(User,Machine,Target,Plan,Initial,InitialFiles) then Exit(gdtSessionInvalid);
  if not SameText(DN,Target.DN) or not SameText(Guid,Target.Guid) then Exit(gdtTargetMismatch);
  Plan:=Default(TGpoOfflinePlan); Initial:=Default(TGpoLdapEvidence); InitialFiles:=Default(TGpoObservedFiles);
  Capture:=GpoCaptureLdapEvidence(Client,DN,Guid,Before,Control);
  if not Ready then Exit(gdtSessionInvalid);
  if Capture=gprSessionInvalid then Exit(gdtSessionInvalid);
  if Capture=gprTargetMismatch then Exit(gdtTargetMismatch);
  if Capture<>gprEvidenceIncomplete then Exit(gdtReadUnavailable);
  Capture:=GpoCapturePreflightEvidence(Target,Files,Control);
  if not Ready then Exit(gdtSessionInvalid);
  if Capture=gprSessionInvalid then Exit(gdtSessionInvalid);
  if Capture=gprTargetMismatch then Exit(gdtTargetMismatch);
  if not (Capture in [gprEvidenceIncomplete,gprReadUnavailable]) then Exit(gdtReadUnavailable);
  Capture:=GpoCaptureLdapEvidence(Client,DN,Guid,After,Control);
  if not Ready then Exit(gdtSessionInvalid);
  if Capture=gprSessionInvalid then Exit(gdtSessionInvalid);
  if Capture=gprTargetMismatch then Exit(gdtTargetMismatch);
  if Capture<>gprEvidenceIncomplete then Exit(gdtReadUnavailable);
  Result:=GpoDiagnoseCapturedDraft(Draft,User,Machine,Before,After,Files,Control,Report);
end;

end.
