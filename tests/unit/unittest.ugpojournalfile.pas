unit unittest.ugpojournalfile;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses mormot.core.test;
type TUnitTestGpoJournalFile=class(TSynTestCase)
published procedure LocalCheckpoints;
end;
implementation
uses SysUtils,Classes,ugpoformats,ugporeplaymodel,ugpojournalfile{$ifdef windows},Windows{$endif};
{$ifdef windows}
function MakeSymbolicLink(LinkName,TargetName:PWideChar; Flags:DWORD):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateSymbolicLinkW';
function MakeHardLink(FileName,ExistingFileName:PWideChar; SecurityAttributes:Pointer):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateHardLinkW';

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
  Check(CreateDir(Dir)); LinkDir:=Dir+'-link';
  try
    Missing:=Default(TGpoPolicyImage); Empty:=Default(TGpoPolicyImage); Empty.Exists:=True;
    Check(SerializeRegistryPol(nil,Empty.Data)=grsOk);
    Ini:=TBytes.Create(91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,49);
    H.TransactionId:='isolated-test'; H.Domain:='example.test'; H.DC:='dc.example.test';
    H.DN:='CN=test,DC=example,DC=test'; H.ObjectId:='test-object'; H.SessionId:='test-session';
    Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Empty,Missing,Missing,H.Plan)=gopOk);
    E:=nil; if not SaveJournal(Dir,1,H,E,Err) then raise Exception.Create('Save 1: '+Err);
    Check(LoadJournal(Dir,1,S,Err)); Check(S=rrNotStarted);
    Check(not SaveJournal(Dir,1,H,E,Err),'existing checkpoint never overwritten');
    SetLength(E,1); E[0].Sequence:=1; E[0].Step:=rsUser; E[0].Kind:=rkIntent;
    E[0].Evidence:=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
    Check(SaveJournal(Dir,2,H,E,Err)); Check(LoadJournal(Dir,2,S,Err)); Check(S=rrInterrupted);
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
{$else}
procedure TUnitTestGpoJournalFile.LocalCheckpoints;
begin Check(True,'unsupported platform'); end;
{$endif}
end.
