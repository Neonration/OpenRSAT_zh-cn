unit ugpolocalfiles;
{$mode ObjFPC}{$H+}{$codepage UTF8}
interface
uses SysUtils, ugpoformats;

// Local Windows files only. Save exclusively creates a new regular file.
function GpoLoadLocalFile(const Path: string; out Data: TBytes; out Error: string): Boolean;
function GpoSaveNewLocalFile(const Path: string; const Data: TBytes; out Error: string): Boolean;

implementation
{$ifdef windows}
uses Windows;
{$push}{$packrecords c}
type
  TNativeString = record Length, MaximumLength: Word; Buffer: PWideChar; end;
  TNativeAttributes = record
    Length: ULONG; RootDirectory: THandle; ObjectName: ^TNativeString;
    Attributes: ULONG; SecurityDescriptor, SecurityQualityOfService: Pointer;
  end;
  TNativeIo = record StatusOrPointer, Information: PtrUInt; end;
{$pop}
function NtCreateFile(out H:THandle; Access:ACCESS_MASK; var A:TNativeAttributes;
  out Io:TNativeIo; AllocationSize:Pointer; FileAttributes,ShareAccess,
  Disposition,Options:ULONG; EaBuffer:Pointer; EaLength:ULONG):LongInt;
  stdcall; external 'ntdll.dll';
function GetFinalPathNameByHandleW(H:THandle; Buffer:PWideChar; Size,Flags:DWORD):DWORD;
  stdcall; external 'kernel32.dll';
function SetFileInformationByHandle(H:THandle; InfoClass:LongInt;
  Info:Pointer; Size:DWORD):LongBool; stdcall; external 'kernel32.dll';

function OpenLocalParent(const Path:string; ForWrite:Boolean; out Parent:THandle;
  out Leaf:UnicodeString; out Error:string):Boolean;
var Dir,Name,Prefix:string; I:Integer; WDir,FinalPath,Root:UnicodeString;
  N,Access:DWORD; Info:TByHandleFileInformation; DriveType:UINT;
begin
  Result:=False; Parent:=INVALID_HANDLE_VALUE; Leaf:=''; Error:='';
  if (Length(Path)<4) or not (UpCase(Path[1]) in ['A'..'Z']) or
     (Path[2]<>':') or not (Path[3] in ['\','/']) then
  begin Error:='请选择本机绝对路径，不能使用网络共享或设备路径。'; Exit; end;
  for I:=1 to Length(Path) do
    if Ord(Path[I])<32 then
    begin Error:='路径包含不允许的控制字符。'; Exit; end;
  Name:=ExtractFileName(Path); Dir:=ExtractFileDir(Path);
  if (Name='') or (Name='.') or (Name='..') or (Name[Length(Name)] in ['.',' ']) then
  begin Error:='无效的本地文件名。'; Exit; end;
  for I:=1 to Length(Name) do
    if (Ord(Name[I])<32) or (Name[I] in ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then
    begin Error:='文件名包含不允许的字符。'; Exit; end;
  Prefix:=UpperCase(Name); I:=Pos('.',Prefix); if I>0 then Prefix:=Copy(Prefix,1,I-1);
  if (Prefix='CON') or (Prefix='PRN') or (Prefix='AUX') or (Prefix='NUL') or
     ((Length(Prefix)=4) and ((Copy(Prefix,1,3)='COM') or (Copy(Prefix,1,3)='LPT'))
       and (Prefix[4] in ['1'..'9'])) then
  begin Error:='不能使用系统设备名。'; Exit; end;
  Leaf:=UTF8Decode(Name);
  if Length(Leaf)>255 then begin Error:='文件名太长。'; Exit; end;
  WDir:=UTF8Decode(Dir);
  Access:=$00100080; if ForWrite then Access:=Access or 2;
  Parent:=CreateFileW(PWideChar(WDir),Access,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS,0);
  if Parent=INVALID_HANDLE_VALUE then
  begin Error:='无法打开本地目录：'+SysErrorMessage(GetLastError); Exit; end;
  if not GetFileInformationByHandle(Parent,Info) or
     ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY)=0) then
  begin Error:='无法确认本地目录。'; CloseHandle(Parent); Parent:=INVALID_HANDLE_VALUE; Exit; end;
  SetLength(FinalPath,32768);
  N:=GetFinalPathNameByHandleW(Parent,PWideChar(FinalPath),Length(FinalPath),0);
  if (N=0) or (N>=DWORD(Length(FinalPath))) then
  begin Error:='无法确认目录的实际位置。'; CloseHandle(Parent); Parent:=INVALID_HANDLE_VALUE; Exit; end;
  SetLength(FinalPath,N);
  if (Length(FinalPath)<7) or (Copy(FinalPath,1,4)<>'\\?\') or
     not (UpCase(FinalPath[5]) in ['A'..'Z']) or (FinalPath[6]<>':') or
     (FinalPath[7]<>'\') then
  begin Error:='目录不是可确认的本地磁盘，不能使用网络位置。'; CloseHandle(Parent); Parent:=INVALID_HANDLE_VALUE; Exit; end;
  Root:=Copy(FinalPath,5,3); DriveType:=GetDriveTypeW(PWideChar(Root));
  if not (DriveType in [DRIVE_FIXED,DRIVE_REMOVABLE]) then
  begin Error:='只能使用本机固定或可移动磁盘。'; CloseHandle(Parent); Parent:=INVALID_HANDLE_VALUE; Exit; end;
  Result:=True;
end;

function OpenLeaf(Parent:THandle; const Leaf:UnicodeString; CreateNew:Boolean;
  out H:THandle; out Error:string):Boolean;
var U:TNativeString; A:TNativeAttributes; Io:TNativeIo; Status:LongInt;
  Access,Disposition:ULONG;
begin
  H:=INVALID_HANDLE_VALUE; Error:=''; FillChar(U,SizeOf(U),0);
  U.Length:=Length(Leaf)*2; U.MaximumLength:=U.Length+2; U.Buffer:=PWideChar(Leaf);
  FillChar(A,SizeOf(A),0); A.Length:=SizeOf(A); A.RootDirectory:=Parent;
  A.ObjectName:=@U; A.Attributes:=$1040; // CASE_INSENSITIVE | DONT_REPARSE.
  if CreateNew then begin Access:=$00110082; Disposition:=2; end // write, delete, sync; FILE_CREATE
  else begin Access:=$00100081; Disposition:=1; end; // read, attributes, sync; FILE_OPEN
  Status:=NtCreateFile(H,Access,A,Io,nil,FILE_ATTRIBUTE_NORMAL,FILE_SHARE_READ,
    Disposition,$00200060,nil,0); // OPEN_REPARSE_POINT | NON_DIRECTORY | SYNCHRONOUS
  Result:=Status=0;
  if not Result then
  begin
    H:=INVALID_HANDLE_VALUE;
    if Cardinal(Status)=$c0000035 then Error:='文件已存在。请另选一个新文件名，不会覆盖原文件。'
    else Error:=Format('无法打开本地文件（状态 0x%.8x）。',[Cardinal(Status)]);
  end;
end;

function GpoLoadLocalFile(const Path:string; out Data:TBytes; out Error:string):Boolean;
var Parent,H:THandle; Leaf:UnicodeString; Info:TByHandleFileInformation;
  Got,Count:DWORD; Extra:Byte;
begin
  Result:=False; Data:=nil; Parent:=INVALID_HANDLE_VALUE; H:=INVALID_HANDLE_VALUE;
  if not OpenLocalParent(Path,False,Parent,Leaf,Error) then Exit;
  try
    if not OpenLeaf(Parent,Leaf,False,H,Error) then Exit;
    if not GetFileInformationByHandle(H,Info) then begin Error:='无法读取文件属性。'; Exit; end;
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT))<>0 then
    begin Error:='不能打开目录或重解析点。'; Exit; end;
    if (Info.nFileSizeHigh<>0) or (Info.nFileSizeLow>GpoMaxFileBytes) then
    begin Error:='文件超过 16 MiB 上限。'; Exit; end;
    Count:=Info.nFileSizeLow; SetLength(Data,Count);
    if Count>0 then
      if not ReadFile(H,Data[0],Count,Got,nil) or (Got<>Count) then
      begin Error:='读取本地文件失败或文件长度发生变化。'; Exit; end;
    if not ReadFile(H,Extra,1,Got,nil) or (Got<>0) then
    begin Error:='读取本地文件失败或文件长度发生变化。'; Exit; end;
    Result:=True;
  finally
    if H<>INVALID_HANDLE_VALUE then CloseHandle(H);
    if Parent<>INVALID_HANDLE_VALUE then CloseHandle(Parent);
    if not Result then Data:=nil;
  end;
end;

function GpoSaveNewLocalFile(const Path:string; const Data:TBytes; out Error:string):Boolean;
var Parent,H:THandle; Leaf:UnicodeString; Written:DWORD; DeleteIt:Byte;
begin
  Result:=False; Parent:=INVALID_HANDLE_VALUE; H:=INVALID_HANDLE_VALUE;
  if Length(Data)>GpoMaxFileBytes then begin Error:='文件超过 16 MiB 上限。'; Exit; end;
  if not OpenLocalParent(Path,True,Parent,Leaf,Error) then Exit;
  try
    if not OpenLeaf(Parent,Leaf,True,H,Error) then Exit;
    if (Length(Data)>0) and (not WriteFile(H,Data[0],Length(Data),Written,nil) or
       (Written<>DWORD(Length(Data)))) then begin Error:='写入本地副本失败。'; Exit; end;
    if not FlushFileBuffers(H) then begin Error:='无法确认本地副本已写入。'; Exit; end;
    Result:=True;
  finally
    if H<>INVALID_HANDLE_VALUE then
    begin
      if not Result then
      begin
        DeleteIt:=1;
        if not SetFileInformationByHandle(H,4,@DeleteIt,SizeOf(DeleteIt)) then
          Error:=Error+' 无法清理新建的部分文件，请检查所选位置。';
      end;
      CloseHandle(H);
    end;
    if Parent<>INVALID_HANDLE_VALUE then CloseHandle(Parent);
  end;
end;
{$else}
function GpoLoadLocalFile(const Path:string; out Data:TBytes; out Error:string):Boolean;
begin Data:=nil; Error:='当前平台暂不支持安全的本地文件读取。'; Result:=False; end;
function GpoSaveNewLocalFile(const Path:string; const Data:TBytes; out Error:string):Boolean;
begin Error:='当前平台暂不支持安全的本地文件保存。'; Result:=False; end;
{$endif}
end.
