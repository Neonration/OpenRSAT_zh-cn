unit unittest.ugporeadonly;
{$mode ObjFPC}{$H+}
interface
uses SysUtils, mormot.core.test, ugpoformats, ugposysvol;
type
  TUnitTestGpoReadOnly = class(TSynTestCase)
  published
    procedure RegistryRecords;
    procedure RegistryBounds;
    procedure IniAndVersions;
    procedure LdapVersionSigned;
    procedure SafePaths;
    procedure NativeTransportBoundary;
    {$if defined(windows) and defined(OPENRSATTESTS)}
    procedure GuardedRelativePathValidation;
    {$endif}
  end;
implementation
procedure AddByte(var B:TBytes; V:Byte);
var N:SizeInt;
begin N:=Length(B); SetLength(B,N+1); B[N]:=V; end;
procedure AddWord(var B:TBytes; V:Word);
begin AddByte(B,V and 255); AddByte(B,V shr 8); end;
procedure AddDword(var B:TBytes; V:Cardinal);
begin AddWord(B,V and 65535); AddWord(B,V shr 16); end;
procedure AddName(var B:TBytes; const S:UnicodeString);
var I:SizeInt;
begin for I:=1 to Length(S) do AddWord(B,Ord(S[I])); AddWord(B,0); end;
function Header:TBytes;
begin Result:=nil; AddDword(Result,$67655250); AddDword(Result,1); end;
function RecordBytes(const Key,Name:UnicodeString; Kind:Cardinal; const Payload:array of Byte):TBytes;
var I:SizeInt;
begin
  Result:=Header; AddWord(Result,Ord('[')); AddName(Result,Key);
  AddWord(Result,Ord(';')); AddName(Result,Name); AddWord(Result,Ord(';'));
  AddDword(Result,Kind); AddWord(Result,Ord(';')); AddDword(Result,Length(Payload));
  AddWord(Result,Ord(';')); for I:=0 to High(Payload) do AddByte(Result,Payload[I]);
  AddWord(Result,Ord(']'));
end;
function Bytes(const S:RawByteString):TBytes;
begin Result:=nil; SetLength(Result,Length(S)); if Length(S)>0 then Move(S[1],Result[0],Length(S)); end;
procedure TUnitTestGpoReadOnly.RegistryRecords;
var B:TBytes; R:TGpoRegistryRecords; U:UnicodeString;
begin
  B:=Header; Check(ParseRegistryPol(B,R)=grsOk); Check(Length(R)=0);
  B:=RecordBytes('Software\Policies\Test','Value',4,[1,0,0,0]);
  Check(ParseRegistryPol(B,R)=grsOk); Check(Length(R)=1); Check(R[0].Key='Software\Policies\Test');
  Check(R[0].ValueName='Value'); Check(R[0].ValueType=4); Check(Length(R[0].Data)=4); Check(R[0].Data[0]=1);
  U:=UnicodeString(WideChar($4e2d))+WideChar($d83d)+WideChar($de00);
  B:=RecordBytes(U,'', $deadbeef,[0,59,0,93,0,255,0]);
  Check(ParseRegistryPol(B,R)=grsOk); Check(R[0].Key=U); Check(R[0].ValueName='');
  Check(R[0].ValueType=$deadbeef); Check(Length(R[0].Data)=7); Check(R[0].Data[5]=255);
  B:=RecordBytes('K','V',0,[]); Check(ParseRegistryPol(B,R)=grsOk); Check(Length(R[0].Data)=0);
  B:=RecordBytes(UnicodeString(WideChar($d800)),'',1,[]); Check(ParseRegistryPol(B,R)=grsCorrupt);
  B:=RecordBytes(UnicodeString(WideChar($dc00)),'',1,[]); Check(ParseRegistryPol(B,R)=grsCorrupt);
  B:=RecordBytes('','',1,[]); Check(ParseRegistryPol(B,R)=grsCorrupt);
end;
procedure TUnitTestGpoReadOnly.RegistryBounds;
var B,C:TBytes; R:TGpoRegistryRecords; I,N:SizeInt;
begin
  B:=RecordBytes('K','V',4,[1,2,3,4]);
  for I:=0 to Length(B)-1 do
  begin
    if I=8 then Continue; // Empty, valid header is a valid zero-policy file.
    C:=Copy(B,0,I); Check(ParseRegistryPol(C,R)=grsCorrupt); Check(Length(R)=0);
  end;
  C:=Copy(B); C[0]:=0; Check(ParseRegistryPol(C,R)=grsCorrupt);
  C:=Copy(B); C[4]:=2; Check(ParseRegistryPol(C,R)=grsUnsupported);
  C:=Copy(B); C[7]:=1; Check(ParseRegistryPol(C,R)=grsUnsupported);
  C:=Copy(B); C[8]:=0; Check(ParseRegistryPol(C,R)=grsCorrupt);
  C:=Copy(B); C[28]:=255; C[29]:=255; C[30]:=255; C[31]:=255;
  Check(ParseRegistryPol(C,R)=grsTooLarge);
  C:=Copy(B); AddByte(C,0); Check(ParseRegistryPol(C,R)=grsCorrupt); Check(Length(R)=0);
  SetLength(C,GpoMaxFileBytes+1); Check(ParseRegistryPol(C,R)=grsTooLarge);
  SetLength(C,GpoMaxFileBytes); FillChar(C[0],Length(C),0); Check(ParseRegistryPol(C,R)=grsCorrupt);
  B:=RecordBytes(UnicodeString(StringOfChar('K',GpoMaxNameUnits)),'',0,[]); Check(ParseRegistryPol(B,R)=grsOk);
  B:=RecordBytes(UnicodeString(StringOfChar('K',GpoMaxNameUnits+1)),'',0,[]); Check(ParseRegistryPol(B,R)=grsCorrupt);
  // Maximum payload is 65535 per MS-GPREG, not the application file cap.
  SetLength(C,GpoMaxValueBytes); FillChar(C[0],Length(C),$ff);
  B:=RecordBytes('K','V',3,C); Check(ParseRegistryPol(B,R)=grsOk); Check(Length(R[0].Data)=GpoMaxValueBytes);
  SetLength(C,GpoMaxValueBytes+1); B:=RecordBytes('K','V',3,C); Check(ParseRegistryPol(B,R)=grsTooLarge);
  B:=RecordBytes('K','V',3,[]); N:=Length(B)-8;
  SetLength(C,8+GpoMaxRecords*N); Move(B[0],C[0],8);
  for I:=0 to GpoMaxRecords-1 do Move(B[8],C[8+I*N],N);
  Check(ParseRegistryPol(C,R)=grsOk); Check(Length(R)=GpoMaxRecords);
  SetLength(C,Length(C)+N); Move(B[8],C[Length(C)-N],N);
  Check(ParseRegistryPol(C,R)=grsTooLarge); Check(Length(R)=0);
  // Unknown or odd-sized binary payload does not shift subsequent UTF-16 fields.
  B:=RecordBytes('One','',99,[1]); C:=RecordBytes('Two','',4,[2,0,0,0]);
  N:=Length(B); SetLength(B,N+Length(C)-8); Move(C[8],B[N],Length(C)-8);
  Check(ParseRegistryPol(B,R)=grsOk); Check(Length(R)=2); Check(R[1].Key='Two');
end;
procedure TUnitTestGpoReadOnly.IniAndVersions;
var V:Cardinal; B:TBytes; I:Integer; S:string;
begin
  Check(GpoUserVersion($12345678)=$1234); Check(GpoMachineVersion($12345678)=$5678);
  Check(ParseGptIni(Bytes('[General]'#13#10'Version=305419896'#13#10),V)=grsOk); Check(V=$12345678);
  Check(ParseGptIni(Bytes('[general]'#10'version=0'),V)=grsOk); Check(V=0);
  Check(ParseGptIni(Bytes('[General]'#10'Version=4294967295'),V)=grsOk); Check(V=High(Cardinal));
  Check(ParseGptIni(Bytes('[General]'#10'Version=4294967296'),V)=grsCorrupt);
  Check(ParseGptIni(Bytes('[General]'#10'Version=-1'),V)=grsCorrupt);
  Check(ParseGptIni(Bytes('[General]'#10'Version=1'#10'Version=2'),V)=grsCorrupt); Check(V=0);
  Check(ParseGptIni(Bytes('[Other]'#10'Version=1'),V)=grsCorrupt);
  Check(ParseGptIni(nil,V)=grsCorrupt);
  S:='[General]'#13#10'Version=65538'; B:=nil; AddWord(B,$feff);
  for I:=1 to Length(S) do AddWord(B,Ord(S[I]));
  Check(ParseGptIni(B,V)=grsOk); Check(V=65538);
  AddByte(B,0); Check(ParseGptIni(B,V)=grsCorrupt);
  Check(ParseGptIni(Bytes(#239#187#191'[General]'#10'Version=2'),V)=grsOk);
  Check(not GpoParseUnsigned('+1',V)); Check(not GpoParseUnsigned('1x',V));
end;
procedure TUnitTestGpoReadOnly.LdapVersionSigned;
const Invalid: array[0..15] of string = ('', '-', '+1', ' 1', '1 ', '--1',
  '1.0', '1x', '0x80000000', '2147483648', '-2147483649', '4294967295',
  '999999999999999999999999999', '-999999999999999999999999999', '- 1', #0);
var V: Cardinal; I: Integer;
begin
  Check(GpoParseLdapVersion('-2147483648',V)); Check(V=$80000000);
  Check(GpoUserVersion(V)=$8000); Check(GpoMachineVersion(V)=0);
  Check(GpoParseLdapVersion('-2147483647',V)); Check(V=$80000001);
  Check(GpoUserVersion(V)=$8000); Check(GpoMachineVersion(V)=1);
  Check(GpoParseLdapVersion('-1',V)); Check(V=$ffffffff);
  Check(GpoUserVersion(V)=$ffff); Check(GpoMachineVersion(V)=$ffff);
  Check(GpoParseLdapVersion('2147483647',V)); Check(V=$7fffffff);
  Check(GpoParseLdapVersion('0',V)); Check(V=0);
  Check(GpoParseLdapVersion('-0',V)); Check(V=0);
  Check(GpoParseLdapVersion('65538',V)); Check(V=65538);
  for I := Low(Invalid) to High(Invalid) do
  begin
    V := $deadbeef;
    Check(not GpoParseLdapVersion(Invalid[I],V)); Check(V=0);
  end;
  // LDAP and GPT encodings differ intentionally. GPT remains unsigned DWORD.
  Check(ParseGptIni(Bytes('[General]'#10'Version=2147483648'),V)=grsOk);
  Check(V=$80000000);
  Check(ParseGptIni(Bytes('[General]'#10'Version=-2147483648'),V)=grsCorrupt);
  Check(V=0);
end;
{$if defined(windows) and defined(OPENRSATTESTS)}
procedure TUnitTestGpoReadOnly.GuardedRelativePathValidation;
const Invalid: array[0..13] of UnicodeString = ('', '.', '..', '\file',
  'dir\\file', 'dir\..\file', 'dir\.\file', 'dir\file:stream', 'dir/file',
  'dir\file.', 'dir\file ', 'dir\file*', 'dir\'+#0+'file',
  'a\b\c\d\e\f\g\h\i');
var B:TBytes; I:Integer;
begin
  // Invalid segments fail before even attempting to open this nonexistent root.
  for I:=Low(Invalid) to High(Invalid) do
  begin
    SetLength(B,1); B[0]:=99;
    Check(GpoTestReadGuardedFile('\??\C:\nonexistent-gpo-unit-fixture',Invalid[I],B)=grsInvalidPath);
    Check(Length(B)=0);
  end;
  Check(GpoTestReadGuardedFile('','file',B)=grsInvalidPath);
  Check(Length(B)=0);
end;
{$endif}
procedure TUnitTestGpoReadOnly.NativeTransportBoundary;
const G='{12345678-1234-1234-1234-123456789ABC}';
  Root='\\example.test\SYSVOL\example.test\Policies\'+G;
var Path:string;
begin
  Check(GpoBuildNativePath(Root,'example.test','dc.example.test',G,gfGptIni,Path)=grsOk);
  Check(Path='\Device\Mup\dc.example.test\SYSVOL\example.test\Policies\'+G+'\GPT.INI');
  Check(GpoBuildNativePath(Root,'example.test','dc.example.test',G,gfMachineRegistry,Path)=grsOk);
  Check(Path='\Device\Mup\dc.example.test\SYSVOL\example.test\Policies\'+G+'\Machine\Registry.pol');
  Check(GpoBuildNativePath(Root+'\..','example.test','dc.example.test',G,gfGptIni,Path)=grsInvalidPath);
  Check(Path='');
  Check(GpoNtStatusToReadStatus($00000000)=grsOk);
  Check(GpoNtStatusToReadStatus($c000000f)=grsMissing);
  Check(GpoNtStatusToReadStatus($c0000034)=grsMissing);
  Check(GpoNtStatusToReadStatus($c000003a)=grsMissing);
  Check(GpoNtStatusToReadStatus($c0000022)=grsAccessDenied);
  Check(GpoNtStatusToReadStatus($c000006d)=grsAccessDenied);
  Check(GpoNtStatusToReadStatus($c000050b)=grsReparseBlocked);
  Check(GpoNtStatusToReadStatus($8000002d)=grsReparseBlocked);
  Check(GpoNtStatusToReadStatus($c0000279)=grsReparseBlocked);
  Check(GpoNtStatusToReadStatus($c000000d)=grsUnsupported);
  Check(GpoNtStatusToReadStatus($c00000bb)=grsUnsupported);
  Check(GpoNtStatusToReadStatus($c0000002)=grsUnsupported);
  Check(GpoNtStatusToReadStatus($c00000b5)=grsIoError); // Timeout must not look missing.
  Check(GpoStatusText(grsReparseBlocked)='Reparse blocked');
end;
procedure TUnitTestGpoReadOnly.SafePaths;
const G='{12345678-1234-1234-1234-123456789ABC}';
  Root='\\example.test\SYSVOL\example.test\Policies\'+G;
var Path:string; B:TBytes;
begin
  Check(GpoValidGuid(G)); Check(not GpoValidGuid('12345678-1234-1234-1234-123456789ABC'));
  Check(GpoBuildSafePath(Root,'example.test','dc.example.test',G,gfGptIni,Path)=grsOk);
  Check(Path='\\dc.example.test\SYSVOL\example.test\Policies\'+G+'\GPT.INI');
  Check(GpoBuildSafePath(Root,'example.test','dc.example.test',G,gfUserRegistry,Path)=grsOk);
  Check(Pos('\User\Registry.pol',Path)>0);
  Check(GpoBuildSafePath(Root+'\..','example.test','dc.example.test',G,gfGptIni,Path)=grsInvalidPath); Check(Path='');
  Check(GpoBuildSafePath(Root,'other.test','dc.example.test',G,gfGptIni,Path)=grsInvalidPath);
  Check(GpoBuildSafePath(Root,'example.test','dc.example.test\evil',G,gfGptIni,Path)=grsInvalidPath);
  Check(GpoBuildSafePath('\\evil\SYSVOL\example.test\Policies\'+G,'example.test','dc.example.test',G,gfGptIni,Path)=grsInvalidPath);
  Check(GpoBuildSafePath(Root,'example.test','dc.example.test',G+'\..',gfGptIni,Path)=grsInvalidPath);
  Check(GpoReadFile('invalid','example.test','dc.example.test',G,gfGptIni,B)=grsInvalidPath); Check(Length(B)=0);
end;
end.
