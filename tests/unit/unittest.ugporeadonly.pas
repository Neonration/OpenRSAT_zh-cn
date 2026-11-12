unit unittest.ugporeadonly;
{$mode ObjFPC}{$H+}
interface
uses Classes, SysUtils, mormot.core.base, mormot.core.test, mormot.core.os.security, mormot.net.ldap, ugpoformats, ugposysvol;
type
  TUnitTestGpoReadOnly = class(TSynTestCase)
  published
    procedure RegistryRecords;
    procedure RegistryBounds;
    procedure IniAndVersions;
    procedure LdapVersionSigned;
    procedure VersionPlanning;
    procedure GptIniCandidate;
    procedure GptIniUnicodeCandidate;
    procedure OfflineChangePlan;
    procedure OfflinePlanPresence;
    procedure OfflineBaselineChecks;
    procedure OfflinePlanIntegrity;
    procedure BoundPlanComparison;
    procedure BoundPlanWithFiles;
    procedure FileEvidenceSecurityValidation;
    procedure LdapEvidenceParsing;
    procedure LdapCaptureTransport;
    procedure SafePaths;
    procedure NativeTransportBoundary;
    {$if defined(windows) and defined(OPENRSATTESTS)}
    procedure GuardedRelativePathValidation;
    procedure GuardedFileObservation;
    {$endif}
  end;
implementation
type
  TPreflightToken=class(TInterfacedObject,ILdapSessionToken)
    Valid:Boolean;
    function IsValid:Boolean;
    procedure Invalidate;
  end;
  TFakeEvidenceTransport=class(TInterfacedObject,IGpoLdapEvidenceTransport)
    Current:TGpoLdapSessionState;
    Flags,RootFlags,GpcFlags:TLdapSearchSDFlags;
    Root,RootWithoutControl,Gpc:TLdapResult;
    Token:ILdapSessionToken;
    CancelControl:TGpoReadControl;
    Mode,Calls:Integer;
    AskedSupport,AskedSD:Boolean;
    constructor Create;
    destructor Destroy; override;
    function State(out Value:TGpoLdapSessionState):Boolean;
    function GetSDFlags:TLdapSearchSDFlags;
    procedure SetSDFlags(Value:TLdapSearchSDFlags);
    function Search(const DN,Filter:RawUtf8; const Attributes:array of RawUtf8):TLdapResult;
  end;
function TPreflightToken.IsValid:Boolean; begin Result:=Valid; end;
procedure TPreflightToken.Invalidate; begin Valid:=False; end;
const TestEvidenceGuid='{12345678-1234-1234-1234-123456789ABC}';
  TestEvidenceDN='CN='+TestEvidenceGuid+',CN=Policies,CN=System,DC=example,DC=test';
constructor TFakeEvidenceTransport.Create;
var T:TPreflightToken; SD:mormot.core.os.security.TSecurityDescriptor;
begin
  inherited Create; T:=TPreflightToken.Create; T.Valid:=True; Token:=T;
  Current.Session:=Token; Current.Connected:=True; Current.Bound:=True; Current.Socket:=Pointer(1);
  Current.Host:='dc.example.test'; Current.Port:='389'; Current.UserName:='test';
  Current.Server:='dc.example.test'; Current.DefaultDN:='DC=example,DC=test';
  Flags:=[lsfSaclSecurityInformation];
  Root:=TLdapResult.Create; Root.Attributes.Add('dnsHostName',Current.Host);
  Root.Attributes.Add('defaultNamingContext',Current.DefaultDN); Root.Attributes.Add('supportedControl',LDAP_SERVER_SD_FLAGS_OID);
  RootWithoutControl:=TLdapResult.Create; RootWithoutControl.Attributes.Add('dnsHostName',Current.Host);
  RootWithoutControl.Attributes.Add('defaultNamingContext',Current.DefaultDN);
  Gpc:=TLdapResult.Create; Gpc.ObjectName:=TestEvidenceDN;
  Gpc.Attributes.Add('name',TestEvidenceGuid); Gpc.Attributes.Add('objectGUID',#1+StringOfChar(#0,15));
  Gpc.Attributes.Add('gPCFileSysPath','\\example.test\SYSVOL\example.test\Policies\'+TestEvidenceGuid);
  Gpc.Attributes.Add('versionNumber','1'); Gpc.Attributes.Add('flags','0'); Gpc.Attributes.Add('uSNChanged','17');
  SD.FromText('O:SYG:SYD:(A;;GA;;;SY)'); Gpc.Attributes.Add('nTSecurityDescriptor',SD.ToBinary);
end;
destructor TFakeEvidenceTransport.Destroy;
begin Root.Free; RootWithoutControl.Free; Gpc.Free; inherited Destroy; end;
function TFakeEvidenceTransport.State(out Value:TGpoLdapSessionState):Boolean;
begin Value:=Current; Result:=True; end;
function TFakeEvidenceTransport.GetSDFlags:TLdapSearchSDFlags; begin Result:=Flags; end;
procedure TFakeEvidenceTransport.SetSDFlags(Value:TLdapSearchSDFlags);
begin
  if (Mode=10) and (Value=[lsfSaclSecurityInformation]) then raise Exception.Create('synthetic restore failure');
  Flags:=Value;
end;
function TFakeEvidenceTransport.Search(const DN,Filter:RawUtf8; const Attributes:array of RawUtf8):TLdapResult;
var T:TPreflightToken; I:Integer;
begin
  Inc(Calls);
  for I:=0 to High(Attributes) do begin
    if Attributes[I]='supportedControl' then AskedSupport:=True;
    if Attributes[I]='nTSecurityDescriptor' then AskedSD:=True;
  end;
  if DN='' then
  begin
    RootFlags:=Flags;
    if Mode=1 then Token.Invalidate;
    if (Mode=11) and Assigned(CancelControl) then CancelControl.Cancel;
    if Mode=2 then begin T:=TPreflightToken.Create; T.Valid:=True; Current.Session:=T; end;
    if Mode=8 then Current.Host:='dc2.example.test';
    if Mode=5 then Exit(RootWithoutControl);
    Exit(Root);
  end;
  GpcFlags:=Flags;
  if Mode=3 then raise Exception.Create('synthetic read failure');
  if Mode=4 then Exit(nil);
  if Mode=6 then Token.Invalidate;
  if Mode=7 then Gpc.Find('nTSecurityDescriptor').Clear;
  if Mode=9 then Current.DefaultDN:='DC=other,DC=test';
  Result:=Gpc;
end;
procedure TUnitTestGpoReadOnly.LdapCaptureTransport;
var F:TFakeEvidenceTransport; Transport:IGpoLdapEvidenceTransport; E:TGpoLdapEvidence; Mode:Integer; R:TGpoPreflightResult;
  Control:TGpoReadControl;
begin
  for Mode:=0 to 10 do
  begin
    F:=TFakeEvidenceTransport.Create; Transport:=F; F.Mode:=Mode;
    R:=GpoCaptureLdapFromTransport(Transport,TestEvidenceDN,TestEvidenceGuid,E);
    if Mode=10 then Check(F.Flags=lsfMain) else
      Check(F.Flags=[lsfSaclSecurityInformation],'Original SD control must be restored');
    Check(F.RootFlags=[]); Check(F.AskedSupport);
    if Mode=0 then
    begin
      Check(R=gprEvidenceIncomplete); Check(F.Calls=2); Check(F.GpcFlags=lsfMain); Check(F.AskedSD);
      Check(E.SecurityStatus=gseUnverified); Check(Assigned(E.Target.Session)); Check(E.USNChanged=17);
    end else
    begin
      if Mode in [1,2,6,8,9] then Check(R=gprSessionInvalid) else Check(R=gprReadUnavailable);
      Check((Length(E.SecurityDescriptor)=0) and (E.SecurityStatus=gseUnavailable));
      if Mode in [1,2,5,8] then Check(F.Calls=1) else begin Check(F.Calls=2); Check(F.GpcFlags=lsfMain); end;
    end;
    Transport:=nil;
  end;
  F:=TFakeEvidenceTransport.Create; Transport:=F; F.Mode:=11;
  Control:=TGpoReadControl.Create(30000,F.Token); F.CancelControl:=Control;
  try
    R:=GpoCaptureLdapFromTransport(Transport,TestEvidenceDN,TestEvidenceGuid,E,Control);
    Check(R=gprReadUnavailable); Check(F.Calls=1,'Cancellation prevents the second LDAP query');
    Check(F.Flags=[lsfSaclSecurityInformation]); Check(Length(E.SecurityDescriptor)=0);
  finally Control.Free; Transport:=nil; end;
end;

procedure TUnitTestGpoReadOnly.VersionPlanning;
var P:TGpoVersionPlan; V:Cardinal;
begin
  Check(GpoPlanVersion($12345678,$12345678,False,False,P));
  Check(P.Version=$12345678); Check(P.LdapValue='305419896'); Check(P.GptValue='305419896');
  Check(GpoPlanVersion($12345678,$12345678,True,False,P)); Check(P.Version=$12355678);
  Check(GpoPlanVersion($12345678,$12345678,False,True,P)); Check(P.Version=$12345679);
  Check(GpoPlanVersion($0000ffff,$0000ffff,False,True,P)); Check(P.Version=$00000001);
  Check(GpoPlanVersion($ffff4321,$ffff4321,True,False,P)); Check(P.Version=$00014321);
  Check(GpoPlanVersion($ffffffff,$ffffffff,True,True,P)); Check(P.Version=$00010001);
  Check(GpoPlanVersion($7fff0000,$7fff0000,True,False,P));
  Check(P.Version=$80000000); Check(P.LdapValue='-2147483648'); Check(P.GptValue='2147483648');
  Check(GpoParseLdapVersion(P.LdapValue,V)); Check(V=P.Version);
  Check(GpoParseUnsigned(P.GptValue,V)); Check(V=P.Version);
  Check(GpoPlanVersion($ffffffff,$ffffffff,False,False,P));
  Check(P.LdapValue='-1'); Check(P.GptValue='4294967295');
  Check(not GpoPlanVersion(1,2,True,False,P));
  Check(P.Version=0); Check(P.LdapValue=''); Check(P.GptValue='');
end;
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
procedure TUnitTestGpoReadOnly.FileEvidenceSecurityValidation;
var E,Other:TGpoFileEvidence; SD:mormot.core.os.security.TSecurityDescriptor; RawSD:RawByteString;
  K:TGpoEvidenceKind; N:Integer; NullEvidence:TGpoFileEvidence;
begin
  for K:=gekFile to gekParent do
  begin
    E:=Default(TGpoFileEvidence); E.Available:=True; E.Kind:=K; E.FileIndexLow:=1;
    if K=gekParent then E.Attributes:=$10;
    Check(SD.FromText('O:SYG:SYD:(A;;GA;;;SY)')=atpSuccess); RawSD:=SD.ToBinary;
    E.SecurityDescriptor:=Bytes(RawSD);
    Check(GpoCompareFileEvidence(E,E)=gprEvidenceIncomplete);
    Other:=E; Other.SecurityDescriptor:=Bytes(#0);
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Malformed SD must not validate against itself');
    Check(GpoCompareFileEvidence(E,Other)=gprReadUnavailable);
    Check(GpoCompareFileEvidence(Other,E)=gprReadUnavailable);
    Other.SecurityDescriptor:=Copy(E.SecurityDescriptor,0,Length(E.SecurityDescriptor)-1);
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Truncated SD must be rejected');
    Check(SD.FromText('G:SYD:(A;;GA;;;SY)')=atpSuccess); Other.SecurityDescriptor:=Bytes(SD.ToBinary);
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Missing owner');
    Check(SD.FromText('O:SYD:(A;;GA;;;SY)')=atpSuccess); Other.SecurityDescriptor:=Bytes(SD.ToBinary);
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Missing group');
    Check(SD.FromText('O:SYG:SY')=atpSuccess); Other.SecurityDescriptor:=Bytes(SD.ToBinary);
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'DACL information absent');
    Include(SD.Flags,scDaclPresent); Other.SecurityDescriptor:=Bytes(SD.ToBinary);
    Check(GpoCompareFileEvidence(Other,Other)=gprEvidenceIncomplete,'Present NULL DACL is valid evidence');
    Check(GpoCompareFileEvidence(E,Other)=gprConflict,'Valid but changed DACL');
    NullEvidence:=Other; Other.SecurityDescriptor:=Copy(Other.SecurityDescriptor);
    N:=Length(Other.SecurityDescriptor); SetLength(Other.SecurityDescriptor,N+8);
    Other.SecurityDescriptor[16]:=N and $ff; Other.SecurityDescriptor[17]:=(N shr 8) and $ff;
    Other.SecurityDescriptor[18]:=(N shr 16) and $ff; Other.SecurityDescriptor[19]:=(N shr 24) and $ff;
    Other.SecurityDescriptor[N]:=2; Other.SecurityDescriptor[N+2]:=8;
    Check(GpoCompareFileEvidence(Other,Other)=gprEvidenceIncomplete,'Present empty DACL is valid evidence');
    Check(GpoCompareFileEvidence(NullEvidence,Other)=gprConflict,'NULL and empty DACL differ');
    Other.SecurityDescriptor[N+4]:=1;
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Missing ACE is invalid');
    Other:=E; Other.SecurityDescriptor:=Copy(E.SecurityDescriptor);
    Other.SecurityDescriptor[4]:=$ff; Other.SecurityDescriptor[5]:=$ff;
    Other.SecurityDescriptor[6]:=$ff; Other.SecurityDescriptor[7]:=$ff;
    Check(GpoCompareFileEvidence(Other,Other)=gprReadUnavailable,'Invalid owner offset');
  end;
end;

procedure TUnitTestGpoReadOnly.BoundPlanWithFiles;
const Guid='{12345678-1234-1234-1234-123456789ABC}';
var T:TGpoPreflightTarget; Token:ILdapSessionToken; TokenObj:TPreflightToken;
  E,Other:TGpoLdapEvidence; F,Changed:TGpoObservedFiles; P,Replanned:TGpoOfflinePlan; B:TGpoBoundPlan; Draft:TGpoObservedDraft;
  SD:mormot.core.os.security.TSecurityDescriptor; RawSD:RawByteString;
  OldUser,NewUser,OldMachine,NewMachine,SnapshotUser,SnapshotMachine:TGpoPolicyImage; Ini:TBytes; A:TGpoFile;
begin
  TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; Token:=TokenObj;
  T:=Default(TGpoPreflightTarget); T.Domain:='example.test'; T.DC:='dc.example.test';
  T.DN:='CN=policy,DC=example,DC=test'; T.Guid:=Guid;
  T.FileSysPath:='\\example.test\SYSVOL\example.test\Policies\'+Guid;
  SetLength(T.ObjectGuid,16); T.ObjectGuid[0]:=1; T.Session:=Token;
  Ini:=Bytes('[General]'#13#10'Version=1'#13#10);
  OldUser.Exists:=True; OldUser.Data:=Header; NewUser:=OldUser;
  OldMachine.Exists:=True; OldMachine.Data:=Header; NewMachine:=OldMachine;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldUser,NewUser,OldMachine,NewMachine,P)=gopOk);
  SD.FromText('O:SYG:SYD:(A;;GA;;;SY)'); RawSD:=SD.ToBinary;
  E:=Default(TGpoLdapEvidence); E.Target:=T; E.Version:=1; E.USNChanged:=4;
  E.SecurityStatus:=gseUnverified; E.SecurityDescriptor:=Bytes(RawSD);
  F:=Default(TGpoObservedFiles); F.Captured:=True; F.Target:=T;
  for A:=Low(TGpoFile) to High(TGpoFile) do
  begin
    F.Items[A].Attempted:=True; F.Items[A].Status:=grsOk; F.Items[A].Observation:=gfoPresent;
    F.Items[A].Metadata.Available:=True; F.Items[A].Metadata.Kind:=gekFile; F.Items[A].Metadata.FileIndexLow:=Ord(A)+1;
    F.Items[A].Metadata.SecurityDescriptor:=Bytes(RawSD);
  end;
  F.Items[gfGptIni].Data:=Copy(Ini); F.Items[gfUserRegistry].Data:=Header; F.Items[gfMachineRegistry].Data:=Header;
  Check(TGpoObservedDraft.Bind(E,F,Draft)=gprEvidenceIncomplete);
  if not Assigned(Draft) then begin Check(False,'Expected target-bound draft'); Exit; end;
  try
    Check(Draft.GetBaseline(SnapshotUser,SnapshotMachine));
    Check(SnapshotUser.Exists and SnapshotMachine.Exists);
    Check(Draft.MatchesObjectGuid(T.ObjectGuid));
    Other:=E; Other.Target.ObjectGuid:=Copy(T.ObjectGuid); Other.Target.ObjectGuid[0]:=2;
    Check(not Draft.MatchesObjectGuid(Other.Target.ObjectGuid));
    SnapshotUser.Data[0]:=0;
    Check(Draft.GetBaseline(SnapshotUser,SnapshotMachine)); Check(SnapshotUser.Data[0]<>0);
    Check(Draft.BuildPlan(E,F,NewUser,NewMachine,Replanned)=gprEvidenceIncomplete);
    Check((Replanned.UserAction=gpaNone) and (Replanned.MachineAction=gpaNone));
    NewUser.Data:=RecordBytes('K','V',3,[1]);
    Check(Draft.BuildPlan(E,F,NewUser,NewMachine,Replanned)=gprEvidenceIncomplete);
    Check((Replanned.UserAction=gpaReplace) and (Replanned.MachineAction=gpaNone));
    Check(Draft.BindPlan(E,F,NewUser,NewMachine,B)=gprEvidenceIncomplete);
    Check(Assigned(B));
    if Assigned(B) then
    begin
      NewUser.Data[0]:=0;
      Check(B.CompareWithFiles(E,F)=gprEvidenceIncomplete,'Bound candidate must own its data');
      Other:=E; Other.Target.DN:='CN=other,DC=example,DC=test';
      Changed:=F; Changed.Target:=Other.Target;
      Check(B.CompareWithFiles(Other,Changed)=gprTargetMismatch,'Bound candidate cannot follow another target');
      B.Free;
    end;
    NewUser.Data:=RecordBytes('K','V',3,[1]);
    Check(GpoBuildObservedDraftPlan(nil,T.DN,Guid,Draft,NewUser,NewMachine,Replanned)=gprSessionInvalid);
    Check(Length(Replanned.GptIni)=0);
    NewUser.Data:=Bytes('broken');
    Check(Draft.BuildPlan(E,F,NewUser,NewMachine,Replanned)=gprInvalid);
    Check(Length(Replanned.GptIni)=0);
    NewUser.Data:=RecordBytes('K','V',3,[1]);
    Changed:=F; Changed.Target.DC:='dc2.example.test';
    Check(Draft.BuildPlan(E,Changed,NewUser,NewMachine,Replanned)=gprTargetMismatch);
    Check(Length(Replanned.GptIni)=0);
    Other:=E; Inc(Other.USNChanged);
    Check(Draft.BuildPlan(Other,F,NewUser,NewMachine,Replanned)=gprConflict);
    Changed:=F; Changed.Items[gfUserRegistry].Data:=Copy(F.Items[gfUserRegistry].Data);
    F.Items[gfUserRegistry].Data:=Copy(F.Items[gfUserRegistry].Data); F.Items[gfUserRegistry].Data[0]:=0;
    Check(Draft.BuildPlan(E,Changed,NewUser,NewMachine,Replanned)=gprEvidenceIncomplete,'Draft owns original baseline');
    F.Items[gfUserRegistry].Data:=Copy(Changed.Items[gfUserRegistry].Data);
    Token.Invalidate;
    Check(Draft.BuildPlan(E,F,NewUser,NewMachine,Replanned)=gprSessionInvalid);
    Check(not Draft.MatchesObjectGuid(T.ObjectGuid));
    Check(Draft.BindPlan(E,F,NewUser,NewMachine,B)=gprSessionInvalid); Check(not Assigned(B));
    Check(not Draft.GetBaseline(SnapshotUser,SnapshotMachine)); Check(Length(SnapshotUser.Data)=0);
  finally Draft.Free; end;
  TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; Token:=TokenObj; T.Session:=Token; E.Target:=T; F.Target:=T;
  NewUser:=OldUser;
  Check(TGpoBoundPlan.BindWithFiles(E,P,F,B)=gprEvidenceIncomplete);
  if not Assigned(B) then begin Check(False,'Expected bound plan'); Exit; end;
  try
    Check(B.CompareWithFiles(E,F)=gprEvidenceIncomplete);
    Changed:=F; Changed.Items[gfUserRegistry].Metadata.FileIndexLow:=99;
    Check(B.CompareWithFiles(E,Changed)=gprConflict);
    Changed:=F; Changed.Items[gfMachineRegistry].Metadata.SecurityDescriptor:=Copy(F.Items[gfMachineRegistry].Metadata.SecurityDescriptor);
    Changed.Items[gfMachineRegistry].Metadata.SecurityDescriptor[0]:=0;
    Check(B.CompareWithFiles(E,Changed)=gprReadUnavailable);
    Changed:=F; Changed.Items[gfUserRegistry].Metadata.SecurityDescriptor:=Copy(F.Items[gfUserRegistry].Metadata.SecurityDescriptor);
    F.Items[gfUserRegistry].Metadata.SecurityDescriptor[0]:=0;
    Check(B.CompareWithFiles(E,Changed)=gprEvidenceIncomplete,'Bound metadata must be independently owned');
    F.Items[gfUserRegistry].Metadata.SecurityDescriptor:=Copy(Changed.Items[gfUserRegistry].Metadata.SecurityDescriptor);
    Changed:=F; Changed.Items[gfUserRegistry].Status:=grsAccessDenied;
    Check(B.CompareWithFiles(E,Changed)=gprReadUnavailable);
    Changed:=F; Changed.Items[gfUserRegistry].Attempted:=False;
    Check(B.CompareWithFiles(E,Changed)=gprReadUnavailable);
    Changed:=F; Changed.Target.DC:='dc2.example.test'; Check(B.CompareWithFiles(E,Changed)=gprTargetMismatch);
    Other:=E; Inc(Other.USNChanged); Check(B.CompareWithFiles(Other,F)=gprConflict);
    Changed:=F; Changed.Items[gfUserRegistry].Data:=Bytes('bad');
    Check(B.CompareWithFiles(E,Changed)=gprInvalid);
    Changed:=F; Changed.Items[gfUserRegistry].Data:=RecordBytes('K','V',3,[1]);
    Check(B.CompareWithFiles(E,Changed)=gprConflict);
    Changed:=F; Changed.Items[gfUserRegistry].Observation:=gfoLeafAbsent; Changed.Items[gfUserRegistry].Status:=grsMissing;
    Check(B.CompareWithFiles(E,Changed)=gprReadUnavailable);
    Token.Invalidate; Check(B.CompareWithFiles(E,F)=gprSessionInvalid);
  finally B.Free; end;
  TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; Token:=TokenObj; T.Session:=Token; E.Target:=T; F.Target:=T;
  Changed:=F; Changed.Items[gfUserRegistry].Metadata.Available:=False;
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprReadUnavailable); Check(not Assigned(B));
  Changed:=F; Changed.Items[gfUserRegistry].Metadata.SecurityDescriptor:=Bytes(#0);
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprReadUnavailable,'Reject malformed file SD at binding');
  Check(not Assigned(B)); if Assigned(B) then B.Free;
  OldUser:=Default(TGpoPolicyImage); NewUser.Exists:=True; NewUser.Data:=Header;
  OldMachine.Exists:=True; OldMachine.Data:=Header; NewMachine:=Default(TGpoPolicyImage);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldUser,NewUser,OldMachine,NewMachine,P)=gopOk);
  Check((P.UserAction=gpaCreate) and (P.MachineAction=gpaDelete));
  Changed:=F; Changed.Items[gfUserRegistry].Status:=grsMissing; Changed.Items[gfUserRegistry].Observation:=gfoLeafAbsent;
  Changed.Items[gfUserRegistry].Data:=nil; Changed.Items[gfUserRegistry].Metadata:=Default(TGpoFileEvidence);
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprReadUnavailable); Check(not Assigned(B));
  Changed.Items[gfUserRegistry].Metadata:=F.Items[gfUserRegistry].Metadata;
  Changed.Items[gfUserRegistry].Metadata.Kind:=gekParent; Changed.Items[gfUserRegistry].Metadata.Attributes:=$10;
  Changed.Items[gfUserRegistry].Metadata.Attributes:=$410;
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprReadUnavailable); Check(not Assigned(B));
  Changed.Items[gfUserRegistry].Metadata.Attributes:=$10;
  Check(TGpoObservedDraft.Bind(E,Changed,Draft)=gprEvidenceIncomplete);
  if Assigned(Draft) then
  begin
    Check(Draft.BuildPlan(E,Changed,NewUser,NewMachine,Replanned)=gprEvidenceIncomplete);
    Check((Replanned.UserAction=gpaCreate) and (Replanned.MachineAction=gpaDelete));
    Inc(Changed.Items[gfUserRegistry].Metadata.FileIndexLow);
    Check(Draft.BuildPlan(E,Changed,NewUser,NewMachine,Replanned)=gprConflict);
    Dec(Changed.Items[gfUserRegistry].Metadata.FileIndexLow); Draft.Free;
  end;
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprEvidenceIncomplete);
  if Assigned(B) then
  begin
    Check(B.CompareWithFiles(E,Changed)=gprEvidenceIncomplete);
    Inc(Changed.Items[gfUserRegistry].Metadata.FileIndexLow);
    Check(B.CompareWithFiles(E,Changed)=gprConflict); Dec(Changed.Items[gfUserRegistry].Metadata.FileIndexLow);
    B.Free;
  end;
  NewUser:=OldUser; NewMachine:=OldMachine;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldUser,NewUser,OldMachine,NewMachine,P)=gopOk);
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprEvidenceIncomplete);
  if Assigned(B) then begin Check(B.CompareWithFiles(E,Changed)=gprEvidenceIncomplete); B.Free; end;
  OldUser.Exists:=True; OldUser.Data:=Header; NewUser:=Default(TGpoPolicyImage);
  OldMachine:=Default(TGpoPolicyImage); NewMachine.Exists:=True; NewMachine.Data:=Header;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,OldUser,NewUser,OldMachine,NewMachine,P)=gopOk);
  Check((P.UserAction=gpaDelete) and (P.MachineAction=gpaCreate));
  Changed:=F; Changed.Items[gfMachineRegistry].Status:=grsMissing; Changed.Items[gfMachineRegistry].Observation:=gfoLeafAbsent;
  Changed.Items[gfMachineRegistry].Data:=nil; Changed.Items[gfMachineRegistry].Metadata:=Default(TGpoFileEvidence);
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprReadUnavailable); Check(not Assigned(B));
  Changed.Items[gfMachineRegistry].Metadata:=F.Items[gfMachineRegistry].Metadata;
  Changed.Items[gfMachineRegistry].Metadata.Kind:=gekParent; Changed.Items[gfMachineRegistry].Metadata.Attributes:=$10;
  Check(TGpoBoundPlan.BindWithFiles(E,P,Changed,B)=gprEvidenceIncomplete);
  if Assigned(B) then begin Check(B.CompareWithFiles(E,Changed)=gprEvidenceIncomplete); B.Free; end;
  Check(GpoBeginReadOnlyPreflight(nil,T.DN,Guid,P,B)=gprSessionInvalid); Check(not Assigned(B));
  Check(GpoCheckReadOnlyPreflight(nil,T.DN,Guid,nil)=gprInvalid);
  Check(GpoCaptureObservedDraft(nil,T.DN,Guid,Draft)=gprSessionInvalid); Check(not Assigned(Draft));
  Check(GpoBuildObservedDraftPlan(nil,T.DN,Guid,nil,NewUser,NewMachine,Replanned)=gprInvalid);
  Check(GpoBindObservedDraftPlan(nil,T.DN,Guid,nil,NewUser,NewMachine,B)=gprInvalid); Check(not Assigned(B));
end;
procedure TUnitTestGpoReadOnly.LdapEvidenceParsing;
const Guid='{12345678-1234-1234-1234-123456789ABC}'; DN='CN='+Guid+',CN=Policies,CN=System,DC=example,DC=test';
var Entry:TLdapResult; E:TGpoLdapEvidence; SD:mormot.core.os.security.TSecurityDescriptor; RawSD:RawByteString;
begin
  Check(GpoCaptureLdapEvidence(nil,DN,Guid,E)=gprSessionInvalid);
  Check(GpoParseLdapGpc(nil,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
  Entry:=TLdapResult.Create;
  try
    Entry.ObjectName:=DN; Entry.Attributes.Add('name',Guid);
    Entry.Attributes.Add('objectGUID',#1+StringOfChar(#0,15));
    Entry.Attributes.Add('gPCFileSysPath','\\example.test\SYSVOL\example.test\Policies\'+Guid);
    Entry.Attributes.Add('versionNumber','-2147483648'); Entry.Attributes.Add('flags','0');
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
    Entry.Attributes.Add('uSNChanged','17');
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
    SD.FromText('O:SYG:SYD:(A;;GA;;;SY)'); RawSD:=SD.ToBinary;
    Entry.Attributes.Add('nTSecurityDescriptor',RawSD);
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprEvidenceIncomplete);
    Check((E.Version=$80000000) and (E.USNChanged=17) and (Length(E.Target.ObjectGuid)=16));
    Check((Length(E.SecurityDescriptor)=Length(RawSD)) and (E.Target.DC='dc.example.test'));
    Check(not Assigned(E.Target.Session),'Parsed facts do not authenticate LDAP origin');
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,'{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}',E)=gprTargetMismatch);
    Entry.Attributes.Add('objectGUID',StringOfChar(#0,16),aoReplaceValue);
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
    Entry.Attributes.Add('objectGUID',#1+StringOfChar(#0,15),aoReplaceValue);
    Entry.Attributes.Add('uSNChanged','-1',aoReplaceValue);
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
    Check((Length(E.Target.ObjectGuid)=0) and (Length(E.SecurityDescriptor)=0));
    Entry.Attributes.Add('uSNChanged','17',aoReplaceValue);
    Entry.Attributes.Add('nTSecurityDescriptor','invalid',aoReplaceValue);
    Check(GpoParseLdapGpc(Entry,'example.test','dc.example.test',DN,Guid,E)=gprReadUnavailable);
  finally Entry.Free; end;
end;
procedure TUnitTestGpoReadOnly.BoundPlanComparison;
const Guid='{12345678-1234-1234-1234-123456789ABC}';
var T,Other:TGpoPreflightTarget; Token,OtherToken:ILdapSessionToken; TokenObj:TPreflightToken; UOld,UNew,MOld,MNew:TGpoPolicyImage;
  P:TGpoOfflinePlan; Bound,B2:TGpoBoundPlan; Ini:TBytes; R:TGpoPreflightResult; Files:TGpoCapturedFiles;
  E,Changed:TGpoLdapEvidence; SD:mormot.core.os.security.TSecurityDescriptor; RawSD:RawByteString;
  function CompareCurrent:TGpoPreflightResult;
  begin Result:=Bound.Compare(T,grsOk,1,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data); end;
begin
  TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; Token:=TokenObj;
  T:=Default(TGpoPreflightTarget); T.Domain:='example.test'; T.DC:='dc.example.test'; T.DN:='CN=policy,DC=example,DC=test';
  T.Guid:=Guid; T.FileSysPath:='\\example.test\SYSVOL\example.test\Policies\'+Guid;
  SetLength(T.ObjectGuid,16); T.ObjectGuid[0]:=7; T.Session:=Token;
  Ini:=Bytes('[General]'#13#10'Version=1'#13#10);
  UOld:=Default(TGpoPolicyImage); UNew.Exists:=True; UNew.Data:=Header;
  MOld.Exists:=True; MOld.Data:=Header; MNew:=Default(TGpoPolicyImage);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,UOld,UNew,MOld,MNew,P)=gopOk);
  Check((P.UserAction=gpaCreate) and (P.MachineAction=gpaDelete));
  SD.FromText('O:SYG:SYD:(A;;GA;;;SY)'); RawSD:=SD.ToBinary;
  E:=Default(TGpoLdapEvidence); E.Target:=T; E.Version:=1; E.USNChanged:=17; E.SecurityDescriptor:=Bytes(RawSD); E.SecurityStatus:=gseUnverified;
  Check(TGpoBoundPlan.BindEvidence(E,P,B2)=gprEvidenceIncomplete);
  if Assigned(B2) then
  try
    Check(B2.CompareEvidence(E,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprEvidenceIncomplete);
    Changed:=E; Inc(Changed.USNChanged);
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprConflict);
    Changed:=E; Changed.SecurityDescriptor:=nil;
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprReadUnavailable);
    Changed:=E; Changed.SecurityStatus:=gseUnavailable;
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprReadUnavailable);
    Changed:=E; Changed.Flags:=1;
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprConflict);
    Changed:=E; E.SecurityDescriptor[0]:=0;
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprReadUnavailable);
    Changed.SecurityDescriptor:=Bytes(RawSD);
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprEvidenceIncomplete);
    SD.FromText('O:SYG:SYD:(A;;GR;;;SY)'); Changed.SecurityDescriptor:=Bytes(SD.ToBinary);
    Check(B2.CompareEvidence(Changed,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprConflict);
  finally B2.Free; end;
  R:=TGpoBoundPlan.Bind(T,P,Bound); Check((R=gprEvidenceIncomplete) and Assigned(Bound));
  if not Assigned(Bound) then Exit;
  try
    Check(CompareCurrent=gprEvidenceIncomplete);
    P.Baseline.GptIni[0]:=0; P.UserPolicy[0]:=0;
    Check(CompareCurrent=gprEvidenceIncomplete,'Binding must own independent plan bytes');
    Other:=T; Other.DC:='dc2.example.test';
    Check(Bound.Compare(Other,grsOk,1,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprTargetMismatch);
    Other:=T; Other.FileSysPath:='\\untrusted\share';
    Check(GpoCapturePreflightFiles(Other,Files)=gprInvalid);
    Check(Files[gfGptIni].Observation=gfoUnavailable);
    Other:=T; Other.ObjectGuid:=Copy(T.ObjectGuid); Other.ObjectGuid[0]:=8;
    Check(Bound.Compare(Other,grsOk,1,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprTargetMismatch);
    Check(Bound.Compare(T,grsOk,1,grsOk,Ini,grsMissing,gfoUnavailable,nil,grsOk,gfoPresent,MOld.Data)=gprReadUnavailable);
    Check(Bound.Compare(T,grsAccessDenied,1,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprReadUnavailable);
    Check(Bound.Compare(T,grsOk,2,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprConflict);
    TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; OtherToken:=TokenObj; Other:=T; Other.Session:=OtherToken;
    Check(Bound.Compare(Other,grsOk,1,grsOk,Ini,grsMissing,gfoLeafAbsent,nil,grsOk,gfoPresent,MOld.Data)=gprSessionInvalid);
    Token.Invalidate; Check(CompareCurrent=gprSessionInvalid);
    Check(GpoCapturePreflightFiles(T,Files)=gprSessionInvalid);
    Check(Files[gfMachineRegistry].Observation=gfoUnavailable);
  finally Bound.Free; end;
  TokenObj:=TPreflightToken.Create; TokenObj.Valid:=True; Token:=TokenObj; T.Session:=Token;
  UNew:=UOld; MNew:=MOld;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,UOld,UNew,MOld,MNew,P)=gopOk);
  Check((P.UserAction=gpaNone) and (P.MachineAction=gpaNone));
  R:=TGpoBoundPlan.Bind(T,P,Bound); Check((R=gprEvidenceIncomplete) and Assigned(Bound));
  if Assigned(Bound) then begin Check(CompareCurrent=gprEvidenceIncomplete); Bound.Free; end;
  UOld.Exists:=True; UOld.Data:=Header; UNew:=Default(TGpoPolicyImage);
  MOld:=Default(TGpoPolicyImage); MNew.Exists:=True; MNew.Data:=Header;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,UOld,UNew,MOld,MNew,P)=gopOk);
  Check((P.UserAction=gpaDelete) and (P.MachineAction=gpaCreate));
  Check(TGpoBoundPlan.Bind(T,P,Bound)=gprEvidenceIncomplete);
  if Assigned(Bound) then
  begin
    Check(Bound.Compare(T,grsOk,1,grsOk,Ini,grsOk,gfoPresent,UOld.Data,grsMissing,gfoLeafAbsent,nil)=gprEvidenceIncomplete);
    Bound.Free;
  end;
  P.Version.Version:=99; Check(TGpoBoundPlan.Bind(T,P,Bound)=gprInvalid); Check(not Assigned(Bound));
end;
procedure TUnitTestGpoReadOnly.OfflineChangePlan;
var Empty, ChangedUser, ChangedMachine, Bad, Ini, OriginalIni:TBytes;
  P:TGpoOfflinePlan; V:Cardinal;
  procedure EmptyResult;
  begin
    Check(not P.UserChanged and not P.MachineChanged);
    Check((Length(P.GptIni)=0) and (Length(P.UserPolicy)=0) and (Length(P.MachinePolicy)=0));
    Check((P.Version.Version=0) and (P.Version.LdapValue='') and (P.Version.GptValue=''));
    Check((Length(P.Baseline.GptIni)=0) and (Length(P.Baseline.UserPolicy.Data)=0) and
      (Length(P.Baseline.MachinePolicy.Data)=0));
  end;
begin
  Empty:=Header; ChangedUser:=RecordBytes('UserKey','V',3,[1]);
  ChangedMachine:=RecordBytes('MachineKey','V',3,[2]); Bad:=Bytes('bad');
  Ini:=Bytes('[General]'#13#10'Version=0001'#13#10'Other=untouched'); OriginalIni:=Copy(Ini);
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Empty,Empty,P)=gopOk);
  Check(not P.UserChanged and not P.MachineChanged); Check(P.Version.Version=1);
  Check((Length(P.GptIni)=Length(Ini)) and CompareMem(@P.GptIni[0],@Ini[0],Length(Ini)));
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,ChangedUser,Empty,Empty,P)=gopOk);
  Check(P.UserChanged and not P.MachineChanged); Check(P.Version.Version=$00010001);
  Check(ParseGptIni(P.GptIni,V)=grsOk); Check(V=P.Version.Version);
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Empty,ChangedMachine,P)=gopOk);
  Check(not P.UserChanged and P.MachineChanged); Check(P.Version.Version=2);
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,ChangedUser,Empty,ChangedMachine,P)=gopOk);
  Check(P.UserChanged and P.MachineChanged); Check(P.Version.Version=$00010002);
  Check(ParseGptIni(P.GptIni,V)=grsOk); Check(V=P.Version.Version);
  Check(P.Version.LdapValue='65538'); Check(P.Version.GptValue='65538');
  ChangedUser[0]:=0; ChangedMachine[0]:=0; Ini[0]:=0;
  Check(P.UserPolicy[0]=Ord('P')); Check(P.MachinePolicy[0]=Ord('P')); Check(P.GptIni[0]=Ord('['));
  ChangedUser:=RecordBytes('UserKey','V',3,[1]); ChangedMachine:=RecordBytes('MachineKey','V',3,[2]);
  Ini:=Copy(OriginalIni); P.UserPolicy[0]:=0; P.MachinePolicy[0]:=0; P.GptIni[0]:=0;
  Check(ChangedUser[0]=Ord('P')); Check(ChangedMachine[0]=Ord('P')); Check(Ini[0]=Ord('['));
  Check(GpoBuildOfflinePlan(1,1,Ini,Bad,ChangedUser,Empty,Empty,P)=gopInvalidPolicy); EmptyResult;
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Bad,Empty,Empty,P)=gopInvalidPolicy); EmptyResult;
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Bad,ChangedMachine,P)=gopInvalidPolicy); EmptyResult;
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Empty,Bad,P)=gopInvalidPolicy); EmptyResult;
  Check(GpoBuildOfflinePlan(1,2,Ini,Empty,Empty,Empty,Empty,P)=gopBaselineMismatch); EmptyResult;
  Check(GpoBuildOfflinePlan(2,2,Ini,Empty,ChangedUser,Empty,Empty,P)=gopBaselineMismatch); EmptyResult;
  Ini:=Bytes('[General]'#10'Version=1'#10'[general]'#10'X=1');
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Empty,Empty,P)=gopInvalidIni); EmptyResult;
  Ini:=Bytes('[General]'#10'Version=1'#10'X='#255);
  Check(GpoBuildOfflinePlan(1,1,Ini,Empty,Empty,Empty,Empty,P)=gopUnsupportedIni); EmptyResult;
end;
procedure TUnitTestGpoReadOnly.OfflinePlanPresence;
var Missing, Empty, User, Machine, Invalid, BadMissing:TGpoPolicyImage;
  Ini:TBytes; P:TGpoOfflinePlan; V:Cardinal;
  procedure CheckVersion(Expected:Cardinal);
  begin Check(P.Version.Version=Expected); Check(ParseGptIni(P.GptIni,V)=grsOk); Check(V=Expected); end;
  procedure CheckFailure;
  begin
    Check(not P.UserExists and not P.MachineExists and not P.UserChanged and not P.MachineChanged);
    Check((P.UserAction=gpaNone) and (P.MachineAction=gpaNone));
    Check((Length(P.UserPolicy)=0) and (Length(P.MachinePolicy)=0) and (Length(P.GptIni)=0));
  end;
begin
  Missing:=Default(TGpoPolicyImage); Empty.Exists:=True; Empty.Data:=Header;
  User.Exists:=True; User.Data:=RecordBytes('User','V',3,[1]);
  Machine.Exists:=True; Machine.Data:=RecordBytes('Machine','V',3,[2]);
  Invalid.Exists:=True; Invalid.Data:=nil;
  BadMissing.Exists:=False; BadMissing.Data:=Header;
  Ini:=Bytes('[General]'#10'Version=1');
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Missing,Missing,Missing,P)=gopOk);
  CheckVersion(1); Check((P.UserAction=gpaNone) and (P.MachineAction=gpaNone));
  Check(not P.UserExists and not P.MachineExists);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Empty,Missing,Missing,P)=gopOk);
  CheckVersion($10001); Check(P.UserExists and (P.UserAction=gpaCreate)); Check(Length(P.UserPolicy)=8);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,User,Missing,Missing,P)=gopOk);
  CheckVersion($10001); Check(P.UserAction=gpaCreate);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Empty,Missing,Missing,Missing,P)=gopOk);
  CheckVersion($10001); Check(not P.UserExists and (P.UserAction=gpaDelete)); Check(Length(P.UserPolicy)=0);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Empty,User,Missing,Missing,P)=gopOk);
  CheckVersion($10001); Check(P.UserAction=gpaReplace);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,User,Machine,Missing,P)=gopOk);
  CheckVersion($10002); Check((P.UserAction=gpaCreate) and (P.MachineAction=gpaDelete));
  Check(P.UserExists and not P.MachineExists); Check(Length(P.MachinePolicy)=0);
  User.Data[0]:=0; Check(P.UserPolicy[0]=Ord('P'));
  User.Data:=RecordBytes('User','V',3,[1]); P.UserPolicy[0]:=0; Check(User.Data[0]=Ord('P'));
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Invalid,Missing,Missing,Missing,P)=gopInvalidPolicy); CheckFailure;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Invalid,Missing,Missing,P)=gopInvalidPolicy); CheckFailure;
  Invalid.Data:=Bytes('corrupt');
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Missing,Invalid,Missing,P)=gopInvalidPolicy); CheckFailure;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Missing,Missing,Invalid,P)=gopInvalidPolicy); CheckFailure;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,BadMissing,Missing,Missing,Missing,P)=gopInvalidPolicy); CheckFailure;
  Check(GpoBuildOfflinePlanWithPresence(1,2,Ini,Missing,Empty,Missing,Missing,P)=gopBaselineMismatch); CheckFailure;
  Check(GpoBuildOfflinePlanWithPresence(2,2,Ini,Missing,Empty,Missing,Missing,P)=gopBaselineMismatch); CheckFailure;
end;
procedure TUnitTestGpoReadOnly.OfflineBaselineChecks;
var User,Machine,Missing,ChangedUser,ChangedMachine,Invalid:TGpoPolicyImage;
  Ini, ChangedIni:TBytes; P:TGpoOfflinePlan;
begin
  User.Exists:=True; User.Data:=RecordBytes('User','V',3,[1]);
  Machine.Exists:=True; Machine.Data:=RecordBytes('Machine','V',3,[2]);
  Missing:=Default(TGpoPolicyImage); Invalid.Exists:=True; Invalid.Data:=nil;
  Ini:=Bytes('[General]'#10'Version=1'#10'Other=abc');
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,User,User,Machine,Machine,P)=gopOk);
  Check(not P.UserChanged and not P.MachineChanged);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,Machine)=gbcMatch);
  Check(GpoCheckOfflineBaseline(P.Baseline,2,Ini,User,Machine)=gbcConflict);
  ChangedUser.Exists:=True; ChangedUser.Data:=RecordBytes('User','V',3,[3]);
  ChangedMachine.Exists:=True; ChangedMachine.Data:=RecordBytes('Machine','V',3,[4]);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,ChangedUser,Machine)=gbcConflict);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,ChangedMachine)=gbcConflict);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,ChangedUser,ChangedMachine)=gbcConflict);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,Missing,Machine)=gbcConflict);
  ChangedIni:=Bytes('[General]'#10'Version=1'#10'Other=xyz');
  Check(GpoCheckOfflineBaseline(P.Baseline,1,ChangedIni,User,Machine)=gbcConflict);
  ChangedIni:=Bytes('[General]'#10'Version=2'#10'Other=abc');
  Check(GpoCheckOfflineBaseline(P.Baseline,1,ChangedIni,User,Machine)=gbcConflict);
  ChangedIni:=Bytes('[General]'#10'Version=1'#10'[general]'#10'X=1');
  Check(GpoCheckOfflineBaseline(P.Baseline,1,ChangedIni,User,Machine)=gbcInvalid);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,Invalid,Machine)=gbcInvalid);
  User.Data[0]:=0; Machine.Data[0]:=0; Ini[0]:=0;
  Check(P.Baseline.UserPolicy.Data[0]=Ord('P')); Check(P.Baseline.MachinePolicy.Data[0]=Ord('P'));
  Check(P.Baseline.GptIni[0]=Ord('['));
  User.Data:=RecordBytes('User','V',3,[1]); Machine.Data:=RecordBytes('Machine','V',3,[2]);
  Ini:=Bytes('[General]'#10'Version=1'#10'Other=abc');
  P.Baseline.UserPolicy.Data[0]:=0; P.Baseline.MachinePolicy.Data[0]:=0; P.Baseline.GptIni[0]:=0;
  Check(User.Data[0]=Ord('P')); Check(Machine.Data[0]=Ord('P')); Check(Ini[0]=Ord('['));
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,Machine)=gbcInvalid);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Missing,Missing,Missing,P)=gopOk);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,Missing,Missing)=gbcMatch);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,Missing)=gbcConflict);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,User,ChangedUser,Machine,Missing,P)=gopOk);
  Check(P.UserChanged and P.MachineChanged);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,Machine)=gbcMatch);
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,ChangedUser,Missing)=gbcConflict);
  Check(P.UserChanged and P.MachineChanged and (P.Version.Version=$10002));
end;
procedure TUnitTestGpoReadOnly.OfflinePlanIntegrity;
var User,Changed,Missing:TGpoPolicyImage; Ini:TBytes; P:TGpoOfflinePlan;
  procedure Build;
  begin Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,User,Changed,Missing,Missing,P)=gopOk); end;
  procedure Reject;
  begin Check(GpoCheckOfflinePlan(P,1,Ini,User,Missing)=gbcInvalid); end;
begin
  P:=Default(TGpoOfflinePlan);
  User.Exists:=True; User.Data:=RecordBytes('User','V',3,[1]);
  Changed.Exists:=True; Changed.Data:=RecordBytes('User','V',3,[2]);
  Missing:=Default(TGpoPolicyImage); Ini:=Bytes('[General]'#10'Version=1');
  Build; Check(GpoCheckOfflinePlan(P,1,Ini,User,Missing)=gbcMatch);
  Check(GpoCheckOfflinePlan(P,2,Ini,User,Missing)=gbcConflict);
  P.UserChanged:=False;
  Check(GpoCheckOfflineBaseline(P.Baseline,1,Ini,User,Missing)=gbcMatch); Reject;
  Build; P.MachineChanged:=True; Reject;
  Build; P.UserAction:=gpaDelete; Reject;
  Build; P.MachineAction:=gpaCreate; Reject;
  Build; P.UserExists:=False; Reject;
  Build; P.MachineExists:=True; Reject;
  Build; Inc(P.Version.Version); Reject;
  Build; P.Version.LdapValue:='0'; Reject;
  Build; P.Version.GptValue:='0'; Reject;
  Build; P.GptIni:=Bytes('[General]'#10'Version=1'); Reject;
  Build; P.UserPolicy:=Copy(P.UserPolicy); P.UserPolicy[0]:=0; Reject;
  Build; P.MachinePolicy:=Header; Reject;
  Build; P.Baseline.GpcVersion:=2; Reject;
  Build; P.Baseline.GptIni:=Bytes('[General]'#10'Version=2'); Reject;
  Build; P.UserPolicy:=RecordBytes('User','V',3,[9]);
  Check(GpoCheckOfflinePlan(P,1,Ini,User,Missing)=gbcMatch,
    'A coherent replacement cannot be authenticated by structural validation');
  P:=Default(TGpoOfflinePlan); Reject;
  Check(GpoBuildOfflinePlanWithPresence(1,1,Ini,Missing,Missing,Missing,Missing,P)=gopOk);
  Check(GpoCheckOfflinePlan(P,1,Ini,Missing,Missing)=gbcMatch);
end;
procedure TUnitTestGpoReadOnly.GptIniCandidate;
var Source, Candidate, Expected:TBytes; V:Cardinal; Plan:TGpoVersionPlan; I:Integer;
  Missing:TGpoPolicyImage; Offline:TGpoOfflinePlan;
  Original, Updated:RawByteString;
  procedure Reject(const Input:RawByteString; Status:TGptIniCandidateStatus);
  begin
    Candidate:=Bytes('stale'); Source:=Bytes(Input);
    Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=Status); Check(Length(Candidate)=0);
    Check((Length(Source)=Length(Input)) and ((Length(Input)=0) or CompareMem(@Source[0],@Input[1],Length(Input))));
  end;
begin
  Original:=#239#187#191';keep'#13#10'[Other]'#10'Data=unchanged'#13'[General]'#13#10' Version = 1  '#10'Extra=abc'#13#10;
  Updated:=#239#187#191';keep'#13#10'[Other]'#10'Data=unchanged'#13'[General]'#13#10' Version = 65537  '#10'Extra=abc'#13#10;
  Source:=Bytes(Original); Expected:=Bytes(Updated);
  Check(GpoPlanVersion(1,1,True,False,Plan));
  Check(GpoBuildGptIniCandidate(Source,1,Plan.Version,Candidate)=gicOk);
  Check((Length(Candidate)=Length(Expected)) and CompareMem(@Candidate[0],@Expected[0],Length(Expected)));
  Check(ParseGptIni(Candidate,V)=grsOk); Check(V=Plan.Version);
  Check(CompareMem(@Source[0],@Original[1],Length(Source)));
  Candidate:=Bytes('stale'); Check(GpoBuildGptIniCandidate(Source,2,3,Candidate)=gicBaselineMismatch);
  Check(Length(Candidate)=0);
  Source:=Bytes('[general]'#10'version=0001');
  Check(GpoBuildGptIniCandidate(Source,1,High(Cardinal),Candidate)=gicOk);
  Expected:=Bytes('[general]'#10'version=4294967295');
  Check((Length(Candidate)=Length(Expected)) and CompareMem(@Candidate[0],@Expected[0],Length(Expected)));
  Check(ParseGptIni(Candidate,V)=grsOk); Check(V=High(Cardinal));
  Reject('[General]'#10'Version=1'#10'version=1',gicInvalid);
  Reject('[General]'#10'Version=1'#10'[general]'#10'Other=x',gicInvalid);
  Reject('[Other]'#10'X=1'#10'x=2'#10'[General]'#10'Version=1',gicInvalid);
  Reject('[General]'#10'Version=1 ; comment',gicInvalid);
  Reject('[General]'#10'Version=4294967296',gicInvalid);
  Reject(#254#255#0#65,gicUnsupported);
  Reject(#255#254#0#0#65#0#0#0,gicUnsupported);
  Reject('[General]'#10'Version=1'#10'Other='#255,gicUnsupported);
  Original:='[General]'#13#10'Version=0'#13#10'displayName='#$d0#$c2#$bd#$a8#$d7#$e9#$b2#$df#$c2#$d4#$b6#$d4#$cf#$f3#13#10;
  Updated:='[General]'#13#10'Version=1'#13#10'displayName='#$d0#$c2#$bd#$a8#$d7#$e9#$b2#$df#$c2#$d4#$b6#$d4#$cf#$f3#13#10;
  Source:=Bytes(Original); Expected:=Bytes(Updated);
  Check(GpoBuildGptIniCandidate(Source,0,1,Candidate)=gicOk);
  Check((Length(Candidate)=Length(Expected)) and CompareMem(@Candidate[0],@Expected[0],Length(Expected)),'CP936 bytes must be preserved');
  Check(ParseGptIni(Candidate,V)=grsOk); Check(V=1);
  Missing:=Default(TGpoPolicyImage);
  Check(GpoBuildOfflinePlanWithPresence(0,0,Source,Missing,Missing,Missing,Missing,Offline)=gopOk);
  Check((Length(Offline.GptIni)=Length(Source)) and CompareMem(@Offline.GptIni[0],@Source[0],Length(Source)));
  Check(GpoCheckOfflinePlan(Offline,0,Source,Missing,Missing)=gbcMatch);
  Original:='[General]'#13#10'Version=1'#13#10'; price='#$80#13#10'Label='#$80#13#10;
  Updated:='[General]'#13#10'Version=2'#13#10'; price='#$80#13#10'Label='#$80#13#10;
  Source:=Bytes(Original); Expected:=Bytes(Updated);
  Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicOk);
  Check((Length(Candidate)=Length(Expected)) and CompareMem(@Candidate[0],@Expected[0],Length(Expected)),'CP936 euro bytes must be preserved');
  Check(CompareMem(@Source[0],@Original[1],Length(Source)));
  Reject('[General]'#10'Version=1'#10'key'#$80'=x',gicInvalid);
  Reject(#$ef#$bb#$bf'[General]'#10'Version=1'#10'X='#$80,gicUnsupported);
  Reject('[General]'#10'Version=1'#10'X='#$80#$81,gicUnsupported);
  Reject('[General]'#10'Version=1'#10'X='#$81#$7f,gicUnsupported);
  Reject('[General]'#10'Version=1'#10'X='#$81,gicUnsupported);
  Source:=nil; AddWord(Source,$feff); Original:='[General]'#13#10'Version=4294967295'#13#10'Other=x';
  for I:=1 to Length(Original) do AddWord(Source,Ord(Original[I]));
  Check(GpoBuildGptIniCandidate(Source,High(Cardinal),0,Candidate)=gicOk);
  Expected:=nil; AddWord(Expected,$feff); Updated:='[General]'#13#10'Version=0'#13#10'Other=x';
  for I:=1 to Length(Updated) do AddWord(Expected,Ord(Updated[I]));
  Check((Length(Candidate)=Length(Expected)) and CompareMem(@Candidate[0],@Expected[0],Length(Expected)));
  Check(ParseGptIni(Candidate,V)=grsOk); Check(V=0);
  SetLength(Source,Length(Source)+1); Candidate:=Bytes('stale');
  Check(GpoBuildGptIniCandidate(Source,High(Cardinal),0,Candidate)=gicInvalid); Check(Length(Candidate)=0);
  Original:='[General]'#10'Version=1'#10';';
  SetLength(Source,GpoMaxFileBytes); FillChar(Source[0],Length(Source),Ord('x'));
  Move(Original[1],Source[0],Length(Original)); Candidate:=Bytes('stale');
  Check(GpoBuildGptIniCandidate(Source,1,High(Cardinal),Candidate)=gicTooLarge);
  Check(Length(Candidate)=0);
end;
procedure TUnitTestGpoReadOnly.GptIniUnicodeCandidate;
const InvalidUtf8:array[0..7] of RawByteString=(#128,#192#128,#226#130,
  #237#160#128,#240#128#128#128,#244#144#128#128,#245#128#128#128,#226#40#161);
var Original,Updated,Text:RawByteString;
  Source,Candidate,Before:TBytes; I:Integer; V:Cardinal;
  Missing,NewUser:TGpoPolicyImage; Plan:TGpoOfflinePlan;
  function Utf16File(const Value:RawByteString):TBytes;
  var S:UnicodeString; K:Integer;
  begin
    Result:=nil; AddWord(Result,$feff); S:=UTF8Decode(Value);
    for K:=1 to Length(S) do AddWord(Result,Ord(S[K]));
  end;
  procedure Verify(const Input,Output:TBytes);
  begin
    Source:=Copy(Input); Before:=Copy(Source);
    Check(GpoBuildGptIniCandidate(Source,1,65537,Candidate)=gicOk);
    Check((Length(Candidate)=Length(Output)) and CompareMem(@Candidate[0],@Output[0],Length(Output)));
    Check((Length(Source)=Length(Before)) and CompareMem(@Source[0],@Before[0],Length(Before)));
    Check(ParseGptIni(Candidate,V)=grsOk); Check(V=65537);
    Candidate:=Bytes('stale');
    Check(GpoBuildGptIniCandidate(Source,2,3,Candidate)=gicBaselineMismatch); Check(Length(Candidate)=0);
  end;
begin
  Text:=#228#184#173#230#150#135#240#159#152#128;
  Original:=';'+Text+#13#10'[Other]'#10'Label='+Text+#13'[General]'#13#10'Version=1'#10'Extra='+Text;
  Updated:=';'+Text+#13#10'[Other]'#10'Label='+Text+#13'[General]'#13#10'Version=65537'#10'Extra='+Text;
  Verify(Bytes(Original),Bytes(Updated));
  Verify(Bytes(#239#187#191+Original),Bytes(#239#187#191+Updated));
  Verify(Utf16File(Original),Utf16File(Updated));
  Missing:=Default(TGpoPolicyImage); NewUser.Exists:=True; NewUser.Data:=Header;
  Source:=Utf16File(Original);
  Check(GpoBuildOfflinePlanWithPresence(1,1,Source,Missing,NewUser,Missing,Missing,Plan)=gopOk);
  Check(Plan.UserChanged and (Plan.Version.Version=65537));
  Check(ParseGptIni(Plan.GptIni,V)=grsOk); Check(V=65537);
  Check(GpoCheckOfflinePlan(Plan,1,Source,Missing,Missing)=gbcMatch);
  for I:=Low(InvalidUtf8) to High(InvalidUtf8) do
  begin
    Source:=Bytes(#$ef#$bb#$bf'[General]'#10'Version=1'#10'X='+InvalidUtf8[I]); Before:=Copy(Source);
    Candidate:=Bytes('stale');
    Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicUnsupported);
    Check(Length(Candidate)=0); Check(CompareMem(@Source[0],@Before[0],Length(Source)));
  end;
  Source:=Utf16File('[General]'#10'Version=1'#10'X='); AddWord(Source,$d800);
  Candidate:=Bytes('stale'); Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicInvalid);
  Check(Length(Candidate)=0);
  Source:=Utf16File('[General]'#10'Version=1'#10'X='); AddWord(Source,$dc00);
  Candidate:=Bytes('stale'); Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicInvalid);
  Check(Length(Candidate)=0);
  Source:=Bytes('[General]'#10'Version=1'#10'[general]'#10'X='+Text);
  Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicInvalid); Check(Length(Candidate)=0);
  Source:=Utf16File('[General]'#10'Version=1'#10+Text+'=1');
  Check(GpoBuildGptIniCandidate(Source,1,2,Candidate)=gicInvalid); Check(Length(Candidate)=0);
end;
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
function GpoTestCreateDirectoryLink(LinkName,TargetName:PWideChar; Flags:Cardinal):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateSymbolicLinkW';
procedure TUnitTestGpoReadOnly.GuardedFileObservation;
var G:TGuid; Dir,Root,FileName,LinkName:UnicodeString; B:TBytes; O:TGpoFileObservation; S:TFileStream; V:Byte; Meta,OtherMeta:TGpoFileEvidence;
begin
  Check(CreateGUID(G)=0); Dir:=UnicodeString(GetTempDir(False)+'openrsat-observe-'+GUIDToString(G));
  if not CreateDir(Dir) then begin Check(False,'Cannot create observation fixture'); Exit; end;
  Root:='\??\'+Dir; FileName:=Dir+'\fixture.pol';
  try
    Check(GpoTestReadGuardedObservation(Root,'fixture.pol',B,O)=grsMissing);
    Check(O=gfoLeafAbsent); Check(Length(B)=0);
    Check(GpoTestReadGuardedObservation(Root,'missing\fixture.pol',B,O)=grsMissing);
    Check(O=gfoUnavailable); Check(Length(B)=0);
    S:=TFileStream.Create(FileName,fmCreate);
    try V:=42; S.WriteBuffer(V,1); finally S.Free; end;
    Check(GpoTestReadGuardedObservation(Root,'fixture.pol',B,O)=grsOk);
    Check(O=gfoPresent); Check((Length(B)=1) and (B[0]=42));
    Check(GpoTestReadGuardedEvidence(Root,'fixture.pol',B,O,Meta)=grsOk);
    Check(O=gfoPresent); Check(Meta.Available); Check(Meta.Kind=gekFile); Check(Length(Meta.SecurityDescriptor)>0);
    Check((Meta.FileIndexHigh<>0) or (Meta.FileIndexLow<>0));
    OtherMeta:=Meta; OtherMeta.SecurityDescriptor:=Copy(Meta.SecurityDescriptor);
    Check(GpoCompareFileEvidence(Meta,OtherMeta)=gprEvidenceIncomplete);
    Inc(OtherMeta.FileIndexLow); Check(GpoCompareFileEvidence(Meta,OtherMeta)=gprConflict);
    OtherMeta:=Meta; OtherMeta.SecurityDescriptor:=Copy(Meta.SecurityDescriptor); OtherMeta.SecurityDescriptor[0]:=0;
    Check(GpoCompareFileEvidence(Meta,OtherMeta)=gprReadUnavailable);
    OtherMeta.Available:=False; Check(GpoCompareFileEvidence(Meta,OtherMeta)=gprReadUnavailable);
    S:=TFileStream.Create(FileName,fmOpenReadWrite or fmShareExclusive);
    try
      Check(GpoTestReadGuardedEvidence(Root,'fixture.pol',B,O,Meta)=grsIoError);
      Check((O=gfoUnavailable) and not Meta.Available and (Length(B)=0));
    finally S.Free; end;
    Check(GpoTestReadGuardedEvidence(Root,'absent.pol',B,O,Meta)=grsMissing);
    Check(O=gfoLeafAbsent); Check(Meta.Available); Check(Meta.Kind=gekParent); Check(Length(Meta.SecurityDescriptor)>0);
    Check(GpoTestReadGuardedEvidence(Root,'missing\absent.pol',B,O,Meta)=grsMissing);
    Check((O=gfoUnavailable) and not Meta.Available and (Length(Meta.SecurityDescriptor)=0));
    LinkName:=Dir+'\link';
    if GpoTestCreateDirectoryLink(PWideChar(LinkName),PWideChar(Dir),3) then
    try
      Check(GpoTestReadGuardedEvidence(Root,'link\absent.pol',B,O,Meta)=grsReparseBlocked);
      Check((O=gfoUnavailable) and not Meta.Available);
    finally Check(RemoveDir(LinkName)); end
    else WriteLn('SKIP: local directory symlink creation is unavailable');
    Check(GpoTestReadGuardedEvidence(Root,'..\fixture.pol',B,O,Meta)=grsInvalidPath);
    Check((O=gfoUnavailable) and not Meta.Available and (Length(B)=0));
    Check(GpoTestReadGuardedObservation(Root,'..\fixture.pol',B,O)=grsInvalidPath);
    Check(O=gfoUnavailable); Check(Length(B)=0);
  finally
    if FileExists(FileName) then Check(SysUtils.DeleteFile(FileName));
    Check(RemoveDir(Dir));
  end;
end;

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
