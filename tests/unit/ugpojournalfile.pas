unit ugpojournalfile;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses SysUtils,ugporeplaymodel{$ifdef windows},Windows{$endif};
type TJournalTestFault=(jfNone,jfBeforeWrite,jfShortWrite,jfFlushFailure);
  TJournalAssessment=(jaUnavailable,jaInvalid,jaMismatch,jaMatchedUntrusted);
// Isolated test checkpoints only; a checkpoint never authorizes execution.
function SaveJournal(const Directory:string; Number:Cardinal; const Header:TReplayHeader;
  const Entries:TReplayEntries; out Error:string):Boolean;
function LoadJournal(const Directory:string; Number:Cardinal; out State:TReplayResult;
  out Error:string):Boolean;
function SaveJournalInjected(const Directory:string; Number:Cardinal; const Header:TReplayHeader;
  const Entries:TReplayEntries; Fault:TJournalTestFault; out Error:string):Boolean;
// Diagnostic only. Even a matching result never authorizes cross-process recovery.
function AssessJournal(const Directory:string; Number:Cardinal; const Expected:TReplayHeader;
  const ExpectedEntries:TReplayEntries):TJournalAssessment;
{$ifdef windows}
function OpenDirectory(const Directory:string; WriteAccess:Boolean; out H:THandle):Boolean;
{$endif}

implementation
uses ugpoformats;
const MaxJournal=8*1024*1024; MaxEntries=10; MaxIdentity=1024;
type TBuffer=record Data:TBytes; Pos:SizeInt; end;

procedure Put32(var B:TBuffer; V:Cardinal);
var I,N:Integer;
begin N:=Length(B.Data); SetLength(B.Data,N+4); for I:=0 to 3 do B.Data[N+I]:=Byte(V shr (I*8)); end;
function Get32(var B:TBuffer; out V:Cardinal):Boolean;
var I:Integer;
begin V:=0; Result:=(B.Pos>=0) and (B.Pos<=Length(B.Data)-4); if not Result then Exit;
  for I:=0 to 3 do V:=V or (Cardinal(B.Data[B.Pos+I]) shl (I*8)); Inc(B.Pos,4); end;
procedure PutBytes(var B:TBuffer; const V:TBytes);
var N:SizeInt;
begin Put32(B,Length(V)); N:=Length(B.Data); SetLength(B.Data,N+Length(V)); if Length(V)>0 then Move(V[0],B.Data[N],Length(V)); end;
function GetBytes(var B:TBuffer; out V:TBytes; Limit:Cardinal):Boolean;
var N:Cardinal;
begin V:=nil; Result:=Get32(B,N) and (N<=Limit) and (N<=Cardinal(Length(B.Data)-B.Pos));
  if not Result then Exit; SetLength(V,N); if N>0 then Move(B.Data[B.Pos],V[0],N); Inc(B.Pos,N); end;
function ValidIdentity(const S:string):Boolean;
var I:Integer;
begin Result:=(Length(S)>0) and (Length(S)<=MaxIdentity); if not Result then Exit;
  for I:=1 to Length(S) do if (Ord(S[I])<32) or (Ord(S[I])>126) then Exit(False); end;
procedure PutString(var B:TBuffer; const S:string);
var V:TBytes;
begin SetLength(V,Length(S)); if Length(S)>0 then Move(S[1],V[0],Length(S)); PutBytes(B,V); end;
function GetString(var B:TBuffer; out S:string):Boolean;
var V:TBytes;
begin S:=''; Result:=GetBytes(B,V,MaxIdentity); if not Result then Exit;
  SetLength(S,Length(V)); if Length(V)>0 then Move(V[0],S[1],Length(V)); Result:=ValidIdentity(S); end;
procedure PutImage(var B:TBuffer; const Image:TGpoPolicyImage);
begin Put32(B,Ord(Image.Exists)); PutBytes(B,Image.Data); end;
function GetImage(var B:TBuffer; out Image:TGpoPolicyImage):Boolean;
var V:Cardinal;
begin Image:=Default(TGpoPolicyImage); Result:=Get32(B,V) and (V<=1) and GetBytes(B,Image.Data,MaxJournal);
  if Result then begin Image.Exists:=V=1; Result:=Image.Exists or (Length(Image.Data)=0); end; end;
function Crc32(const Data:TBytes; Start:SizeInt):Cardinal;
var I,J:SizeInt; C:Cardinal;
begin C:=$ffffffff; for I:=Start to High(Data) do begin C:=C xor Data[I];
  for J:=1 to 8 do if (C and 1)<>0 then C:=(C shr 1) xor $edb88320 else C:=C shr 1; end; Result:=not C; end;
function Encode(const H:TReplayHeader; const E:TReplayEntries; out Data:TBytes):Boolean;
var B:TBuffer; I,J:Integer; Mask:Cardinal; U,M:TGpoPolicyImage;
begin
  Result:=False; Data:=nil;
  if not ValidIdentity(H.TransactionId) or not ValidIdentity(H.Domain) or not ValidIdentity(H.DC) or
     not ValidIdentity(H.DN) or not ValidIdentity(H.ObjectId) or not ValidIdentity(H.SessionId) or
     (Length(E)>MaxEntries) or (ReplayGpoJournal(H,E)=rrInvalid) then Exit;
  if QWord(Length(H.Plan.Baseline.GptIni))+QWord(Length(H.Plan.Baseline.UserPolicy.Data))+
    QWord(Length(H.Plan.Baseline.MachinePolicy.Data))+QWord(Length(H.Plan.UserPolicy))+
    QWord(Length(H.Plan.MachinePolicy))>MaxJournal-8192 then Exit;
  B.Data:=nil; Put32(B,$4c4a5047); Put32(B,1); Put32(B,0); Put32(B,0);
  PutString(B,H.TransactionId); PutString(B,H.Domain); PutString(B,H.DC); PutString(B,H.DN);
  PutString(B,H.ObjectId); PutString(B,H.SessionId); Put32(B,H.Plan.Baseline.GpcVersion);
  PutBytes(B,H.Plan.Baseline.GptIni); PutImage(B,H.Plan.Baseline.UserPolicy); PutImage(B,H.Plan.Baseline.MachinePolicy);
  U.Exists:=H.Plan.UserExists; U.Data:=H.Plan.UserPolicy; M.Exists:=H.Plan.MachineExists; M.Data:=H.Plan.MachinePolicy;
  PutImage(B,U); PutImage(B,M); Put32(B,Length(E));
  for I:=0 to High(E) do begin
    Put32(B,E[I].Sequence); Put32(B,Ord(E[I].Step)); Put32(B,Ord(E[I].Kind)); Mask:=0;
    for J:=Ord(Low(TReplayEvidence)) to Ord(High(TReplayEvidence)) do
      if TReplayEvidence(J) in E[I].Evidence then Mask:=Mask or (Cardinal(1) shl J);
    Put32(B,Mask);
  end;
  if Length(B.Data)>MaxJournal then Exit;
  I:=Length(B.Data); for J:=0 to 3 do B.Data[8+J]:=Byte(Cardinal(I) shr (8*J));
  Mask:=Crc32(B.Data,16); for J:=0 to 3 do B.Data[12+J]:=Byte(Mask shr (8*J));
  Data:=B.Data; Result:=True;
end;
function Decode(const Data:TBytes; out State:TReplayResult):Boolean;
var B:TBuffer; H:TReplayHeader; E:TReplayEntries; OU,OM,NU,NM:TGpoPolicyImage;
  Ini:TBytes; V,Magic,Version,Size,CheckSum,Count,Step,Kind,Mask:Cardinal; I,J:Integer;
begin
  Result:=False; State:=rrInvalid; H:=Default(TReplayHeader); B.Data:=Data; B.Pos:=0;
  if (Length(Data)<16) or (Length(Data)>MaxJournal) or not Get32(B,Magic) or not Get32(B,Version) or
     not Get32(B,Size) or not Get32(B,CheckSum) or (Magic<>$4c4a5047) or (Version<>1) or
     (Size<>Cardinal(Length(Data))) or (CheckSum<>Crc32(Data,16)) then Exit;
  if not GetString(B,H.TransactionId) or not GetString(B,H.Domain) or not GetString(B,H.DC) or
    not GetString(B,H.DN) or not GetString(B,H.ObjectId) or not GetString(B,H.SessionId) or
    not Get32(B,V) or not GetBytes(B,Ini,MaxJournal) or not GetImage(B,OU) or not GetImage(B,OM) or
    not GetImage(B,NU) or not GetImage(B,NM) or not Get32(B,Count) or (Count>MaxEntries) then Exit;
  if GpoBuildOfflinePlanWithPresence(V,V,Ini,OU,NU,OM,NM,H.Plan)<>gopOk then Exit;
  SetLength(E,Count);
  for I:=0 to Integer(Count)-1 do begin
    if not Get32(B,E[I].Sequence) or not Get32(B,Step) or not Get32(B,Kind) or not Get32(B,Mask) or
      (Step>Ord(High(TReplayStep))) or (Kind>Ord(High(TReplayKind))) or (Mask>31) then Exit;
    E[I].Step:=TReplayStep(Step); E[I].Kind:=TReplayKind(Kind); E[I].Evidence:=[];
    for J:=0 to Ord(High(TReplayEvidence)) do if (Mask and (Cardinal(1) shl J))<>0 then Include(E[I].Evidence,TReplayEvidence(J));
  end;
  if B.Pos<>Length(Data) then Exit;
  State:=ReplayGpoJournal(H,E); Result:=State<>rrInvalid;
end;

{$ifdef windows}
{$push}{$packrecords c}
type TNString=record Length,MaximumLength:Word; Buffer:PWideChar; end;
  TNAttrs=record Length:ULONG; RootDirectory:THandle; ObjectName:^TNString; Attributes:ULONG;
    SecurityDescriptor,SecurityQualityOfService:Pointer; end;
  TNIO=record StatusOrPointer,Information:PtrUInt; end;
{$pop}
function NtCreateFile(out H:THandle; Access:ACCESS_MASK; var A:TNAttrs; out Io:TNIO;
  AllocationSize:Pointer; FileAttributes,ShareAccess,Disposition,Options:ULONG; EaBuffer:Pointer; EaLength:ULONG):LongInt;
  stdcall; external 'ntdll.dll';
function GetFinalPathNameByHandleW(H:THandle; Buffer:PWideChar; Size,Flags:DWORD):DWORD;
  stdcall; external 'kernel32.dll';
function CompareStringOrdinal(A:PWideChar; ALen:Integer; B:PWideChar; BLen:Integer; IgnoreCase:LongBool):Integer;
  stdcall; external 'kernel32.dll';
function OpenDirectory(const Directory:string; WriteAccess:Boolean; out H:THandle):Boolean;
var W,FinalPath,Expected,Root:UnicodeString; Info:TByHandleFileInformation; N,Access:DWORD;
begin
  Result:=False; H:=INVALID_HANDLE_VALUE;
  if (Length(Directory)<3) or not (UpCase(Directory[1]) in ['A'..'Z']) or
    (Directory[2]<>':') or (Directory[3]<>'\') or (Pos(#0,Directory)>0) then Exit;
  W:=UTF8Decode(ExpandFileName(Directory)); Expected:='\\?\'+W;
  Access:=$00100080; if WriteAccess then Access:=Access or 2;
  H:=CreateFileW(PWideChar(W),Access,FILE_SHARE_READ or FILE_SHARE_WRITE,nil,
    OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or $00200000,0);
  if H=INVALID_HANDLE_VALUE then Exit;
  try
    if not GetFileInformationByHandle(H,Info) or ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY)=0) or
      ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then Exit;
    SetLength(FinalPath,32768); N:=GetFinalPathNameByHandleW(H,PWideChar(FinalPath),Length(FinalPath),0);
    if (N=0) or (N>=DWORD(Length(FinalPath))) then Exit; SetLength(FinalPath,N);
    if CompareStringOrdinal(PWideChar(FinalPath),Length(FinalPath),PWideChar(Expected),Length(Expected),LongBool(1))<>2 then Exit;
    Root:=Copy(W,1,3); if not (GetDriveTypeW(PWideChar(Root)) in [DRIVE_FIXED,DRIVE_REMOVABLE]) then Exit;
    Result:=True;
  finally if not Result then begin CloseHandle(H); H:=INVALID_HANDLE_VALUE; end; end;
end;
function OpenJournal(Dir:THandle; Number:Cardinal; CreateNew:Boolean; out H:THandle):Boolean;
var Name:UnicodeString; U:TNString; A:TNAttrs; Io:TNIO; Access,Disposition:ULONG; Info:TByHandleFileInformation;
begin
  Name:=UnicodeString(Format('gpo-%.8x.journal',[Number])); FillChar(U,SizeOf(U),0);
  U.Length:=Length(Name)*2; U.MaximumLength:=U.Length+2; U.Buffer:=PWideChar(Name);
  FillChar(A,SizeOf(A),0); A.Length:=SizeOf(A); A.RootDirectory:=Dir; A.ObjectName:=@U; A.Attributes:=$1040;
  if CreateNew then begin Access:=$00100082; Disposition:=2; end
  else begin Access:=$00100081; Disposition:=1; end;
  Result:=NtCreateFile(H,Access,A,Io,nil,FILE_ATTRIBUTE_NORMAL,FILE_SHARE_READ,Disposition,$00200060,nil,0)=0;
  if not Result then begin H:=INVALID_HANDLE_VALUE; Exit; end;
  Result:=GetFileInformationByHandle(H,Info) and (Info.nNumberOfLinks=1) and
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT))=0);
  if not Result then begin CloseHandle(H); H:=INVALID_HANDLE_VALUE; end;
end;
function SaveJournalInjected(const Directory:string; Number:Cardinal; const Header:TReplayHeader;
  const Entries:TReplayEntries; Fault:TJournalTestFault; out Error:string):Boolean;
var Data:TBytes; Dir,H:THandle; N:DWORD;
begin
  Result:=False; Error:='invalid journal';
  if not Encode(Header,Entries,Data) then Exit;
  Error:='unavailable or unsafe directory';
  if not OpenDirectory(Directory,True,Dir) then Exit;
  try
    Error:='cannot create checkpoint';
    if not OpenJournal(Dir,Number,True,H) then Exit;
    try
      if Fault=jfBeforeWrite then begin Error:='injected failure; checkpoint is incomplete'; Exit; end;
      if Fault=jfShortWrite then begin
        WriteFile(H,Data[0],8,N,nil); Error:='injected short write; checkpoint is incomplete'; Exit;
      end;
      if not WriteFile(H,Data[0],Length(Data),N,nil) or (N<>DWORD(Length(Data))) then begin Error:='write failed; checkpoint may be partial'; Exit; end;
      if Fault=jfFlushFailure then begin Error:='injected flush failure; checkpoint state unknown'; Exit; end;
      if not FlushFileBuffers(H) then begin Error:='flush failed; checkpoint state unknown'; Exit; end;
      Result:=True; Error:='';
    finally CloseHandle(H); end;
  finally CloseHandle(Dir); end;
end;
function SaveJournal(const Directory:string; Number:Cardinal; const Header:TReplayHeader;
  const Entries:TReplayEntries; out Error:string):Boolean;
begin Result:=SaveJournalInjected(Directory,Number,Header,Entries,jfNone,Error); end;
function ReadJournal(const Directory:string; Number:Cardinal; out Data:TBytes):Boolean;
var Dir,H:THandle; N,Extra:DWORD; Tail:Byte; Info:TByHandleFileInformation;
begin
  Result:=False; Data:=nil;
  if not OpenDirectory(Directory,False,Dir) then Exit;
  try
    if not OpenJournal(Dir,Number,False,H) then Exit;
    try
      if not GetFileInformationByHandle(H,Info) or (Info.nFileSizeHigh<>0) or (Info.nFileSizeLow<16) or (Info.nFileSizeLow>MaxJournal) then Exit;
      SetLength(Data,Info.nFileSizeLow);
      if not ReadFile(H,Data[0],Length(Data),N,nil) or (N<>DWORD(Length(Data))) or
        not ReadFile(H,Tail,1,Extra,nil) or (Extra<>0) then Exit;
      Result:=True;
    finally CloseHandle(H); end;
  finally CloseHandle(Dir); end;
end;
function LoadJournal(const Directory:string; Number:Cardinal; out State:TReplayResult; out Error:string):Boolean;
var Data:TBytes;
begin
  State:=rrInvalid; Error:='invalid or unavailable checkpoint';
  Result:=ReadJournal(Directory,Number,Data) and Decode(Data,State);
  if Result then Error:='';
end;
function AssessJournal(const Directory:string; Number:Cardinal; const Expected:TReplayHeader;
  const ExpectedEntries:TReplayEntries):TJournalAssessment;
var Data,Anchor:TBytes; State:TReplayResult;
begin
  if not Encode(Expected,ExpectedEntries,Anchor) then Exit(jaInvalid);
  if not ReadJournal(Directory,Number,Data) then Exit(jaUnavailable);
  if not Decode(Data,State) then Exit(jaInvalid);
  if (Length(Data)<>Length(Anchor)) or ((Length(Data)>0) and not CompareMem(@Data[0],@Anchor[0],Length(Data))) then Exit(jaMismatch);
  Result:=jaMatchedUntrusted;
end;
{$else}
function SaveJournalInjected(const Directory:string; Number:Cardinal; const Header:TReplayHeader;
  const Entries:TReplayEntries; Fault:TJournalTestFault; out Error:string):Boolean;
begin Error:='unsupported platform'; Result:=False; end;
function SaveJournal(const Directory:string; Number:Cardinal; const Header:TReplayHeader; const Entries:TReplayEntries; out Error:string):Boolean;
begin Error:='unsupported platform'; Result:=False; end;
function LoadJournal(const Directory:string; Number:Cardinal; out State:TReplayResult; out Error:string):Boolean;
begin Error:='unsupported platform'; State:=rrInvalid; Result:=False; end;
function AssessJournal(const Directory:string; Number:Cardinal; const Expected:TReplayHeader;
  const ExpectedEntries:TReplayEntries):TJournalAssessment;
begin Result:=jaUnavailable; end;
{$endif}
end.
