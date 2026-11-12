unit unittest.ugpowritemodel;
{$mode objfpc}{$H+}
interface
uses mormot.core.test;
type TUnitTestGpoWriteModel=class(TSynTestCase)
  published procedure ExperimentalModel;
end;
implementation
uses SysUtils,ugpoformats,ugpowritemodel;
var Tests:Integer; ActiveCase:TUnitTestGpoWriteModel; Base,Dest,Cur,Other:TSnapshot; Rows:TGpoRegistryRecords; Last:TStepToken;
procedure Check(B:Boolean; const MessageText:string);
begin Inc(Tests); ActiveCase.Check(B,MessageText); if not B then raise Exception.Create(MessageText); end;
function CopySnap(const A:TSnapshot):TSnapshot; begin Result:=SnapshotCopy(A); end;
procedure Step(P:TPlan; Status:TOutcome; const S:TSnapshot);
var T,U:TStepToken;
begin Check(P.BeginStep(T),'begin expected'); Check(not P.BeginStep(U),'duplicate begin blocked'); Check(P.Advance(T,Status,S),'advance expected'); Last:=T;end;
procedure Mutate(var S:TSnapshot; Stage:TStage);
begin
  case Stage of
    stPublish:begin S.Exists:=Dest.Exists;S.Policy:=Copy(Dest.Policy);end;
    stGpt:begin S.GptVersion:=Dest.GptVersion;S.Ini:=Copy(Dest.Ini);end;
    stGpc:begin S.GpcVersion:=Dest.GpcVersion;S.Metadata:=Copy(Dest.Metadata);end;
  end;
end;
procedure Reach(P:TPlan; Goal:TStage; var S:TSnapshot);
begin
  while P.Stage<>Goal do begin
    if P.Stage in [stPublish,stGpt,stGpc] then Mutate(S,P.Stage);
    Step(P,ocOk,S);
  end;
end;
procedure TokenRegressions;
var P,Q:TPlan; S,Changed:TSnapshot; A,B,C,Foreign:TStepToken; N:QWord;
begin
  P:=TPlan.Create(Base,Dest); S:=CopySnap(Base);
  Check(P.BeginStep(A),'start check'); Check(P.Advance(A,ocOk,S),'check complete');
  Check(P.BeginStep(B),'start backup'); Check(not P.Advance(A,ocOk,S),'stale check rejected during backup');
  Check((P.Stage=stBackup) and not P.BackupConfirmed,'backup stays pending');
  Check(P.Advance(B,ocOk,S),'real backup accepted'); Check(not P.Advance(B,ocOk,S),'duplicate rejected');
  Mutate(S,stPublish);Step(P,ocOk,S);Mutate(S,stGpt);Step(P,ocOk,S);Mutate(S,stGpc);
  Check(P.BeginStep(C),'start gpc');Check(P.Advance(C,ocOk,S),'complete gpc');
  Check(P.BeginStep(B),'start final verify');Changed:=CopySnap(S);Changed.GptVersion:=88;
  Check(not P.Advance(C,ocOk,S),'stale gpc rejected during verify');
  Check(P.Stage=stVerify,'verify still pending');Check(P.Advance(B,ocOk,Changed),'actual verify accepted');
  Check(P.Stage=stUnknown,'changed final snapshot not success');
  Check((P.LastAttemptedStage=stVerify) and (P.LastDirection=dirSubmit) and
    (P.LastOutcome=doOk) and (P.UnknownReason=urObservationMismatch),'forward mismatch diagnostics');P.Free;

  P:=TPlan.Create(Base,Dest);S:=CopySnap(Base);Check(P.BeginStep(A),'recovery initial');
  Check(P.Advance(A,ocOk,S),'recovery check');Reach(P,stVerify,S);Step(P,ocFail,S);
  Check(P.PrepareRecovery(S),'prepare');Step(P,ocOk,S);Check(P.Stage=stVerifyRecovery,'recovery verify');
  Check(P.BeginStep(B),'begin recovery verify');Check(not P.Advance(A,ocOk,Base),'stale check rejected during recovery verify');
  Changed:=CopySnap(Base);Changed.GpcVersion:=44;Check(P.Advance(B,ocOk,Changed),'actual recovery verify');
  Check(P.Stage=stUnknown,'changed recovery not success');
  Check((P.LastAttemptedStage=stVerifyRecovery) and (P.LastDirection=dirRecovery) and
    (P.UnknownReason=urObservationMismatch),'recovery mismatch diagnostics');P.Free;

  P:=TPlan.Create(Base,Dest);Q:=TPlan.Create(Base,Dest);Check(P.BeginStep(A) and Q.BeginStep(B),'two plans begin');
  Check(not P.Advance(B,ocOk,Base),'foreign token rejected');Check(P.Advance(A,ocOk,Base),'correct token remains valid');
  Q.Cancel;Check(not Q.Advance(B,ocOk,Base),'cancel invalidates token');P.Free;Q.Free;
  P:=TPlan.Create(Base,Dest);Check(P.BeginStep(Foreign),'old instance token');P.Free;
  P:=TPlan.Create(Base,Dest);Check(P.BeginStep(B),'new instance token');
  Check(not P.Advance(Foreign,ocOk,Base),'recreated plan rejects old token');
  C:=B;C.Step:=stBackup;Check(not P.Advance(C,ocOk,Base),'forged phase rejected');
  Check(P.Advance(B,ocOk,Base),'valid result follows rejections');P.Free;
  N:=High(QWord)-1;Check(NextStepSequence(N) and (N=High(QWord)),'last sequence issued');
  Check(not NextStepSequence(N) and (N=High(QWord)),'sequence overflow fails closed');

  P:=TPlan.Create(Base,Dest);S:=CopySnap(Base);Reach(P,stVerify,S);Step(P,ocUnknown,S);
  Check((P.LastAttemptedStage=stVerify) and (P.LastDirection=dirSubmit) and
    (P.LastOutcome=doUnknown) and (P.UnknownReason=urOperationUnknown) and
    (P.UnknownStage=stVerify) and (P.UnknownDirection=dirSubmit),'forward unknown diagnostic');P.Free;
  P:=TPlan.Create(Base,Dest);S:=CopySnap(Base);Reach(P,stVerify,S);Step(P,ocFail,S);
  Check(P.PrepareRecovery(S),'prepare for unknown recovery');Step(P,ocOk,S);Step(P,ocUnknown,Base);
  Check((P.LastAttemptedStage=stVerifyRecovery) and (P.LastDirection=dirRecovery) and
    (P.LastOutcome=doUnknown) and (P.UnknownReason=urOperationUnknown) and
    (P.UnknownStage=stVerifyRecovery) and (P.UnknownDirection=dirRecovery),'recovery unknown diagnostic');P.Free;
end;
procedure TUnitTestGpoWriteModel.ExperimentalModel;
var P,Q:TPlan; St:TStage; Before:TBytes;
begin
  ActiveCase:=Self; Tests:=0;
  Base:=Default(TSnapshot);Base.Domain:='example.test';Base.DC:='dc.example.test';Base.Guid:='{G}';Base.Session:='session-1';
  Base.GpcVersion:=1;Base.GptVersion:=1;Base.Exists:=True;
  Check(SerializeRegistryPol(nil,Base.Policy)=grsOk,'serialize baseline');
  Base.Ini:=TBytes.Create(1);Base.Metadata:=TBytes.Create(2);
  SetLength(Rows,1);Rows[0].Key:='Software\Test';Rows[0].ValueType:=3;Rows[0].Data:=TBytes.Create(42);
  Dest:=CopySnap(Base);Check(SerializeRegistryPol(Rows,Dest.Policy)=grsOk,'serialize candidate');
  Dest.GpcVersion:=2;Dest.GptVersion:=2;Dest.Ini:=TBytes.Create(3);Dest.Metadata:=TBytes.Create(4);
  P:=TPlan.Create(Base,Dest); Cur:=CopySnap(Base);Reach(P,stSucceeded,Cur);
  Check(P.BackupConfirmed and P.PublishConfirmed and P.GptConfirmed and P.GpcConfirmed,'successful steps recorded');
  Check(SameSnapshot(Cur,Dest),'success verified');Check(not P.Advance(Last,ocOk,Cur),'repeat commit blocked');P.Free;
  for St:=stCheck to stVerify do begin
    P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,St,Cur);Step(P,ocFail,Cur);
    if St in [stCheck,stBackup,stPublish] then Check(P.Stage=stFailed,'early failure')
    else Check(P.Stage=stNeedsRecovery,'partial failure');
    Check(P.Stage<>stSucceeded,'no false success');P.Free;
    P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,St,Cur);Step(P,ocUnknown,Cur);
    Check(P.Stage=stUnknown,'unknown response');Check(not P.PrepareRecovery(Cur),'no blind rollback');P.Free;
    P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,St,Cur);P.Cancel;
    if St in [stCheck,stBackup,stPublish] then Check(P.Stage=stCancelled,'cancel before publish')
    else Check(P.Stage=stUnknown,'cancel after publish uncertain');P.Free;
    P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,St,Cur);
    Check(P.BeginStep(Last),'begin before in-flight cancellation');P.Cancel;Check(P.Stage=stUnknown,'in-flight cancellation uncertain');
    Check(not P.Advance(Last,ocOk,Cur),'late result ignored after cancel');P.Free;
  end;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Cur.GptVersion:=99;Step(P,ocOk,Cur);Check(P.Stage=stConflict,'baseline version conflict');P.Free;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Cur.Policy[0]:=0;Step(P,ocOk,Cur);Check(P.Stage=stConflict,'baseline content conflict');P.Free;
  Other:=CopySnap(Dest);Other.Session:='other';P:=TPlan.Create(Base,Other);Check(P.Stage=stInvalid,'identity mismatch');P.Free;
  Other:=CopySnap(Dest);Other.Policy:=TBytes.Create(0);P:=TPlan.Create(Base,Other);Check(P.Stage=stInvalid,'invalid candidate');P.Free;
  P:=TPlan.Create(Base,Base);Check(P.Stage=stInvalid,'unchanged plan');P.Free;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,stGpc,Cur);Step(P,ocFail,Cur);
  Check(P.PublishConfirmed and P.GptConfirmed and not P.GpcConfirmed,'partial progress recorded');
  Other:=CopySnap(Cur);Other.Metadata:=TBytes.Create(99);Check(not P.PrepareRecovery(Other),'external change prohibits recovery');Check(P.Stage=stConflict,'recovery conflict');P.Free;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,stGpt,Cur);Step(P,ocFail,Cur);Check(P.PrepareRecovery(Cur),'prepare recovery');Step(P,ocFail,Cur);Check(P.Stage=stRecoveryFailed,'recovery failed');P.Free;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,stGpt,Cur);Step(P,ocFail,Cur);Check(P.PrepareRecovery(Cur),'prepare recovery');Step(P,ocOk,Cur);Step(P,ocOk,Base);Check(P.Stage=stRecovered,'verified recovery');P.Free;
  P:=TPlan.Create(Base,Dest);Cur:=CopySnap(Base);Reach(P,stVerify,Cur);Other:=CopySnap(Cur);Other.GpcVersion:=77;Step(P,ocOk,Other);Check(P.Stage=stUnknown,'verify mismatch');P.Free;
  // Fake compare-and-swap backend: both read the same baseline; only the first conditional publish wins.
  Cur:=CopySnap(Base);P:=TPlan.Create(Base,Dest);Q:=TPlan.Create(Base,Dest);
  Step(P,ocOk,Cur);Step(Q,ocOk,Cur);Step(P,ocOk,Cur);Step(Q,ocOk,Cur);
  Check(SameSnapshot(Cur,Base),'fake CAS first baseline');Mutate(Cur,stPublish);Step(P,ocOk,Cur);
  Check(not SameSnapshot(Cur,Base),'fake CAS second rejects');Step(Q,ocConflict,Cur);
  Check(Q.Stage=stConflict,'competing plan cannot proceed');Check(not Q.PublishConfirmed,'loser has no confirmed publish');Check(P.Stage=stGpt,'winner continues');P.Free;Q.Free;
  P:=TPlan.Create(Base,Dest); Before:=Copy(Dest.Policy);Dest.Policy[0]:=0;Cur:=CopySnap(Base);Reach(P,stPublish,Cur);
  Cur.Policy:=Before;Step(P,ocOk,Cur);Check(P.Stage=stGpt,'plan owns independent candidate');P.Free;
  Dest.Policy:=Before; TokenRegressions;
  ActiveCase:=nil;
end;
end.
