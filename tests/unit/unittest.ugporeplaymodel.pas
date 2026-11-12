unit unittest.ugporeplaymodel;
{$mode objfpc}{$H+}
interface
uses mormot.core.test;
type TUnitTestGpoReplayModel=class(TSynTestCase)
published procedure DualSidedJournal;
end;
implementation
uses SysUtils,ugpoformats,ugporeplaymodel;

procedure TUnitTestGpoReplayModel.DualSidedJournal;
const AllEvidence:TReplayEvidenceSet=[reTarget,reSession,reExpectedState,reDurableBackup,reConditionalUpdate];
var H,Bad:TReplayHeader; E,Prefix,Corrupt:TReplayEntries;
    OldU,NewU,OldM,NewM,Missing,Empty,Full:TGpoPolicyImage;
    Rows:TGpoRegistryRecords; Ini:TBytes; A,B:TGpoPolicyAction;
    I,J:Integer; Entry:TReplayEntry; HasWritten:Boolean; R:TReplayResult;
  procedure Images(Action:TGpoPolicyAction; out OldImage,NewImage:TGpoPolicyImage);
  begin
    case Action of
      gpaNone:begin OldImage:=Missing; NewImage:=Missing; end;
      gpaCreate:begin OldImage:=Missing; NewImage:=Empty; end;
      gpaReplace:begin OldImage:=Empty; NewImage:=Full; end;
      gpaDelete:begin OldImage:=Empty; NewImage:=Missing; end;
    end;
  end;
  procedure Append(Step:TReplayStep; Kind:TReplayKind; Evidence:TReplayEvidenceSet);
  var N:Integer;
  begin N:=Length(E); SetLength(E,N+1); E[N].Sequence:=N+1; E[N].Step:=Step; E[N].Kind:=Kind; E[N].Evidence:=Evidence; end;
  procedure Pair(Step:TReplayStep);
  begin Append(Step,rkIntent,AllEvidence); Append(Step,rkConfirmed,[]); end;
begin
  Missing:=Default(TGpoPolicyImage); Empty:=Default(TGpoPolicyImage); Empty.Exists:=True;
  Check(SerializeRegistryPol(nil,Empty.Data)=grsOk);
  SetLength(Rows,1); Rows[0].Key:='Software\Test'; Rows[0].ValueType:=3; Rows[0].Data:=TBytes.Create(1);
  Full:=Default(TGpoPolicyImage); Full.Exists:=True; Check(SerializeRegistryPol(Rows,Full.Data)=grsOk);
  Ini:=TBytes.Create(91,71,101,110,101,114,97,108,93,10,86,101,114,115,105,111,110,61,49);
  H.TransactionId:='txn-1'; H.Domain:='example.test'; H.DC:='dc.example.test';
  H.DN:='CN=policy,DC=example,DC=test'; H.ObjectId:='object-guid'; H.SessionId:='session-1';
  for A:=Low(TGpoPolicyAction) to High(TGpoPolicyAction) do
    for B:=Low(TGpoPolicyAction) to High(TGpoPolicyAction) do begin
      Images(A,OldU,NewU); Images(B,OldM,NewM);
      Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldU,NewU,OldM,NewM,H.Plan)=gopOk);
      Check((H.Plan.UserAction=A) and (H.Plan.MachineAction=B));
      E:=nil;
      if B<>gpaNone then Pair(rsMachine);
      if A<>gpaNone then Pair(rsUser);
      if (A<>gpaNone) or (B<>gpaNone) then begin Pair(rsGpt); Pair(rsGpc); end;
      Pair(rsVerify);
      Check(ReplayGpoJournal(H,E)=rrVerified,'all action pairs must reach verified');
      for I:=0 to High(E) do begin
        Prefix:=Copy(E,0,I);
        R:=ReplayGpoJournal(H,Prefix);
        if I=0 then Check(R=rrNotStarted) else Check(R=rrInterrupted,'restart requires reconciliation');
        if E[I].Kind=rkConfirmed then begin
          Prefix:=Copy(E,0,I+1); Prefix[I].Kind:=rkUnknown;
          Check(ReplayGpoJournal(H,Prefix)=rrUnknown,'lost response remains unknown');
          HasWritten:=False;
          for J:=0 to I-1 do if (E[J].Kind=rkConfirmed) and (E[J].Step<>rsVerify) then HasWritten:=True;
          Prefix[I].Kind:=rkFailed;
          if HasWritten then Check(ReplayGpoJournal(H,Prefix)=rrPartialFailure)
          else Check(ReplayGpoJournal(H,Prefix)=rrFailed);
          Prefix[I].Kind:=rkConflict;
          if HasWritten then Check(ReplayGpoJournal(H,Prefix)=rrPartialConflict)
          else Check(ReplayGpoJournal(H,Prefix)=rrConflict);
          SetLength(Prefix,I+2); Prefix[I+1]:=E[I]; Prefix[I+1].Sequence:=I+2;
          Check(ReplayGpoJournal(H,Prefix)=rrInvalid,'terminal result forbids blind retry');
        end else begin
          Prefix:=Copy(E,0,I+1); Prefix[I].Evidence:=[];
          Check(ReplayGpoJournal(H,Prefix)=rrInvalid,'missing evidence blocks every step');
        end;
      end;
      Corrupt:=Copy(E); Corrupt[0].Sequence:=2; Check(ReplayGpoJournal(H,Corrupt)=rrInvalid);
      Corrupt:=Copy(E); Corrupt[0].Kind:=rkConfirmed; Check(ReplayGpoJournal(H,Corrupt)=rrInvalid);
      Bad:=H; Bad.SessionId:=''; Check(ReplayGpoJournal(Bad,E)=rrInvalid);
      Bad:=H; Bad.Plan.UserAction:=gpaDelete; if A<>gpaDelete then Check(ReplayGpoJournal(Bad,E)=rrInvalid);
      if (A=gpaNone) and (B=gpaNone) then begin
        Entry:=E[0]; Entry.Step:=rsMachine; Corrupt:=Copy(E); Corrupt[0]:=Entry;
        Check(ReplayGpoJournal(H,Corrupt)=rrInvalid,'no-op does not issue a write');
      end;
    end;
  // Each individual condition is mandatory at a mutating intent.
  Images(gpaCreate,OldU,NewU); Images(gpaNone,OldM,NewM);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldU,NewU,OldM,NewM,H.Plan)=gopOk);
  for I:=Ord(Low(TReplayEvidence)) to Ord(High(TReplayEvidence)) do begin
    E:=nil; Append(rsUser,rkIntent,AllEvidence-[TReplayEvidence(I)]);
    Check(ReplayGpoJournal(H,E)=rrInvalid,'each required condition fails closed');
  end;
end;
end.
