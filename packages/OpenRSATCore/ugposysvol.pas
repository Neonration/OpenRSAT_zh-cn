unit ugposysvol;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, ugpoformats, mormot.net.ldap;

type
  TGpoFile = (gfGptIni, gfMachineRegistry, gfUserRegistry);
  TGpoFileObservation = (gfoUnavailable, gfoPresent, gfoLeafAbsent);
  TGpoPreflightTarget = record
    Domain, DC, DN, Guid, FileSysPath:string;
    ObjectGuid:TBytes;
    Session:IInterface;
  end;
  TGpoPreflightResult = (gprInvalid, gprSessionInvalid, gprTargetMismatch,
    gprReadUnavailable, gprConflict, gprEvidenceIncomplete);
  TGpoCapturedFile = record
    Status:TGpoReadStatus;
    Observation:TGpoFileObservation;
    Data:TBytes;
  end;
  TGpoCapturedFiles = array[TGpoFile] of TGpoCapturedFile;
  TGpoLdapEvidence = record
    Target:TGpoPreflightTarget;
    Version, Flags:Cardinal;
    USNChanged:QWord;
    SecurityDescriptor:TBytes;
  end;
  // In-memory binding only. The caller must independently verify target provenance.
  // Even matching evidence returns EvidenceIncomplete: file metadata is not captured.
  TGpoBoundPlan = class
  private
    fTarget:TGpoPreflightTarget;
    fPlan:TGpoOfflinePlan;
    fToken:ILdapSessionToken;
    fLdapCaptured:Boolean;
    fUSN:QWord;
    fFlags:Cardinal;
    fSecurityDescriptor:TBytes;
  public
    class function Bind(const Target:TGpoPreflightTarget; const Plan:TGpoOfflinePlan;
      out Bound:TGpoBoundPlan):TGpoPreflightResult; static;
    class function BindEvidence(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
      out Bound:TGpoBoundPlan):TGpoPreflightResult; static;
    function Compare(const Target:TGpoPreflightTarget; GpcStatus:TGpoReadStatus; GpcVersion:Cardinal;
      GptStatus:TGpoReadStatus; const Ini:TBytes;
      UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
      MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
    function CompareEvidence(const Evidence:TGpoLdapEvidence; GptStatus:TGpoReadStatus; const Ini:TBytes;
      UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
      MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
  end;
  // Cooperative only: synchronous OS SMB calls may outlive this deadline.
  // The caller keeps this object alive until the read has returned.
  TGpoReadControl = class
  private
    fCancelled: LongInt;
    fSession: ILdapSessionToken;
    fStarted: QWord;
    fBudget: Cardinal;
  public
    constructor Create(BudgetMS: Cardinal = 30000; const SessionToken: IInterface = nil);
    procedure Cancel;
    function Cancelled: Boolean;
    function SessionValid: Boolean;
    function Status: TGpoReadStatus;
  end;

// ExpectedDomain and ConnectedDC MUST come from the active verified LDAP session,
// never from the untrusted gPCFileSysPath attribute. No IO occurs in this function.
function GpoBuildSafePath(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out SafePath: string): TGpoReadStatus;
// Explicit read only. Uses the existing OS SMB session, never maps credentials.
// On non-Windows there is no implicit UNC-to-local/mount fallback.
function GpoReadFile(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out Data: TBytes;
  Control: TGpoReadControl = nil): TGpoReadStatus;
// An absent leaf is distinguished from a missing ancestor; no metadata is returned.
function GpoReadFileObserved(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out Data: TBytes; out Observation:TGpoFileObservation;
  Control: TGpoReadControl = nil): TGpoReadStatus;
// Synchronous and read-only. Caller must first verify the target via LDAP;
// a successful file capture still lacks metadata and never authorizes writing.
function GpoCapturePreflightFiles(const Target:TGpoPreflightTarget; out Files:TGpoCapturedFiles):TGpoPreflightResult;
// Synchronous, on the caller's serialized LDAP client. No credentials or permissions are changed.
// Captures only owner/group/DACL; success remains evidence-incomplete.
function GpoCaptureLdapEvidence(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
// Parses a caller-supplied LDAP result, but does not verify its origin or session.
function GpoParseLdapGpc(Entry:TLdapResult; const Domain,DC,ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;

// Uses the same canonical validation, then bypasses the Win32 UNC alias only.
function GpoBuildNativePath(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out NativePath: string): TGpoReadStatus;
function GpoNtStatusToReadStatus(Status: Cardinal): TGpoReadStatus;
{$if defined(windows) and defined(OPENRSATTESTS)}
// Test-only seam: identical guarded traversal, unavailable in production builds.
function GpoTestReadGuardedFile(const NativeRoot, RelativePath: UnicodeString;
  out Data: TBytes): TGpoReadStatus;
function GpoTestReadGuardedObservation(const NativeRoot, RelativePath: UnicodeString;
  out Data:TBytes; out Observation:TGpoFileObservation):TGpoReadStatus;
{$endif}

implementation

uses mormot.core.base, mormot.core.os.security{$ifdef windows}, Windows{$endif};
{$ifdef windows}
{$push}{$packrecords c}
type
  TGpoNativeString = record
    Length, MaximumLength: Word;
    Buffer: PWideChar;
  end;
  TGpoNativeAttributes = record
    Length: ULONG;
    RootDirectory: THandle;
    ObjectName: ^TGpoNativeString;
    Attributes: ULONG;
    SecurityDescriptor, SecurityQualityOfService: Pointer;
  end;
  TGpoNativeIoStatus = record
    StatusOrPointer, Information: PtrUInt;
  end;
  TGpoAttributeTagInfo = record FileAttributes, ReparseTag: DWORD; end;
{$pop}
function NtOpenFile(out FileHandle: THandle; DesiredAccess: ACCESS_MASK;
  var ObjectAttributes: TGpoNativeAttributes; out IoStatusBlock: TGpoNativeIoStatus;
  ShareAccess, OpenOptions: ULONG): LongInt; stdcall; external 'ntdll.dll';
function GetFileInformationByHandleEx(H: THandle; InfoClass: LongInt;
  Info: Pointer; Size: DWORD): LongBool; stdcall; external 'kernel32.dll';
{$endif}

class function TGpoBoundPlan.Bind(const Target:TGpoPreflightTarget; const Plan:TGpoOfflinePlan;
  out Bound:TGpoBoundPlan):TGpoPreflightResult;
var Token:ILdapSessionToken; Path:string; U,M:TGpoPolicyImage; Frozen:TGpoOfflinePlan;
begin
  Bound:=nil; Result:=gprInvalid;
  if not Assigned(Target.Session) or not Supports(Target.Session,ILdapSessionToken,Token) or
     not Token.IsValid then Exit(gprSessionInvalid);
  if (Target.DN='') or (Length(Target.ObjectGuid)<>16) or SameText(Target.Domain,Target.DC) or
     (GpoBuildSafePath(Target.FileSysPath,Target.Domain,Target.DC,Target.Guid,gfGptIni,Path)<>grsOk) then Exit;
  if GpoCheckOfflinePlan(Plan,Plan.Baseline.GpcVersion,Plan.Baseline.GptIni,
    Plan.Baseline.UserPolicy,Plan.Baseline.MachinePolicy)<>gbcMatch then Exit;
  U.Exists:=Plan.UserExists; U.Data:=Plan.UserPolicy;
  M.Exists:=Plan.MachineExists; M.Data:=Plan.MachinePolicy;
  if GpoBuildOfflinePlanWithPresence(Plan.Baseline.GpcVersion,Plan.Baseline.GpcVersion,
    Plan.Baseline.GptIni,Plan.Baseline.UserPolicy,U,Plan.Baseline.MachinePolicy,M,Frozen)<>gopOk then Exit;
  if not Token.IsValid then Exit(gprSessionInvalid);
  Bound:=TGpoBoundPlan.Create; Bound.fTarget:=Target; Bound.fTarget.ObjectGuid:=Copy(Target.ObjectGuid);
  Bound.fToken:=Token; Bound.fPlan:=Frozen; Result:=gprEvidenceIncomplete;
end;

class function TGpoBoundPlan.BindEvidence(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
  out Bound:TGpoBoundPlan):TGpoPreflightResult;
var SD:mormot.core.os.security.TSecurityDescriptor;
begin
  Bound:=nil;
  if (Evidence.USNChanged=0) or (Length(Evidence.SecurityDescriptor)=0) or
     not SD.FromBinary(mormot.core.base.PByteArray(@Evidence.SecurityDescriptor[0]),Length(Evidence.SecurityDescriptor)) then Exit(gprReadUnavailable);
  if Evidence.Version<>Plan.Baseline.GpcVersion then Exit(gprConflict);
  Result:=Bind(Evidence.Target,Plan,Bound);
  if not Assigned(Bound) then Exit;
  Bound.fUSN:=Evidence.USNChanged; Bound.fFlags:=Evidence.Flags;
  Bound.fSecurityDescriptor:=Copy(Evidence.SecurityDescriptor); Bound.fLdapCaptured:=True;
end;

function TGpoBoundPlan.Compare(const Target:TGpoPreflightTarget; GpcStatus:TGpoReadStatus; GpcVersion:Cardinal;
  GptStatus:TGpoReadStatus; const Ini:TBytes;
  UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
  MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
var U,M:TGpoPolicyImage; Check:TGpoBaselineCheck; Token:ILdapSessionToken;
  function Image(Status:TGpoReadStatus; Observation:TGpoFileObservation; const Data:TBytes; out Value:TGpoPolicyImage):Boolean;
  begin
    Value:=Default(TGpoPolicyImage); Result:=False;
    if (Status=grsOk) and (Observation=gfoPresent) then begin Value.Exists:=True; Value.Data:=Data; Exit(True); end;
    if (Status=grsMissing) and (Observation=gfoLeafAbsent) and (Length(Data)=0) then Exit(True);
  end;
begin
  if not Assigned(fToken) or not fToken.IsValid or not Assigned(Target.Session) or
     not Supports(Target.Session,ILdapSessionToken,Token) or not Token.IsValid or
     (Target.Session<>fTarget.Session) then Exit(gprSessionInvalid);
  if not SameText(Target.Domain,fTarget.Domain) or not SameText(Target.DC,fTarget.DC) or
     not SameText(Target.DN,fTarget.DN) or not SameText(Target.Guid,fTarget.Guid) or
     not SameText(Target.FileSysPath,fTarget.FileSysPath) or (Length(Target.ObjectGuid)<>16) or
     not CompareMem(@Target.ObjectGuid[0],@fTarget.ObjectGuid[0],16) then Exit(gprTargetMismatch);
  if (GpcStatus<>grsOk) or (GptStatus<>grsOk) or
     not Image(UserStatus,UserObservation,UserData,U) or
     not Image(MachineStatus,MachineObservation,MachineData,M) then Exit(gprReadUnavailable);
  Check:=GpoCheckOfflinePlan(fPlan,GpcVersion,Ini,U,M);
  if not fToken.IsValid then Exit(gprSessionInvalid);
  case Check of
    gbcInvalid:Result:=gprInvalid;
    gbcConflict:Result:=gprConflict;
    else Result:=gprEvidenceIncomplete;
  end;
end;

function TGpoBoundPlan.CompareEvidence(const Evidence:TGpoLdapEvidence; GptStatus:TGpoReadStatus; const Ini:TBytes;
  UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
  MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
var SD:mormot.core.os.security.TSecurityDescriptor;
begin
  if not fLdapCaptured or (Evidence.USNChanged=0) or (Length(Evidence.SecurityDescriptor)=0) or
     not SD.FromBinary(mormot.core.base.PByteArray(@Evidence.SecurityDescriptor[0]),Length(Evidence.SecurityDescriptor)) then Exit(gprReadUnavailable);
  Result:=Compare(Evidence.Target,grsOk,Evidence.Version,GptStatus,Ini,
    UserStatus,UserObservation,UserData,MachineStatus,MachineObservation,MachineData);
  if Result<>gprEvidenceIncomplete then Exit;
  if (Evidence.USNChanged<>fUSN) or (Evidence.Flags<>fFlags) or
     (Length(Evidence.SecurityDescriptor)<>Length(fSecurityDescriptor)) or
     not CompareMem(@Evidence.SecurityDescriptor[0],@fSecurityDescriptor[0],Length(fSecurityDescriptor)) then Exit(gprConflict);
  if not fToken.IsValid then Exit(gprSessionInvalid);
  Result:=gprEvidenceIncomplete;
end;

constructor TGpoReadControl.Create(BudgetMS: Cardinal; const SessionToken: IInterface);
begin
  inherited Create;
  fStarted := GetTickCount64; fBudget := BudgetMS;
  if Assigned(SessionToken) and not Supports(SessionToken, ILdapSessionToken, fSession) then
    Cancel; // Never silently accept an unrecognized session identity.
end;

procedure TGpoReadControl.Cancel;
begin InterlockedExchange(fCancelled,1); end;

function TGpoReadControl.Cancelled: Boolean;
begin Result := InterlockedCompareExchange(fCancelled,0,0) <> 0; end;

function TGpoReadControl.SessionValid: Boolean;
begin
  Result := not Assigned(fSession) or fSession.IsValid;
end;

function TGpoReadControl.Status: TGpoReadStatus;
begin
  if Cancelled or not SessionValid then Exit(grsCancelled);
  if GetTickCount64-fStarted >= fBudget then Exit(grsTimedOut);
  Result := grsOk;
end;

function GpoCapturePreflightFiles(const Target:TGpoPreflightTarget; out Files:TGpoCapturedFiles):TGpoPreflightResult;
var Token:ILdapSessionToken; Control:TGpoReadControl; Artifact:TGpoFile; Path:string;
begin
  for Artifact:=Low(TGpoFile) to High(TGpoFile) do
  begin Files[Artifact].Status:=grsIoError; Files[Artifact].Observation:=gfoUnavailable; Files[Artifact].Data:=nil; end;
  if not Assigned(Target.Session) or not Supports(Target.Session,ILdapSessionToken,Token) or
     not Token.IsValid then Exit(gprSessionInvalid);
  if (Target.DN='') or (Length(Target.ObjectGuid)<>16) or SameText(Target.Domain,Target.DC) or
     (GpoBuildSafePath(Target.FileSysPath,Target.Domain,Target.DC,Target.Guid,gfGptIni,Path)<>grsOk) then Exit(gprInvalid);
  Control:=TGpoReadControl.Create(30000,Target.Session);
  try
    for Artifact:=Low(TGpoFile) to High(TGpoFile) do
    begin
      Files[Artifact].Status:=GpoReadFileObserved(Target.FileSysPath,Target.Domain,Target.DC,Target.Guid,
        Artifact,Files[Artifact].Data,Files[Artifact].Observation,Control);
      if not Token.IsValid then Exit(gprSessionInvalid);
      if not ((Files[Artifact].Status=grsOk) and (Files[Artifact].Observation=gfoPresent)) and
         not ((Artifact<>gfGptIni) and (Files[Artifact].Status=grsMissing) and
           (Files[Artifact].Observation=gfoLeafAbsent)) then Exit(gprReadUnavailable);
    end;
    Result:=gprEvidenceIncomplete;
  finally Control.Free; end;
end;

function GpoParseLdapGpc(Entry:TLdapResult; const Domain,DC,ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
var Guid,Path,UsnText:string; RawGuid,RawSD:RawByteString;
  SD:mormot.core.os.security.TSecurityDescriptor; U:QWord; I:Integer; NonZero:Boolean; E:TGpoLdapEvidence;
begin
  Evidence:=Default(TGpoLdapEvidence); E:=Default(TGpoLdapEvidence);
  if not Assigned(Entry) then Exit(gprReadUnavailable);
  if not SameText(Entry.ObjectName,ExpectedDN) or not Assigned(Entry.Find('name')) then Exit(gprTargetMismatch);
  Guid:=Entry.Find('name').GetReadable;
  if not GpoValidGuid(Guid) or not SameText(Guid,ExpectedGuid) then Exit(gprTargetMismatch);
  if not Assigned(Entry.Find('objectGUID')) or not Assigned(Entry.Find('gPCFileSysPath')) or
     not Assigned(Entry.Find('versionNumber')) or not Assigned(Entry.Find('flags')) or
     not Assigned(Entry.Find('uSNChanged')) or not Assigned(Entry.Find('nTSecurityDescriptor')) then Exit(gprReadUnavailable);
  RawGuid:=Entry.Find('objectGUID').GetRaw; RawSD:=Entry.Find('nTSecurityDescriptor').GetRaw;
  UsnText:=Entry.Find('uSNChanged').GetReadable;
  if (Length(RawGuid)<>16) or (Length(RawSD)=0) or (UsnText='') then Exit(gprReadUnavailable);
  NonZero:=False; for I:=1 to Length(RawGuid) do if RawGuid[I]<>#0 then NonZero:=True;
  if not NonZero then Exit(gprReadUnavailable);
  for I:=1 to Length(UsnText) do if not (UsnText[I] in ['0'..'9']) then Exit(gprReadUnavailable);
  if not TryStrToQWord(UsnText,U) or (U=0) or not SD.FromBinary(RawSD) or
     not GpoParseLdapVersion(Entry.Find('versionNumber').GetReadable,E.Version) or
     not GpoParseUnsigned(Entry.Find('flags').GetReadable,E.Flags) then Exit(gprReadUnavailable);
  E.Target.FileSysPath:=Entry.Find('gPCFileSysPath').GetReadable;
  if GpoBuildSafePath(E.Target.FileSysPath,Domain,DC,Guid,gfGptIni,Path)<>grsOk then Exit(gprTargetMismatch);
  E.Target.Domain:=Domain; E.Target.DC:=DC; E.Target.DN:=ExpectedDN; E.Target.Guid:=Guid;
  SetLength(E.Target.ObjectGuid,16); Move(RawGuid[1],E.Target.ObjectGuid[0],16);
  E.USNChanged:=U; SetLength(E.SecurityDescriptor,Length(RawSD)); Move(RawSD[1],E.SecurityDescriptor[0],Length(RawSD));
  Evidence:=E; Result:=gprEvidenceIncomplete;
end;

function GpoCaptureLdapEvidence(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
var Token:ILdapSessionToken; Session:IInterface; SavedFlags:TLdapSearchSDFlags;
  Root:TLdapResult; Host,Port,User,Server,DefaultDN,Domain,DC:string;
  Socket:Pointer; E:TGpoLdapEvidence; ParseResult:TGpoPreflightResult;
  function SameSession:Boolean;
  begin
    Result:=Assigned(Client) and Assigned(Client.Settings) and Assigned(Client.Sock) and
      Client.Connected and Client.Bound and Assigned(Token) and Token.IsValid and
      (Client.SessionToken=Session) and (Pointer(Client.Sock)=Socket) and
      (Client.Settings.TargetHost=Host) and (Client.Settings.TargetPort=Port) and
      (Client.BoundUser=User) and (Client.Sock.Server=Server) and (Client.DefaultDN=DefaultDN);
  end;
begin
  Evidence:=Default(TGpoLdapEvidence); E:=Default(TGpoLdapEvidence);
  if not Assigned(Client) or not Assigned(Client.Settings) or not Assigned(Client.Sock) or
     not Client.Connected or not Client.Bound or (Client.BoundUser='') then Exit(gprSessionInvalid);
  Session:=Client.SessionToken;
  if not Assigned(Session) or not Supports(Session,ILdapSessionToken,Token) or not Token.IsValid then Exit(gprSessionInvalid);
  if (ExpectedDN='') or not GpoValidGuid(ExpectedGuid) then Exit(gprInvalid);
  Host:=Client.Settings.TargetHost; Port:=Client.Settings.TargetPort; User:=Client.BoundUser;
  Socket:=Pointer(Client.Sock); Server:=Client.Sock.Server; DefaultDN:=Client.DefaultDN;
  SavedFlags:=Client.SearchSDFlags;
  try
    try
      Client.SearchSDFlags:=[];
      if not SameSession then Exit(gprSessionInvalid);
      Root:=Client.SearchObject('','',['dnsHostName','defaultNamingContext']);
      if not SameSession then Exit(gprSessionInvalid);
      if not Assigned(Root) or not Assigned(Root.Find('dnsHostName')) or
         not Assigned(Root.Find('defaultNamingContext')) then Exit(gprReadUnavailable);
      DC:=Root.Find('dnsHostName').GetReadable;
      if not SameText(Root.Find('defaultNamingContext').GetReadable,DefaultDN) then Exit(gprTargetMismatch);
      Domain:=DNToCN(DefaultDN,True,[dnDC]);
      if (Domain='') or (DC='') or SameText(Domain,DC) or not SameText(DC,Host) then Exit(gprTargetMismatch);
      Client.SearchSDFlags:=lsfMain;
      if not SameSession then Exit(gprSessionInvalid);
      Root:=Client.SearchObject(ExpectedDN,'(objectClass=groupPolicyContainer)',
        ['name','objectGUID','gPCFileSysPath','versionNumber','flags','uSNChanged','nTSecurityDescriptor']);
      if not SameSession then Exit(gprSessionInvalid);
      ParseResult:=GpoParseLdapGpc(Root,Domain,DC,ExpectedDN,ExpectedGuid,E);
      if ParseResult<>gprEvidenceIncomplete then Exit(ParseResult);
      E.Target.Session:=Session;
      if not SameSession then Exit(gprSessionInvalid);
      Evidence:=E; Result:=gprEvidenceIncomplete;
    except
      Evidence:=Default(TGpoLdapEvidence); Result:=gprReadUnavailable;
    end;
  finally Client.SearchSDFlags:=SavedFlags; end;
end;

function ReadControlStatus(Control: TGpoReadControl): TGpoReadStatus;
begin
  if Assigned(Control) then Result := Control.Status else Result := grsOk;
end;

function ValidHost(const S: string): Boolean;
var I, LabelStart: SizeInt;
begin
  Result := False;
  if (Length(S) = 0) or (Length(S) > 253) then Exit;
  LabelStart := 1;
  for I := 1 to Length(S) do
  begin
    if S[I] = '.' then
    begin
      if (I = LabelStart) or (I-LabelStart > 63) or (S[I-1] = '-') then Exit;
      LabelStart := I+1;
    end
    else if not (S[I] in ['a'..'z','A'..'Z','0'..'9','-']) or
      ((I = LabelStart) and (S[I] = '-')) then Exit;
  end;
  Result := (LabelStart <= Length(S)) and (Length(S)-LabelStart < 63) and
    (S[Length(S)] <> '-');
end;

function GpoBuildSafePath(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out SafePath: string): TGpoReadStatus;
var DomainRoot, DcRoot: string;
begin
  SafePath := ''; Result := grsInvalidPath;
  if not ValidHost(ExpectedDomain) or not ValidHost(ConnectedDC) or
    not GpoValidGuid(Guid) then Exit;
  DomainRoot := '\\' + ExpectedDomain + '\SYSVOL\' + ExpectedDomain + '\Policies\' + Guid;
  DcRoot := '\\' + ConnectedDC + '\SYSVOL\' + ExpectedDomain + '\Policies\' + Guid;
  // Exact canonical structure only: no traversal, alternate shares, device paths,
  // ports, suffixes, trailing separators or attacker-selected server targets.
  if not SameText(FileSysPath,DomainRoot) and not SameText(FileSysPath,DcRoot) then Exit;
  SafePath := DcRoot;
  case Artifact of
    gfGptIni: SafePath := SafePath + '\GPT.INI';
    gfMachineRegistry: SafePath := SafePath + '\Machine\Registry.pol';
    gfUserRegistry: SafePath := SafePath + '\User\Registry.pol';
  end;
  Result := grsOk;
end;

function GpoBuildNativePath(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out NativePath: string): TGpoReadStatus;
var SafePath: string;
begin
  NativePath := '';
  Result := GpoBuildSafePath(FileSysPath,ExpectedDomain,ConnectedDC,Guid,Artifact,SafePath);
  if Result = grsOk then NativePath := '\Device\Mup\' + Copy(SafePath,3,MaxInt);
end;

function GpoNtStatusToReadStatus(Status: Cardinal): TGpoReadStatus;
begin
  case Status of
    $00000000: Result := grsOk;
    $c000000f, $c0000034, $c000003a: Result := grsMissing;
    $c0000022, $c000006d, $c000006a, $c000015b: Result := grsAccessDenied;
    $c000050b, $8000002d, $c0000275, $c0000279: Result := grsReparseBlocked;
    $c0000002, $c000000d, $c00000bb: Result := grsUnsupported;
    else Result := grsIoError;
  end;
end;

{$ifdef windows}
function FileError(Code: DWORD): TGpoReadStatus;
begin
  case Code of
    ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: Result := grsMissing;
    ERROR_ACCESS_DENIED, ERROR_LOGON_FAILURE, ERROR_NETWORK_ACCESS_DENIED:
      Result := grsAccessDenied;
    ERROR_NOT_SUPPORTED, ERROR_INVALID_PARAMETER, ERROR_CALL_NOT_IMPLEMENTED:
      Result := grsUnsupported;
    else Result := grsIoError;
  end;
end;

// All opens reject client-side name reparses and deny concurrent write/delete
// handles. The sole permitted reparse is a checked domain-root MOUNT_POINT.
// Configured SYSVOL/share roots remain trusted server configuration: this is
// not a namespace-integrity guarantee against a malicious SMB server.
function OpenNativeReadOnly(const NativePath: UnicodeString;
  Directory, AllowRootMount, ResolveRoot: Boolean;
  out H: THandle; out IsMount: Boolean; NativeStatus:PCardinal = nil): TGpoReadStatus;
var U: TGpoNativeString; A: TGpoNativeAttributes; IO: TGpoNativeIoStatus;
  Status: LongInt; Info: TByHandleFileInformation;
  Tag: TGpoAttributeTagInfo; Options: ULONG;
begin
  H := INVALID_HANDLE_VALUE; IsMount := False;
  if Assigned(NativeStatus) then NativeStatus^:=$ffffffff;
  if (Length(NativePath) = 0) or (Length(NativePath) > 32766) then Exit(grsInvalidPath);
  FillChar(U,SizeOf(U),0);
  U.Length := Length(NativePath)*2; U.MaximumLength := U.Length+2;
  U.Buffer := PWideChar(NativePath);
  FillChar(A,SizeOf(A),0);
  A.Length := SizeOf(A); A.ObjectName := @U;
  A.Attributes := $1040; // OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE; never relaxed.
  FillChar(IO,SizeOf(IO),0);
  Options := $20; // FILE_SYNCHRONOUS_IO_NONALERT
  if not ResolveRoot then Options := Options or $00200000; // FILE_OPEN_REPARSE_POINT
  if Directory then Options := Options or $1 else Options := Options or $40;
  // FILE_READ_DATA (LIST_DIRECTORY) | FILE_READ_ATTRIBUTES | SYNCHRONIZE.
  Status := NtOpenFile(H,$00100081,A,IO,FILE_SHARE_READ,Options);
  if Assigned(NativeStatus) then NativeStatus^:=Cardinal(Status);
  Result := GpoNtStatusToReadStatus(Cardinal(Status));
  if Result <> grsOk then begin H := INVALID_HANDLE_VALUE; Exit; end;
  if not GetFileInformationByHandle(H,Info) then Result := FileError(GetLastError)
  else if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) <> Directory then
    Result := grsUnsupported
  else if (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
  begin
    Result := grsReparseBlocked;
    if Directory and AllowRootMount and not ResolveRoot then
    begin
      FillChar(Tag,SizeOf(Tag),0);
      if not GetFileInformationByHandleEx(H,9,@Tag,SizeOf(Tag)) then Result := FileError(GetLastError)
      else if ((Tag.FileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) and
        (Tag.ReparseTag = $a0000003) then // IO_REPARSE_TAG_MOUNT_POINT only.
      begin IsMount := True; Result := grsOk; end;
    end;
  end;
  if Result <> grsOk then begin CloseHandle(H); H := INVALID_HANDLE_VALUE; end;
end;

function ReadGuardedFile(const NativeRoot, RelativePath: UnicodeString;
  out Data: TBytes; Control: TGpoReadControl; out Observation:TGpoFileObservation): TGpoReadStatus;
var Parts: array of UnicodeString; Guards: array of THandle;
  I, J, Start: SizeInt; Path: UnicodeString; H: THandle; IsMount: Boolean;
  Info: TByHandleFileInformation; Count, Got, NativeStatus: DWORD; Extra: Byte; Stop:TGpoReadStatus;
  procedure KeepGuard;
  begin
    SetLength(Guards,Length(Guards)+1); Guards[High(Guards)] := H;
    H := INVALID_HANDLE_VALUE;
  end;
begin
  Data := nil; Parts := nil; Guards := nil; H := INVALID_HANDLE_VALUE; Observation:=gfoUnavailable;
  Result := grsInvalidPath;
  // Validate all segments before any open, including the test-only seam.
  if (NativeRoot = '') or (RelativePath = '') then Exit;
  Start := 1;
  for I := 1 to Length(RelativePath)+1 do
    if (I > Length(RelativePath)) or (RelativePath[I] = '\') then
    begin
      if (I = Start) or (Length(Parts) = 8) then Exit;
      Path := Copy(RelativePath,Start,I-Start);
      if (Path = '.') or (Path = '..') or (Path[Length(Path)] in ['.', ' ']) then Exit;
      for J := 1 to Length(Path) do
        if (Ord(Path[J]) < 32) or (Path[J] in ['/', ':', '*', '?', '"', '<', '>', '|']) then Exit;
      SetLength(Parts,Length(Parts)+1); Parts[High(Parts)] := Path;
      Start := I+1;
    end;
  try
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    Path := NativeRoot;
    Result := OpenNativeReadOnly(Path,True,True,False,H,IsMount);
    if Result <> grsOk then Exit;
    KeepGuard;
    if IsMount then
    begin
      // Hold both checked MOUNT_POINT link and its resolved normal target root.
      // OBJ_DONT_REPARSE stays enabled; local/client symlink following fails.
      Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
      Result := OpenNativeReadOnly(Path,True,False,True,H,IsMount);
      if Result <> grsOk then Exit;
      KeepGuard;
    end;
    for I := 0 to High(Parts)-1 do
    begin
      Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
      Path := Path + '\' + Parts[I];
      Result := OpenNativeReadOnly(Path,True,False,False,H,IsMount);
      if Result <> grsOk then Exit;
      KeepGuard;
    end;
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    Path := Path + '\' + Parts[High(Parts)];
    Result := OpenNativeReadOnly(Path,False,False,False,H,IsMount,@NativeStatus);
    if Result <> grsOk then
    begin
      Stop:=ReadControlStatus(Control); if Stop<>grsOk then begin Result:=Stop; Exit; end;
      if (Result=grsMissing) and (NativeStatus=$c0000034) then
        Observation:=gfoLeafAbsent;
      Exit;
    end;
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    if not GetFileInformationByHandle(H,Info) then Exit(FileError(GetLastError));
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0 then Exit(grsReparseBlocked);
    if (Info.nFileSizeHigh <> 0) or (Info.nFileSizeLow > GpoMaxFileBytes) then Exit(grsTooLarge);
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    Count := Info.nFileSizeLow; SetLength(Data,Count);
    if Count > 0 then
    begin
      if not ReadFile(H,Data[0],Count,Got,nil) then Exit(FileError(GetLastError));
      if Got <> Count then Exit(grsIoError);
    end;
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    if not ReadFile(H,Extra,1,Got,nil) then Exit(FileError(GetLastError));
    if Got <> 0 then Exit(grsIoError);
    Result := ReadControlStatus(Control);
    if Result=grsOk then Observation:=gfoPresent;
  finally
    if H <> INVALID_HANDLE_VALUE then CloseHandle(H);
    for I := High(Guards) downto 0 do CloseHandle(Guards[I]);
    if Result <> grsOk then Data := nil;
  end;
end;

{$ifdef OPENRSATTESTS}
function GpoTestReadGuardedFile(const NativeRoot, RelativePath: UnicodeString;
  out Data: TBytes): TGpoReadStatus;
var Observation:TGpoFileObservation;
begin
  Result := ReadGuardedFile(NativeRoot,RelativePath,Data,nil,Observation);
end;
function GpoTestReadGuardedObservation(const NativeRoot, RelativePath: UnicodeString;
  out Data:TBytes; out Observation:TGpoFileObservation):TGpoReadStatus;
begin
  Result:=ReadGuardedFile(NativeRoot,RelativePath,Data,nil,Observation);
end;
{$endif}
{$endif}

function GpoReadFile(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out Data: TBytes;
  Control: TGpoReadControl): TGpoReadStatus;
var Observation:TGpoFileObservation;
begin
  Result:=GpoReadFileObserved(FileSysPath,ExpectedDomain,ConnectedDC,Guid,Artifact,Data,Observation,Control);
end;

function GpoReadFileObserved(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out Data: TBytes; out Observation:TGpoFileObservation;
  Control: TGpoReadControl): TGpoReadStatus;
var Path: string;
{$ifdef windows}
  Root: string;
{$endif}
begin
  Data := nil; Observation:=gfoUnavailable;
  Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
  Result := GpoBuildNativePath(FileSysPath,ExpectedDomain,ConnectedDC,Guid,Artifact,Path);
  if Result <> grsOk then Exit;
{$ifdef windows}
  Root := '\Device\Mup\' + ConnectedDC + '\SYSVOL\' + ExpectedDomain;
  Result := ReadGuardedFile(UTF8Decode(Root),UTF8Decode(Copy(Path,Length(Root)+2,MaxInt)),Data,Control,Observation);
{$else}
  Result := grsUnsupported;
{$endif}
end;

end.
