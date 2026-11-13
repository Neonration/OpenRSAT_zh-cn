unit ugposnapshot;

{$mode ObjFPC}{$H+}

interface

uses SysUtils, ugpoformats, ugporegistrydraft;

const
  GpoSnapshotMaxBytes = 6 * GpoMaxFileBytes + 48;

type
  TGpoSnapshotSide = (gssMachine, gssUser);
  TGpoSnapshotPart = record
    Baseline, Candidate: TGpoPolicyImage;
    Hidden: TBytes;
  end;
  TGpoSnapshot = array[TGpoSnapshotSide] of TGpoSnapshotPart;
  TGpoSnapshotDrafts = array[TGpoSnapshotSide] of TGpoRegistryDraft;

function GpoEncodeSnapshot(const Value: TGpoSnapshot; out Data: TBytes): TGpoReadStatus;
function GpoDecodeSnapshot(const Data: TBytes; out Value: TGpoSnapshot): TGpoReadStatus;
function GpoRestoreSnapshot(const Value: TGpoSnapshot; out Drafts: TGpoSnapshotDrafts): TGpoReadStatus;

implementation

uses mormot.core.base;

const Magic: array[0..7] of Byte = (79, 71, 80, 68, 82, 65, 70, 84);

function ValidPart(const Part: TGpoSnapshotPart): TGpoReadStatus;
var Rows: TGpoRegistryRecords;
begin
  Result := grsCorrupt;
  if (not Part.Baseline.Exists) and (Length(Part.Baseline.Data) <> 0) then Exit;
  if (not Part.Candidate.Exists) and (Length(Part.Candidate.Data) <> 0) then Exit;
  if Part.Candidate.Exists and (Length(Part.Hidden) <> 0) then Exit;
  if Part.Baseline.Exists then begin
    Result := ParseRegistryPol(Part.Baseline.Data, Rows); if Result <> grsOk then Exit;
  end;
  if Part.Candidate.Exists then begin
    Result := ParseRegistryPol(Part.Candidate.Data, Rows); if Result <> grsOk then Exit;
  end;
  if Length(Part.Hidden) <> 0 then begin
    Result := ParseRegistryPol(Part.Hidden, Rows); if Result <> grsOk then Exit;
  end;
  Result := grsOk;
end;

procedure Put32(var Data: TBytes; var Offset: SizeInt; Value: Cardinal);
var I: Integer;
begin
  for I := 0 to 3 do begin Data[Offset] := Byte(Value shr (I * 8)); Inc(Offset); end;
end;

function Get32(const Data: TBytes; var Offset: SizeInt): Cardinal;
var I: Integer;
begin
  Result := 0;
  for I := 0 to 3 do begin Result := Result or (Cardinal(Data[Offset]) shl (I * 8)); Inc(Offset); end;
end;

function GpoEncodeSnapshot(const Value: TGpoSnapshot; out Data: TBytes): TGpoReadStatus;
var Side: TGpoSnapshotSide; P, Size: SizeInt; Flags: Cardinal;
  procedure WriteBytes(const Bytes: TBytes);
  begin
    Put32(Data, P, Length(Bytes));
    if Length(Bytes) > 0 then begin Move(Bytes[0], Data[P], Length(Bytes)); Inc(P, Length(Bytes)); end;
  end;
begin
  Data := nil; Size := 16 + 2 * 16;
  for Side := Low(Side) to High(Side) do begin
    Result := ValidPart(Value[Side]); if Result <> grsOk then Exit;
    Inc(Size, Length(Value[Side].Baseline.Data) + Length(Value[Side].Candidate.Data) + Length(Value[Side].Hidden));
  end;
  if Size > GpoSnapshotMaxBytes then Exit(grsTooLarge);
  SetLength(Data, Size); Move(Magic[0], Data[0], 8); P := 8; Put32(Data, P, 1);
  for Side := Low(Side) to High(Side) do begin
    Flags := Ord(Value[Side].Baseline.Exists) or (Ord(Value[Side].Candidate.Exists) shl 1);
    Put32(Data, P, Flags);
    WriteBytes(Value[Side].Baseline.Data); WriteBytes(Value[Side].Candidate.Data); WriteBytes(Value[Side].Hidden);
  end;
  Put32(Data, P, crc32c(0, @Data[0], P)); Result := grsOk;
end;

function GpoDecodeSnapshot(const Data: TBytes; out Value: TGpoSnapshot): TGpoReadStatus;
var Temp: TGpoSnapshot; Side: TGpoSnapshotSide; P, Limit: SizeInt; Flags, Stored: Cardinal;
  function ReadBytes(out Bytes: TBytes): Boolean;
  var Count: Cardinal;
  begin
    Result := False; Bytes := nil;
    if P > Limit - 4 then Exit;
    Count := Get32(Data, P);
    if (Count > GpoMaxFileBytes) or (Count > Cardinal(Limit - P)) then Exit;
    SetLength(Bytes, Count);
    if Count > 0 then begin Move(Data[P], Bytes[0], Count); Inc(P, Count); end;
    Result := True;
  end;
begin
  Value := Default(TGpoSnapshot); Temp := Default(TGpoSnapshot); Result := grsCorrupt;
  if Length(Data) > GpoSnapshotMaxBytes then Exit(grsTooLarge);
  if Length(Data) < 48 then Exit;
  if not CompareMem(@Data[0], @Magic[0], 8) then Exit;
  Limit := Length(Data) - 4; P := Limit; Stored := Get32(Data, P);
  if Stored <> crc32c(0, @Data[0], Limit) then Exit;
  P := 8; if Get32(Data, P) <> 1 then Exit;
  for Side := Low(Side) to High(Side) do begin
    Result := grsCorrupt;
    if P > Limit - 4 then Exit;
    Flags := Get32(Data, P); if Flags > 3 then Exit;
    Temp[Side].Baseline.Exists := (Flags and 1) <> 0;
    Temp[Side].Candidate.Exists := (Flags and 2) <> 0;
    if not ReadBytes(Temp[Side].Baseline.Data) or not ReadBytes(Temp[Side].Candidate.Data) or
       not ReadBytes(Temp[Side].Hidden) then Exit;
    Result := ValidPart(Temp[Side]); if Result <> grsOk then Exit;
  end;
  Result := grsCorrupt; if P <> Limit then Exit;
  Value := Temp; Result := grsOk;
end;

function GpoRestoreSnapshot(const Value: TGpoSnapshot; out Drafts: TGpoSnapshotDrafts): TGpoReadStatus;
var Side: TGpoSnapshotSide; Empty, Base, Current: TBytes;
begin
  Drafts := Default(TGpoSnapshotDrafts);
  for Side := Low(Side) to High(Side) do begin
    Result := ValidPart(Value[Side]); if Result <> grsOk then Exit;
  end;
  Result := SerializeRegistryPol(nil, Empty); if Result <> grsOk then Exit;
  try
    for Side := Low(Side) to High(Side) do begin
      if Value[Side].Baseline.Exists then Base := Value[Side].Baseline.Data else Base := Empty;
      if Value[Side].Candidate.Exists then Current := Value[Side].Candidate.Data
      else if Length(Value[Side].Hidden) > 0 then Current := Value[Side].Hidden else Current := Empty;
      Drafts[Side] := TGpoRegistryDraft.Create;
      Result := Drafts[Side].Restore(Base, Current);
      if Result <> grsOk then Break;
    end;
  except
    for Side := Low(Side) to High(Side) do FreeAndNil(Drafts[Side]);
    raise;
  end;
  if Result <> grsOk then
    for Side := Low(Side) to High(Side) do FreeAndNil(Drafts[Side]);
end;

end.
