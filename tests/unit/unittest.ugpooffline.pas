unit unittest.ugpooffline;
{$mode ObjFPC}{$H+}
interface
uses SysUtils, mormot.core.test, mormot.core.base, ugpoformats, ugporegistrydraft, ugposysvol, ugposnapshot;
type
  TUnitTestGpoOffline = class(TSynTestCase)
  published
    procedure LosslessSerialization;
    procedure SerializationBounds;
    procedure DraftValidationUndoAndOwnership;
    procedure SnapshotRoundTrip;
    procedure CooperativeReadControl;
  end;
implementation

function EqualBytes(const A,B:TBytes):Boolean; forward;

procedure TUnitTestGpoOffline.SnapshotRoundTrip;
var S, Decoded: TGpoSnapshot; Drafts: TGpoSnapshotDrafts; Side: TGpoSnapshotSide;
  Empty, Edited, Encoded, Bad, BeforeBytes: TBytes; Rows: TGpoRegistryRecords;
  D: TGpoRegistryDraft; N, I: Integer; Revision, Started: QWord; CRC: Cardinal;
begin
  Check(SerializeRegistryPol(nil, Empty)=grsOk);
  SetLength(Rows,1); Rows[0].Key:='Unknown'; Rows[0].ValueName:='Value';
  Rows[0].ValueType:=$deadbeef; SetLength(Rows[0].Data,1); Rows[0].Data[0]:=42;
  Check(SerializeRegistryPol(Rows,Edited)=grsOk);
  for N:=0 to 15 do begin
    S:=Default(TGpoSnapshot);
    for Side:=Low(Side) to High(Side) do begin
      S[Side].Baseline.Exists:=(N and (1 shl (Ord(Side)*2)))<>0;
      S[Side].Candidate.Exists:=(N and (2 shl (Ord(Side)*2)))<>0;
      if S[Side].Baseline.Exists then S[Side].Baseline.Data:=Copy(Empty);
      if S[Side].Candidate.Exists then S[Side].Candidate.Data:=Copy(Edited)
      else S[Side].Hidden:=Copy(Edited);
    end;
    Check(GpoEncodeSnapshot(S,Encoded)=grsOk);
    Check(GpoDecodeSnapshot(Encoded,Decoded)=grsOk);
    Check(GpoRestoreSnapshot(Decoded,Drafts)=grsOk);
    for Side:=Low(Side) to High(Side) do begin
      Check(S[Side].Baseline.Exists=Decoded[Side].Baseline.Exists);
      Check(S[Side].Candidate.Exists=Decoded[Side].Candidate.Exists);
      Check(Drafts[Side].Export(BeforeBytes)=grsOk); Check(EqualBytes(BeforeBytes,Edited));
      Check(not Drafts[Side].CanUndo); Drafts[Side].Free;
    end;
    if Decoded[gssMachine].Candidate.Exists then begin
      Decoded[gssMachine].Candidate.Data[0]:=0;
      Check(S[gssMachine].Candidate.Data[0]<>0,'Decoded candidate must not alias source');
    end else begin
      Decoded[gssMachine].Hidden[0]:=0;
      Check(S[gssMachine].Hidden[0]<>0,'Decoded hidden content must not alias source');
    end;
  end;
  S:=Default(TGpoSnapshot); S[gssMachine].Candidate.Exists:=True;
  S[gssMachine].Candidate.Data:=Copy(Empty); S[gssMachine].Hidden:=Copy(Edited);
  Check(GpoEncodeSnapshot(S,Encoded)=grsCorrupt); Check(Length(Encoded)=0);
  S[gssMachine].Hidden:=nil; Check(GpoEncodeSnapshot(S,Encoded)=grsOk);
  for I:=0 to High(Encoded)-1 do begin
    Bad:=Copy(Encoded,0,I); Check(GpoDecodeSnapshot(Bad,Decoded)<>grsOk);
  end;
  Bad:=Copy(Encoded); Bad[0]:=Bad[0] xor 1; Check(GpoDecodeSnapshot(Bad,Decoded)=grsCorrupt);
  Bad:=Copy(Encoded); SetLength(Bad,Length(Bad)+1); Check(GpoDecodeSnapshot(Bad,Decoded)=grsCorrupt);
  Bad:=Copy(Encoded); SetLength(Bad,Length(Bad)+1); CRC:=crc32c(0,@Bad[0],Length(Bad)-4);
  for I:=0 to 3 do Bad[Length(Bad)-4+I]:=Byte(CRC shr (8*I));
  Check(GpoDecodeSnapshot(Bad,Decoded)=grsCorrupt,'Valid checksum cannot permit trailing bytes');
  Bad:=Copy(Encoded); Bad[16]:=255; CRC:=crc32c(0,@Bad[0],Length(Bad)-4);
  for I:=0 to 3 do Bad[Length(Bad)-4+I]:=Byte(CRC shr (8*I));
  Check(GpoDecodeSnapshot(Bad,Decoded)=grsCorrupt);
  Bad:=Copy(Encoded); Bad[36]:=4; CRC:=crc32c(0,@Bad[0],Length(Bad)-4);
  for I:=0 to 3 do Bad[Length(Bad)-4+I]:=Byte(CRC shr (8*I));
  Check(GpoDecodeSnapshot(Bad,Decoded)=grsCorrupt,'Invalid second side must not return success');
  Bad:=Copy(Encoded); Bad[23]:=1; CRC:=crc32c(0,@Bad[0],Length(Bad)-4);
  for I:=0 to 3 do Bad[Length(Bad)-4+I]:=Byte(CRC shr (8*I));
  Check(GpoDecodeSnapshot(Bad,Decoded)<>grsOk,'Oversized member must be rejected');
  SetLength(Bad,GpoMaxFileBytes); FillChar(Bad[0],Length(Bad),$5a);
  Started:=GetTickCount64; CRC:=crc32c(0,@Bad[0],Length(Bad));
  WriteLn('Snapshot CRC32C 16 MiB: ',GetTickCount64-Started,' ms (',CRC,')');
  D:=TGpoRegistryDraft.Create;
  try
    Check(D.Load(Empty)=grsOk); Check(D.Insert(0,Rows[0])=grsOk);
    Revision:=D.Revision; Check(D.Export(BeforeBytes)=grsOk);
    Check(D.Restore(Empty,nil)=grsCorrupt); Check(D.Loaded and D.Dirty and D.CanUndo);
    Check(D.Revision=Revision); Check(D.Export(Bad)=grsOk); Check(EqualBytes(Bad,BeforeBytes));
    Check(D.Restore(Empty,Edited)=grsOk); Edited[0]:=0;
    Check(D.Export(Bad)=grsOk); Check(EqualBytes(Bad,BeforeBytes)); Check(not D.CanUndo);
  finally D.Free; end;
  SetLength(Rows,256);
  for I:=0 to High(Rows) do begin
    Rows[I].Key:='K'; Rows[I].ValueName:='V'; Rows[I].ValueType:=3;
    SetLength(Rows[I].Data,GpoMaxValueBytes);
  end;
  SetLength(Rows[255].Data,GpoMaxFileBytes-48-8-255*(28+GpoMaxValueBytes)-28);
  Check(SerializeRegistryPol(Rows,Edited)=grsOk); S:=Default(TGpoSnapshot);
  S[gssMachine].Candidate.Exists:=True; S[gssMachine].Candidate.Data:=Edited;
  Started:=GetTickCount64; Check(GpoEncodeSnapshot(S,Encoded)=grsOk);
  WriteLn('Snapshot encode near 16 MiB: ',GetTickCount64-Started,' ms');
  Check(Length(Encoded)=GpoMaxFileBytes);
  Started:=GetTickCount64; Check(GpoDecodeSnapshot(Encoded,Decoded)=grsOk);
  WriteLn('Snapshot decode 16 MiB: ',GetTickCount64-Started,' ms');
  Check(EqualBytes(Decoded[gssMachine].Candidate.Data,Edited));
end;

function EqualBytes(const A,B:TBytes):Boolean;
begin
  Result:=Length(A)=Length(B);
  if Result and (Length(A)>0) then Result:=CompareMem(@A[0],@B[0],Length(A));
end;
function Item(const Key,Name:UnicodeString; Kind:Cardinal;
  const Data:array of Byte):TGpoRegistryRecord;
var I:Integer;
begin
  Result.Key:=Key; Result.ValueName:=Name; Result.ValueType:=Kind;
  Result.Data:=nil; SetLength(Result.Data,Length(Data));
  for I:=0 to High(Data) do Result.Data[I]:=Data[I];
end;
// Independent byte fixture builder: no call to production serializer.
procedure WordBytes(var B:TBytes; V:Word);
var N:Integer;
begin N:=Length(B); SetLength(B,N+2); B[N]:=V and 255; B[N+1]:=V shr 8; end;
procedure DwordBytes(var B:TBytes; V:Cardinal);
begin WordBytes(B,V and 65535); WordBytes(B,V shr 16); end;
procedure NameBytes(var B:TBytes; const S:UnicodeString);
var I:Integer;
begin for I:=1 to Length(S) do WordBytes(B,Ord(S[I])); WordBytes(B,0); end;
procedure FixtureRecord(var B:TBytes; const R:TGpoRegistryRecord);
var N:Integer;
begin
  WordBytes(B,91); NameBytes(B,R.Key); WordBytes(B,59);
  NameBytes(B,R.ValueName); WordBytes(B,59); DwordBytes(B,R.ValueType);
  WordBytes(B,59); DwordBytes(B,Length(R.Data)); WordBytes(B,59);
  N:=Length(B); SetLength(B,N+Length(R.Data));
  if Length(R.Data)>0 then Move(R.Data[0],B[N],Length(R.Data));
  WordBytes(B,93);
end;
procedure TUnitTestGpoOffline.LosslessSerialization;
var B,C:TBytes; R,Parsed:TGpoRegistryRecords; I:Integer; U:UnicodeString;
begin
  B:=nil; DwordBytes(B,$67655250); DwordBytes(B,1);
  Check(SerializeRegistryPol(nil,C)=grsOk); Check(EqualBytes(B,C));
  SetLength(R,5);
  U:=UnicodeString(WideChar($4e2d))+WideChar($d83d)+WideChar($de00);
  R[0]:=Item('Software\Policies\Example','Same',4,[1,0,0,0]);
  R[1]:=Item('Software\Policies\Example','Same',4,[2,0,0,0]);
  R[2]:=Item(U,'', $deadbeef,[0,59,0,93,0,255,0]);
  R[3]:=Item('K;[]','**DeleteValues',1,[65,0,0,0]);
  R[4]:=Item('k;[]','semi;[]',0,[]);
  for I:=0 to High(R) do FixtureRecord(B,R[I]);
  Check(ParseRegistryPol(B,Parsed)=grsOk);
  Check(Length(Parsed)=5);
  Check(SerializeRegistryPol(Parsed,C)=grsOk);
  Check(EqualBytes(B,C),'Ordered duplicates, Unicode, commands and unknown raw data must survive exactly');
  for I:=0 to 11 do
  begin
    R[0].ValueType:=I; SetLength(R,1); B:=nil;
    DwordBytes(B,$67655250); DwordBytes(B,1); FixtureRecord(B,R[0]);
    Check(ParseRegistryPol(B,Parsed)=grsOk);
    Check(SerializeRegistryPol(Parsed,C)=grsOk); Check(EqualBytes(B,C));
  end;
end;
procedure TUnitTestGpoOffline.SerializationBounds;
var R:TGpoRegistryRecords; B:TBytes; I:Integer;
  procedure Reject(Expected:TGpoReadStatus);
  begin
    SetLength(B,1); B[0]:=99;
    Check(SerializeRegistryPol(R,B)=Expected); Check(Length(B)=0);
  end;
begin
  SetLength(R,1); R[0]:=Item('','',0,[]); Reject(grsCorrupt);
  R[0].Key:='A'+#0+'B'; Reject(grsCorrupt);
  R[0].Key:='K'; R[0].ValueName:='V'+#0; Reject(grsCorrupt);
  R[0].ValueName:=UnicodeString(WideChar($dc00)); Reject(grsCorrupt);
  R[0].ValueName:=''; R[0].Key:=UnicodeString(WideChar($d800)); Reject(grsCorrupt);
  R[0].Key:=UnicodeString(StringOfChar('K',GpoMaxNameUnits));
  R[0].ValueName:=R[0].Key;
  Check(SerializeRegistryPol(R,B)=grsOk);
  R[0].Key:=R[0].Key+'x'; Reject(grsTooLarge);
  R[0].Key:='K'; R[0].ValueName:=R[0].ValueName+'x'; Reject(grsTooLarge);
  R[0].ValueName:=''; SetLength(R[0].Data,GpoMaxValueBytes);
  Check(SerializeRegistryPol(R,B)=grsOk);
  SetLength(R[0].Data,GpoMaxValueBytes+1); Reject(grsTooLarge);
  SetLength(R,GpoMaxRecords);
  for I:=0 to High(R) do R[I]:=Item('K','',0,[]);
  Check(SerializeRegistryPol(R,B)=grsOk);
  SetLength(R,GpoMaxRecords+1); R[High(R)]:=R[0]; Reject(grsTooLarge);
  SetLength(R,256);
  for I:=0 to High(R) do
  begin R[I]:=Item('K','V',3,[]); SetLength(R[I].Data,GpoMaxValueBytes); end;
  SetLength(R[255].Data,GpoMaxFileBytes-8-255*(28+GpoMaxValueBytes)-28);
  Check(SerializeRegistryPol(R,B)=grsOk); Check(Length(B)=GpoMaxFileBytes);
  SetLength(R[255].Data,Length(R[255].Data)+1); Reject(grsTooLarge);
end;
procedure TUnitTestGpoOffline.DraftValidationUndoAndOwnership;
var D:TGpoRegistryDraft; R,V:TGpoRegistryRecord; Rows:TGpoRegistryRecords;
  Changes:TGpoRegistryChanges; Original,B,BeforeEdit:TBytes;
begin
  D:=TGpoRegistryDraft.Create;
  try
    R:=Item('K','Duplicate',4,[1,0,0,0]);
    Check(not D.Loaded); Check(not D.Undo);
    Check(D.Export(B)=grsMissing); Check(Length(B)=0);
    Check(D.Insert(0,R)=grsMissing);
    Check(D.Load(nil)=grsCorrupt); Check(not D.Loaded);
    SetLength(Rows,2); Rows[0]:=R; Rows[1]:=R;
    Check(SerializeRegistryPol(Rows,Original)=grsOk);
    B:=Copy(Original); Check(D.Load(B)=grsOk); B[0]:=0;
    Check(D.Loaded and not D.Dirty); Check(not D.CanUndo);
    Check(D.Export(B)=grsOk); Check(EqualBytes(B,Original));
    B[0]:=0; Check(D.Export(B)=grsOk); Check(EqualBytes(B,Original));
    Rows:=D.Records; Rows[0].Data[0]:=99; Rows[0].Key[1]:='W';
    Check(D.Export(B)=grsOk); Check(EqualBytes(B,Original));
    V:=Item('K','Duplicate',999,[9,59,93]);
    Check(D.Replace(1,V)=grsOk); Check(D.Dirty and D.CanUndo); V.Data[0]:=88;
    Rows:=D.Records; Check(Rows[0].Data[0]=1); Check(Rows[1].Data[0]=9);
    Changes:=D.Preview; Check(Length(Changes)=1); Check(Changes[0].Index=1);
    Check(Changes[0].Kind=gckChanged); Check(Changes[0].BeforeValue.Data[0]=1);
    Check(Changes[0].AfterValue.ValueType=999);
    Changes[0].AfterValue.Data[0]:=77;
    Changes[0].AfterValue.Key[1]:='X';
    Changes[0].BeforeValue.ValueName[1]:='X';
    Rows:=D.Records; Check(Rows[1].Key='K'); Check(Rows[1].ValueName='Duplicate');
    Check(D.Export(BeforeEdit)=grsOk);
    Check(D.Replace(1,Rows[1])=grsOk); Check(D.CanUndo,'No-op keeps undo');
    Check(D.Replace(-1,R)=grsCorrupt); Check(D.Insert(3,R)=grsCorrupt);
    Check(D.Delete(2)=grsCorrupt); V.Key:=''; Check(D.Replace(0,V)=grsCorrupt);
    Check(D.Load(nil)=grsCorrupt); Check(D.CanUndo);
    Check(D.Export(B)=grsOk); Check(EqualBytes(B,BeforeEdit));
    Check(D.Undo); Check(not D.CanUndo); Check(not D.Undo); Check(not D.Dirty);
    Check(D.Export(B)=grsOk); Check(EqualBytes(B,Original));
    Check(D.Insert(0,R)=grsOk); R.Data[0]:=45;
    Rows:=D.Records; Check(Length(Rows)=3); Check(Rows[0].Data[0]=1);
    Check(D.Undo); Check(not D.Dirty);
    Check(D.Insert(2,R)=grsOk); Changes:=D.Preview;
    Check(Length(Changes)=1); Check(Changes[0].Kind=gckAdded); Check(Changes[0].Index=2);
    Check(D.Delete(0)=grsOk); Check(D.Delete(1)=grsOk);
    Changes:=D.Preview; Check(Length(Changes)=1); Check(Changes[0].Kind=gckRemoved);
    D.Reset; Check(not D.Dirty); Check(not D.CanUndo); Check(Length(D.Preview)=0);
    Check(D.Export(B)=grsOk); Check(EqualBytes(B,Original));
    Check(SerializeRegistryPol(nil,B)=grsOk); Check(D.Load(B)=grsOk);
    Check(D.Insert(0,R)=grsOk); Check(D.Delete(0)=grsOk); Check(not D.Dirty);
    Check(D.Undo); Check(D.Dirty); D.Reset; Check(not D.Dirty);
  finally D.Free; end;
end;
procedure TUnitTestGpoOffline.CooperativeReadControl;
var C:TGpoReadControl; B:TBytes;
begin
  C:=TGpoReadControl.Create;
  try
    Check(C.Status=grsOk); C.Cancel; C.Cancel; Check(C.Status=grsCancelled);
    SetLength(B,1); B[0]:=42;
    Check(GpoReadFile('','','','',gfGptIni,B,C)=grsCancelled); Check(Length(B)=0);
  finally C.Free; end;
  C:=TGpoReadControl.Create(0);
  try
    Check(C.Status=grsTimedOut);
    Check(GpoReadFile('','','','',gfGptIni,B,C)=grsTimedOut); Check(Length(B)=0);
    C.Cancel; Check(C.Status=grsCancelled);
  finally C.Free; end;
end;
end.
