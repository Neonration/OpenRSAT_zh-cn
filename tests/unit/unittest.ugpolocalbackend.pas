unit unittest.ugpolocalbackend;
{$mode objfpc}{$H+}
interface
uses mormot.core.test;
type TUnitTestGpoLocalBackend=class(TSynTestCase)
published procedure ConditionalFiles; procedure PlanTrace; procedure StagedReplacement;
end;
implementation
uses SysUtils,Classes,ugpoformats,ugpolocalbackend,ugporeplaymodel,ugpojournalfile{$ifdef windows},Windows{$endif};
{$ifdef windows}
function MakeSymbolicLink(LinkName,TargetName:PWideChar; Flags:Cardinal):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateSymbolicLinkW';
function MakeHardLink(FileName,ExistingFileName:PWideChar; SecurityAttributes:Pointer):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateHardLinkW';
procedure TUnitTestGpoLocalBackend.ConditionalFiles;
var Dir:string; Id:TGUID; B,Other:TLocalBackend; Base,Now,Wrong:TLocalSnapshot;
  Image,Absent:TGpoPolicyImage; R,Q:TLocalReceipt; Side:TLocalSide;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-backend-'+GUIDToString(Id);
  Check(CreateDir(Dir)); B:=TLocalBackend.Create(Dir); Other:=TLocalBackend.Create(Dir);
  try
    Check(B.Ready); Check(Other.Ready); Absent:=Default(TGpoPolicyImage);
    for Side:=Low(TLocalSide) to High(TLocalSide) do begin
      Check(B.Observe(Side,Base)=lrOk); Check(not Base.Exists);
      Image.Exists:=True; Image.Data:=TBytes.Create(1,2,3);
      Check(B.Publish(Side,Base,Image,lfNone,R)=lrOk); Check(Assigned(R));
      Check(B.Observe(Side,Now)=lrOk); Check(Now.Exists and (Length(Now.Data)=3));
      Check(B.Publish(Side,Base,Image,lfNone,Q)=lrConflict); Check(Q=nil);
      Check(Other.Restore(R,lfNone)=lrInvalid,'receipt bound to backend instance');
      Check(B.Restore(R,lfNone)=lrOk); Check(B.Restore(R,lfNone)=lrInvalid); R.Free;
      Check(B.Observe(Side,Base)=lrOk); Check(not Base.Exists);
      Check(B.Publish(Side,Base,Image,lfNone,R)=lrOk); R.Free;
      Check(B.Observe(Side,Base)=lrOk); Wrong:=Base; Wrong.IndexLow:=Wrong.IndexLow xor 1;
      Image.Data:=TBytes.Create(4,5); Check(B.Publish(Side,Wrong,Image,lfNone,R)=lrConflict);
      Wrong:=Base; Wrong.Data:=Copy(Base.Data); Wrong.Data[0]:=99;
      Check(B.Publish(Side,Wrong,Image,lfNone,R)=lrConflict);
      Check(B.Publish(Side,Base,Image,lfNone,R)=lrUnavailable); Check(R=nil,'unsafe in-place replacement blocked');
      Check(B.Observe(Side,Now)=lrOk); Check((Length(Now.Data)=3) and (Now.Data[0]=1));
      Image.Data:=Copy(Now.Data); Check(B.Publish(Side,Now,Image,lfNone,Q)=lrOk); Check(Q=nil,'no-op makes no receipt');
      Check(B.Publish(Side,Now,Absent,lfNone,R)=lrOk); Check(B.Observe(Side,Base)=lrOk); Check(not Base.Exists);
      Check(B.Restore(R,lfNone)=lrUnavailable,'deleted ACL cannot be restored safely'); R.Free;
      Image.Data:=TBytes.Create(1,2,3); Check(B.Publish(Side,Base,Image,lfNone,Q)=lrOk); Q.Free;
      Check(B.Observe(Side,Now)=lrOk); Check(Now.Exists and (Length(Now.Data)=3));
      Check(B.Publish(Side,Now,Absent,lfNone,R)=lrOk);
      Check(Other.Observe(Side,Base)=lrOk); Image.Data:=TBytes.Create(77);
      Check(Other.Publish(Side,Base,Image,lfNone,Q)=lrOk); Q.Free;
      Check(B.Restore(R,lfNone)=lrUnavailable,'recreated file is never overwritten'); R.Free;
      Check(Other.Observe(Side,Base)=lrOk); Check((Length(Base.Data)=1) and (Base.Data[0]=77));
      Check(Other.Publish(Side,Base,Absent,lfNone,Q)=lrOk); Q.Free;
      Check(B.Observe(Side,Base)=lrOk); Image.Data:=TBytes.Create(1,2,3);
      Check(B.Publish(Side,Base,Image,lfNone,R)=lrOk);
      Check(Other.Observe(Side,Base)=lrOk); Check(Other.Publish(Side,Base,Absent,lfNone,Q)=lrOk); Q.Free;
      Check(Other.Observe(Side,Base)=lrOk); Image.Data:=TBytes.Create(9);
      Check(Other.Publish(Side,Base,Image,lfNone,Q)=lrOk); Q.Free;
      Check(B.Restore(R,lfNone)=lrConflict,'external change blocks recovery');
      Check(B.Restore(R,lfNone)=lrInvalid,'conflict stops automatic retry'); R.Free;
      Check(B.Observe(Side,Base)=lrOk); Check((Length(Base.Data)=1) and (Base.Data[0]=9));
      Check(B.Publish(Side,Base,Absent,lfBeforeMutation,R)=lrUnavailable); Check(R=nil);
      Check(B.Observe(Side,Now)=lrOk); Check((Length(Now.Data)=1) and (Now.Data[0]=9));
      Check(B.Publish(Side,Now,Absent,lfAfterMutation,R)=lrUnknown); Check(R=nil);
      Check(B.Observe(Side,Base)=lrOk); Check(not Base.Exists);
      Check(B.Publish(Side,Base,Absent,lfNone,R)=lrOk); Check(R=nil);
      Image.Data:=TBytes.Create(5); Check(B.Publish(Side,Base,Image,lfNone,R)=lrOk);
      Check(B.Restore(R,lfAfterMutation)=lrUnknown); Check(B.Restore(R,lfNone)=lrInvalid); R.Free;
      Check(B.Observe(Side,Now)=lrOk); Check(not Now.Exists);
    end;
    Check(B.Observe(lsUser,Base)=lrOk); Image.Exists:=True; Image.Data:=TBytes.Create(88);
    Check(B.Publish(lsUser,Base,Image,lfNone,R)=lrOk); R.Free;
    if MakeSymbolicLink(PWideChar(UTF8Decode(Dir+'\machine.pol')),
      PWideChar(UTF8Decode(Dir+'\user.pol')),2) then begin
      WriteLn('BACKEND_LINK symlink executed');
      Check(B.Observe(lsMachine,Now)=lrUnavailable); Check(SysUtils.DeleteFile(Dir+'\machine.pol'));
    end else WriteLn('BACKEND_LINK symlink skipped');
    if MakeHardLink(PWideChar(UTF8Decode(Dir+'\machine.pol')),
      PWideChar(UTF8Decode(Dir+'\user.pol')),nil) then begin
      WriteLn('BACKEND_LINK hardlink executed');
      Check(B.Observe(lsMachine,Now)=lrUnavailable); Check(SysUtils.DeleteFile(Dir+'\machine.pol'));
    end else WriteLn('BACKEND_LINK hardlink skipped');
    Check(B.Observe(lsUser,Now)=lrOk); Check((Length(Now.Data)=1) and (Now.Data[0]=88));
  finally
    B.Free; Other.Free;
    if FileExists(Dir+'\machine.pol') then SysUtils.DeleteFile(Dir+'\machine.pol');
    if FileExists(Dir+'\user.pol') then SysUtils.DeleteFile(Dir+'\user.pol');
    Check(RemoveDir(Dir),'test directory cleaned');
  end;
end;
procedure TUnitTestGpoLocalBackend.PlanTrace;
var Dir,Err:string; Id:TGUID; B,Other:TLocalBackend; H:TReplayHeader; E:TReplayEntries;
  Missing,Empty:TGpoPolicyImage; OldMachine,OldUser,Current:TLocalSnapshot; Ini:TBytes;
  MachineReceipt,ThirdParty:TLocalReceipt; State:TReplayResult; I:Integer;
  procedure Add(Step:TReplayStep; Kind:TReplayKind);
  var N:Integer;
  begin
    N:=Length(E); SetLength(E,N+1); E[N].Sequence:=N+1; E[N].Step:=Step; E[N].Kind:=Kind;
    // Model flags are simulated; the checkpoint never authorizes the real test operation.
    if Kind=rkIntent then E[N].Evidence:=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate]
    else E[N].Evidence:=[];
  end;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-trace-'+GUIDToString(Id); Check(CreateDir(Dir));
  B:=TLocalBackend.Create(Dir); Other:=TLocalBackend.Create(Dir);
  try
    Check(B.Ready and Other.Ready); Missing:=Default(TGpoPolicyImage); Empty:=Default(TGpoPolicyImage); Empty.Exists:=True;
    Check(SerializeRegistryPol(nil,Empty.Data)=grsOk);
    Ini:=TBytes.Create(91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,49);
    H.TransactionId:='test-trace'; H.Domain:='example.test'; H.DC:='dc.example.test';
    H.DN:='CN=test,DC=example,DC=test'; H.ObjectId:='test-object'; H.SessionId:='test-session';
    Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Empty,Missing,Empty,H.Plan)=gopOk);
    Check(B.Observe(lsMachine,OldMachine)=lrOk); Check(B.Observe(lsUser,OldUser)=lrOk);
    E:=nil; Add(rsMachine,rkIntent); Check(SaveJournal(Dir,1,H,E,Err));
    Check(B.Publish(lsMachine,OldMachine,Empty,lfNone,MachineReceipt)=lrOk);
    Add(rsMachine,rkConfirmed); Check(SaveJournal(Dir,2,H,E,Err));
    Check(Other.Publish(lsUser,OldUser,Empty,lfNone,ThirdParty)=lrOk); ThirdParty.Free;
    Add(rsUser,rkIntent); Check(SaveJournal(Dir,3,H,E,Err));
    Check(B.Publish(lsUser,OldUser,Empty,lfNone,ThirdParty)=lrConflict);
    Add(rsUser,rkConflict); Check(SaveJournal(Dir,4,H,E,Err));
    Check(LoadJournal(Dir,4,State,Err)); Check(State=rrPartialConflict);
    Check(B.Restore(MachineReceipt,lfNone)=lrOk); MachineReceipt.Free;
    Check(B.Observe(lsMachine,Current)=lrOk); Check(not Current.Exists);
    Check(B.Observe(lsUser,Current)=lrOk); Check(Current.Exists);
  finally
    B.Free; Other.Free;
    if FileExists(Dir+'\machine.pol') then SysUtils.DeleteFile(Dir+'\machine.pol');
    if FileExists(Dir+'\user.pol') then SysUtils.DeleteFile(Dir+'\user.pol');
    for I:=1 to 4 do Check(Windows.DeleteFileW(PWideChar(UTF8Decode(Dir+'\'+Format('gpo-%.8x.journal',[I])))),
      'remove trace checkpoint');
    Check(RemoveDir(Dir),'trace test directory cleaned');
  end;
end;
procedure TUnitTestGpoLocalBackend.StagedReplacement;
var Dir,Prefix,Path:string; Id:TGUID; B:TLocalBackend; Side:TLocalSide; Base,Current,Wrong:TLocalSnapshot;
  Image:TGpoPolicyImage; R:TLocalReceipt; Evidence:TStageEvidence; Before,After,FileData:TBytes;
  F:TFileStream;
  function Security(const FilePath:string):TBytes;
  var Handle:THandle; L,Got:DWORD;
  begin
    Result:=nil; Handle:=CreateFileW(PWideChar(UTF8Decode(FilePath)),$00020000,FILE_SHARE_READ,nil,OPEN_EXISTING,0,0);
    if Handle=INVALID_HANDLE_VALUE then Exit;
    try
      L:=0; GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,nil,0,@L);
      if L=0 then Exit; SetLength(Result,L);
      if not GetKernelObjectSecurity(Handle,OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
        PSECURITY_DESCRIPTOR(@Result[0]),L,@Got) then Result:=nil;
    finally CloseHandle(Handle); end;
  end;
  function Equal(const A,C:TBytes):Boolean;
  begin Result:=(Length(A)=Length(C)) and ((Length(A)=0) or CompareMem(@A[0],@C[0],Length(A))); end;
  procedure CheckOriginal;
  begin
    Check(B.Observe(Side,Current)=lrOk); Check(Current.Exists and (Current.IndexLow=Base.IndexLow) and
      (Current.IndexHigh=Base.IndexHigh) and (Current.Volume=Base.Volume) and Equal(Current.Data,Base.Data));
    After:=Security(Path); Check((Length(Before)>0) and Equal(Before,After),'original owner and DACL unchanged');
  end;
  procedure RemoveArtifact(const S:string);
  begin Check(DeleteFileW(PWideChar(UTF8Decode(Dir+'\'+Prefix+S))),'remove isolated artifact'); end;
  procedure ReadArtifact(const S:string);
  begin
    F:=TFileStream.Create(Dir+'\'+Prefix+S,fmOpenRead);
    try SetLength(FileData,F.Size); if F.Size>0 then F.ReadBuffer(FileData[0],F.Size); finally F.Free; end;
  end;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-stage-'+GUIDToString(Id); Check(CreateDir(Dir));
  B:=TLocalBackend.Create(Dir);
  try
    Check(B.Ready);
    for Side:=Low(TLocalSide) to High(TLocalSide) do begin
      if Side=lsMachine then Prefix:='machine' else Prefix:='user'; Path:=Dir+'\'+Prefix+'.pol';
      Check(B.Observe(Side,Base)=lrOk); Image.Exists:=True; Image.Data:=TBytes.Create(1,2,3);
      Check(B.Publish(Side,Base,Image,lfNone,R)=lrOk); R.Free;
      Check(B.Observe(Side,Base)=lrOk); Before:=Security(Path); Check(Length(Before)>0);
      Wrong:=Base; Wrong.IndexLow:=Wrong.IndexLow xor 1;
      Check(B.PrepareReplacement(Side,Wrong,TBytes.Create(8,9),sfNone,Evidence)=lrConflict); CheckOriginal;
      Check(B.PrepareReplacement(Side,Base,TBytes.Create(8,9),sfBeforeBackup,Evidence)=lrUnavailable); CheckOriginal;
      Check(B.PrepareReplacement(Side,Base,TBytes.Create(8,9),sfAfterBackup,Evidence)=lrUnavailable);
      ReadArtifact('.backup'); Check(Equal(FileData,Base.Data)); CheckOriginal; RemoveArtifact('.backup');
      Check(B.PrepareReplacement(Side,Base,TBytes.Create(8,9),sfPartialCandidate,Evidence)=lrUnknown);
      ReadArtifact('.backup'); Check(Equal(FileData,Base.Data)); ReadArtifact('.candidate'); Check(Length(FileData)=1);
      CheckOriginal; RemoveArtifact('.backup'); RemoveArtifact('.candidate');
      Check(B.PrepareReplacement(Side,Base,TBytes.Create(8,9),sfNone,Evidence)=lrOk);
      Check(Equal(Evidence.Original.Data,Base.Data)); Check(Equal(Evidence.Backup.Data,Base.Data));
      Check(Equal(Evidence.Candidate.Data,TBytes.Create(8,9))); Check(Equal(Evidence.OriginalSecurity,Before));
      ReadArtifact('.backup'); Check(Equal(FileData,Base.Data)); ReadArtifact('.candidate'); Check(Equal(FileData,TBytes.Create(8,9)));
      Check(B.PrepareReplacement(Side,Base,TBytes.Create(7),sfNone,Evidence)=lrConflict); CheckOriginal;
      RemoveArtifact('.backup'); RemoveArtifact('.candidate');
      Check(DeleteFileW(PWideChar(UTF8Decode(Path))),'remove isolated original');
    end;
  finally B.Free; Check(RemoveDir(Dir),'stage test directory cleaned'); end;
end;
{$else}
procedure TUnitTestGpoLocalBackend.ConditionalFiles; begin Check(True,'unsupported platform'); end;
procedure TUnitTestGpoLocalBackend.PlanTrace; begin Check(True,'unsupported platform'); end;
procedure TUnitTestGpoLocalBackend.StagedReplacement; begin Check(True,'unsupported platform'); end;
{$endif}
end.
