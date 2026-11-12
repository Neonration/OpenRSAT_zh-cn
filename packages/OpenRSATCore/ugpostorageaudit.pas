unit ugpostorageaudit;
{$mode objfpc}{$H+}
interface
{$ifdef windows}
uses Windows;
type TStorageAudit=(saUnavailable,saRejected,saRestrictiveUnverified);
// Descriptor and owner SID must be valid OS-created objects for the entire call.
// This is a narrow DACL shape check, not effective access or recovery authority.
function GpoInspectStorageDescriptor(Descriptor:PSECURITY_DESCRIPTOR; ExpectedOwner:PSID):TStorageAudit;
function GpoAuditStorageHandle(Handle:THandle):TStorageAudit;
{$endif}
implementation
{$ifdef windows}
uses SysUtils;
function CreateWellKnownSid(Kind:LongInt; DomainSid:PSID; Sid:PSID; var Size:DWORD):LongBool;
  stdcall; external 'advapi32.dll';
const DaclProtected=$1000; FileAllAccess=$001f01ff; GenericAll=$10000000;

function GpoInspectStorageDescriptor(Descriptor:PSECURITY_DESCRIPTOR; ExpectedOwner:PSID):TStorageAudit;
var Owner,Principal,SystemSid,AdminSid:PSID; Dacl:PACL; Present,Defaulted:LongBool;
  Control:SECURITY_DESCRIPTOR_CONTROL; Revision,Size,I,SidBytes:DWORD; Entry:Pointer;
  SysBuffer,AdminBuffer:array[0..67] of Byte; Ace:PACCESS_ALLOWED_ACE; OwnerFull:Boolean;
begin
  Result:=saRejected;
  if (Descriptor=nil) or (ExpectedOwner=nil) or not IsValidSecurityDescriptor(Descriptor) or
    not IsValidSid(ExpectedOwner) then Exit;
  Owner:=nil; Defaulted:=False;
  if not GetSecurityDescriptorOwner(Descriptor,Owner,@Defaulted) or Defaulted or (Owner=nil) or
    not IsValidSid(Owner) or not EqualSid(Owner,ExpectedOwner) then Exit;
  Control:=0; Revision:=0;
  if not GetSecurityDescriptorControl(Descriptor,@Control,@Revision) or ((Control and DaclProtected)=0) then Exit;
  Dacl:=nil; Present:=False; Defaulted:=False;
  if not GetSecurityDescriptorDacl(Descriptor,@Present,Dacl,@Defaulted) or not Present or Defaulted or (Dacl=nil) or
    not IsValidAcl(Dacl) or (Dacl^.AceCount=0) then Exit;
  Size:=SizeOf(SysBuffer); SystemSid:=@SysBuffer[0];
  if not CreateWellKnownSid(22,nil,SystemSid,Size) then Exit(saUnavailable); // WinLocalSystemSid
  Size:=SizeOf(AdminBuffer); AdminSid:=@AdminBuffer[0];
  if not CreateWellKnownSid(26,nil,AdminSid,Size) then Exit(saUnavailable); // WinBuiltinAdministratorsSid
  OwnerFull:=False;
  for I:=0 to Dacl^.AceCount-1 do begin
    Entry:=nil; if not GetAce(Dacl,I,Entry) or (Entry=nil) then Exit;
    Ace:=PACCESS_ALLOWED_ACE(Entry);
    if (Ace^.Header.AceType<>ACCESS_ALLOWED_ACE_TYPE) or (Ace^.Header.AceFlags<>0) or
      (Ace^.Header.AceSize<16) then Exit;
    Principal:=PSID(@Ace^.SidStart);
    SidBytes:=8+4*PByte(PtrUInt(Principal)+1)^;
    if (SidBytes>68) or (8+SidBytes>Ace^.Header.AceSize) or not IsValidSid(Principal) then Exit;
    if not EqualSid(Principal,ExpectedOwner) and not EqualSid(Principal,SystemSid) and
      not EqualSid(Principal,AdminSid) then Exit;
    if EqualSid(Principal,ExpectedOwner) and (((Ace^.Mask and FileAllAccess)=FileAllAccess) or
      ((Ace^.Mask and GenericAll)<>0)) then OwnerFull:=True;
  end;
  if OwnerFull then Result:=saRestrictiveUnverified;
end;

function GpoAuditStorageHandle(Handle:THandle):TStorageAudit;
var Token,ThreadToken:THandle; Needed,Size,Code:DWORD; Info:TByHandleFileInformation;
  TokenData,Security:TBytes; User:PTOKENUSER;
begin
  Result:=saUnavailable;
  if (Handle=0) or (Handle=INVALID_HANDLE_VALUE) or (GetFileType(Handle)<>FILE_TYPE_DISK) or
    not GetFileInformationByHandle(Handle,Info) then Exit;
  if ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
    (((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY)=0) and (Info.nNumberOfLinks<>1)) then Exit(saRejected);
  ThreadToken:=0;
  if OpenThreadToken(GetCurrentThread,TOKEN_QUERY,True,ThreadToken) then begin CloseHandle(ThreadToken); Exit; end;
  if GetLastError<>ERROR_NO_TOKEN then Exit;
  Token:=0; if not OpenProcessToken(GetCurrentProcess,TOKEN_QUERY,Token) then Exit;
  try
    Needed:=0; GetTokenInformation(Token,TokenUser,nil,0,@Needed);
    if (GetLastError<>ERROR_INSUFFICIENT_BUFFER) or (Needed=0) or (Needed>1024*1024) then Exit;
    SetLength(TokenData,Needed); if not GetTokenInformation(Token,TokenUser,@TokenData[0],Needed,@Size) then Exit;
    User:=PTOKENUSER(@TokenData[0]); if (User^.User.Sid=nil) or not IsValidSid(User^.User.Sid) then Exit;
    Needed:=0;
    if GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,nil,0,@Needed) then Exit;
    Code:=GetLastError; if (Code<>ERROR_INSUFFICIENT_BUFFER) or (Needed=0) or (Needed>1024*1024) then Exit;
    SetLength(Security,Needed);
    if not GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
      PSECURITY_DESCRIPTOR(@Security[0]),Needed,@Size) then Exit;
    Result:=GpoInspectStorageDescriptor(PSECURITY_DESCRIPTOR(@Security[0]),User^.User.Sid);
  finally CloseHandle(Token); end;
end;
{$endif}
end.
