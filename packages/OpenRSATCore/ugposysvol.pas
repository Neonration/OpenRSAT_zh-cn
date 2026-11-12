unit ugposysvol;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, ugpoformats, mormot.core.base, mormot.net.ldap;

type
  TGpoFile = (gfGptIni, gfMachineRegistry, gfUserRegistry);
  TGpoFileObservation = (gfoUnavailable, gfoPresent, gfoLeafAbsent);
  TGpoEvidenceKind = (gekUnavailable, gekFile, gekParent);
  TGpoFileEvidence = record
    Available:Boolean;
    Kind:TGpoEvidenceKind;
    VolumeSerial, FileIndexHigh, FileIndexLow, Attributes:Cardinal;
    LastWriteHigh, LastWriteLow:Cardinal;
    SecurityDescriptor:TBytes; // owner/group/DACL only; never a write authorization.
  end;
  PGpoFileEvidence=^TGpoFileEvidence;
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
  TGpoObservedFile = record
    Attempted:Boolean;
    Status:TGpoReadStatus;
    Observation:TGpoFileObservation;
    Data:TBytes;
    Metadata:TGpoFileEvidence;
  end;
  TGpoObservedFiles = record
    Target:TGpoPreflightTarget;
    Captured:Boolean;
    Items:array[TGpoFile] of TGpoObservedFile;
  end;
  TGpoSecurityEvidence = (gseUnavailable, gseUnverified);
  TGpoLdapEvidence = record
    Target:TGpoPreflightTarget;
    Version, Flags:Cardinal;
    USNChanged:QWord;
    SecurityDescriptor:TBytes;
    SecurityStatus:TGpoSecurityEvidence;
  end;
  TGpoLdapSessionState = record
    Session:IInterface;
    Connected,Bound:Boolean;
    Host,Port,UserName,Server,DefaultDN:string;
    Socket:Pointer;
  end;
  IGpoLdapEvidenceTransport = interface
    ['{BDAB8775-8D51-431E-A180-D599DCB0B20A}']
    function State(out Value:TGpoLdapSessionState):Boolean;
    function GetSDFlags:TLdapSearchSDFlags;
    procedure SetSDFlags(Value:TLdapSearchSDFlags);
    function Search(const DN,Filter:RawUtf8; const Attributes:array of RawUtf8):TLdapResult;
  end;
  // In-memory binding only. The caller must independently verify target provenance.
  // Even matching evidence returns EvidenceIncomplete and never authorizes writing.
  TGpoBoundPlan = class
  private
    fTarget:TGpoPreflightTarget;
    fPlan:TGpoOfflinePlan;
    fToken:ILdapSessionToken;
    fLdapCaptured:Boolean;
    fUSN:QWord;
    fFlags:Cardinal;
    fSecurityDescriptor:TBytes;
    fFilesCaptured:Boolean;
    fFileEvidence:array[TGpoFile] of TGpoFileEvidence;
  public
    class function Bind(const Target:TGpoPreflightTarget; const Plan:TGpoOfflinePlan;
      out Bound:TGpoBoundPlan):TGpoPreflightResult; static;
    class function BindEvidence(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
      out Bound:TGpoBoundPlan):TGpoPreflightResult; static;
    class function BindWithFiles(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
      const Files:TGpoObservedFiles; out Bound:TGpoBoundPlan):TGpoPreflightResult; static;
    function Compare(const Target:TGpoPreflightTarget; GpcStatus:TGpoReadStatus; GpcVersion:Cardinal;
      GptStatus:TGpoReadStatus; const Ini:TBytes;
      UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
      MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
    function CompareEvidence(const Evidence:TGpoLdapEvidence; GptStatus:TGpoReadStatus; const Ini:TBytes;
      UserStatus:TGpoReadStatus; UserObservation:TGpoFileObservation; const UserData:TBytes;
      MachineStatus:TGpoReadStatus; MachineObservation:TGpoFileObservation; const MachineData:TBytes):TGpoPreflightResult;
    function CompareWithFiles(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles):TGpoPreflightResult;
  end;
  // Caller must obtain evidence from the verified live capture flow, not local paths.
  TGpoObservedDraft = class
  private
    fBound:TGpoBoundPlan;
    fVersion:Cardinal;
    fIni:TBytes;
    fUser,fMachine:TGpoPolicyImage;
  public
    destructor Destroy; override;
    class function Bind(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles;
      out Draft:TGpoObservedDraft):TGpoPreflightResult; static;
    function MatchesObjectGuid(const Expected:TBytes):Boolean;
    function GetBaseline(out User,Machine:TGpoPolicyImage):Boolean;
    // Candidate data must not alias fields in the output plan.
    function BuildPlan(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles;
      const UserCandidate,MachineCandidate:TGpoPolicyImage; out Plan:TGpoOfflinePlan):TGpoPreflightResult;
    function BindPlan(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles;
      const UserCandidate,MachineCandidate:TGpoPolicyImage; out Bound:TGpoBoundPlan):TGpoPreflightResult;
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
// Requires READ_CONTROL; absent leaf evidence describes its guarded parent, never the missing file.
function GpoReadFileEvidence(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid:string; Artifact:TGpoFile; out Data:TBytes; out Observation:TGpoFileObservation;
  out Evidence:TGpoFileEvidence; Control:TGpoReadControl = nil):TGpoReadStatus;
// Compares caller-held evidence only; equality never authorizes writing.
function GpoCompareFileEvidence(const Before,After:TGpoFileEvidence):TGpoPreflightResult;
// Synchronous and read-only. Caller must first verify the target via LDAP;
// a successful file capture still lacks metadata and never authorizes writing.
function GpoCapturePreflightFiles(const Target:TGpoPreflightTarget; out Files:TGpoCapturedFiles):TGpoPreflightResult;
// A missing policy leaf requires guarded parent evidence; missing ancestors remain unavailable.
function GpoCapturePreflightEvidence(const Target:TGpoPreflightTarget; out Files:TGpoObservedFiles):TGpoPreflightResult;
// Synchronous, on the caller's serialized LDAP client. No credentials or permissions are changed.
// Captures only owner/group/DACL; success remains evidence-incomplete.
function GpoCaptureLdapEvidence(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
// Serialized, synchronous LDAP/SMB reads only; equality is never write authorization.
function GpoBeginReadOnlyPreflight(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  const Plan:TGpoOfflinePlan; out Bound:TGpoBoundPlan):TGpoPreflightResult;
function GpoCheckReadOnlyPreflight(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Bound:TGpoBoundPlan):TGpoPreflightResult;
// Creates a target-bound draft from live LDAP/SMB evidence; serial client access required.
function GpoCaptureObservedDraft(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Draft:TGpoObservedDraft):TGpoPreflightResult;
function GpoBuildObservedDraftPlan(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Draft:TGpoObservedDraft; const UserCandidate,MachineCandidate:TGpoPolicyImage;
  out Plan:TGpoOfflinePlan):TGpoPreflightResult;
// The resulting candidate keeps the draft's verified target/session binding.
function GpoBindObservedDraftPlan(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Draft:TGpoObservedDraft; const UserCandidate,MachineCandidate:TGpoPolicyImage;
  out Bound:TGpoBoundPlan):TGpoPreflightResult;
// Shared capture flow; a supplied transport is not authenticated by this interface.
function GpoCaptureLdapFromTransport(const Transport:IGpoLdapEvidenceTransport;
  const ExpectedDN,ExpectedGuid:string; out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
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
function GpoTestReadGuardedEvidence(const NativeRoot, RelativePath:UnicodeString;
  out Data:TBytes; out Observation:TGpoFileObservation; out Evidence:TGpoFileEvidence):TGpoReadStatus;
{$endif}

implementation

uses mormot.core.os.security{$ifdef windows}, Windows{$endif};

function ValidFileSecurityEvidence(const Data:TBytes):Boolean;
var Control,Owner,Group,Sacl,Dacl:Cardinal;
  function U16(P:SizeInt):Cardinal;
  begin Result:=Cardinal(Data[P]) or (Cardinal(Data[P+1]) shl 8); end;
  function U32(P:SizeInt):Cardinal;
  begin Result:=U16(P) or (U16(P+2) shl 16); end;
  function ValidSid(P,Limit:SizeInt):Boolean;
  begin
    Result:=(P>=0) and (P<=Limit-8);
    if not Result then Exit;
    Result:=(Data[P]=1) and (Data[P+1]<=15) and
      (SizeInt(Data[P+1])*4<=Limit-P-8);
  end;
  function ValidAcl(Offset:Cardinal):Boolean;
  var P,Last,Count,Size,SidPos:SizeInt; Flags:Cardinal; AceType:Byte;
  begin
    Result:=False;
    if Offset=0 then Exit(True);
    if (Offset<20) or ((Offset and 3)<>0) or (Offset>Cardinal(Length(Data)-8)) then Exit;
    P:=Offset;
    if not (Data[P] in [2,3,4]) then Exit;
    Size:=U16(P+2); Count:=U16(P+4);
    if (Size<8) or ((Size and 3)<>0) or (Size>Length(Data)-P) then Exit;
    Last:=P+Size; Inc(P,8);
    while Count>0 do
    begin
      if P>Last-4 then Exit;
      AceType:=Data[P]; Size:=U16(P+2);
      if (Size<4) or ((Size and 3)<>0) or (Size>Last-P) then Exit;
      case AceType of
        0,1,2,3,9,10,13,14,17,18,19,20,21: SidPos:=8;
        4: SidPos:=12;
        5,6,7,8,11,12,15,16:
          begin
            if Size<12 then Exit;
            Flags:=U32(P+8); if (Flags and not Cardinal(3))<>0 then Exit;
            SidPos:=12;
            if (Flags and 1)<>0 then Inc(SidPos,16);
            if (Flags and 2)<>0 then Inc(SidPos,16);
          end;
        // shortcut: reject unknown ACE types until their layout can be validated.
        else Exit;
      end;
      if not ValidSid(P+SidPos,P+Size) then Exit;
      Inc(P,Size); Dec(Count);
    end;
    Result:=True;
  end;
begin
  Result:=False;
  if (Length(Data)<20) or (Length(Data)>1024*1024) or (Data[0]<>1) then Exit;
  Control:=U16(2);
  if ((Control and $8000)=0) or ((Control and 4)=0) then Exit;
  Owner:=U32(4); Group:=U32(8); Sacl:=U32(12); Dacl:=U32(16);
  if (Owner<20) or (Group<20) or ((Owner and 3)<>0) or ((Group and 3)<>0) or
    (Owner>Cardinal(Length(Data)-8)) or (Group>Cardinal(Length(Data)-8)) then Exit;
  if not ValidSid(Owner,Length(Data)) or not ValidSid(Group,Length(Data)) then Exit;
  if ((Control and $10)=0) and (Sacl<>0) then Exit;
  Result:=ValidAcl(Sacl) and ValidAcl(Dacl);
end;
type
  TGpoClientEvidenceTransport=class(TInterfacedObject,IGpoLdapEvidenceTransport)
  private
    fClient:TLdapClient;
  public
    constructor Create(Client:TLdapClient);
    function State(out Value:TGpoLdapSessionState):Boolean;
    function GetSDFlags:TLdapSearchSDFlags;
    procedure SetSDFlags(Value:TLdapSearchSDFlags);
    function Search(const DN,Filter:RawUtf8; const Attributes:array of RawUtf8):TLdapResult;
  end;
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

function GpoBeginReadOnlyPreflight(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  const Plan:TGpoOfflinePlan; out Bound:TGpoBoundPlan):TGpoPreflightResult;
var Before,After:TGpoLdapEvidence; Files:TGpoObservedFiles; Complete:Boolean;
begin
  Bound:=nil; Complete:=False;
  try
    try
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,Before); if Result<>gprEvidenceIncomplete then Exit;
      Result:=GpoCapturePreflightEvidence(Before.Target,Files); if Result<>gprEvidenceIncomplete then Exit;
      Result:=TGpoBoundPlan.BindWithFiles(Before,Plan,Files,Bound); if not Assigned(Bound) then Exit;
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,After); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Bound.CompareWithFiles(After,Files); Complete:=Result=gprEvidenceIncomplete;
    except Result:=gprReadUnavailable; end;
  finally if not Complete then FreeAndNil(Bound); end;
end;

function GpoCheckReadOnlyPreflight(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Bound:TGpoBoundPlan):TGpoPreflightResult;
var Before,After:TGpoLdapEvidence; Files:TGpoObservedFiles;
begin
  if not Assigned(Bound) then Exit(gprInvalid);
  try
    Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,Before); if Result<>gprEvidenceIncomplete then Exit;
    Result:=GpoCapturePreflightEvidence(Before.Target,Files); if Result<>gprEvidenceIncomplete then Exit;
    Result:=Bound.CompareWithFiles(Before,Files); if Result<>gprEvidenceIncomplete then Exit;
    Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,After); if Result<>gprEvidenceIncomplete then Exit;
    Result:=Bound.CompareWithFiles(After,Files);
  except Result:=gprReadUnavailable; end;
end;

function ValidObservedFile(Artifact:TGpoFile; const Item:TGpoObservedFile):Boolean; forward;

function GpoCapturePreflightEvidence(const Target:TGpoPreflightTarget; out Files:TGpoObservedFiles):TGpoPreflightResult;
var Token:ILdapSessionToken; Control:TGpoReadControl; Artifact:TGpoFile; Path:string;
begin
  Files:=Default(TGpoObservedFiles);
  for Artifact:=Low(TGpoFile) to High(TGpoFile) do Files.Items[Artifact].Status:=grsIoError;
  if not Assigned(Target.Session) or not Supports(Target.Session,ILdapSessionToken,Token) or
     not Token.IsValid then Exit(gprSessionInvalid);
  if (Target.DN='') or (Length(Target.ObjectGuid)<>16) or SameText(Target.Domain,Target.DC) or
     (GpoBuildSafePath(Target.FileSysPath,Target.Domain,Target.DC,Target.Guid,gfGptIni,Path)<>grsOk) then Exit(gprInvalid);
  Control:=TGpoReadControl.Create(30000,Target.Session);
  try
    for Artifact:=Low(TGpoFile) to High(TGpoFile) do
    begin
      Files.Items[Artifact].Attempted:=True;
      Files.Items[Artifact].Status:=GpoReadFileEvidence(Target.FileSysPath,Target.Domain,Target.DC,Target.Guid,
        Artifact,Files.Items[Artifact].Data,Files.Items[Artifact].Observation,Files.Items[Artifact].Metadata,Control);
      if not Token.IsValid then Exit(gprSessionInvalid);
      if not ValidObservedFile(Artifact,Files.Items[Artifact]) then Exit(gprReadUnavailable);
    end;
    Files.Target:=Target; Files.Target.ObjectGuid:=Copy(Target.ObjectGuid); Files.Captured:=True;
    if not Token.IsValid then begin Files.Captured:=False; Exit(gprSessionInvalid); end;
    Result:=gprEvidenceIncomplete;
  finally Control.Free; end;
end;

class function TGpoBoundPlan.BindEvidence(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
  out Bound:TGpoBoundPlan):TGpoPreflightResult;
var SD:mormot.core.os.security.TSecurityDescriptor;
begin
  Bound:=nil;
  if (Evidence.SecurityStatus<>gseUnverified) or (Evidence.USNChanged=0) or (Length(Evidence.SecurityDescriptor)=0) or
     not SD.FromBinary(mormot.core.base.PByteArray(@Evidence.SecurityDescriptor[0]),Length(Evidence.SecurityDescriptor)) then Exit(gprReadUnavailable);
  if Evidence.Version<>Plan.Baseline.GpcVersion then Exit(gprConflict);
  Result:=Bind(Evidence.Target,Plan,Bound);
  if not Assigned(Bound) then Exit;
  Bound.fUSN:=Evidence.USNChanged; Bound.fFlags:=Evidence.Flags;
  Bound.fSecurityDescriptor:=Copy(Evidence.SecurityDescriptor); Bound.fLdapCaptured:=True;
end;

function SamePreflightTarget(const A,B:TGpoPreflightTarget):Boolean;
begin
  Result:=Assigned(A.Session) and (A.Session=B.Session) and
    SameText(A.Domain,B.Domain) and SameText(A.DC,B.DC) and SameText(A.DN,B.DN) and
    SameText(A.Guid,B.Guid) and SameText(A.FileSysPath,B.FileSysPath) and
    (Length(A.ObjectGuid)=16) and (Length(B.ObjectGuid)=16) and CompareMem(@A.ObjectGuid[0],@B.ObjectGuid[0],16);
end;

function ValidObservedFile(Artifact:TGpoFile; const Item:TGpoObservedFile):Boolean;
begin
  Result:=Item.Attempted and
    (GpoCompareFileEvidence(Item.Metadata,Item.Metadata)=gprEvidenceIncomplete) and
    ((Item.Metadata.Attributes and $400)=0) and
    (((Item.Status=grsOk) and (Item.Observation=gfoPresent) and (Item.Metadata.Kind=gekFile) and
       ((Item.Metadata.Attributes and $10)=0)) or
     ((Artifact<>gfGptIni) and (Item.Status=grsMissing) and (Item.Observation=gfoLeafAbsent) and
       (Item.Metadata.Kind=gekParent) and ((Item.Metadata.Attributes and $10)<>0) and (Length(Item.Data)=0)));
end;

class function TGpoBoundPlan.BindWithFiles(const Evidence:TGpoLdapEvidence; const Plan:TGpoOfflinePlan;
  const Files:TGpoObservedFiles; out Bound:TGpoBoundPlan):TGpoPreflightResult;
var Artifact:TGpoFile; Completed:Boolean;
begin
  Bound:=nil;
  if not Files.Captured then Exit(gprReadUnavailable);
  Result:=BindEvidence(Evidence,Plan,Bound);
  if not Assigned(Bound) then Exit;
  Completed:=False;
  try
    if not SamePreflightTarget(Evidence.Target,Files.Target) then begin Result:=gprTargetMismatch; Exit; end;
    for Artifact:=Low(TGpoFile) to High(TGpoFile) do
      if not ValidObservedFile(Artifact,Files.Items[Artifact]) then
      begin Result:=gprReadUnavailable; Exit; end;
    Result:=Bound.CompareEvidence(Evidence,Files.Items[gfGptIni].Status,Files.Items[gfGptIni].Data,
      Files.Items[gfUserRegistry].Status,Files.Items[gfUserRegistry].Observation,Files.Items[gfUserRegistry].Data,
      Files.Items[gfMachineRegistry].Status,Files.Items[gfMachineRegistry].Observation,Files.Items[gfMachineRegistry].Data);
    if Result<>gprEvidenceIncomplete then Exit;
    for Artifact:=Low(TGpoFile) to High(TGpoFile) do
    begin
      Bound.fFileEvidence[Artifact]:=Files.Items[Artifact].Metadata;
      Bound.fFileEvidence[Artifact].SecurityDescriptor:=Copy(Files.Items[Artifact].Metadata.SecurityDescriptor);
    end;
    if not Bound.fToken.IsValid then begin Result:=gprSessionInvalid; Exit; end;
    Bound.fFilesCaptured:=True; Completed:=True;
  finally if not Completed then FreeAndNil(Bound); end;
end;

destructor TGpoObservedDraft.Destroy;
begin
  fBound.Free;
  inherited Destroy;
end;

function TGpoObservedDraft.MatchesObjectGuid(const Expected:TBytes):Boolean;
begin
  Result:=Assigned(fBound) and Assigned(fBound.fToken) and fBound.fToken.IsValid and
    (Length(Expected)=16) and (Length(fBound.fTarget.ObjectGuid)=16) and
    CompareMem(@Expected[0],@fBound.fTarget.ObjectGuid[0],16);
end;

function TGpoObservedDraft.GetBaseline(out User,Machine:TGpoPolicyImage):Boolean;
begin
  User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
  Result:=Assigned(fBound) and Assigned(fBound.fToken) and fBound.fToken.IsValid;
  if not Result then Exit;
  User.Exists:=fUser.Exists; User.Data:=Copy(fUser.Data);
  Machine.Exists:=fMachine.Exists; Machine.Data:=Copy(fMachine.Data);
  Result:=fBound.fToken.IsValid;
  if not Result then begin User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage); end;
end;

class function TGpoObservedDraft.Bind(const Evidence:TGpoLdapEvidence;
  const Files:TGpoObservedFiles; out Draft:TGpoObservedDraft):TGpoPreflightResult;
var User,Machine:TGpoPolicyImage; Gpt:Cardinal; Plan:TGpoOfflinePlan; Bound:TGpoBoundPlan;
  Artifact:TGpoFile;
begin
  Draft:=nil;
  if not Files.Captured then Exit(gprReadUnavailable);
  for Artifact:=Low(TGpoFile) to High(TGpoFile) do
    if not ValidObservedFile(Artifact,Files.Items[Artifact]) then Exit(gprReadUnavailable);
  if ParseGptIni(Files.Items[gfGptIni].Data,Gpt)<>grsOk then Exit(gprReadUnavailable);
  User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
  User.Exists:=Files.Items[gfUserRegistry].Status=grsOk;
  Machine.Exists:=Files.Items[gfMachineRegistry].Status=grsOk;
  User.Data:=Copy(Files.Items[gfUserRegistry].Data);
  Machine.Data:=Copy(Files.Items[gfMachineRegistry].Data);
  if GpoBuildOfflinePlanWithPresence(Evidence.Version,Gpt,Files.Items[gfGptIni].Data,
    User,User,Machine,Machine,Plan)<>gopOk then Exit(gprInvalid);
  Result:=TGpoBoundPlan.BindWithFiles(Evidence,Plan,Files,Bound);
  if not Assigned(Bound) then Exit;
  try
    try
      Draft:=TGpoObservedDraft.Create;
      Draft.fBound:=Bound; Bound:=nil;
      Draft.fVersion:=Evidence.Version; Draft.fIni:=Copy(Files.Items[gfGptIni].Data);
      Draft.fUser:=User; Draft.fMachine:=Machine;
      if not Draft.fBound.fToken.IsValid then begin FreeAndNil(Draft); Result:=gprSessionInvalid; end;
    except FreeAndNil(Draft); raise; end;
  finally Bound.Free; end;
end;

function TGpoObservedDraft.BuildPlan(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles;
  const UserCandidate,MachineCandidate:TGpoPolicyImage; out Plan:TGpoOfflinePlan):TGpoPreflightResult;
var Candidate:TGpoOfflinePlan; Gpt:Cardinal;
begin
  Plan:=Default(TGpoOfflinePlan);
  if not Assigned(fBound) then Exit(gprInvalid);
  Result:=fBound.CompareWithFiles(Evidence,Files);
  if Result<>gprEvidenceIncomplete then Exit;
  if (ParseGptIni(fIni,Gpt)<>grsOk) or
    (GpoBuildOfflinePlanWithPresence(fVersion,Gpt,fIni,fUser,UserCandidate,
      fMachine,MachineCandidate,Candidate)<>gopOk) then Exit(gprInvalid);
  Result:=fBound.CompareWithFiles(Evidence,Files);
  if Result=gprEvidenceIncomplete then Plan:=Candidate;
end;

function TGpoObservedDraft.BindPlan(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles;
  const UserCandidate,MachineCandidate:TGpoPolicyImage; out Bound:TGpoBoundPlan):TGpoPreflightResult;
var Plan:TGpoOfflinePlan; Complete:Boolean;
begin
  Bound:=nil; Complete:=False;
  try
    Result:=BuildPlan(Evidence,Files,UserCandidate,MachineCandidate,Plan);
    if Result<>gprEvidenceIncomplete then Exit;
    Result:=TGpoBoundPlan.BindWithFiles(Evidence,Plan,Files,Bound);
    if not Assigned(Bound) then Exit;
    Result:=fBound.CompareWithFiles(Evidence,Files);
    Complete:=Result=gprEvidenceIncomplete;
  finally if not Complete then FreeAndNil(Bound); end;
end;

function GpoCaptureObservedDraft(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Draft:TGpoObservedDraft):TGpoPreflightResult;
var Before,After:TGpoLdapEvidence; Files:TGpoObservedFiles; Complete:Boolean;
begin
  Draft:=nil; Complete:=False;
  try
    try
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,Before); if Result<>gprEvidenceIncomplete then Exit;
      Result:=GpoCapturePreflightEvidence(Before.Target,Files); if Result<>gprEvidenceIncomplete then Exit;
      Result:=TGpoObservedDraft.Bind(Before,Files,Draft); if not Assigned(Draft) then Exit;
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,After); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Draft.fBound.CompareWithFiles(After,Files); Complete:=Result=gprEvidenceIncomplete;
    except Result:=gprReadUnavailable; end;
  finally if not Complete then FreeAndNil(Draft); end;
end;

function GpoBuildObservedDraftPlan(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Draft:TGpoObservedDraft; const UserCandidate,MachineCandidate:TGpoPolicyImage;
  out Plan:TGpoOfflinePlan):TGpoPreflightResult;
var Before,After:TGpoLdapEvidence; Files:TGpoObservedFiles; Candidate:TGpoOfflinePlan; Complete:Boolean;
begin
  Plan:=Default(TGpoOfflinePlan); Complete:=False;
  if not Assigned(Draft) then Exit(gprInvalid);
  try
    try
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,Before); if Result<>gprEvidenceIncomplete then Exit;
      Result:=GpoCapturePreflightEvidence(Before.Target,Files); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Draft.BuildPlan(Before,Files,UserCandidate,MachineCandidate,Candidate); if Result<>gprEvidenceIncomplete then Exit;
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,After); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Draft.fBound.CompareWithFiles(After,Files); Complete:=Result=gprEvidenceIncomplete;
      if Complete then Plan:=Candidate;
    except Result:=gprReadUnavailable; end;
  finally if not Complete then Plan:=Default(TGpoOfflinePlan); end;
end;

function GpoBindObservedDraftPlan(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  Draft:TGpoObservedDraft; const UserCandidate,MachineCandidate:TGpoPolicyImage;
  out Bound:TGpoBoundPlan):TGpoPreflightResult;
var Before,After:TGpoLdapEvidence; Files:TGpoObservedFiles; Complete:Boolean;
begin
  Bound:=nil; Complete:=False;
  if not Assigned(Draft) then Exit(gprInvalid);
  try
    try
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,Before); if Result<>gprEvidenceIncomplete then Exit;
      Result:=GpoCapturePreflightEvidence(Before.Target,Files); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Draft.BindPlan(Before,Files,UserCandidate,MachineCandidate,Bound); if not Assigned(Bound) then Exit;
      Result:=GpoCaptureLdapEvidence(Client,ExpectedDN,ExpectedGuid,After); if Result<>gprEvidenceIncomplete then Exit;
      Result:=Bound.CompareWithFiles(After,Files); Complete:=Result=gprEvidenceIncomplete;
    except Result:=gprReadUnavailable; end;
  finally if not Complete then FreeAndNil(Bound); end;
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
  if not fLdapCaptured or (Evidence.SecurityStatus<>gseUnverified) or (Evidence.USNChanged=0) or (Length(Evidence.SecurityDescriptor)=0) or
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

function TGpoBoundPlan.CompareWithFiles(const Evidence:TGpoLdapEvidence; const Files:TGpoObservedFiles):TGpoPreflightResult;
var Artifact:TGpoFile;
begin
  if not Assigned(fToken) or not fToken.IsValid then Exit(gprSessionInvalid);
  if not fFilesCaptured or not Files.Captured then Exit(gprReadUnavailable);
  if not SamePreflightTarget(Evidence.Target,Files.Target) then Exit(gprTargetMismatch);
  Result:=CompareEvidence(Evidence,Files.Items[gfGptIni].Status,Files.Items[gfGptIni].Data,
    Files.Items[gfUserRegistry].Status,Files.Items[gfUserRegistry].Observation,Files.Items[gfUserRegistry].Data,
    Files.Items[gfMachineRegistry].Status,Files.Items[gfMachineRegistry].Observation,Files.Items[gfMachineRegistry].Data);
  if Result<>gprEvidenceIncomplete then Exit;
  for Artifact:=Low(TGpoFile) to High(TGpoFile) do
  begin
    if not ValidObservedFile(Artifact,Files.Items[Artifact]) then Exit(gprReadUnavailable);
    Result:=GpoCompareFileEvidence(fFileEvidence[Artifact],Files.Items[Artifact].Metadata);
    if Result<>gprEvidenceIncomplete then Exit;
  end;
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
  E.SecurityStatus:=gseUnverified;
  Evidence:=E; Result:=gprEvidenceIncomplete;
end;

constructor TGpoClientEvidenceTransport.Create(Client:TLdapClient);
begin inherited Create; fClient:=Client; end;
function TGpoClientEvidenceTransport.State(out Value:TGpoLdapSessionState):Boolean;
begin
  Value:=Default(TGpoLdapSessionState);
  Result:=Assigned(fClient) and Assigned(fClient.Settings) and Assigned(fClient.Sock);
  if not Result then Exit;
  Value.Session:=fClient.SessionToken; Value.Connected:=fClient.Connected; Value.Bound:=fClient.Bound;
  Value.Host:=fClient.Settings.TargetHost; Value.Port:=fClient.Settings.TargetPort;
  Value.UserName:=fClient.BoundUser; Value.Server:=fClient.Sock.Server; Value.DefaultDN:=fClient.DefaultDN;
  Value.Socket:=Pointer(fClient.Sock);
end;
function TGpoClientEvidenceTransport.GetSDFlags:TLdapSearchSDFlags; begin Result:=fClient.SearchSDFlags; end;
procedure TGpoClientEvidenceTransport.SetSDFlags(Value:TLdapSearchSDFlags); begin fClient.SearchSDFlags:=Value; end;
function TGpoClientEvidenceTransport.Search(const DN,Filter:RawUtf8; const Attributes:array of RawUtf8):TLdapResult;
begin Result:=fClient.SearchObject(DN,Filter,Attributes); end;

function GpoCaptureLdapEvidence(Client:TLdapClient; const ExpectedDN,ExpectedGuid:string;
  out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
var Transport:IGpoLdapEvidenceTransport;
begin
  Evidence:=Default(TGpoLdapEvidence);
  if not Assigned(Client) then Exit(gprSessionInvalid);
  Transport:=TGpoClientEvidenceTransport.Create(Client);
  Result:=GpoCaptureLdapFromTransport(Transport,ExpectedDN,ExpectedGuid,Evidence);
end;

function GpoCaptureLdapFromTransport(const Transport:IGpoLdapEvidenceTransport;
  const ExpectedDN,ExpectedGuid:string; out Evidence:TGpoLdapEvidence):TGpoPreflightResult;
var Token:ILdapSessionToken; SavedFlags:TLdapSearchSDFlags;
  Root:TLdapResult; Original,NowState:TGpoLdapSessionState; Domain,DC:string;
  E:TGpoLdapEvidence; ParseResult:TGpoPreflightResult;
  function SameSession:Boolean;
  begin
    Result:=Transport.State(NowState) and NowState.Connected and NowState.Bound and
      Assigned(Token) and Token.IsValid and (NowState.Session=Original.Session) and
      (NowState.Socket=Original.Socket) and (NowState.Host=Original.Host) and
      (NowState.Port=Original.Port) and (NowState.UserName=Original.UserName) and
      (NowState.Server=Original.Server) and (NowState.DefaultDN=Original.DefaultDN);
  end;
begin
  Evidence:=Default(TGpoLdapEvidence); E:=Default(TGpoLdapEvidence);
  try
  if not Assigned(Transport) or not Transport.State(Original) or not Original.Connected or
     not Original.Bound or (Original.UserName='') or not Assigned(Original.Socket) then Exit(gprSessionInvalid);
  if not Assigned(Original.Session) or not Supports(Original.Session,ILdapSessionToken,Token) or not Token.IsValid then Exit(gprSessionInvalid);
  if (ExpectedDN='') or not GpoValidGuid(ExpectedGuid) then Exit(gprInvalid);
  SavedFlags:=Transport.GetSDFlags;
  try
    try
      Transport.SetSDFlags([]);
      if not SameSession then Exit(gprSessionInvalid);
      Root:=Transport.Search('','',['dnsHostName','defaultNamingContext','supportedControl']);
      if not SameSession then Exit(gprSessionInvalid);
      if not Assigned(Root) or not Assigned(Root.Find('dnsHostName')) or
         not Assigned(Root.Find('defaultNamingContext')) or not Assigned(Root.Find('supportedControl')) or
         (Root.Find('supportedControl').FindIndex(LDAP_SERVER_SD_FLAGS_OID)<0) then Exit(gprReadUnavailable);
      DC:=Root.Find('dnsHostName').GetReadable;
      if not SameText(Root.Find('defaultNamingContext').GetReadable,Original.DefaultDN) then Exit(gprTargetMismatch);
      Domain:=DNToCN(Original.DefaultDN,True,[dnDC]);
      if (Domain='') or (DC='') or SameText(Domain,DC) or not SameText(DC,Original.Host) then Exit(gprTargetMismatch);
      Transport.SetSDFlags(lsfMain);
      if not SameSession then Exit(gprSessionInvalid);
      Root:=Transport.Search(ExpectedDN,'(objectClass=groupPolicyContainer)',
        ['name','objectGUID','gPCFileSysPath','versionNumber','flags','uSNChanged','nTSecurityDescriptor']);
      if not SameSession then Exit(gprSessionInvalid);
      ParseResult:=GpoParseLdapGpc(Root,Domain,DC,ExpectedDN,ExpectedGuid,E);
      if ParseResult<>gprEvidenceIncomplete then Exit(ParseResult);
      E.Target.Session:=Original.Session;
      if not SameSession then Exit(gprSessionInvalid);
      Evidence:=E; Result:=gprEvidenceIncomplete;
    except
      Evidence:=Default(TGpoLdapEvidence); Result:=gprReadUnavailable;
    end;
  finally Transport.SetSDFlags(SavedFlags); end;
  except
    Evidence:=Default(TGpoLdapEvidence); Result:=gprReadUnavailable;
  end;
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
  out H: THandle; out IsMount: Boolean; NativeStatus:PCardinal = nil;
  NeedSecurity:Boolean = False): TGpoReadStatus;
var U: TGpoNativeString; A: TGpoNativeAttributes; IO: TGpoNativeIoStatus;
  Status: LongInt; Info: TByHandleFileInformation;
  Tag: TGpoAttributeTagInfo; Options,Access: ULONG;
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
  Access:=$00100081; if NeedSecurity then Access:=Access or $00020000; // READ_CONTROL
  Status := NtOpenFile(H,Access,A,IO,FILE_SHARE_READ,Options);
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
  out Data: TBytes; Control: TGpoReadControl; out Observation:TGpoFileObservation;
  Evidence:Pointer = nil): TGpoReadStatus;
var Parts: array of UnicodeString; Guards: array of THandle;
  I, J, Start: SizeInt; Path: UnicodeString; H,ParentHandle: THandle; IsMount: Boolean;
  Info,AfterInfo: TByHandleFileInformation; Count, Got, NativeStatus: DWORD; Extra: Byte; Stop:TGpoReadStatus;
  SD,AfterSD:TBytes; Temp:TGpoFileEvidence;
  function ReadSecurity(Handle:THandle; out Bytes:TBytes):TGpoReadStatus;
  var Needed,Code:DWORD; Owner,Group:PSID; Dacl:PACL; Present,Defaulted:LongBool;
  begin
    Bytes:=nil; Needed:=0;
    if GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or GROUP_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,nil,0,@Needed) then Exit(grsUnsupported);
    Code:=GetLastError; if Code<>ERROR_INSUFFICIENT_BUFFER then Exit(FileError(Code));
    if (Needed=0) or (Needed>1024*1024) then Exit(grsUnsupported);
    SetLength(Bytes,Needed);
    if not GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or GROUP_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
      PSECURITY_DESCRIPTOR(@Bytes[0]),Needed,@Needed) then begin Bytes:=nil; Exit(FileError(GetLastError)); end;
    if not ValidFileSecurityEvidence(Bytes) then begin Bytes:=nil; Exit(grsCorrupt); end;
    Owner:=nil; Group:=nil; Dacl:=nil; Present:=False; Defaulted:=False;
    if not GetSecurityDescriptorOwner(PSECURITY_DESCRIPTOR(@Bytes[0]),Owner,@Defaulted) or (Owner=nil) or
       not GetSecurityDescriptorGroup(PSECURITY_DESCRIPTOR(@Bytes[0]),Group,@Defaulted) or (Group=nil) or
       not GetSecurityDescriptorDacl(PSECURITY_DESCRIPTOR(@Bytes[0]),@Present,Dacl,@Defaulted) or not Present then
    begin Bytes:=nil; Exit(grsUnsupported); end;
    Result:=grsOk;
  end;
  function SameInfo(const A,B:TByHandleFileInformation):Boolean;
  begin
    Result:=(A.dwVolumeSerialNumber=B.dwVolumeSerialNumber) and (A.nFileIndexHigh=B.nFileIndexHigh) and
      (A.nFileIndexLow=B.nFileIndexLow) and (A.dwFileAttributes=B.dwFileAttributes) and
      (A.nFileSizeHigh=B.nFileSizeHigh) and (A.nFileSizeLow=B.nFileSizeLow) and
      (A.ftLastWriteTime.dwLowDateTime=B.ftLastWriteTime.dwLowDateTime) and
      (A.ftLastWriteTime.dwHighDateTime=B.ftLastWriteTime.dwHighDateTime);
  end;
  procedure StoreMetadata(Kind:TGpoEvidenceKind);
  begin
    Temp:=Default(TGpoFileEvidence); Temp.Kind:=Kind; Temp.VolumeSerial:=Info.dwVolumeSerialNumber;
    Temp.FileIndexHigh:=Info.nFileIndexHigh; Temp.FileIndexLow:=Info.nFileIndexLow;
    Temp.Attributes:=Info.dwFileAttributes; Temp.LastWriteHigh:=Info.ftLastWriteTime.dwHighDateTime;
    Temp.LastWriteLow:=Info.ftLastWriteTime.dwLowDateTime; Temp.SecurityDescriptor:=SD; Temp.Available:=True;
  end;
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
    Result := OpenNativeReadOnly(Path,True,True,False,H,IsMount,nil,Assigned(Evidence) and (Length(Parts)=1));
    if Result <> grsOk then Exit;
    KeepGuard;
    if IsMount then
    begin
      // Hold both checked MOUNT_POINT link and its resolved normal target root.
      // OBJ_DONT_REPARSE stays enabled; local/client symlink following fails.
      Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
      Result := OpenNativeReadOnly(Path,True,False,True,H,IsMount,nil,Assigned(Evidence) and (Length(Parts)=1));
      if Result <> grsOk then Exit;
      KeepGuard;
    end;
    for I := 0 to High(Parts)-1 do
    begin
      Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
      Path := Path + '\' + Parts[I];
      Result := OpenNativeReadOnly(Path,True,False,False,H,IsMount,nil,Assigned(Evidence) and (I=High(Parts)-1));
      if Result <> grsOk then Exit;
      KeepGuard;
    end;
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    Path := Path + '\' + Parts[High(Parts)];
    Result := OpenNativeReadOnly(Path,False,False,False,H,IsMount,@NativeStatus,Assigned(Evidence));
    if Result <> grsOk then
    begin
      Stop:=ReadControlStatus(Control); if Stop<>grsOk then begin Result:=Stop; Exit; end;
      if (Result=grsMissing) and (NativeStatus=$c0000034) then
      begin
        if Assigned(Evidence) then
        begin
          ParentHandle:=Guards[High(Guards)];
          if not GetFileInformationByHandle(ParentHandle,Info) then Exit(FileError(GetLastError));
          if (Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0) then Exit(grsUnsupported);
          Result:=ReadSecurity(ParentHandle,SD); if Result<>grsOk then Exit;
          Result:=ReadControlStatus(Control); if Result<>grsOk then Exit;
          Result:=OpenNativeReadOnly(Path,False,False,False,H,IsMount,@NativeStatus);
          if Result=grsOk then Exit(grsIoError);
          if (Result<>grsMissing) or (NativeStatus<>$c0000034) then Exit;
          if not GetFileInformationByHandle(ParentHandle,AfterInfo) then Exit(FileError(GetLastError));
          Result:=ReadSecurity(ParentHandle,AfterSD); if Result<>grsOk then Exit;
          if not SameInfo(Info,AfterInfo) or (Length(SD)<>Length(AfterSD)) or
             not CompareMem(@SD[0],@AfterSD[0],Length(SD)) then Exit(grsIoError);
          Result:=ReadControlStatus(Control); if Result<>grsOk then Exit;
          StoreMetadata(gekParent); PGpoFileEvidence(Evidence)^:=Temp;
          Result:=grsMissing;
        end;
        Observation:=gfoLeafAbsent;
      end;
      Exit;
    end;
    Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
    if not GetFileInformationByHandle(H,Info) then Exit(FileError(GetLastError));
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0 then Exit(grsReparseBlocked);
    if (Info.nFileSizeHigh <> 0) or (Info.nFileSizeLow > GpoMaxFileBytes) then Exit(grsTooLarge);
    if Assigned(Evidence) then begin
      if (Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0) then Exit(grsUnsupported);
      Result:=ReadSecurity(H,SD); if Result<>grsOk then Exit;
    end;
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
    if Assigned(Evidence) then
    begin
      if not GetFileInformationByHandle(H,AfterInfo) then Exit(FileError(GetLastError));
      Result:=ReadSecurity(H,AfterSD); if Result<>grsOk then Exit;
      if not SameInfo(Info,AfterInfo) or (Length(SD)<>Length(AfterSD)) or
         not CompareMem(@SD[0],@AfterSD[0],Length(SD)) then Exit(grsIoError);
      StoreMetadata(gekFile);
    end;
    Result := ReadControlStatus(Control);
    if Result=grsOk then begin Observation:=gfoPresent; if Assigned(Evidence) then PGpoFileEvidence(Evidence)^:=Temp; end;
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
function GpoTestReadGuardedEvidence(const NativeRoot, RelativePath:UnicodeString;
  out Data:TBytes; out Observation:TGpoFileObservation; out Evidence:TGpoFileEvidence):TGpoReadStatus;
begin
  Evidence:=Default(TGpoFileEvidence);
  Result:=ReadGuardedFile(NativeRoot,RelativePath,Data,nil,Observation,@Evidence);
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

function GpoReadFileEvidence(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid:string; Artifact:TGpoFile; out Data:TBytes; out Observation:TGpoFileObservation;
  out Evidence:TGpoFileEvidence; Control:TGpoReadControl):TGpoReadStatus;
var Path:string;
{$ifdef windows} Root:string; {$endif}
begin
  Data:=nil; Observation:=gfoUnavailable; Evidence:=Default(TGpoFileEvidence);
  Result:=ReadControlStatus(Control); if Result<>grsOk then Exit;
  Result:=GpoBuildNativePath(FileSysPath,ExpectedDomain,ConnectedDC,Guid,Artifact,Path);
  if Result<>grsOk then Exit;
  {$ifdef windows}
  Root:='\Device\Mup\'+ConnectedDC+'\SYSVOL\'+ExpectedDomain;
  Result:=ReadGuardedFile(UTF8Decode(Root),UTF8Decode(Copy(Path,Length(Root)+2,MaxInt)),Data,Control,Observation,@Evidence);
  {$else}
  Result:=grsUnsupported;
  {$endif}
end;

function GpoCompareFileEvidence(const Before,After:TGpoFileEvidence):TGpoPreflightResult;
begin
  if not Before.Available or not After.Available or
     not (Before.Kind in [gekFile,gekParent]) or not (After.Kind in [gekFile,gekParent]) or
     not ValidFileSecurityEvidence(Before.SecurityDescriptor) or not ValidFileSecurityEvidence(After.SecurityDescriptor) or
     ((Before.FileIndexHigh=0) and (Before.FileIndexLow=0)) or
     ((After.FileIndexHigh=0) and (After.FileIndexLow=0)) then Exit(gprReadUnavailable);
  if (Before.Kind<>After.Kind) or (Before.VolumeSerial<>After.VolumeSerial) or (Before.FileIndexHigh<>After.FileIndexHigh) or
     (Before.FileIndexLow<>After.FileIndexLow) or (Before.Attributes<>After.Attributes) or
     (Before.LastWriteHigh<>After.LastWriteHigh) or (Before.LastWriteLow<>After.LastWriteLow) or
     (Length(Before.SecurityDescriptor)<>Length(After.SecurityDescriptor)) or
     not CompareMem(@Before.SecurityDescriptor[0],@After.SecurityDescriptor[0],Length(Before.SecurityDescriptor)) then Exit(gprConflict);
  Result:=gprEvidenceIncomplete;
end;

end.
