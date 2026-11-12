unit unittest.ugpostorageaudit;
{$mode objfpc}{$H+}
interface
uses mormot.core.test;
type TUnitTestGpoStorageAudit=class(TSynTestCase)
published procedure ReadOnlyAclAssessment;
end;
implementation
{$ifdef windows}
uses SysUtils,Windows,ugpostorageaudit;
function ConvertStringSecurityDescriptorToSecurityDescriptorW(Text:PWideChar; Revision:DWORD;
  out Descriptor:PSECURITY_DESCRIPTOR; Size:PDWORD):LongBool; stdcall; external 'advapi32.dll';
function ConvertSidToStringSidW(Sid:PSID; out Text:PWideChar):LongBool; stdcall; external 'advapi32.dll';
function SetSecurityDescriptorControl(Descriptor:PSECURITY_DESCRIPTOR; ControlBitsOfInterest,ControlBitsToSet:Word):LongBool;
  stdcall; external 'advapi32.dll';
function ReadDescriptor(H:THandle):TBytes;
var N,M:DWORD;
begin
  Result:=nil; N:=0; GetKernelObjectSecurity(H,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,nil,0,@N);
  if (GetLastError<>ERROR_INSUFFICIENT_BUFFER) or (N=0) then Exit;
  SetLength(Result,N); if not GetKernelObjectSecurity(H,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR(@Result[0]),N,@M) then Result:=nil;
end;
procedure TUnitTestGpoStorageAudit.ReadOnlyAclAssessment;
var Token,H:THandle; N,M:DWORD; TokenData,Before,After:TBytes; User:PTOKENUSER; SidText:PWideChar;
  Sid:UnicodeString; SD:PSECURITY_DESCRIPTOR; Dacl:PACL; Present,Defaulted:LongBool; Entry:Pointer;
  Dir,Path:string; Id:TGUID; State:TStorageAudit; NullSD:SECURITY_DESCRIPTOR;
  function Descriptor(const S:UnicodeString):PSECURITY_DESCRIPTOR;
  begin
    Result:=nil;
    if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(S),1,Result,nil) then
      raise Exception.Create('Cannot create simulated security descriptor');
  end;
  procedure Expect(const S:UnicodeString; Expected:TStorageAudit);
  var D:PSECURITY_DESCRIPTOR;
  begin D:=Descriptor(S); try Check(GpoInspectStorageDescriptor(D,User^.User.Sid)=Expected);
    finally LocalFree(HLOCAL(D)); end; end;
begin
  Token:=0; if not OpenProcessToken(GetCurrentProcess,TOKEN_QUERY,Token) then raise Exception.Create('No process token');
  try
    N:=0; GetTokenInformation(Token,TokenUser,nil,0,@N); if N=0 then raise Exception.Create('No token user');
    SetLength(TokenData,N); if not GetTokenInformation(Token,TokenUser,@TokenData[0],N,@M) then raise Exception.Create('No token user');
    User:=PTOKENUSER(@TokenData[0]); SidText:=nil;
    if not ConvertSidToStringSidW(User^.User.Sid,SidText) then raise Exception.Create('Cannot format SID');
    try Sid:=UnicodeString(SidText); finally LocalFree(HLOCAL(SidText)); end;
    Expect('O:'+Sid+'D:P(A;;FA;;;'+Sid+')(A;;FA;;;SY)(A;;FA;;;BA)',saRestrictiveUnverified);
    Expect('O:'+Sid+'D:P(A;;FA;;;WD)(A;;FA;;;'+Sid+')',saRejected);
    Expect('O:'+Sid+'D:P(D;;FA;;;WD)(A;;FA;;;'+Sid+')',saRejected);
    Expect('O:'+Sid+'D:(A;;FA;;;'+Sid+')',saRejected);
    Expect('O:'+Sid+'D:P',saRejected);
    Expect('O:'+Sid,saRejected);
    FillChar(NullSD,SizeOf(NullSD),0);
    Check(InitializeSecurityDescriptor(@NullSD,1)); Check(SetSecurityDescriptorOwner(@NullSD,User^.User.Sid,False));
    Check(SetSecurityDescriptorDacl(@NullSD,True,nil,False));
    Check(SetSecurityDescriptorControl(@NullSD,$1000,$1000));
    Check(GpoInspectStorageDescriptor(@NullSD,User^.User.Sid)=saRejected,'NULL DACL rejected');
    Expect('O:SYD:P(A;;FA;;;'+Sid+')',saRejected);
    Expect('O:'+Sid+'D:P(A;;FR;;;'+Sid+')',saRejected);
    SD:=Descriptor('O:'+Sid+'D:P(A;;FA;;;'+Sid+')');
    try
      Dacl:=nil; Present:=False; Defaulted:=False;
      if not GetSecurityDescriptorDacl(SD,@Present,Dacl,@Defaulted) then raise Exception.Create('Missing DACL');
      if not Present or (Dacl=nil) then raise Exception.Create('Invalid DACL');
      Entry:=nil; if not GetAce(Dacl,0,Entry) or (Entry=nil) then raise Exception.Create('Missing ACE');
      PACE_HEADER(Entry)^.AceFlags:=$10; Check(GpoInspectStorageDescriptor(SD,User^.User.Sid)=saRejected,'inherited ACE rejected');
      PACE_HEADER(Entry)^.AceFlags:=0; PACE_HEADER(Entry)^.AceType:=$09;
      Check(GpoInspectStorageDescriptor(SD,User^.User.Sid)=saRejected,'unknown ACE rejected');
    finally LocalFree(HLOCAL(SD)); end;
    Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-audit-'+GUIDToString(Id); Check(CreateDir(Dir));
    try
      H:=CreateFileW(PWideChar(UTF8Decode(Dir)),$00020000 or FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or $00200000,0);
      if H=INVALID_HANDLE_VALUE then raise Exception.Create('Cannot open isolated directory');
      try
        Before:=ReadDescriptor(H); Check(Length(Before)>0);
        State:=GpoAuditStorageHandle(H); Check(State in [saRejected,saRestrictiveUnverified],'real handle inspection available');
        After:=ReadDescriptor(H); Check((Length(Before)=Length(After)) and (Length(Before)>0) and
          CompareMem(@Before[0],@After[0],Length(Before)),'inspection must not modify security');
        if State=saRejected then WriteLn('STORAGE_AUDIT real handle: rejected by strict policy')
        else WriteLn('STORAGE_AUDIT real handle: restrictive shape only');
      finally CloseHandle(H); end;
      Path:=Dir+'\probe.dat';
      H:=CreateFileW(PWideChar(UTF8Decode(Path)),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
      if H=INVALID_HANDLE_VALUE then raise Exception.Create('Cannot create isolated file');
      CloseHandle(H);
      try
        H:=CreateFileW(PWideChar(UTF8Decode(Path)),$00020000 or FILE_READ_ATTRIBUTES,
          FILE_SHARE_READ,nil,OPEN_EXISTING,$00200000,0);
        if H=INVALID_HANDLE_VALUE then raise Exception.Create('Cannot open isolated file');
        try
          Before:=ReadDescriptor(H); State:=GpoAuditStorageHandle(H); After:=ReadDescriptor(H);
          Check(State in [saRejected,saRestrictiveUnverified],'real file handle inspection available');
          Check((Length(Before)=Length(After)) and (Length(Before)>0) and
            CompareMem(@Before[0],@After[0],Length(Before)),'file security unchanged');
        finally CloseHandle(H); end;
      finally Check(DeleteFileW(PWideChar(UTF8Decode(Path))),'audit file cleaned'); end;
    finally Check(RemoveDir(Dir),'audit directory cleaned'); end;
  finally CloseHandle(Token); end;
end;
{$else}
procedure TUnitTestGpoStorageAudit.ReadOnlyAclAssessment;
begin Check(True,'unsupported platform'); end;
{$endif}
end.
