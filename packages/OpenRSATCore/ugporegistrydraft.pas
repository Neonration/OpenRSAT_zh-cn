unit ugporegistrydraft;

{$mode ObjFPC}{$H+}

interface

uses SysUtils, ugpoformats;

type
  TGpoRegistryChangeKind = (gckAdded, gckRemoved, gckChanged);
  TGpoRegistryChange = record
    Kind: TGpoRegistryChangeKind;
    Index: SizeInt; // Zero-based row in each snapshot, not a registry identity.
    BeforeValue, AfterValue: TGpoRegistryRecord;
  end;
  TGpoRegistryChanges = array of TGpoRegistryChange;

  // Memory-only raw records. No LDAP, SMB, filesystem or Windows registry writes.
  TGpoRegistryDraft = class
  private
    fOriginal, fCurrent, fUndo: TBytes;
    fRecords: TGpoRegistryRecords;
    fLoaded, fCanUndo: Boolean;
    fRevision: QWord;
    function Accept(const Candidate: TGpoRegistryRecords): TGpoReadStatus;
    function GetRecords: TGpoRegistryRecords;
    function GetDirty: Boolean;
  public
    // Invalid input preserves the existing draft. Missing is NOT an empty file.
    function Load(const Data: TBytes): TGpoReadStatus;
    function Restore(const Original, Current: TBytes): TGpoReadStatus;
    function Insert(Index: SizeInt; const Value: TGpoRegistryRecord): TGpoReadStatus;
    function Replace(Index: SizeInt; const Value: TGpoRegistryRecord): TGpoReadStatus;
    function Delete(Index: SizeInt): TGpoReadStatus;
    function Export(out Data: TBytes): TGpoReadStatus;
    function Baseline(out Data: TBytes): TGpoReadStatus;
    function Undo: Boolean; // One successful change; no-op edits keep the undo.
    procedure Reset; // Discard every edit and restore the original exact bytes.
    function Preview: TGpoRegistryChanges; // Positional raw diff, not effective policy.
    property Loaded: Boolean read fLoaded;
    property Dirty: Boolean read GetDirty;
    property CanUndo: Boolean read fCanUndo;
    property Revision: QWord read fRevision;
    property Records: TGpoRegistryRecords read GetRecords;
  end;

implementation

function EqualBytes(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) then Result := CompareMem(@A[0],@B[0],Length(A));
end;

function CloneRecord(const Value: TGpoRegistryRecord): TGpoRegistryRecord;
begin Result := Value; Result.Data := Copy(Value.Data); end;

function SameRecord(const A, B: TGpoRegistryRecord): Boolean;
begin
  Result := (A.Key = B.Key) and (A.ValueName = B.ValueName) and
    (A.ValueType = B.ValueType) and EqualBytes(A.Data,B.Data);
end;

function TGpoRegistryDraft.GetRecords: TGpoRegistryRecords;
var I: SizeInt;
begin
  Result := nil; SetLength(Result,Length(fRecords));
  for I := 0 to High(fRecords) do Result[I] := CloneRecord(fRecords[I]);
end;

function TGpoRegistryDraft.GetDirty: Boolean;
begin Result := fLoaded and not EqualBytes(fOriginal,fCurrent); end;

function TGpoRegistryDraft.Load(const Data: TBytes): TGpoReadStatus;
var Parsed: TGpoRegistryRecords;
begin
  Result := ParseRegistryPol(Data,Parsed);
  if Result <> grsOk then Exit;
  fOriginal := Copy(Data); fCurrent := Copy(Data); fRecords := Parsed;
  fUndo := nil; fCanUndo := False; fLoaded := True;
  Inc(fRevision);
end;

function TGpoRegistryDraft.Restore(const Original, Current: TBytes): TGpoReadStatus;
var OriginalRows, CurrentRows: TGpoRegistryRecords; OriginalCopy, CurrentCopy: TBytes;
begin
  Result := ParseRegistryPol(Original, OriginalRows);
  if Result <> grsOk then Exit;
  Result := ParseRegistryPol(Current, CurrentRows);
  if Result <> grsOk then Exit;
  OriginalCopy := Copy(Original); CurrentCopy := Copy(Current);
  fOriginal := OriginalCopy; fCurrent := CurrentCopy; fRecords := CurrentRows;
  fUndo := nil; fCanUndo := False; fLoaded := True;
  Inc(fRevision);
end;

function TGpoRegistryDraft.Accept(const Candidate: TGpoRegistryRecords): TGpoReadStatus;
var Encoded: TBytes; Parsed: TGpoRegistryRecords;
begin
  Result := SerializeRegistryPol(Candidate,Encoded);
  if Result <> grsOk then Exit;
  if EqualBytes(Encoded,fCurrent) then Exit;
  // Parse the owned bytes to sever every caller's nested dynamic-array alias.
  Result := ParseRegistryPol(Encoded,Parsed);
  if Result <> grsOk then Exit;
  fUndo := fCurrent; fCanUndo := True;
  fCurrent := Encoded; fRecords := Parsed;
  Inc(fRevision);
end;

function TGpoRegistryDraft.Insert(Index: SizeInt;
  const Value: TGpoRegistryRecord): TGpoReadStatus;
var Candidate: TGpoRegistryRecords; I: SizeInt;
begin
  if not fLoaded then Exit(grsMissing);
  if (Index < 0) or (Index > Length(fRecords)) then Exit(grsCorrupt);
  if Length(fRecords) = GpoMaxRecords then Exit(grsTooLarge);
  Candidate := nil; SetLength(Candidate,Length(fRecords)+1);
  for I := 0 to Index-1 do Candidate[I] := fRecords[I];
  Candidate[Index] := Value;
  for I := Index to High(fRecords) do Candidate[I+1] := fRecords[I];
  Result := Accept(Candidate);
end;

function TGpoRegistryDraft.Replace(Index: SizeInt;
  const Value: TGpoRegistryRecord): TGpoReadStatus;
var Candidate: TGpoRegistryRecords;
begin
  if not fLoaded then Exit(grsMissing);
  if (Index < 0) or (Index >= Length(fRecords)) then Exit(grsCorrupt);
  Candidate := Copy(fRecords); Candidate[Index] := Value;
  Result := Accept(Candidate);
end;

function TGpoRegistryDraft.Delete(Index: SizeInt): TGpoReadStatus;
var Candidate: TGpoRegistryRecords; I: SizeInt;
begin
  if not fLoaded then Exit(grsMissing);
  if (Index < 0) or (Index >= Length(fRecords)) then Exit(grsCorrupt);
  Candidate := nil; SetLength(Candidate,Length(fRecords)-1);
  for I := 0 to Index-1 do Candidate[I] := fRecords[I];
  for I := Index+1 to High(fRecords) do Candidate[I-1] := fRecords[I];
  Result := Accept(Candidate);
end;

function TGpoRegistryDraft.Export(out Data: TBytes): TGpoReadStatus;
begin
  Data := nil;
  if not fLoaded then Exit(grsMissing);
  Data := Copy(fCurrent); Result := grsOk;
end;

function TGpoRegistryDraft.Baseline(out Data: TBytes): TGpoReadStatus;
begin
  Data := nil;
  if not fLoaded then Exit(grsMissing);
  Data := Copy(fOriginal); Result := grsOk;
end;

function TGpoRegistryDraft.Undo: Boolean;
var Parsed: TGpoRegistryRecords;
begin
  Result := fCanUndo;
  if not Result then Exit;
  Result := ParseRegistryPol(fUndo,Parsed) = grsOk;
  if not Result then Exit;
  fCurrent := fUndo; fRecords := Parsed; fUndo := nil; fCanUndo := False;
  Inc(fRevision);
end;

procedure TGpoRegistryDraft.Reset;
var Parsed: TGpoRegistryRecords;
begin
  if not fLoaded then Exit;
  if ParseRegistryPol(fOriginal,Parsed) <> grsOk then Exit;
  fCurrent := fOriginal; fRecords := Parsed; fUndo := nil; fCanUndo := False;
  Inc(fRevision);
end;

function TGpoRegistryDraft.Preview: TGpoRegistryChanges;
var Original: TGpoRegistryRecords; I, Count, Limit: SizeInt;
begin
  Result := nil;
  if not fLoaded or (ParseRegistryPol(fOriginal,Original) <> grsOk) then Exit;
  Limit := Length(Original);
  if Length(fRecords) > Limit then Limit := Length(fRecords);
  SetLength(Result,Limit); Count := 0;
  for I := 0 to Limit-1 do
  begin
    if (I < Length(Original)) and (I < Length(fRecords)) and
       SameRecord(Original[I],fRecords[I]) then Continue;
    Result[Count].Index := I;
    if I >= Length(Original) then Result[Count].Kind := gckAdded
    else if I >= Length(fRecords) then Result[Count].Kind := gckRemoved
    else Result[Count].Kind := gckChanged;
    if I < Length(Original) then Result[Count].BeforeValue := CloneRecord(Original[I]);
    if I < Length(fRecords) then Result[Count].AfterValue := CloneRecord(fRecords[I]);
    Inc(Count);
  end;
  SetLength(Result,Count);
end;

end.
