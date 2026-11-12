unit ugpowritemodel;
{$mode objfpc}{$H+}
interface
uses SysUtils, ugpoformats;
type
  TSnapshot=record
    Domain,DC,Guid,Session: string;
    GpcVersion,GptVersion:Cardinal;
    Exists:Boolean;
    Policy,Ini,Metadata:TBytes;
  end;
  TStage=(stInvalid,stCheck,stBackup,stPublish,stGpt,stGpc,stVerify,
    stSucceeded,stConflict,stFailed,stCancelled,stUnknown,stNeedsRecovery,
    stRecoveryReady,stVerifyRecovery,stRecovered,stRecoveryFailed);
  TOutcome=(ocOk,ocFail,ocUnknown,ocConflict);
  TDirection=(dirSubmit,dirRecovery);
  TDiagnosticOutcome=(doNone,doOk,doFail,doUnknown,doConflict,doCancelled);
  TUnknownReason=(urNone,urOperationUnknown,urInFlightCancel,urAfterWriteCancel,urObservationMismatch,urTokenExhausted);
  TStepToken=record
    PlanId:TGUID;
    Sequence:QWord;
    Step:TStage;
  end;
  TPlan=class
  private
    FBase,FDesired,FLast:TSnapshot;
    FStage:TStage;
    FInFlight:Boolean;
    FPlanId:TGUID;
    FSequence:QWord;
    FActiveToken,FLastToken:TStepToken;
    FLastAttemptedStage:TStage;
    FLastDirection:TDirection;
    FLastOutcome:TDiagnosticOutcome;
    FUnknownReason:TUnknownReason;
    FUnknownStage:TStage;
    FUnknownDirection:TDirection;
    FBackupConfirmed,FPublishConfirmed,FGptConfirmed,FGpcConfirmed:Boolean;
    procedure MarkUnknown(Reason:TUnknownReason);
    function SameIdentity(const A,B:TSnapshot):Boolean;
  public
    constructor Create(const Baseline,Desired:TSnapshot);
    function BeginStep(out Token:TStepToken):Boolean;
    function Advance(const Token:TStepToken; Outcome:TOutcome; const Observed:TSnapshot):Boolean;
    procedure Cancel;
    function PrepareRecovery(const Observed:TSnapshot):Boolean;
    property Stage:TStage read FStage;
    property LastToken:TStepToken read FLastToken;
    property LastAttemptedStage:TStage read FLastAttemptedStage;
    property LastDirection:TDirection read FLastDirection;
    property LastOutcome:TDiagnosticOutcome read FLastOutcome;
    property UnknownReason:TUnknownReason read FUnknownReason;
    property UnknownStage:TStage read FUnknownStage;
    property UnknownDirection:TDirection read FUnknownDirection;
    property BackupConfirmed:Boolean read FBackupConfirmed;
    property PublishConfirmed:Boolean read FPublishConfirmed;
    property GptConfirmed:Boolean read FGptConfirmed;
    property GpcConfirmed:Boolean read FGpcConfirmed;
  end;
function NextStepSequence(var Value:QWord):Boolean;
function SameSnapshot(const A,B:TSnapshot):Boolean;
function SnapshotCopy(const A:TSnapshot):TSnapshot;
implementation
function NextStepSequence(var Value:QWord):Boolean;
begin Result:=Value<High(QWord); if Result then Inc(Value);end;
function BytesEqual(const A,B:TBytes):Boolean;
begin Result:=(Length(A)=Length(B)) and ((Length(A)=0) or CompareMem(@A[0],@B[0],Length(A))); end;
function SnapshotCopy(const A:TSnapshot):TSnapshot;
begin Result:=A;Result.Policy:=Copy(A.Policy);Result.Ini:=Copy(A.Ini);Result.Metadata:=Copy(A.Metadata); end;
function SameSnapshot(const A,B:TSnapshot):Boolean;
begin Result:=(A.Domain=B.Domain) and (A.DC=B.DC) and (A.Guid=B.Guid) and (A.Session=B.Session) and
  (A.GpcVersion=B.GpcVersion) and (A.GptVersion=B.GptVersion) and (A.Exists=B.Exists) and
  BytesEqual(A.Policy,B.Policy) and BytesEqual(A.Ini,B.Ini) and BytesEqual(A.Metadata,B.Metadata);end;
function TPlan.SameIdentity(const A,B:TSnapshot):Boolean;
begin Result:=(A.Domain<>'') and (A.DC<>'') and (A.Guid<>'') and (A.Session<>'') and
  (A.Domain=B.Domain) and (A.DC=B.DC) and (A.Guid=B.Guid) and (A.Session=B.Session);end;
constructor TPlan.Create(const Baseline,Desired:TSnapshot);
var Records:TGpoRegistryRecords;
begin
  inherited Create; FStage:=stInvalid; if CreateGUID(FPlanId)<>0 then Exit; FBase:=SnapshotCopy(Baseline); FDesired:=SnapshotCopy(Desired); FLast:=SnapshotCopy(Baseline);
  if not SameIdentity(FBase,FDesired) or not FDesired.Exists then Exit;
  if (not FBase.Exists) and (Length(FBase.Policy)<>0) then Exit;
  if ParseRegistryPol(FDesired.Policy,Records)<>grsOk then Exit;
  if SameSnapshot(FBase,FDesired) then Exit;
  FStage:=stCheck;
end;
procedure TPlan.MarkUnknown(Reason:TUnknownReason);
begin
  FUnknownStage:=FStage;
  if FStage in [stRecoveryReady,stVerifyRecovery] then FUnknownDirection:=dirRecovery else FUnknownDirection:=dirSubmit;
  FUnknownReason:=Reason; FStage:=stUnknown;
end;
function TPlan.BeginStep(out Token:TStepToken):Boolean;
begin
  Token:=Default(TStepToken);
  Result:=not FInFlight and (FStage in [stCheck,stBackup,stPublish,stGpt,stGpc,stVerify,stRecoveryReady,stVerifyRecovery]);
  if not Result then Exit;
  if not NextStepSequence(FSequence) then begin MarkUnknown(urTokenExhausted); Result:=False; Exit;end;
  FActiveToken.PlanId:=FPlanId; FActiveToken.Sequence:=FSequence; FActiveToken.Step:=FStage;
  FLastToken:=FActiveToken; FLastAttemptedStage:=FStage;
  if FStage in [stRecoveryReady,stVerifyRecovery] then FLastDirection:=dirRecovery else FLastDirection:=dirSubmit;
  FLastOutcome:=doNone; FUnknownReason:=urNone; FInFlight:=True; Token:=FActiveToken;
end;
procedure TPlan.Cancel;
begin
  if FInFlight then begin FInFlight:=False; FLastOutcome:=doCancelled; MarkUnknown(urInFlightCancel);Exit;end;
  case FStage of
    stCheck,stBackup,stPublish: FStage:=stCancelled;
    stGpt,stGpc,stVerify,stRecoveryReady,stVerifyRecovery: begin MarkUnknown(urAfterWriteCancel);end;
  end;
end;
function TPlan.Advance(const Token:TStepToken; Outcome:TOutcome; const Observed:TSnapshot):Boolean;
var Expected:TSnapshot;
begin
  Result:=False;
  if not FInFlight or (Token.Sequence<>FActiveToken.Sequence) or (Token.Step<>FActiveToken.Step) or
    not IsEqualGUID(Token.PlanId,FActiveToken.PlanId) then Exit;
  FInFlight:=False; Result:=True;
  case Outcome of ocOk:FLastOutcome:=doOk; ocFail:FLastOutcome:=doFail;
    ocUnknown:FLastOutcome:=doUnknown; ocConflict:FLastOutcome:=doConflict; end;
  if Outcome=ocUnknown then begin MarkUnknown(urOperationUnknown); Exit; end;
  if Outcome=ocConflict then begin FStage:=stConflict; Exit; end;
  if Outcome=ocFail then begin
    case FStage of
      stCheck,stBackup,stPublish: FStage:=stFailed;
      stGpt,stGpc,stVerify: FStage:=stNeedsRecovery;
      stRecoveryReady,stVerifyRecovery: FStage:=stRecoveryFailed;
    end; Exit;
  end;
  case FStage of
    stCheck: if SameSnapshot(Observed,FBase) then FStage:=stBackup else FStage:=stConflict;
    stBackup: begin FBackupConfirmed:=True;FStage:=stPublish;end;
    stPublish: begin
      Expected:=SnapshotCopy(FLast);Expected.Exists:=FDesired.Exists;Expected.Policy:=Copy(FDesired.Policy);
      if not SameSnapshot(Observed,Expected) then begin MarkUnknown(urObservationMismatch);Exit;end;
      FLast:=Expected;FPublishConfirmed:=True;FStage:=stGpt;
    end;
    stGpt: begin
      Expected:=SnapshotCopy(FLast);Expected.GptVersion:=FDesired.GptVersion;Expected.Ini:=Copy(FDesired.Ini);
      if not SameSnapshot(Observed,Expected) then begin MarkUnknown(urObservationMismatch);Exit;end;
      FLast:=Expected;FGptConfirmed:=True;FStage:=stGpc;
    end;
    stGpc: begin
      Expected:=SnapshotCopy(FLast);Expected.GpcVersion:=FDesired.GpcVersion;Expected.Metadata:=Copy(FDesired.Metadata);
      if not SameSnapshot(Observed,Expected) then begin MarkUnknown(urObservationMismatch);Exit;end;
      FLast:=Expected;FGpcConfirmed:=True;FStage:=stVerify;
    end;
    stVerify: if SameSnapshot(Observed,FDesired) then FStage:=stSucceeded else begin MarkUnknown(urObservationMismatch);end;
    stRecoveryReady: FStage:=stVerifyRecovery;
    stVerifyRecovery: if SameSnapshot(Observed,FBase) then FStage:=stRecovered else begin MarkUnknown(urObservationMismatch);end;
  end;
end;
function TPlan.PrepareRecovery(const Observed:TSnapshot):Boolean;
begin
  Result:=(FStage=stNeedsRecovery) and SameSnapshot(Observed,FLast);
  if Result then FStage:=stRecoveryReady else if FStage=stNeedsRecovery then FStage:=stConflict;
end;
end.
