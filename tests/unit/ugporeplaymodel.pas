unit ugporeplaymodel;
{$mode objfpc}{$H+}
interface
uses SysUtils, ugpoformats;
type
  TReplayStep=(rsMachine,rsUser,rsGpt,rsGpc,rsVerify,rsEnd);
  TReplayKind=(rkIntent,rkConfirmed,rkFailed,rkConflict,rkUnknown);
  TReplayEvidence=(reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate);
  TReplayEvidenceSet=set of TReplayEvidence;
  TReplayEntry=record
    Sequence:Cardinal;
    Step:TReplayStep;
    Kind:TReplayKind;
    Evidence:TReplayEvidenceSet;
  end;
  TReplayEntries=array of TReplayEntry;
  TReplayResult=(rrInvalid,rrNotStarted,rrInterrupted,rrFailed,rrConflict,rrPartialFailure,rrPartialConflict,rrUnknown,rrVerified);
  TReplayHeader=record
    TransactionId,Domain,DC,DN,ObjectId,SessionId:string;
    Plan:TGpoOfflinePlan;
  end;

// Pure validator for already acknowledged records; no persistence or I/O.
function ReplayGpoJournal(const Header:TReplayHeader; const Entries:TReplayEntries):TReplayResult;

implementation
function NextStep(S:TReplayStep; const Plan:TGpoOfflinePlan):TReplayStep;
begin
  Result:=S;
  while Result<rsEnd do begin
    case Result of
      rsMachine:if Plan.MachineAction<>gpaNone then Exit;
      rsUser:if Plan.UserAction<>gpaNone then Exit;
      rsGpt,rsGpc:if Plan.UserChanged or Plan.MachineChanged then Exit;
      rsVerify:Exit;
    end;
    Result:=Succ(Result);
  end;
end;

function ReplayGpoJournal(const Header:TReplayHeader; const Entries:TReplayEntries):TReplayResult;
const Required:TReplayEvidenceSet=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
var Step:TReplayStep; InFlight,Changed:Boolean; I:SizeInt; E:TReplayEntry;
begin
  Result:=rrInvalid;
  if (Header.TransactionId='') or (Header.Domain='') or (Header.DC='') or
     (Header.DN='') or (Header.ObjectId='') or (Header.SessionId='') then Exit;
  if GpoCheckOfflinePlan(Header.Plan,Header.Plan.Baseline.GpcVersion,Header.Plan.Baseline.GptIni,
     Header.Plan.Baseline.UserPolicy,Header.Plan.Baseline.MachinePolicy)<>gbcMatch then Exit;
  Step:=NextStep(rsMachine,Header.Plan); InFlight:=False; Changed:=False;
  for I:=0 to High(Entries) do begin
    E:=Entries[I];
    if (QWord(I)+1<>E.Sequence) or (Step=rsEnd) or (E.Step<>Step) then Exit;
    if not InFlight then begin
      if E.Kind<>rkIntent then Exit;
      if Step=rsVerify then begin
        if not ([reTarget,reSession,reExpectedState]<=E.Evidence) then Exit;
      end else if not (Required<=E.Evidence) then Exit;
      InFlight:=True;
    end else begin
      if E.Evidence<>[] then Exit;
      case E.Kind of
        rkConfirmed:begin
          InFlight:=False;
          if Step<>rsVerify then Changed:=True;
          Step:=NextStep(Succ(Step),Header.Plan);
        end;
        rkFailed,rkConflict,rkUnknown:begin
          if I<>High(Entries) then Exit;
          case E.Kind of
            rkFailed:if Changed then Result:=rrPartialFailure else Result:=rrFailed;
            rkConflict:if Changed then Result:=rrPartialConflict else Result:=rrConflict;
            else Result:=rrUnknown;
          end;
          Exit;
        end;
        else Exit;
      end;
    end;
  end;
  if Step=rsEnd then Result:=rrVerified
  else if (Length(Entries)=0) and not Changed then Result:=rrNotStarted
  else Result:=rrInterrupted;
end;
end.
