unit ugpolocalbackend;
{$mode objfpc}{$H+}
interface
uses SysUtils,ugpoformats{$ifdef windows},Windows{$endif};
type
  TLocalSide=(lsMachine,lsUser);
  TLocalResult=(lrOk,lrConflict,lrUnavailable,lrUnknown,lrInvalid);
  TLocalFault=(lfNone,lfBeforeMutation,lfAfterMutation);
  TStageFault=(sfNone,sfBeforeBackup,sfAfterBackup,sfPartialCandidate);
  TLocalSnapshot=record
    Exists:Boolean; Volume,IndexHigh,IndexLow:Cardinal; Data:TBytes;
  end;
  TStageEvidence=record
    Original,Backup,Candidate:TLocalSnapshot;
    OriginalSecurity:TBytes;
  end;
  TLocalReceipt=class
  private
    Owner:TGUID; Side:TLocalSide; Original,After:TLocalSnapshot; Active:Boolean;
  end;
  TLocalBackend=class
  private
    {$ifdef windows} FDir:THandle; FId:TGUID; {$endif}
  public
    constructor Create(const Directory:string);
    destructor Destroy; override;
    function Ready:Boolean;
    function Observe(Side:TLocalSide; out Snapshot:TLocalSnapshot):TLocalResult;
    function PrepareReplacement(Side:TLocalSide; const Expected:TLocalSnapshot;
      const Candidate:TBytes; Fault:TStageFault; out Evidence:TStageEvidence):TLocalResult;
    function Publish(Side:TLocalSide; const Expected:TLocalSnapshot; const Desired:TGpoPolicyImage;
      Fault:TLocalFault; out Receipt:TLocalReceipt):TLocalResult;
    function Restore(Receipt:TLocalReceipt; Fault:TLocalFault):TLocalResult;
  end;
implementation
{$ifdef windows}
uses ugpojournalfile;
{$push}{$packrecords c}
type TNString=record Length,MaximumLength:Word; Buffer:PWideChar; end;
  TNAttrs=record Length:ULONG; RootDirectory:THandle; ObjectName:^TNString; Attributes:ULONG;
    SecurityDescriptor,SecurityQualityOfService:Pointer; end;
  TNIO=record StatusOrPointer,Information:PtrUInt; end;
{$pop}
function NtCreateFile(out H:THandle; Access:ACCESS_MASK; var A:TNAttrs; out Io:TNIO;
  AllocationSize:Pointer; FileAttributes,ShareAccess,Disposition,Options:ULONG; EaBuffer:Pointer; EaLength:ULONG):LongInt;
  stdcall; external 'ntdll.dll';
function SetFileInformationByHandle(H:THandle; InfoClass:LongInt; Info:Pointer; Size:DWORD):LongBool;
  stdcall; external 'kernel32.dll';
const MaxBytes=1024*1024;
function OpenNamed(Dir:THandle; const Name:UnicodeString; CreateNew:Boolean; out H:THandle):LongInt;
var U:TNString; A:TNAttrs; Io:TNIO; Disposition:ULONG;
begin
  FillChar(U,SizeOf(U),0); U.Length:=Length(Name)*2; U.MaximumLength:=U.Length+2; U.Buffer:=PWideChar(Name);
  FillChar(A,SizeOf(A),0); A.Length:=SizeOf(A); A.RootDirectory:=Dir; A.ObjectName:=@U; A.Attributes:=$1040;
  if CreateNew then Disposition:=2 else Disposition:=1;
  Result:=NtCreateFile(H,$00130083,A,Io,nil,FILE_ATTRIBUTE_NORMAL,0,Disposition,$00200060,nil,0);
  if Result<>0 then H:=INVALID_HANDLE_VALUE;
end;
function OpenSide(Dir:THandle; Side:TLocalSide; CreateNew:Boolean; out H:THandle):LongInt;
begin if Side=lsMachine then Result:=OpenNamed(Dir,'machine.pol',CreateNew,H)
  else Result:=OpenNamed(Dir,'user.pol',CreateNew,H); end;
function Capture(H:THandle; out S:TLocalSnapshot):Boolean;
var Info:TByHandleFileInformation; N,Extra:DWORD; Tail:Byte;
begin
  S:=Default(TLocalSnapshot); Result:=False;
  if not GetFileInformationByHandle(H,Info) or (Info.nNumberOfLinks<>1) or
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT))<>0) or
    (Info.nFileSizeHigh<>0) or (Info.nFileSizeLow>MaxBytes) or
    ((Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0)) then Exit;
  if SetFilePointer(H,0,nil,FILE_BEGIN)=$ffffffff then Exit;
  SetLength(S.Data,Info.nFileSizeLow);
  if (Length(S.Data)>0) and (not ReadFile(H,S.Data[0],Length(S.Data),N,nil) or (N<>DWORD(Length(S.Data)))) then Exit;
  if not ReadFile(H,Tail,1,Extra,nil) or (Extra<>0) then Exit;
  S.Exists:=True; S.Volume:=Info.dwVolumeSerialNumber; S.IndexHigh:=Info.nFileIndexHigh; S.IndexLow:=Info.nFileIndexLow;
  Result:=True;
end;
function Same(const A,B:TLocalSnapshot):Boolean;
begin Result:=(A.Exists=B.Exists) and (A.Volume=B.Volume) and (A.IndexHigh=B.IndexHigh) and
  (A.IndexLow=B.IndexLow) and (Length(A.Data)=Length(B.Data)) and
  ((Length(A.Data)=0) or CompareMem(@A.Data[0],@B.Data[0],Length(A.Data))); end;
function SameData(const A,B:TBytes):Boolean;
begin Result:=(Length(A)=Length(B)) and ((Length(A)=0) or CompareMem(@A[0],@B[0],Length(A))); end;
function SecurityBytes(H:THandle; out Data:TBytes):Boolean;
var N,M:DWORD;
begin
  Result:=False; Data:=nil; N:=0;
  if GetKernelObjectSecurity(H,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,nil,0,@N) then Exit;
  if (GetLastError<>ERROR_INSUFFICIENT_BUFFER) or (N=0) or (N>1024*1024) then Exit;
  SetLength(Data,N);
  Result:=GetKernelObjectSecurity(H,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR(@Data[0]),N,@M);
  if not Result then Data:=nil;
end;
function SetContents(H:THandle; const Data:TBytes):Boolean;
var N:DWORD;
begin
  Result:=False; if SetFilePointer(H,0,nil,FILE_BEGIN)=$ffffffff then Exit;
  if (Length(Data)>0) and (not WriteFile(H,Data[0],Length(Data),N,nil) or (N<>DWORD(Length(Data)))) then Exit;
  if not SetEndOfFile(H) or not FlushFileBuffers(H) then Exit;
  Result:=True;
end;
function RemoveFileByHandle(H:THandle):Boolean;
var DeleteFlag:Byte;
begin DeleteFlag:=1; Result:=SetFileInformationByHandle(H,4,@DeleteFlag,SizeOf(DeleteFlag)); end;
constructor TLocalBackend.Create(const Directory:string);
begin inherited Create; FDir:=INVALID_HANDLE_VALUE; if CreateGUID(FId)=0 then OpenDirectory(Directory,True,FDir); end;
destructor TLocalBackend.Destroy;
begin if FDir<>INVALID_HANDLE_VALUE then CloseHandle(FDir); inherited Destroy; end;
function TLocalBackend.Ready:Boolean;
begin Result:=FDir<>INVALID_HANDLE_VALUE; end;
function TLocalBackend.Observe(Side:TLocalSide; out Snapshot:TLocalSnapshot):TLocalResult;
var H:THandle; Status:LongInt;
begin
  Snapshot:=Default(TLocalSnapshot); if not Ready then Exit(lrUnavailable);
  Status:=OpenSide(FDir,Side,False,H);
  if Cardinal(Status)=$c0000034 then Exit(lrOk);
  if Status<>0 then Exit(lrUnavailable);
  try if Capture(H,Snapshot) then Result:=lrOk else Result:=lrUnavailable; finally CloseHandle(H); end;
end;
function TLocalBackend.PrepareReplacement(Side:TLocalSide; const Expected:TLocalSnapshot;
  const Candidate:TBytes; Fault:TStageFault; out Evidence:TStageEvidence):TLocalResult;
var Original,Backup,Stage:THandle; Status:LongInt; Current,After:TLocalSnapshot;
  SecurityAfter:TBytes; BackupName,StageName:UnicodeString; Written:DWORD;
begin
  Evidence:=Default(TStageEvidence); Result:=lrInvalid;
  if not Ready or not Expected.Exists or (Length(Candidate)>MaxBytes) then Exit;
  if Side=lsMachine then begin BackupName:='machine.backup'; StageName:='machine.candidate'; end
  else begin BackupName:='user.backup'; StageName:='user.candidate'; end;
  Status:=OpenSide(FDir,Side,False,Original);
  if Cardinal(Status)=$c0000034 then Exit(lrConflict);
  if Status<>0 then Exit(lrUnavailable);
  try
    if not Capture(Original,Current) or not SecurityBytes(Original,Evidence.OriginalSecurity) then Exit(lrUnavailable);
    if not Same(Expected,Current) then Exit(lrConflict);
    Evidence.Original:=Current; Evidence.Original.Data:=Copy(Current.Data);
    if Fault=sfBeforeBackup then Exit(lrUnavailable);
    Status:=OpenNamed(FDir,BackupName,True,Backup);
    if Cardinal(Status)=$c0000035 then Exit(lrConflict);
    if Status<>0 then Exit(lrUnavailable);
    try
      Result:=lrUnknown;
      if not SetContents(Backup,Current.Data) or not Capture(Backup,Evidence.Backup) or
        not SameData(Evidence.Backup.Data,Current.Data) then Exit;
    finally CloseHandle(Backup); end;
    if Fault=sfAfterBackup then Exit(lrUnavailable);
    Status:=OpenNamed(FDir,StageName,True,Stage);
    if Cardinal(Status)=$c0000035 then Exit(lrConflict);
    if Status<>0 then Exit(lrUnavailable);
    try
      Result:=lrUnknown;
      if Fault=sfPartialCandidate then begin
        if Length(Candidate)>0 then WriteFile(Stage,Candidate[0],1,Written,nil);
        Exit;
      end;
      if not SetContents(Stage,Candidate) or not Capture(Stage,Evidence.Candidate) or
        not SameData(Evidence.Candidate.Data,Candidate) then Exit;
    finally CloseHandle(Stage); end;
    if not Capture(Original,After) or not SecurityBytes(Original,SecurityAfter) or
      not Same(Current,After) or not SameData(Evidence.OriginalSecurity,SecurityAfter) then Exit(lrUnknown);
    Result:=lrOk;
  finally CloseHandle(Original); end;
end;
function TLocalBackend.Publish(Side:TLocalSide; const Expected:TLocalSnapshot; const Desired:TGpoPolicyImage;
  Fault:TLocalFault; out Receipt:TLocalReceipt):TLocalResult;
var H:THandle; Status:LongInt; Actual,After:TLocalSnapshot;
begin
  Receipt:=nil; Result:=lrInvalid;
  if not Ready or (Length(Desired.Data)>MaxBytes) or (not Desired.Exists and (Length(Desired.Data)>0)) or
    (not Expected.Exists and ((Length(Expected.Data)>0) or (Expected.Volume<>0) or (Expected.IndexHigh<>0) or (Expected.IndexLow<>0))) then Exit;
  if not Expected.Exists and not Desired.Exists then begin
    Result:=Observe(Side,Actual); if (Result=lrOk) and Actual.Exists then Result:=lrConflict; Exit;
  end;
  if not Expected.Exists then begin
    if Fault=lfBeforeMutation then Exit(lrUnavailable);
    Status:=OpenSide(FDir,Side,True,H);
    if Cardinal(Status)=$c0000035 then Exit(lrConflict);
    if Status<>0 then Exit(lrUnavailable);
    try
      Result:=lrUnknown; if (Fault=lfAfterMutation) or not SetContents(H,Desired.Data) or not Capture(H,After) then Exit;
    finally CloseHandle(H); end;
  end else begin
    Status:=OpenSide(FDir,Side,False,H);
    if Cardinal(Status)=$c0000034 then Exit(lrConflict);
    if Status<>0 then Exit(lrUnavailable);
    try
      if not Capture(H,Actual) then Exit(lrUnavailable);
      if not Same(Expected,Actual) then Exit(lrConflict);
      if Desired.Exists and (Length(Desired.Data)=Length(Actual.Data)) and
        ((Length(Desired.Data)=0) or CompareMem(@Desired.Data[0],@Actual.Data[0],Length(Actual.Data))) then Exit(lrOk);
      if Desired.Exists then Exit(lrUnavailable); // No safe conditional replace implementation yet.
      if Fault=lfBeforeMutation then Exit(lrUnavailable);
      Result:=lrUnknown;
      if not RemoveFileByHandle(H) or (Fault=lfAfterMutation) then Exit;
      After:=Default(TLocalSnapshot);
    finally CloseHandle(H); end;
  end;
  if Desired.Exists and ((Length(After.Data)<>Length(Desired.Data)) or
    ((Length(After.Data)>0) and not CompareMem(@After.Data[0],@Desired.Data[0],Length(After.Data)))) then Exit(lrUnknown);
  Receipt:=TLocalReceipt.Create; Receipt.Owner:=FId; Receipt.Side:=Side;
  Receipt.Original:=Expected; Receipt.Original.Data:=Copy(Expected.Data); Receipt.After:=After;
  Receipt.After.Data:=Copy(After.Data); Receipt.Active:=True; Result:=lrOk;
end;
function TLocalBackend.Restore(Receipt:TLocalReceipt; Fault:TLocalFault):TLocalResult;
var Reverse:TGpoPolicyImage; Undo:TLocalReceipt;
begin
  if not Assigned(Receipt) or not IsEqualGUID(Receipt.Owner,FId) or not Receipt.Active then Exit(lrInvalid);
  if Receipt.Original.Exists and not Receipt.After.Exists then begin
    Receipt.Active:=False; Exit(lrUnavailable); // Recreating cannot preserve the original ACL.
  end;
  Reverse.Exists:=Receipt.Original.Exists; Reverse.Data:=Copy(Receipt.Original.Data);
  Result:=Publish(Receipt.Side,Receipt.After,Reverse,Fault,Undo);
  if Assigned(Undo) then Undo.Free;
  Receipt.Active:=False;
end;
{$else}
constructor TLocalBackend.Create(const Directory:string); begin inherited Create; end;
destructor TLocalBackend.Destroy; begin inherited Destroy; end;
function TLocalBackend.Ready:Boolean; begin Result:=False; end;
function TLocalBackend.Observe(Side:TLocalSide; out Snapshot:TLocalSnapshot):TLocalResult;
begin Snapshot:=Default(TLocalSnapshot); Result:=lrUnavailable; end;
function TLocalBackend.PrepareReplacement(Side:TLocalSide; const Expected:TLocalSnapshot;
  const Candidate:TBytes; Fault:TStageFault; out Evidence:TStageEvidence):TLocalResult;
begin Evidence:=Default(TStageEvidence); Result:=lrUnavailable; end;
function TLocalBackend.Publish(Side:TLocalSide; const Expected:TLocalSnapshot; const Desired:TGpoPolicyImage; Fault:TLocalFault; out Receipt:TLocalReceipt):TLocalResult;
begin Receipt:=nil; Result:=lrUnavailable; end;
function TLocalBackend.Restore(Receipt:TLocalReceipt; Fault:TLocalFault):TLocalResult; begin Result:=lrUnavailable; end;
{$endif}
end.
