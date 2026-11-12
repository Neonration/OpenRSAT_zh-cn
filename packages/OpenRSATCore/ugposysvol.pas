unit ugposysvol;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, ugpoformats, mormot.net.ldap;

type
  TGpoFile = (gfGptIni, gfMachineRegistry, gfUserRegistry);
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

// Uses the same canonical validation, then bypasses the Win32 UNC alias only.
function GpoBuildNativePath(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out NativePath: string): TGpoReadStatus;
function GpoNtStatusToReadStatus(Status: Cardinal): TGpoReadStatus;
{$if defined(windows) and defined(OPENRSATTESTS)}
// Test-only seam: identical guarded traversal, unavailable in production builds.
function GpoTestReadGuardedFile(const NativeRoot, RelativePath: UnicodeString;
  out Data: TBytes): TGpoReadStatus;
{$endif}

implementation

{$ifdef windows}
uses Windows;
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
  out H: THandle; out IsMount: Boolean): TGpoReadStatus;
var U: TGpoNativeString; A: TGpoNativeAttributes; IO: TGpoNativeIoStatus;
  Status: LongInt; Info: TByHandleFileInformation;
  Tag: TGpoAttributeTagInfo; Options: ULONG;
begin
  H := INVALID_HANDLE_VALUE; IsMount := False;
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
  out Data: TBytes; Control: TGpoReadControl): TGpoReadStatus;
var Parts: array of UnicodeString; Guards: array of THandle;
  I, J, Start: SizeInt; Path: UnicodeString; H: THandle; IsMount: Boolean;
  Info: TByHandleFileInformation; Count, Got: DWORD; Extra: Byte;
  procedure KeepGuard;
  begin
    SetLength(Guards,Length(Guards)+1); Guards[High(Guards)] := H;
    H := INVALID_HANDLE_VALUE;
  end;
begin
  Data := nil; Parts := nil; Guards := nil; H := INVALID_HANDLE_VALUE;
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
    Result := OpenNativeReadOnly(Path,False,False,False,H,IsMount);
    if Result <> grsOk then Exit;
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
  finally
    if H <> INVALID_HANDLE_VALUE then CloseHandle(H);
    for I := High(Guards) downto 0 do CloseHandle(Guards[I]);
    if Result <> grsOk then Data := nil;
  end;
end;

{$ifdef OPENRSATTESTS}
function GpoTestReadGuardedFile(const NativeRoot, RelativePath: UnicodeString;
  out Data: TBytes): TGpoReadStatus;
begin
  Result := ReadGuardedFile(NativeRoot,RelativePath,Data,nil);
end;
{$endif}
{$endif}

function GpoReadFile(const FileSysPath, ExpectedDomain, ConnectedDC,
  Guid: string; Artifact: TGpoFile; out Data: TBytes;
  Control: TGpoReadControl): TGpoReadStatus;
var Path: string;
{$ifdef windows}
  Root: string;
{$endif}
begin
  Data := nil;
  Result := ReadControlStatus(Control); if Result <> grsOk then Exit;
  Result := GpoBuildNativePath(FileSysPath,ExpectedDomain,ConnectedDC,Guid,Artifact,Path);
  if Result <> grsOk then Exit;
{$ifdef windows}
  Root := '\Device\Mup\' + ConnectedDC + '\SYSVOL\' + ExpectedDomain;
  Result := ReadGuardedFile(UTF8Decode(Root),UTF8Decode(Copy(Path,Length(Root)+2,MaxInt)),Data,Control);
{$else}
  Result := grsUnsupported;
{$endif}
end;

end.
