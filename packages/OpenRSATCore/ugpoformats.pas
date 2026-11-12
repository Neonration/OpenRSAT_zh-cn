unit ugpoformats;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils;

const
  GpoMaxFileBytes = 16 * 1024 * 1024;
  GpoMaxRecords = 65536;
  GpoMaxValueBytes = 65535; // MS-GPREG 2.2.1 Size field limit.
  GpoMaxNameUnits = 32767;

type
  TGpoReadStatus = (grsOk, grsMissing, grsAccessDenied, grsCorrupt,
    grsUnsupported, grsInvalidPath, grsTooLarge, grsIoError, grsReparseBlocked,
    grsCancelled, grsTimedOut);
  // LDAP Group Policy Container metadata; never confuses LDAP and GPT versions.
  TGpoContainer = record
    DistinguishedName, Guid, DisplayName, FileSysPath: string;
    Version, Flags: Cardinal;
  end;
  TGpoRegistryRecord = record
    Key, ValueName: UnicodeString;
    ValueType: Cardinal;
    Data: TBytes; // Always retained, including unknown registry types.
  end;
  TGpoRegistryRecords = array of TGpoRegistryRecord;
  TGpoVersionPlan = record
    Version: Cardinal;
    LdapValue, GptValue: string;
  end;
  TGptIniCandidateStatus = (gicOk, gicInvalid, gicUnsupported,
    gicBaselineMismatch, gicTooLarge);
  TGpoOfflinePlanStatus = (gopOk, gopInvalidPolicy, gopBaselineMismatch,
    gopInvalidIni, gopUnsupportedIni, gopTooLarge);
  TGpoPolicyImage = record
    Exists: Boolean;
    Data: TBytes;
  end;
  TGpoPolicyAction = (gpaNone, gpaCreate, gpaReplace, gpaDelete);
  TGpoOfflineBaseline = record
    GpcVersion: Cardinal;
    GptIni: TBytes;
    UserPolicy, MachinePolicy: TGpoPolicyImage;
  end;
  TGpoBaselineCheck = (gbcMatch, gbcConflict, gbcInvalid);
  TGpoOfflinePlan = record
    UserChanged, MachineChanged, UserExists, MachineExists: Boolean;
    UserAction, MachineAction: TGpoPolicyAction;
    Version: TGpoVersionPlan;
    GptIni, UserPolicy, MachinePolicy: TBytes;
    Baseline: TGpoOfflineBaseline;
  end;

function GpoUserVersion(Version: Cardinal): Word;
function GpoMachineVersion(Version: Cardinal): Word;
// Offline only: reject mismatched baselines and preserve unchanged halves.
function GpoPlanVersion(GpcVersion, GptVersion: Cardinal;
  UserChanged, MachineChanged: Boolean; out Plan: TGpoVersionPlan): Boolean;
function GpoValidGuid(const Value: string): Boolean;
// LDAP versionNumber is signed Int32 decimal; expose its unchanged version bits.
function GpoParseLdapVersion(const Value: string; out Number: Cardinal): Boolean;
function GpoParseUnsigned(const Value: string; out Number: Cardinal): Boolean;
function ParseGptIni(const Data: TBytes; out Version: Cardinal): TGpoReadStatus;
// Generates bytes only; Data and Candidate must be distinct variables.
function GpoBuildGptIniCandidate(const Data: TBytes; ExpectedVersion, NewVersion: Cardinal;
  out Candidate: TBytes): TGptIniCandidateStatus;
// Inputs must be distinct from Plan fields. All policies must be present and valid.
function GpoBuildOfflinePlan(GpcVersion, GptVersion: Cardinal; const Ini,
  OldUser, NewUser, OldMachine, NewMachine: TBytes;
  out Plan: TGpoOfflinePlan): TGpoOfflinePlanStatus;
function GpoBuildOfflinePlanWithPresence(GpcVersion, GptVersion: Cardinal; const Ini: TBytes;
  const OldUser, NewUser, OldMachine, NewMachine: TGpoPolicyImage;
  out Plan: TGpoOfflinePlan): TGpoOfflinePlanStatus;
function GpoCheckOfflineBaseline(const Baseline: TGpoOfflineBaseline; LatestGpcVersion: Cardinal;
  const LatestIni: TBytes; const LatestUser, LatestMachine: TGpoPolicyImage): TGpoBaselineCheck;
function ParseRegistryPol(const Data: TBytes; out Records: TGpoRegistryRecords): TGpoReadStatus;
// Preserves ordered records and raw data, including unknown types and commands.
function SerializeRegistryPol(const Records: TGpoRegistryRecords;
  out Data: TBytes): TGpoReadStatus;
function GpoStatusText(Status: TGpoReadStatus): string;

implementation

function EqualPolicyBytes(const A,B:TBytes):Boolean;
begin
  Result:=Length(A)=Length(B);
  if Result and (Length(A)>0) then Result:=CompareMem(@A[0],@B[0],Length(A));
end;

function ValidPolicyImage(const Image:TGpoPolicyImage):Boolean;
var Records:TGpoRegistryRecords;
begin
  if not Image.Exists then Exit(Length(Image.Data)=0);
  Result:=ParseRegistryPol(Image.Data,Records)=grsOk;
end;

function GpoStatusText(Status: TGpoReadStatus): string;
const Names: array[TGpoReadStatus] of string = ('OK', 'Missing', 'Access denied',
  'Corrupt', 'Unsupported', 'Invalid path', 'Too large', 'I/O error', 'Reparse blocked',
  'Cancelled', 'Timed out');
begin Result := Names[Status]; end;

function GpoUserVersion(Version: Cardinal): Word;
begin Result := Version shr 16; end;
function GpoMachineVersion(Version: Cardinal): Word;
begin Result := Version and $ffff; end;

function GpoPlanVersion(GpcVersion, GptVersion: Cardinal;
  UserChanged, MachineChanged: Boolean; out Plan: TGpoVersionPlan): Boolean;
var UserPart, MachinePart: Cardinal; SignedVersion: Int64;
begin
  Plan := Default(TGpoVersionPlan);
  Result := GpcVersion = GptVersion;
  if not Result then Exit;
  UserPart := GpoUserVersion(GpcVersion);
  MachinePart := GpoMachineVersion(GpcVersion);
  if UserChanged then begin
    if UserPart = $ffff then UserPart := 1 else Inc(UserPart);
  end;
  if MachineChanged then begin
    if MachinePart = $ffff then MachinePart := 1 else Inc(MachinePart);
  end;
  Plan.Version := (UserPart shl 16) or MachinePart;
  SignedVersion := Int64(Plan.Version);
  if SignedVersion > High(LongInt) then SignedVersion := SignedVersion - 4294967296;
  Plan.LdapValue := IntToStr(SignedVersion);
  Plan.GptValue := UIntToStr(Plan.Version);
end;

function GpoValidGuid(const Value: string): Boolean;
var I: Integer;
begin
  Result := False;
  if (Length(Value) <> 38) or (Value[1] <> '{') or (Value[38] <> '}') then Exit;
  for I := 2 to 37 do
    if I in [10,15,20,25] then begin if Value[I] <> '-' then Exit; end
    else if not (Value[I] in ['0'..'9','a'..'f','A'..'F']) then Exit;
  Result := True;
end;

function GpoParseUnsigned(const Value: string; out Number: Cardinal): Boolean;
var I: Integer; N: QWord;
begin
  Number := 0; Result := False; N := 0;
  if Value = '' then Exit;
  for I := 1 to Length(Value) do
  begin
    if not (Value[I] in ['0'..'9']) then Exit;
    N := N * 10 + Ord(Value[I]) - Ord('0');
    if N > High(Cardinal) then Exit;
  end;
  Number := N; Result := True;
end;

function GpoParseLdapVersion(const Value: string; out Number: Cardinal): Boolean;
var I, Start: SizeInt; Magnitude, Limit: QWord; Negative: Boolean;
begin
  Number := 0; Result := False;
  if Value = '' then Exit;
  Negative := Value[1] = '-';
  Start := 1; Limit := $7fffffff;
  if Negative then begin Start := 2; Limit := $80000000; end;
  if Start > Length(Value) then Exit;
  Magnitude := 0;
  for I := Start to Length(Value) do
  begin
    if not (Value[I] in ['0'..'9']) then Exit;
    // Previous iteration is bounded by Int32, so this cannot overflow QWord.
    Magnitude := Magnitude * 10 + Ord(Value[I]) - Ord('0');
    if Magnitude > Limit then Exit;
  end;
  if Negative and (Magnitude <> 0) then
    Number := not Cardinal(Magnitude - 1) // Two's-complement without signed casts.
  else
    Number := Cardinal(Magnitude);
  Result := True;
end;

function ValidUtf16(const S: UnicodeString): Boolean;
var I: SizeInt; C: Word;
begin
  Result := False; I := 1;
  while I <= Length(S) do
  begin
    C := Ord(S[I]);
    if (C >= $d800) and (C <= $dbff) then
    begin
      Inc(I);
      if I > Length(S) then Exit;
      C := Ord(S[I]);
      if (C < $dc00) or (C > $dfff) then Exit;
    end
    else if (C >= $dc00) and (C <= $dfff) then Exit;
    Inc(I);
  end;
  Result := True;
end;

function ParseGptIni(const Data: TBytes; out Version: Cardinal): TGpoReadStatus;
var S, Line, Section, Name, Value: string; U: UnicodeString;
  Lines: TStringList; I, P, Start: SizeInt; Found: Boolean;
begin
  Version := 0; Result := grsCorrupt;
  if Length(Data) > GpoMaxFileBytes then Exit(grsTooLarge);
  if Length(Data) = 0 then Exit;
  S := ''; Start := 0;
  if (Length(Data) >= 2) and (Data[0] = $ff) and (Data[1] = $fe) then
  begin
    if Odd(Length(Data)) then Exit;
    SetLength(U, (Length(Data)-2) div 2);
    for I := 1 to Length(U) do U[I] := WideChar(Word(Data[I*2]) or (Word(Data[I*2+1]) shl 8));
    if not ValidUtf16(U) then Exit;
    S := UTF8Encode(U);
  end
  else
  begin
    if (Length(Data) >= 2) and (Data[0] = $fe) and (Data[1] = $ff) then Exit(grsUnsupported);
    if (Length(Data) >= 3) and (Data[0] = $ef) and (Data[1] = $bb) and (Data[2] = $bf) then Start := 3;
    SetLength(S, Length(Data)-Start);
    if Length(S) > 0 then Move(Data[Start], S[1], Length(S));
  end;
  if Pos(#0,S) > 0 then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := S; Section := ''; Found := False;
    for I := 0 to Lines.Count-1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] in [';', '#']) then Continue;
      if Line[1] = '[' then
      begin
        if Line[Length(Line)] <> ']' then Exit;
        Section := LowerCase(Trim(Copy(Line,2,Length(Line)-2))); Continue;
      end;
      P := Pos('=',Line);
      if P = 0 then Exit;
      Name := Trim(Copy(Line,1,P-1)); Value := Trim(Copy(Line,P+1,MaxInt));
      if (Section = 'general') and SameText(Name,'Version') then
      begin
        if Found or not GpoParseUnsigned(Value,Version) then begin Version := 0; Exit; end;
        Found := True;
      end;
    end;
    if Found then Result := grsOk;
  finally
    Lines.Free;
    if Result <> grsOk then Version := 0;
  end;
end;

function GpoBuildGptIniCandidate(const Data: TBytes; ExpectedVersion, NewVersion: Cardinal;
  out Candidate: TBytes): TGptIniCandidateStatus;
var S, Line, Name, Section, Value, Digits: string;
  Sections, Keys: TStringList; Width, Start, N, I, J, LineStart, LineEnd,
  P, FirstDigit, LastDigit, PrefixBytes, SuffixBytes, NewSize: SizeInt;
  Current: Cardinal; InGeneral, Found: Boolean;
begin
  Candidate := nil; Result := gicInvalid;
  if Length(Data)>GpoMaxFileBytes then Exit(gicTooLarge);
  if Length(Data)=0 then Exit;
  if (Length(Data)>=4) and (((Data[0]=$ff) and (Data[1]=$fe) and (Data[2]=0) and (Data[3]=0)) or
     ((Data[0]=0) and (Data[1]=0) and (Data[2]=$fe) and (Data[3]=$ff))) then Exit(gicUnsupported);
  Width:=1; Start:=0;
  if (Length(Data)>=2) and (Data[0]=$ff) and (Data[1]=$fe) then
  begin Width:=2; Start:=2; if Odd(Length(Data)) then Exit; end
  else if (Length(Data)>=2) and (Data[0]=$fe) and (Data[1]=$ff) then Exit(gicUnsupported)
  else if (Length(Data)>=3) and (Data[0]=$ef) and (Data[1]=$bb) and (Data[2]=$bf) then Start:=3;
  N:=(Length(Data)-Start) div Width; SetLength(S,N);
  for I:=0 to N-1 do
  begin
    if (Width=2) and (Data[Start+I*2+1]<>0) then Exit(gicUnsupported);
    J:=Data[Start+I*Width];
    if J>127 then Exit(gicUnsupported);
    if (J<32) and not (J in [9,10,13]) then Exit;
    S[I+1]:=Chr(J);
  end;
  if ParseGptIni(Data,Current)<>grsOk then Exit;
  Sections:=TStringList.Create; Keys:=TStringList.Create;
  try
    Sections.Sorted:=True; Keys.Sorted:=True;
    Section:=''; InGeneral:=False; Found:=False; FirstDigit:=0; LastDigit:=0; I:=1;
    while I<=N do
    begin
      LineStart:=I;
      while (I<=N) and not (S[I] in [#10,#13]) do Inc(I);
      LineEnd:=I-1;
      if (I<=N) and (S[I]=#13) then Inc(I);
      if (I<=N) and (S[I]=#10) then Inc(I);
      Line:=Trim(Copy(S,LineStart,LineEnd-LineStart+1));
      if (Line='') or (Line[1] in [';','#']) then Continue;
      if Line[1]='[' then
      begin
        if Line[Length(Line)]<>']' then Exit;
        Name:=Trim(Copy(Line,2,Length(Line)-2));
        if Name='' then Exit;
        for J:=1 to Length(Name) do
          if not (Name[J] in ['A'..'Z','a'..'z','0'..'9','_',' ','-']) then Exit;
        if Sections.IndexOf(Name)>=0 then Exit;
        Sections.Add(Name); Keys.Clear; Section:=Name; InGeneral:=SameText(Name,'General');
        Continue;
      end;
      if Section='' then Exit;
      P:=Pos('=',Line); if P=0 then Exit;
      Name:=Trim(Copy(Line,1,P-1)); if Name='' then Exit;
      for J:=1 to Length(Name) do
        if not (Name[J] in ['A'..'Z','a'..'z','0'..'9','_','-']) then Exit;
      if Keys.IndexOf(Name)>=0 then Exit;
      Keys.Add(Name);
      if InGeneral and SameText(Name,'Version') then
      begin
        if Found then Exit;
        J:=LineStart; while (J<=LineEnd) and (S[J]<>'=') do Inc(J);
        Inc(J); while (J<=LineEnd) and (S[J] in [' ',#9]) do Inc(J);
        FirstDigit:=J; while (J<=LineEnd) and (S[J] in ['0'..'9']) do Inc(J);
        LastDigit:=J-1; Value:=Copy(S,FirstDigit,LastDigit-FirstDigit+1);
        while (J<=LineEnd) and (S[J] in [' ',#9]) do Inc(J);
        if (J<=LineEnd) or not GpoParseUnsigned(Value,Current) then Exit;
        Found:=True;
      end;
    end;
    if not Found then Exit;
    if Current<>ExpectedVersion then Exit(gicBaselineMismatch);
    Digits:=UIntToStr(NewVersion);
    PrefixBytes:=Start+(FirstDigit-1)*Width; SuffixBytes:=Start+LastDigit*Width;
    NewSize:=PrefixBytes+Length(Digits)*Width+Length(Data)-SuffixBytes;
    if NewSize>GpoMaxFileBytes then Exit(gicTooLarge);
    SetLength(Candidate,NewSize);
    if PrefixBytes>0 then Move(Data[0],Candidate[0],PrefixBytes);
    for J:=1 to Length(Digits) do
    begin
      Candidate[PrefixBytes+(J-1)*Width]:=Ord(Digits[J]);
      if Width=2 then Candidate[PrefixBytes+(J-1)*Width+1]:=0;
    end;
    if Length(Data)>SuffixBytes then
      Move(Data[SuffixBytes],Candidate[PrefixBytes+Length(Digits)*Width],Length(Data)-SuffixBytes);
    Result:=gicOk;
  finally Sections.Free; Keys.Free; end;
end;

function GpoBuildOfflinePlan(GpcVersion, GptVersion: Cardinal; const Ini,
  OldUser, NewUser, OldMachine, NewMachine: TBytes;
  out Plan: TGpoOfflinePlan): TGpoOfflinePlanStatus;
var OU,NU,OM,NM:TGpoPolicyImage;
begin
  OU.Exists:=True; OU.Data:=OldUser; NU.Exists:=True; NU.Data:=NewUser;
  OM.Exists:=True; OM.Data:=OldMachine; NM.Exists:=True; NM.Data:=NewMachine;
  Result:=GpoBuildOfflinePlanWithPresence(GpcVersion,GptVersion,Ini,OU,NU,OM,NM,Plan);
end;

function GpoBuildOfflinePlanWithPresence(GpcVersion, GptVersion: Cardinal; const Ini: TBytes;
  const OldUser, NewUser, OldMachine, NewMachine: TGpoPolicyImage;
  out Plan: TGpoOfflinePlan): TGpoOfflinePlanStatus;
var Work: TGpoOfflinePlan; IniStatus: TGptIniCandidateStatus;
  function PolicyAction(const OldImage,NewImage:TGpoPolicyImage):TGpoPolicyAction;
  begin
    if not OldImage.Exists then begin
      if NewImage.Exists then Result:=gpaCreate else Result:=gpaNone;
    end else if not NewImage.Exists then Result:=gpaDelete
    else if EqualPolicyBytes(OldImage.Data,NewImage.Data) then Result:=gpaNone
    else Result:=gpaReplace;
  end;
begin
  Plan:=Default(TGpoOfflinePlan); Work:=Default(TGpoOfflinePlan);
  Result:=gopInvalidPolicy;
  if not ValidPolicyImage(OldUser) or not ValidPolicyImage(NewUser) or
     not ValidPolicyImage(OldMachine) or not ValidPolicyImage(NewMachine) then Exit;
  Work.UserAction:=PolicyAction(OldUser,NewUser);
  Work.MachineAction:=PolicyAction(OldMachine,NewMachine);
  Work.UserChanged:=Work.UserAction<>gpaNone;
  Work.MachineChanged:=Work.MachineAction<>gpaNone;
  Work.UserExists:=NewUser.Exists; Work.MachineExists:=NewMachine.Exists;
  if not GpoPlanVersion(GpcVersion,GptVersion,Work.UserChanged,Work.MachineChanged,Work.Version) then
    Exit(gopBaselineMismatch);
  IniStatus:=GpoBuildGptIniCandidate(Ini,GptVersion,Work.Version.Version,Work.GptIni);
  case IniStatus of
    gicBaselineMismatch: Exit(gopBaselineMismatch);
    gicInvalid: Exit(gopInvalidIni);
    gicUnsupported: Exit(gopUnsupportedIni);
    gicTooLarge: Exit(gopTooLarge);
  end;
  if not (Work.UserChanged or Work.MachineChanged) then Work.GptIni:=Copy(Ini);
  Work.UserPolicy:=Copy(NewUser.Data); Work.MachinePolicy:=Copy(NewMachine.Data);
  Work.Baseline.GpcVersion:=GpcVersion; Work.Baseline.GptIni:=Copy(Ini);
  Work.Baseline.UserPolicy.Exists:=OldUser.Exists;
  Work.Baseline.UserPolicy.Data:=Copy(OldUser.Data);
  Work.Baseline.MachinePolicy.Exists:=OldMachine.Exists;
  Work.Baseline.MachinePolicy.Data:=Copy(OldMachine.Data);
  Plan:=Work; Result:=gopOk;
end;

function GpoCheckOfflineBaseline(const Baseline: TGpoOfflineBaseline; LatestGpcVersion: Cardinal;
  const LatestIni: TBytes; const LatestUser, LatestMachine: TGpoPolicyImage): TGpoBaselineCheck;
var BaseVersion, LatestVersion:Cardinal; Scratch:TBytes;
  function ValidIni(const Data:TBytes; out Version:Cardinal):Boolean;
  begin
    Result:=ParseGptIni(Data,Version)=grsOk;
    if Result then Result:=GpoBuildGptIniCandidate(Data,Version,Version,Scratch)=gicOk;
    Scratch:=nil;
  end;
begin
  Result:=gbcInvalid;
  if not ValidPolicyImage(Baseline.UserPolicy) or not ValidPolicyImage(Baseline.MachinePolicy) or
     not ValidPolicyImage(LatestUser) or not ValidPolicyImage(LatestMachine) or
     not ValidIni(Baseline.GptIni,BaseVersion) or not ValidIni(LatestIni,LatestVersion) or
     (BaseVersion<>Baseline.GpcVersion) then Exit;
  Result:=gbcConflict;
  if (LatestGpcVersion<>Baseline.GpcVersion) or (LatestVersion<>LatestGpcVersion) or
     not EqualPolicyBytes(Baseline.GptIni,LatestIni) or
     (Baseline.UserPolicy.Exists<>LatestUser.Exists) or
     (Baseline.MachinePolicy.Exists<>LatestMachine.Exists) or
     not EqualPolicyBytes(Baseline.UserPolicy.Data,LatestUser.Data) or
     not EqualPolicyBytes(Baseline.MachinePolicy.Data,LatestMachine.Data) then Exit;
  Result:=gbcMatch;
end;

// MS-GPREG 2.2.1 and Microsoft Registry Policy File Format:
// https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpreg/5c092c22-bf6b-4e7f-b180-b20743d368f5
// https://learn.microsoft.com/en-us/previous-versions/windows/desktop/Policy/registry-policy-file-format
// DWORD LE signature/version, UTF-16LE delimiters and NUL-terminated names,
// DWORD LE type/length, then exactly length raw bytes (possibly odd).
function ParseRegistryPol(const Data: TBytes; out Records: TGpoRegistryRecords): TGpoReadStatus;
var P, N, Count, Capacity: SizeInt; V, Size: Cardinal;
  Item: TGpoRegistryRecord; Parsed: TGpoRegistryRecords;
  function DWord(out Number: Cardinal): Boolean;
  begin
    Result := Length(Data)-P >= 4;
    if not Result then Exit;
    Number := Cardinal(Data[P]) or (Cardinal(Data[P+1]) shl 8) or
      (Cardinal(Data[P+2]) shl 16) or (Cardinal(Data[P+3]) shl 24); Inc(P,4);
  end;
  function Delimiter(C: Byte): Boolean;
  begin
    Result := (Length(Data)-P >= 2);
    if not Result then Exit;
    Result := (Data[P] = C) and (Data[P+1] = 0);
    if Result then Inc(P,2);
  end;
  function Name(out S: UnicodeString): Boolean;
  var BeginAt, Units, J: SizeInt; C: Word;
  begin
    Result := False; S := ''; BeginAt := P; Units := 0;
    while Length(Data)-P >= 2 do
    begin
      C := Word(Data[P]) or (Word(Data[P+1]) shl 8); Inc(P,2);
      if C = 0 then
      begin
        SetLength(S,Units);
        for J := 1 to Units do S[J] := WideChar(Word(Data[BeginAt+(J-1)*2]) or (Word(Data[BeginAt+(J-1)*2+1]) shl 8));
        Result := ValidUtf16(S); Exit;
      end;
      Inc(Units); if Units > GpoMaxNameUnits then Exit;
    end;
  end;
begin
  Records := nil; Parsed := nil; Result := grsCorrupt; P := 0; Count := 0; Capacity := 0;
  if Length(Data) > GpoMaxFileBytes then Exit(grsTooLarge);
  if not DWord(V) or (V <> $67655250) then Exit;
  if not DWord(V) then Exit;
  if V <> 1 then Exit(grsUnsupported);
  while P < Length(Data) do
  begin
    if Count = GpoMaxRecords then Exit(grsTooLarge);
    if not Delimiter(Ord('[')) then Exit;
    if not Name(Item.Key) or (Item.Key = '') then Exit;
    if not Delimiter(Ord(';')) or not Name(Item.ValueName) then Exit;
    if not Delimiter(Ord(';')) or not DWord(Item.ValueType) then Exit;
    if not Delimiter(Ord(';')) or not DWord(Size) then Exit;
    if not Delimiter(Ord(';')) then Exit;
    if Size > GpoMaxValueBytes then Exit(grsTooLarge);
    if Size > Cardinal(Length(Data)-P) then Exit;
    N := Size; SetLength(Item.Data,N);
    if N > 0 then Move(Data[P],Item.Data[0],N); Inc(P,N);
    if not Delimiter(Ord(']')) then Exit;
    if Count = Capacity then
    begin
      if Capacity = 0 then Capacity := 16 else Capacity := Capacity * 2;
      SetLength(Parsed,Capacity);
    end;
    Parsed[Count] := Item; Inc(Count);
    Item.Data := nil;
  end;
  SetLength(Parsed,Count); Records := Parsed; Result := grsOk;
end;


function SerializeRegistryPol(const Records: TGpoRegistryRecords;
  out Data: TBytes): TGpoReadStatus;
var I, J, Size, RecordSize, P: SizeInt;
  procedure PutWord(V: Word);
  begin
    Data[P] := V and $ff; Data[P+1] := V shr 8; Inc(P,2);
  end;
  procedure PutDWord(V: Cardinal);
  begin PutWord(V and $ffff); PutWord(V shr 16); end;
  procedure PutName(const S: UnicodeString);
  var K: SizeInt;
  begin
    for K := 1 to Length(S) do PutWord(Ord(S[K]));
    PutWord(0);
  end;
begin
  Data := nil;
  if Length(Records) > GpoMaxRecords then Exit(grsTooLarge);
  Size := 8;
  for I := 0 to High(Records) do
  begin
    if (Length(Records[I].Key) > GpoMaxNameUnits) or
       (Length(Records[I].ValueName) > GpoMaxNameUnits) or
       (Length(Records[I].Data) > GpoMaxValueBytes) then Exit(grsTooLarge);
    if (Records[I].Key = '') or not ValidUtf16(Records[I].Key) or
       not ValidUtf16(Records[I].ValueName) then Exit(grsCorrupt);
    for J := 1 to Length(Records[I].Key) do
      if Records[I].Key[J] = #0 then Exit(grsCorrupt);
    for J := 1 to Length(Records[I].ValueName) do
      if Records[I].ValueName[J] = #0 then Exit(grsCorrupt);
    // Each term is bounded above before adding: safe on 32-bit targets too.
    RecordSize := 24 + 2*(Length(Records[I].Key)+Length(Records[I].ValueName)) +
      Length(Records[I].Data);
    if RecordSize > GpoMaxFileBytes-Size then Exit(grsTooLarge);
    Inc(Size,RecordSize);
  end;
  SetLength(Data,Size); P := 0;
  PutDWord($67655250); PutDWord(1);
  for I := 0 to High(Records) do
  begin
    PutWord(Ord('[')); PutName(Records[I].Key); PutWord(Ord(';'));
    PutName(Records[I].ValueName); PutWord(Ord(';'));
    PutDWord(Records[I].ValueType); PutWord(Ord(';'));
    PutDWord(Length(Records[I].Data)); PutWord(Ord(';'));
    if Length(Records[I].Data) > 0 then
      Move(Records[I].Data[0],Data[P],Length(Records[I].Data));
    Inc(P,Length(Records[I].Data)); PutWord(Ord(']'));
  end;
  Result := grsOk;
end;

end.
