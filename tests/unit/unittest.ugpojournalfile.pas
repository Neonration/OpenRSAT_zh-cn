unit unittest.ugpojournalfile;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses mormot.core.test;
type TUnitTestGpoJournalFile=class(TSynTestCase)
published procedure LocalCheckpoints; procedure CrossProcessDenial; procedure ShortPathAndReparse;
end;
function RunJournalProbe:Integer;
implementation
uses SysUtils,Classes,Process,ugpoformats,ugporeplaymodel,ugpojournalfile{$ifdef windows},Windows{$endif};
function ProbeFixture(out H:TReplayHeader; out E:TReplayEntries):Boolean;
var Missing,Empty:TGpoPolicyImage; Ini:TBytes;
begin
  H:=Default(TReplayHeader); E:=nil; Missing:=Default(TGpoPolicyImage); Empty:=Default(TGpoPolicyImage); Empty.Exists:=True;
  Result:=SerializeRegistryPol(nil,Empty.Data)=grsOk; if not Result then Exit;
  Ini:=TBytes.Create(91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,49);
  H.TransactionId:='external-expected-transaction'; H.Domain:='example.test'; H.DC:='dc.example.test';
  H.DN:='CN=test,DC=example,DC=test'; H.ObjectId:='test-object'; H.SessionId:='test-session';
  Result:=GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Empty,Missing,Missing,H.Plan)=gopOk;
  SetLength(E,1); E[0].Sequence:=1; E[0].Step:=rsUser; E[0].Kind:=rkIntent;
  E[0].Evidence:=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
end;
function RunJournalProbe:Integer;
var H:TReplayHeader; E:TReplayEntries; N,Code:Integer;
begin
  Result:=99; if ParamCount<>3 then Exit;
  Val(ParamStr(3),N,Code); if (Code<>0) or (N<0) or not ProbeFixture(H,E) then Exit;
  Result:=20+Ord(AssessJournal(ParamStr(2),N,H,E));
end;
{$ifdef windows}
function MakeSymbolicLink(LinkName,TargetName:PWideChar; Flags:DWORD):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateSymbolicLinkW';
function MakeHardLink(FileName,ExistingFileName:PWideChar; SecurityAttributes:Pointer):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateHardLinkW';
function GetShortPathNameW(LongPath,ShortPath:PWideChar; Size:DWORD):DWORD;
  stdcall; external 'kernel32.dll';

procedure TUnitTestGpoJournalFile.ShortPathAndReparse;
var Dir,Child,Link,ShortDir,Err,JournalPath:string; Id:TGUID; Buffer:UnicodeString;
  N:DWORD; LongHandle,ShortHandle:THandle; A,B:TByHandleFileInformation;
  Header:TReplayHeader; Entries:TReplayEntries; State:TReplayResult;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'OpenRSAT Short Path '+GUIDToString(Id);
  if not CreateDir(Dir) then begin Check(False,'cannot create short-path test directory'); Exit; end;
  Child:=Dir+'\child'; Link:=Dir+'-link';
  try
    if not CreateDir(Child) then begin Check(False,'cannot create child directory'); Exit; end;
    SetLength(Buffer,32768); N:=GetShortPathNameW(PWideChar(UTF8Decode(Dir)),PWideChar(Buffer),Length(Buffer));
    if (N>0) and (N<DWORD(Length(Buffer))) then begin
      SetLength(Buffer,N); ShortDir:=UTF8Encode(Buffer);
      if not SameText(ShortDir,Dir) then begin
        WriteLn('SHORT_PATH real alias exercised');
        if not OpenDirectory(Dir,False,LongHandle) then begin Check(False,'long path opens'); Exit; end;
        try
          if not OpenDirectory(ShortDir,False,ShortHandle) then begin Check(False,'short path opens'); Exit; end;
          try
            if not GetFileInformationByHandle(LongHandle,A) or not GetFileInformationByHandle(ShortHandle,B) then
            begin Check(False,'cannot read directory identity'); Exit; end;
            Check((A.dwVolumeSerialNumber=B.dwVolumeSerialNumber) and (A.nFileIndexHigh=B.nFileIndexHigh) and
              (A.nFileIndexLow=B.nFileIndexLow),'short and long names must open the same directory');
          finally CloseHandle(ShortHandle); end;
        finally CloseHandle(LongHandle); end;
        Check(ProbeFixture(Header,Entries));
        Check(SaveJournal(ShortDir,1,Header,Entries,Err),'journal create through short path');
        Check(LoadJournal(Dir,1,State,Err) and (State=rrInterrupted),'long path reopens same journal');
        JournalPath:=Dir+'\gpo-00000001.journal';
        Check(DeleteFileW(PWideChar(UTF8Decode(JournalPath))),'remove short path journal');
      end else WriteLn('SHORT_PATH alias unavailable on this volume');
    end else WriteLn('SHORT_PATH lookup unavailable');
    if MakeSymbolicLink(PWideChar(UTF8Decode(Link)),PWideChar(UTF8Decode(Dir)),1 or 2) then begin
      WriteLn('SHORT_PATH reparse ancestor exercised');
      if OpenDirectory(Link,False,LongHandle) then begin CloseHandle(LongHandle); Check(False,'final directory link rejected'); end
      else Check(True,'final directory link rejected');
      if OpenDirectory(Link+'\child',False,LongHandle) then begin CloseHandle(LongHandle); Check(False,'intermediate directory link rejected'); end
      else Check(True,'intermediate directory link rejected');
      Check(RemoveDir(Link),'remove test link');
    end else WriteLn('SHORT_PATH reparse ancestor skipped');
  finally
    Check(RemoveDir(Child),'remove child directory');
    Check(RemoveDir(Dir),'remove short path directory');
  end;
end;

procedure TUnitTestGpoJournalFile.LocalCheckpoints;
var Dir,LinkDir,Path,Err:string; Id:TGUID; H:TReplayHeader; E:TReplayEntries; S:TReplayResult;
  Empty,Missing:TGpoPolicyImage; Ini:TBytes; F:TFileStream; B:TBytes; C:Cardinal; I:Integer;
  function FileName(N:Integer):string;
  begin Result:=Dir+'\'+Format('gpo-%.8x.journal',[N]); end;
  procedure ReadBytes(N:Integer);
  begin F:=TFileStream.Create(FileName(N),fmOpenRead); try SetLength(B,F.Size); if F.Size>0 then F.ReadBuffer(B[0],F.Size); finally F.Free; end; end;
  procedure WriteBytes(N:Integer);
  begin F:=TFileStream.Create(FileName(N),fmCreate); try if Length(B)>0 then F.WriteBuffer(B[0],Length(B)); finally F.Free; end; end;
  procedure FixCrc;
  var X,Y:Integer;
  begin
    C:=$ffffffff; for X:=16 to High(B) do begin C:=C xor B[X];
      for Y:=1 to 8 do if (C and 1)<>0 then C:=(C shr 1) xor $edb88320 else C:=C shr 1; end;
    C:=not C; for Y:=0 to 3 do B[12+Y]:=Byte(C shr (8*Y));
  end;
  procedure AddPair(Step:TReplayStep);
  var N:Integer;
  begin
    N:=Length(E); SetLength(E,N+2); E[N].Sequence:=N+1; E[N].Step:=Step; E[N].Kind:=rkIntent;
    E[N].Evidence:=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
    E[N+1].Sequence:=N+2; E[N+1].Step:=Step; E[N+1].Kind:=rkConfirmed; E[N+1].Evidence:=[];
  end;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-journal-'+GUIDToString(Id);
  if not CreateDir(Dir) then begin Check(False,'cannot create journal directory'); Exit; end; LinkDir:=Dir+'-link';
  try
    Missing:=Default(TGpoPolicyImage); Empty:=Default(TGpoPolicyImage); Empty.Exists:=True;
    Check(SerializeRegistryPol(nil,Empty.Data)=grsOk);
    Ini:=TBytes.Create(91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,49);
    H.TransactionId:='isolated-test'; H.Domain:='example.test'; H.DC:='dc.example.test';
    H.DN:='CN=test,DC=example,DC=test'; H.ObjectId:='test-object'; H.SessionId:='test-session';
    Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Empty,Missing,Missing,H.Plan)=gopOk);
    E:=nil; if not SaveJournal(Dir,1,H,E,Err) then begin Check(False,'Save 1: '+Err); Exit; end;
    Check(LoadJournal(Dir,1,S,Err)); Check(S=rrNotStarted);
    Check(not SaveJournal(Dir,1,H,E,Err),'existing checkpoint never overwritten');
    SetLength(E,1); E[0].Sequence:=1; E[0].Step:=rsUser; E[0].Kind:=rkIntent;
    E[0].Evidence:=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
    if not SaveJournal(Dir,2,H,E,Err) then begin Check(False,'Save 2: '+Err); Exit; end;
    Check(LoadJournal(Dir,2,S,Err)); Check(S=rrInterrupted);
    SetLength(E,2); E[1].Sequence:=2; E[1].Step:=rsUser; E[1].Kind:=rkUnknown; E[1].Evidence:=[];
    Check(SaveJournal(Dir,3,H,E,Err)); Check(LoadJournal(Dir,3,S,Err)); Check(S=rrUnknown);
    E[1].Kind:=rkConflict; Check(SaveJournal(Dir,4,H,E,Err)); Check(LoadJournal(Dir,4,S,Err)); Check(S=rrConflict);
    E[1].Kind:=rkConfirmed; Check(SaveJournal(Dir,5,H,E,Err)); Check(LoadJournal(Dir,5,S,Err)); Check(S=rrInterrupted);
    E[0].Sequence:=2; Check(not SaveJournal(Dir,6,H,E,Err),'invalid sequence rejected before write'); E[0].Sequence:=1;
    E:=nil; AddPair(rsUser); AddPair(rsGpt); AddPair(rsGpc); AddPair(rsVerify);
    Check(SaveJournal(Dir,14,H,E,Err)); Check(LoadJournal(Dir,14,S,Err)); Check(S=rrVerified);
    ReadBytes(2); SetLength(B,Length(B)-1); WriteBytes(6); Check(not LoadJournal(Dir,6,S,Err)); Check(S=rrInvalid);
    ReadBytes(2); B[20]:=B[20] xor 1; WriteBytes(7); Check(not LoadJournal(Dir,7,S,Err),'checksum failure');
    ReadBytes(2); B[4]:=2; WriteBytes(8); Check(not LoadJournal(Dir,8,S,Err),'unknown version');
    ReadBytes(2); B[Length(B)-16]:=2; FixCrc; WriteBytes(9);
    Check(not LoadJournal(Dir,9,S,Err),'forged checksum cannot bypass sequence validation');
    ReadBytes(2); B[Length(B)-4]:=$ff; FixCrc; WriteBytes(10);
    Check(not LoadJournal(Dir,10,S,Err),'invalid evidence mask');
    ReadBytes(2); SetLength(B,Length(B)+1); C:=Length(B);
    B[8]:=Byte(C); B[9]:=Byte(C shr 8); B[10]:=Byte(C shr 16); B[11]:=Byte(C shr 24);
    FixCrc; WriteBytes(11); Check(not LoadJournal(Dir,11,S,Err),'trailing bytes rejected');
    ReadBytes(2); B[16]:=$ff; B[17]:=$ff; FixCrc; WriteBytes(15);
    Check(not LoadJournal(Dir,15,S,Err),'identity length limit');
    ReadBytes(2); B[Length(B)-20]:=11; FixCrc; WriteBytes(16);
    Check(not LoadJournal(Dir,16,S,Err),'record count limit');
    Check(not SaveJournalInjected(Dir,17,H,E,jfBeforeWrite,Err));
    Check(not LoadJournal(Dir,17,S,Err)); Check(not SaveJournal(Dir,17,H,E,Err));
    Check(not SaveJournalInjected(Dir,18,H,E,jfShortWrite,Err));
    Check(not LoadJournal(Dir,18,S,Err)); Check(not SaveJournal(Dir,18,H,E,Err));
    Check(not SaveJournalInjected(Dir,19,H,E,jfFlushFailure,Err));
    Check(FileExists(FileName(19))); Check(not SaveJournal(Dir,19,H,E,Err));
    Check(LoadJournal(Dir,19,S,Err)); Check(S=rrVerified,'self-consistency does not prove flush succeeded');
    Check(not LoadJournal(Dir+'\..\missing',1,S,Err));
    if MakeSymbolicLink(PWideChar(UTF8Decode(LinkDir)),PWideChar(UTF8Decode(Dir)),1 or 2) then begin
      WriteLn('LINK_TEST directory executed');
      Check(not LoadJournal(LinkDir,1,S,Err),'directory reparse point rejected');
      Check(not SaveJournal(LinkDir,12,H,E,Err),'directory reparse point cannot write');
      Check(RemoveDir(LinkDir));
    end else WriteLn('LINK_TEST directory skipped');
    Path:=FileName(12);
    if MakeSymbolicLink(PWideChar(UTF8Decode(Path)),PWideChar(UTF8Decode(FileName(1))),2) then begin
      WriteLn('LINK_TEST file executed');
      Check(not LoadJournal(Dir,12,S,Err),'file reparse point rejected'); Check(SysUtils.DeleteFile(Path));
    end else WriteLn('LINK_TEST file skipped');
    Path:=FileName(13);
    if MakeHardLink(PWideChar(UTF8Decode(Path)),PWideChar(UTF8Decode(FileName(1))),nil) then begin
      WriteLn('LINK_TEST hardlink executed');
      Check(not LoadJournal(Dir,13,S,Err),'hard links rejected'); Check(SysUtils.DeleteFile(Path));
    end else WriteLn('LINK_TEST hardlink skipped');
  finally
    for I:=1 to 19 do if FileExists(FileName(I)) then SysUtils.DeleteFile(FileName(I));
    Check(RemoveDir(Dir),'isolated test directory cleaned');
  end;
end;
procedure TUnitTestGpoJournalFile.CrossProcessDenial;
var Dir,Path,Err:string; Id:TGUID; H,Other:TReplayHeader; E,Old:TReplayEntries; P:TProcess;
  F:TFileStream; I:Integer; Corrupt:Byte; Missing,Full:TGpoPolicyImage; Rows:TGpoRegistryRecords;
  function Child(N:Integer):Integer;
  begin
    P:=TProcess.Create(nil);
    try
      P.Executable:=ParamStr(0); P.Parameters.Add('--gpo-journal-probe'); P.Parameters.Add(Dir);
      P.Parameters.Add(IntToStr(N)); P.Options:=[poWaitOnExit,poNoConsole]; P.Execute; Result:=P.ExitStatus;
    finally P.Free; end;
  end;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-probe-'+GUIDToString(Id);
  if not CreateDir(Dir) then begin Check(False,'cannot create probe directory'); Exit; end;
  try
    if not ProbeFixture(H,E) then begin Check(False,'cannot create probe fixture'); Exit; end;
    if not SaveJournal(Dir,1,H,E,Err) then begin Check(False,'cannot create probe checkpoint: '+Err); Exit; end;
    Check(Child(1)=20+Ord(jaMatchedUntrusted),'matching checkpoint remains denied');
    Other:=H; Other.TransactionId:='different-transaction'; Check(SaveJournal(Dir,2,Other,E,Err));
    Check(Child(2)=20+Ord(jaMismatch),'foreign transaction rejected');
    Other:=H; Other.DC:='other-dc.example.test'; Check(SaveJournal(Dir,3,Other,E,Err));
    Check(Child(3)=20+Ord(jaMismatch),'foreign target rejected');
    Old:=nil; Check(SaveJournal(Dir,4,H,Old,Err));
    Check(Child(4)=20+Ord(jaMismatch),'old checkpoint rejected against independent expected contents');
    Check(not SaveJournalInjected(Dir,5,H,E,jfFlushFailure,Err));
    Check(Child(5)=20+Ord(jaMatchedUntrusted),'flush failure cannot become permission');
    if not SaveJournal(Dir,6,H,E,Err) then begin Check(False,'cannot create corrupt fixture: '+Err); Exit; end;
    Path:=Dir+'\'+Format('gpo-%.8x.journal',[6]);
    F:=TFileStream.Create(Path,fmOpenReadWrite); try F.Position:=F.Size-1; F.ReadBuffer(Corrupt,1);
      Corrupt:=Corrupt xor 1; F.Position:=F.Size-1; F.WriteBuffer(Corrupt,1); finally F.Free; end;
    Check(Child(6)=20+Ord(jaInvalid),'corruption rejected');
    Check(not SaveJournalInjected(Dir,7,H,E,jfShortWrite,Err));
    Check(Child(7)<>20+Ord(jaMatchedUntrusted),'partial checkpoint rejected');
    Check(Child(8)=20+Ord(jaUnavailable),'missing checkpoint rejected');
    Other:=H; Other.ObjectId:='other-object'; Check(SaveJournal(Dir,9,Other,E,Err));
    Check(Child(9)=20+Ord(jaMismatch),'other object rejected');
    Missing:=Default(TGpoPolicyImage); Full:=Default(TGpoPolicyImage); Full.Exists:=True;
    SetLength(Rows,1); Rows[0].Key:='Software\Test'; Rows[0].ValueType:=3; Rows[0].Data:=TBytes.Create(9);
    Check(SerializeRegistryPol(Rows,Full.Data)=grsOk); Other:=H;
    Check(GpoBuildOfflinePlanWithPresence(1,1,H.Plan.Baseline.GptIni,Missing,Full,Missing,Missing,Other.Plan)=gopOk);
    Check(SaveJournal(Dir,10,Other,E,Err)); Check(Child(10)=20+Ord(jaMismatch),'other candidate rejected');
    Path:=Dir+'\machine.pol'; F:=TFileStream.Create(Path,fmCreate);
    try Corrupt:=77; F.WriteBuffer(Corrupt,1); finally F.Free; end;
    Check(Child(1)=20+Ord(jaMatchedUntrusted));
    F:=TFileStream.Create(Path,fmOpenRead); try Corrupt:=0; F.ReadBuffer(Corrupt,1);
      Check((F.Size=1) and (Corrupt=77),'diagnostic does not modify target'); finally F.Free; end;
  finally
    Path:=Dir+'\machine.pol'; if GetFileAttributesW(PWideChar(UTF8Decode(Path)))<>INVALID_FILE_ATTRIBUTES then
      Check(DeleteFileW(PWideChar(UTF8Decode(Path))),'remove probe target');
    for I:=1 to 10 do begin Path:=Dir+'\'+Format('gpo-%.8x.journal',[I]);
      if GetFileAttributesW(PWideChar(UTF8Decode(Path)))<>INVALID_FILE_ATTRIBUTES then
        Check(DeleteFileW(PWideChar(UTF8Decode(Path))),'remove probe checkpoint'); end;
    Check(RemoveDir(Dir),'probe test directory cleaned');
  end;
end;
{$else}
procedure TUnitTestGpoJournalFile.LocalCheckpoints;
begin Check(True,'unsupported platform'); end;
procedure TUnitTestGpoJournalFile.CrossProcessDenial;
begin Check(True,'unsupported platform'); end;
procedure TUnitTestGpoJournalFile.ShortPathAndReparse;
begin Check(True,'unsupported platform'); end;
{$endif}
end.
