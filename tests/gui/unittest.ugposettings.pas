unit unittest.ugposettings;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses mormot.core.test;
type
  TUnitTestGpoSettings = class(TSynTestCase)
  published
    procedure ReadOnlyDisplayAndReset;
    procedure PagedRecordsAndReset;
    procedure CancelledJobsAndConcurrencyCap;
    procedure SessionChangesRejectDelayedJobs;
    procedure ClosingAndReopeningCancelsRead;
    procedure RevokedSessionStopsWorkerWithoutPoll;
    procedure FullRecordAndEmptyStatus;
    procedure TypedRecordDetails;
    procedure CombinedSnapshotStates;
    procedure CancelPollStates;
    procedure BaselineJobLifecycle;
    procedure DomainDraftJobLifecycle;
    procedure DiagnosticBackendLifecycle;
    procedure SelectedGpcIdentity;
    procedure BackgroundMetadataLifecycle;
    procedure HeaderUsesSystemColors;
    procedure GeneralPageRefreshPreservesProperties;
  end;
implementation
uses Classes, SyncObjs, SysUtils, ugpoformats, ugposysvol, ugpodiagnostic, ufrmpropertygposettings, ufrmpropertygeneralgpo, uproperty,
  mormot.net.ldap, mormot.net.sock
  {$IFDEF WINDOWS}, Windows, CommCtrl, Graphics, Forms{$ENDIF};
procedure TUnitTestGpoSettings.GeneralPageRefreshPreservesProperties;
var F:TFrmPropertyGeneralGPO; Host:TForm; A,B:TProperty; Attributes:TLdapAttributeList; H:PtrUInt;
begin
  Host:=TForm.CreateNew(nil); F:=TFrmPropertyGeneralGPO.Create(Host); F.Parent:=Host;
  A:=TProperty.Create; B:=TProperty.Create;
  try
    H:=F.Edit1.Handle; H:=F.Edit_Description.Handle; H:=F.ComboBox1.Handle;
    Attributes:=TLdapAttributeList.Create;
    try
      Attributes.Add('name','one'); Attributes.Add('displayName','First');
      Attributes.Add('description','First description'); Attributes.Add('flags','3'); A.Attributes:=Attributes;
      Attributes.Clear; Attributes.Add('name','two'); Attributes.Add('flags','8'); B.Attributes:=Attributes;
    finally Attributes.Free; end;
    F.Update(A); Check(not A.IsModified); Check(F.ComboBox1.ItemIndex=3);
    F.Update(B); Check(not B.IsModified,'Refreshing missing values must not stage changes');
    Check(F.Edit1.Text=''); Check(F.Edit_Description.Text='');
    Check(F.ComboBox1.ItemIndex=-1,'Unknown flags must not retain another GPO status');
    F.ComboBox1Change(F.ComboBox1); Check(not B.IsModified,'Invalid selection must not stage flags');
    F.Edit_Description.Text:='New description'; Check(B.IsModified('description'));
    Check(B.GetReadable('description')='New description'); Check(B.GetReadable('flags')='8');
    F.ComboBox1.ItemIndex:=2; F.ComboBox1Change(F.ComboBox1);
    Check(B.IsModified('flags')); Check(B.GetReadable('flags')='2');
    F.Update(B); Check(F.ComboBox1.ItemIndex=2); Check(F.Edit_Description.Text='New description');
    Check(B.IsModified('description') and B.IsModified('flags'));
    F.Update(nil); Check(F.Edit1.Text=''); Check(F.ComboBox1.ItemIndex=-1);
  finally B.Free; A.Free; Host.Free; end;
end;
procedure TUnitTestGpoSettings.TypedRecordDetails;
var P:TGpoRegistryPane; R:TGpoRegistryRecords; D:string; I:Integer;
  procedure Verify(Kind:Cardinal; const Bytes:array of Byte; const Expected:string);
  var J:Integer;
  begin
    R[0].ValueType:=Kind; SetLength(R[0].Data,Length(Bytes));
    for J:=0 to High(Bytes) do R[0].Data[J]:=Bytes[J];
    P.Bind(R); D:=P.RecordDetails(0);
    Check(Pos(Expected,D)>0,Expected);
    for J:=0 to High(Bytes) do Check(R[0].Data[J]=Bytes[J],'Raw bytes changed');
  end;
begin
  P:=TGpoRegistryPane.Create(nil);
  try
    SetLength(R,1); R[0].Key:='K'; R[0].ValueName:='V';
    Verify(4,[$78,$56,$34,$12],'305419896 (0x12345678)');
    Verify(5,[$12,$34,$56,$78],'305419896 (0x12345678)');
    Verify(11,[$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff],'18446744073709551615');
    Verify(4,[1,2],'整数长度');
    Verify(1,[$41,0,0,0],'文本：A');
    Verify(2,[$25,0,$58,0,$25,0,0,0],'%X%');
    Check(Pos('未展开',D)>0);
    Verify(1,[1],'奇数');
    Verify(1,[$41,0],'缺少 NUL');
    Verify(1,[$41,0,0,0,$42,0,0,0],'嵌入 NUL');
    Verify(1,[0,$d8,0,0],'代理项');
    Verify(1,[$3d,$d8,0,$de,0,0],UTF8Encode(UnicodeString(WideChar($d83d))+WideChar($de00)));
    Verify(7,[0,0,0,0],'项目数：0');
    Verify(7,[$41,0,0,0,$42,0,0,0,0,0],'项目数：2');
    Verify(7,[0,0,$41,0,0,0,0,0],'空项目');
    Verify(7,[$41,0,0,0],'双 NUL');
    Verify(6,[$41,0],'仅显示原始数据');
    Verify(999,[1,2,3],'01 02 03');
    R[0].ValueName:='**DeleteValues'; Verify(4,[1,0,0,0],'策略指令');
    R[0].ValueName:='V'; SetLength(R[0].Data,10002);
    for I:=0 to 4999 do begin R[0].Data[I*2]:=65; R[0].Data[I*2+1]:=0; end;
    R[0].Data[10000]:=0; R[0].Data[10001]:=0; R[0].ValueType:=1;
    P.Bind(R); D:=P.RecordDetails(0); Check(Pos('预览已截断',D)>0);
    Check(Pos('41 00 41 00',D)>0); Check(Length(R[0].Data)=10002);
    SetLength(R[0].Data,8200);
    for I:=0 to 4094 do begin R[0].Data[I*2]:=65; R[0].Data[I*2+1]:=0; end;
    R[0].Data[8190]:=$3d; R[0].Data[8191]:=$d8;
    R[0].Data[8192]:=0; R[0].Data[8193]:=$de;
    R[0].Data[8194]:=66; R[0].Data[8195]:=0;
    R[0].Data[8196]:=0; R[0].Data[8197]:=0; SetLength(R[0].Data,8198);
    P.Bind(R); D:=P.RecordDetails(0);
    Check(Pos(StringOfChar('A',4095)+'B',D)=0,'Truncated preview must remain a prefix');
    Check(Pos('预览已截断',D)>0);
    R[0].Data[8190]:=1; R[0].Data[8191]:=0;
    R[0].Data[8192]:=0; R[0].Data[8193]:=0; SetLength(R[0].Data,8194);
    P.Bind(R); D:=P.RecordDetails(0);
    Check(Pos('\u0001',D)=0,'Escape must fit in full');
    Check(Pos('预览已截断',D)>0);
    SetLength(R[0].Data,8198);
    R[0].Data[8190]:=$3d; R[0].Data[8191]:=$d8;
    R[0].Data[8192]:=0; R[0].Data[8193]:=$de;
    R[0].Data[8194]:=0; R[0].Data[8195]:=$dc;
    R[0].Data[8196]:=0; R[0].Data[8197]:=0;
    P.Bind(R); D:=P.RecordDetails(0);
    Check(Pos('代理项无效',D)>0,'Truncation must not skip validation');
  finally P.Free; end;
end;
procedure TUnitTestGpoSettings.SelectedGpcIdentity;
const Guid='{12345678-1234-1234-1234-123456789ABC}';
  DN='CN='+Guid+',CN=Policies,CN=System,DC=example,DC=test';
var E:TLdapResult; Original,Replacement:RawByteString;
begin
  Original:=#1+StringOfChar(#0,15); Replacement:=#2+StringOfChar(#0,15);
  Check(not GpoMatchesSelectedObject(nil,DN,Guid,Original));
  E:=TLdapResult.Create;
  try
    E.ObjectName:=DN; E.Attributes.Add('name',Guid);
    Check(not GpoMatchesSelectedObject(E,DN,Guid,Original),'Missing objectGUID must fail');
    E.Attributes.Add('objectGUID',Original);
    Check(GpoMatchesSelectedObject(E,DN,Guid,Original));
    Check(not GpoMatchesSelectedObject(E,DN,Guid,Replacement),'Recreated object must fail');
    Check(not GpoMatchesSelectedObject(E,DN,Guid,StringOfChar(#0,16)),'Zero GUID must fail');
    Check(not GpoMatchesSelectedObject(E,DN,Guid,Copy(Original,1,15)));
    Check(not GpoMatchesSelectedObject(E,'CN=other,DC=example,DC=test',Guid,Original));
    Check(not GpoMatchesSelectedObject(E,DN,'invalid',Original));
    E.Attributes.Add('objectGUID',Replacement,aoReplaceValue);
    Check(not GpoMatchesSelectedObject(E,DN,Guid,Original),'Fresh changed GUID must fail');
  finally E.Free; end;
end;
type
  TTestGpoFrame = class(TFrmPropertyGpoSettings)
  public
    TestToken:IInterface;
    procedure TestAttachRead(const Job: IGpoSettingsRead);
    function HasRead(const Job:IGpoSettingsRead):Boolean;
    procedure PollNow;
    procedure TestAttachBaseline(const Job:IGpoBaselineJob);
    procedure PollBaselineNow;
    procedure TestAttachDomain(const Job:IGpoDomainDraftJob);
  protected
    function CurrentSessionToken:IInterface; override;
  end;
  TLdapSessionProbe = class(TLdapClient)
  public
    constructor Create; override;
    procedure ResetSameSocket(const UserName: string);
  end;
  TRevokingTransport = class(TInterfacedObject, IGpoSettingsTransport)
  public
    Client: TLdapSessionProbe;
    Calls: Integer;
    RevokeOnFirstRead: Boolean;
    function Read(const Container: TGpoContainer; const Domain, DC: string;
      Artifact: TGpoFile; out Data: TBytes): TGpoReadStatus;
  end;
  TSettingsMetadataProbe = class(TInterfacedObject,IGpoSettingsTransport,IGpoSettingsMetadataTransport)
    Entered,Release:TEvent; PrepareCalls,ReadCalls,Mode:Integer;
    constructor Create;
    destructor Destroy; override;
    function Prepare(var Value:TGpoSettingsSnapshot; Control:TGpoReadControl):TGpoReadStatus;
    function Read(const Container:TGpoContainer; const Domain,DC:string; Artifact:TGpoFile; out Data:TBytes):TGpoReadStatus;
  end;
  TSettingsTestThread=class(TThread)
    Job:IGpoSettingsRead;
    procedure Execute; override;
  end;
  TBaselineProbe = class(TInterfacedObject,IGpoBaselineTransport)
    Client:TLdapSessionProbe;
    Revoke:Boolean;
    Calls:Integer;
    FirstGuid:Byte;
    function Check(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
  end;
  TBlockingBaseline = class(TInterfacedObject,IGpoBaselineTransport)
    Entered,Release:TEvent;
    constructor Create;
    destructor Destroy; override;
    function Check(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
  end;
  TBaselineTestThread = class(TThread)
    Job:IGpoBaselineJob;
    procedure Execute; override;
  end;
  TDomainProbe = class(TInterfacedObject,IGpoDomainDraftBackend)
    Entered,Release:TEvent;
    CheckResult:TGpoPreflightResult;
    BlockOpen:Boolean;
    AfterReleaseStatus:TGpoReadStatus;
    FirstGuid,FirstUserByte:Byte;
    constructor Create;
    destructor Destroy; override;
    function Open(const Request:TGpoBaselineRequest; Control:TGpoReadControl; out User,Machine:TGpoPolicyImage):Boolean;
    function Check(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl):TGpoPreflightResult;
  end;
  TDomainTestThread = class(TThread)
    Job:IGpoDomainDraftJob;
    procedure Execute; override;
  end;
  TDomainDiagnosticProbe = class(TDomainProbe,IGpoDomainDiagnosticBackend)
    Evidence:TBytes;
    FailAfter:Boolean;
    function Diagnose(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl;
      out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
  end;
constructor TDomainProbe.Create;
begin inherited Create; Entered:=TEvent.Create(nil,True,False,''); Release:=TEvent.Create(nil,True,False,''); CheckResult:=gprConflict; end;
destructor TDomainProbe.Destroy;
begin Entered.Free; Release.Free; inherited Destroy; end;
function TDomainProbe.Open(const Request:TGpoBaselineRequest; Control:TGpoReadControl; out User,Machine:TGpoPolicyImage):Boolean;
begin
  FirstGuid:=Request.ObjectGuid[0]; User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
  if BlockOpen then begin Entered.SetEvent; Release.WaitFor(5000); AfterReleaseStatus:=Control.Status; end;
  Machine.Exists:=True; Machine.Data:=TBytes.Create(Ord('P'),Ord('R'),Ord('e'),Ord('g'),1,0,0,0); Result:=True;
end;
function TDomainProbe.Check(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl):TGpoPreflightResult;
begin
  if Length(User.Data)>0 then FirstUserByte:=User.Data[0];
  Entered.SetEvent; Release.WaitFor(5000); Result:=CheckResult;
end;
function TDomainDiagnosticProbe.Diagnose(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl;
  out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
begin
  Report:=Default(TGpoDiagnosticReport); Report.Summary:=gduIncomplete; Report.HasOther:=True;
  Report.Items[gdrMachinePolicy].Match:=gdmOther;
  SetLength(Evidence,1024*1024); Evidence[0]:=42;
  Report.Items[gdrMachinePolicy].Observed.Data:=Evidence;
  Entered.SetEvent; Release.WaitFor(5000);
  if FailAfter then raise Exception.Create('Synthetic diagnostic failure');
  Result:=gdtOk;
end;
procedure TDomainTestThread.Execute; begin Job.Execute; end;
constructor TBlockingBaseline.Create;
begin inherited Create; Entered:=TEvent.Create(nil,True,False,''); Release:=TEvent.Create(nil,True,False,''); end;
destructor TBlockingBaseline.Destroy;
begin Entered.Free; Release.Free; inherited Destroy; end;
function TBlockingBaseline.Check(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
begin Entered.SetEvent; Release.WaitFor(5000); Result:='late result'; end;
procedure TBaselineTestThread.Execute;
begin Job.Execute; end;
function TBaselineProbe.Check(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
begin
  Inc(Calls); if Length(Request.ObjectGuid)>0 then FirstGuid:=Request.ObjectGuid[0];
  if Revoke then Client.ResetSameSocket('B');
  Result:='simulated baseline';
end;
function TRevokingTransport.Read(const Container: TGpoContainer;
  const Domain, DC: string; Artifact: TGpoFile; out Data: TBytes): TGpoReadStatus;
begin
  Data:=nil; Inc(Calls);
  if RevokeOnFirstRead and (Calls=1) then Client.ResetSameSocket('B');
  Result:=grsMissing;
end;
constructor TSettingsMetadataProbe.Create;
begin inherited Create; Entered:=TEvent.Create(nil,True,False,''); Release:=TEvent.Create(nil,True,False,''); end;
destructor TSettingsMetadataProbe.Destroy;
begin Entered.Free; Release.Free; inherited Destroy; end;
function TSettingsMetadataProbe.Prepare(var Value:TGpoSettingsSnapshot; Control:TGpoReadControl):TGpoReadStatus;
begin
  Inc(PrepareCalls);
  if (Mode in [1,4,5,7]) and (PrepareCalls=1) then begin Entered.SetEvent; Release.WaitFor(5000); end;
  if (Mode=9) and (PrepareCalls=2) then begin Entered.SetEvent; Release.WaitFor(5000); end;
  if (Mode=2) and (PrepareCalls=1) then Exit(grsIoError);
  if (Mode=3) and (PrepareCalls=2) then Value.ObjectGuid:=#2+StringOfChar(#0,15);
  if (Mode=6) and (PrepareCalls=2) then Value.DC:='other.example.test';
  if (Mode=8) and (PrepareCalls=2) then Exit(grsIoError);
  if ((Mode=10) and (PrepareCalls=1)) or ((Mode=11) and (PrepareCalls=2)) or (Mode=12) then begin
    Value.DisplayNamePresent:=True; Value.Container.DisplayName:='Example';
  end;
  if ((Mode=13) and (PrepareCalls=2)) or ((Mode=14) and (PrepareCalls=1)) or (Mode=15) then
    Value.DisplayNamePresent:=True;
  Value.Container.FileSysPath:='\\example.test\SYSVOL\example.test\Policies\{12345678-1234-1234-1234-123456789ABC}';
  Result:=Control.Status;
end;
function TSettingsMetadataProbe.Read(const Container:TGpoContainer; const Domain,DC:string;
  Artifact:TGpoFile; out Data:TBytes):TGpoReadStatus;
var Rows:TGpoRegistryRecords;
begin
  Data:=nil; Inc(ReadCalls); Result:=grsMissing;
  if (Mode in [3,6,8,9,10,11,12,13,14,15,16]) and (Artifact=gfMachineRegistry) then begin
    SetLength(Rows,1); Rows[0].Key:='K'; Rows[0].ValueName:='V'; Rows[0].ValueType:=3;
    Result:=SerializeRegistryPol(Rows,Data);
  end;
end;
procedure TSettingsTestThread.Execute; begin Job.Execute; end;

procedure TUnitTestGpoSettings.BackgroundMetadataLifecycle;
var Client:TLdapSessionProbe; Frame:TTestGpoFrame; Value,Snapshot:TGpoSettingsSnapshot;
  Probe:TSettingsMetadataProbe; Transport:IGpoSettingsTransport; Job:IGpoSettingsRead;
  Worker:TSettingsTestThread; Other:IGpoSettingsRead; Mode:Integer;
begin
  Check(GpoSupportsBackgroundSettings(lcbKerberos,False,False));
  Check(not GpoSupportsBackgroundSettings(lcbPlain,False,False));
  Check(not GpoSupportsBackgroundSettings(lcbDigest,False,False));
  Check(not GpoSupportsBackgroundSettings(lcbKerberos,True,False));
  Check(not GpoSupportsBackgroundSettings(lcbKerberos,False,True));
  Check(Pos('显式密码',GpoBackgroundSettingsRestriction(lcbKerberos,True,False))>0);
  Check(Pos('TLS',GpoBackgroundSettingsRestriction(lcbKerberos,False,True))>0);
  Check(Pos('Kerberos',GpoBackgroundSettingsRestriction(lcbPlain,False,False))>0);
  Check(GpoBackgroundSettingsRestriction(lcbKerberos,False,False)='');
  Client:=TLdapSessionProbe.Create;
  try
    for Mode:=0 to 16 do begin
      Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Client.SessionToken;
      Value.NeedsMetadata:=True; Value.ObjectGuid:=#1+StringOfChar(#0,15);
      Value.Domain:='example.test'; Value.DC:='dc.example.test';
      Value.Container.Guid:='{12345678-1234-1234-1234-123456789ABC}';
      Probe:=TSettingsMetadataProbe.Create; Probe.Mode:=Mode; Transport:=Probe;
      Job:=GpoCreateSettingsRead(Value,Transport); Worker:=TSettingsTestThread.Create(True); Worker.Job:=Job;
      Frame:=nil;
      try
        Worker.Start;
        if Mode in [1,4,5,7,9] then begin
          Check(Probe.Entered.WaitFor(2000)=wrSignaled); Check(not Job.Finished);
          Frame:=TTestGpoFrame.Create(nil); Frame.TestAttachRead(Job);
          Frame.LoadButton.Enabled:=True; Frame.LoadButton.Click;
          Check(Frame.HasRead(Job),'Repeated load must not replace the active job');
          if Mode=1 then begin Frame.Free; Frame:=nil; end
          else if Mode=4 then Frame.Update(nil)
          else if Mode in [5,9] then Client.ResetSameSocket('Changed')
          else begin Frame.CancelButton.Enabled:=True; Frame.CancelButton.Click; end;
          Check(Job.ReadStatus=grsCancelled); Check(not Job.Finished,'Blocked LDAP must not delay frame destruction');
          Other:=GpoCreateSettingsRead(Value); Check(Assigned(Other));
          Check(not Assigned(GpoCreateSettingsRead(Value)),'Blocked LDAP keeps its resource slot');
          Other:=nil;
          Probe.Release.SetEvent;
        end;
        Worker.WaitFor; Snapshot:=Job.Snapshot;
        case Mode of
          0:begin Check(Probe.PrepareCalls=2); Check(Probe.ReadCalls=3); Check(Snapshot.MetadataStatus=grsOk); end;
          1:begin Check(Probe.ReadCalls=0); Check(Snapshot.MetadataStatus=grsCancelled); end;
          2:begin
            Check(Probe.ReadCalls=0,'Failed identity check must start no SYSVOL reads');
            Check(Snapshot.MetadataStatus=grsIoError);
            Frame:=TTestGpoFrame.Create(nil); Frame.ShowSnapshot(Snapshot);
            Check(Frame.ComputerRows.Items.Count=0); Check(Pos('后台 LDAP',Frame.Summary.Text)>0);
          end;
          3:begin Check(Probe.PrepareCalls=2); Check(Probe.ReadCalls=3); Check(Snapshot.MetadataStatus=grsIoError);
            Check((Snapshot.MachineStatus=grsIoError) and (Length(Snapshot.MachineRecords)=0)); end;
          4,5,7:begin Check(Probe.ReadCalls=0); Check(Snapshot.MetadataStatus=grsCancelled); end;
          6:begin Check(Probe.PrepareCalls=2); Check(Probe.ReadCalls=3); Check(Snapshot.MetadataStatus=grsIoError); end;
          8:begin Check(Probe.PrepareCalls=2); Check(Probe.ReadCalls=3); Check(Snapshot.MetadataStatus=grsIoError);
            Check(Pos('无法再次核验',Snapshot.MetadataError)>0); Check(Length(Snapshot.UserRecords)=0); end;
          9:begin Check(Probe.ReadCalls=3); Check(Snapshot.MetadataStatus=grsCancelled);
            Check(Length(Snapshot.MachineRecords)=0); end;
          10,11,13,14:begin Check(Probe.PrepareCalls=2); Check(Snapshot.MetadataStatus=grsIoError,
              'Display name presence change must discard results');
            Check(Length(Snapshot.MachineRecords)=0);
            Frame:=TTestGpoFrame.Create(nil); Frame.ShowSnapshot(Snapshot);
            Check((Frame.ComputerRows.Items.Count=0) and (Pos('Example',Frame.Summary.Text)=0)); end;
          12,15,16:begin Check(Snapshot.MetadataStatus=grsOk); Check(Length(Snapshot.MachineRecords)=1); end;
        end;
      finally Probe.Release.SetEvent; Worker.WaitFor; Worker.Free; Frame.Free; Job:=nil; Transport:=nil; end;
    end;
  finally Client.Free; end;
end;

procedure TUnitTestGpoSettings.HeaderUsesSystemColors;
{$IFDEF WINDOWS}
var Frame:TFrmPropertyGpoSettings; Host:TForm; Bitmap:TBitmap; Draw:TNMCustomDraw; View,Header:HWND; I:Integer;
begin
  Host:=TForm.CreateNew(nil);
  Frame:=TFrmPropertyGpoSettings.Create(Host);
  Frame.Parent:=Host;
  Bitmap:=TBitmap.Create;
  try
    Bitmap.SetSize(240,30);
    View:=Frame.ComputerRows.Handle;
    Draw:=Default(TNMCustomDraw);
    Header:=ListView_GetHeader(View);
    Draw.hdr.hwndFrom:=Header;
    Draw.hdr.code:=DWORD(LongInt(NM_CUSTOMDRAW));
    Draw.dwDrawStage:=CDDS_PREPAINT;
    Check(SendMessage(View,WM_NOTIFY,0,LPARAM(@Draw))=(CDRF_NOTIFYITEMDRAW or CDRF_NOTIFYPOSTPAINT));
    Draw.dwDrawStage:=CDDS_ITEMPREPAINT;
    Draw.hdc:=Bitmap.Canvas.Handle;
    Draw.rc.Left:=0; Draw.rc.Top:=0; Draw.rc.Right:=240; Draw.rc.Bottom:=30;
    Check(SendMessage(View,WM_NOTIFY,0,LPARAM(@Draw))=CDRF_SKIPDEFAULT);
    Check(GetPixel(Draw.hdc,230,15)=GetSysColor(COLOR_BTNFACE));
    for I:=0 to Frame.ComputerRows.Columns.Count-1 do Frame.ComputerRows.Columns[I].Width:=30;
    Windows.SetWindowPos(Header,0,0,0,240,30,SWP_NOMOVE or SWP_NOZORDER or SWP_NOACTIVATE);
    SetPixel(Draw.hdc,10,15,RGB(255,0,255));
    SetPixel(Draw.hdc,220,15,RGB(255,0,255));
    Draw.dwDrawStage:=CDDS_POSTPAINT;
    Check(SendMessage(View,WM_NOTIFY,0,LPARAM(@Draw))=CDRF_DODEFAULT);
    Check(GetPixel(Draw.hdc,10,15)=RGB(255,0,255), 'Column drawing must remain untouched.');
    Check(GetPixel(Draw.hdc,220,15)=GetSysColor(COLOR_BTNFACE), 'The empty header tail uses the same background.');
  finally Bitmap.Free; Host.Free; end;
end;
{$ELSE}
begin
  Check(True, 'Other platforms use their native header.');
end;
{$ENDIF}

function TTestGpoFrame.CurrentSessionToken:IInterface;
begin Result:=TestToken; end;
procedure TTestGpoFrame.PollNow;
begin Poll(nil); end;
procedure TTestGpoFrame.PollBaselineNow;
begin PollBaseline(nil); end;
procedure TTestGpoFrame.TestAttachDomain(const Job:IGpoDomainDraftJob);
begin if Assigned(fDomainDraftJob) then fDomainDraftJob.Cancel; fDomainDraftJob:=Job; end;
procedure TTestGpoFrame.TestAttachBaseline(const Job:IGpoBaselineJob);
begin if Assigned(fBaselineJob) then fBaselineJob.Cancel; fBaselineJob:=Job; end;
procedure TTestGpoFrame.TestAttachRead(const Job: IGpoSettingsRead);
begin
  if Assigned(fJob) then fJob.Cancel;
  fJob:=Job;
end;
function TTestGpoFrame.HasRead(const Job:IGpoSettingsRead):Boolean;
begin Result:=fJob=Job; end;
constructor TLdapSessionProbe.Create;
begin
  inherited Create;
  fSock:=TCrtSocket.Create; // Unopened local object: no network access.
end;
procedure TLdapSessionProbe.ResetSameSocket(const UserName: string);
begin
  Reset(True); // Same invalidation path called by automatic Reconnect.
  NewSessionToken; // Same new-generation step performed by each bind entry.
  fBound:=True; fBoundUser:=UserName;
end;
procedure TUnitTestGpoSettings.ReadOnlyDisplayAndReset;
var Frame: TFrmPropertyGpoSettings; Value: TGpoSettingsSnapshot; Props: TProperty;
begin
  Frame := TFrmPropertyGpoSettings.Create(nil);
  Props := TProperty.Create;
  try
    Check(Pos('不存在', GpoLdapFailureText(32)) > 0);
    Check(Pos('访问被拒绝', GpoLdapFailureText(50)) > 0);
    Check(Pos('groupPolicyContainer', GpoLdapFailureText(0)) > 0);
    Check(Pos('LDAP 结果 81', GpoLdapFailureText(81)) > 0);
    Check(Frame.Summary.ReadOnly);
    Check(not Frame.Summary.Visible);
    Check(Pos('尚未加载',Frame.StateLabel.Caption)>0);
    Frame.DetailsButton.Click; Check(Frame.Summary.Visible);
    Frame.DetailsButton.Click; Check(not Frame.Summary.Visible);
    Check(Frame.ComputerRows.ReadOnly and Frame.UserRows.ReadOnly);
    Check(not Frame.LoadButton.Enabled);
    Check(not Frame.BaselineButton.Enabled);
    Check(not Frame.DomainDraftButton.Enabled);
    Check(not Frame.CancelButton.Enabled);
    Frame.Update(Props);
    Check(not Props.IsModified);
    Frame.LoadButton.Click;
    Check(Pos('没有已连接的 LDAP', Frame.Summary.Text) > 0);
    Check(not Frame.BaselineButton.Enabled,'Unbound entry must remain disabled');
    Check(not Frame.DomainDraftButton.Enabled,'Unbound domain draft entry must remain disabled');
    Value := Default(TGpoSettingsSnapshot);
    Value.DC := 'dc.example.test'; Value.Domain := 'example.test';
    Value.Container.Version := $00020003; Value.GptVersion := $00010003;
    Value.GptStatus := grsOk; Value.MachineStatus := grsOk;
    Value.UserStatus := grsAccessDenied;
    SetLength(Value.MachineRecords, 1);
    Value.MachineRecords[0].Key := 'Software\Policy';
    Value.MachineRecords[0].ValueName := 'Unknown';
    Value.MachineRecords[0].ValueType := 987;
    SetLength(Value.MachineRecords[0].Data, 2);
    Value.MachineRecords[0].Data[0] := $AB;
    Value.MachineRecords[0].Data[1] := $CD;
    Frame.ShowSnapshot(Value);
    Check(Pos('计算机 3 / 用户 2', Frame.Summary.Text) > 0);
    Check(Pos('版本不一致', Frame.Summary.Text) > 0);
    Check(Pos('访问被拒绝', Frame.Summary.Text) > 0);
    Check(Frame.ComputerRows.Items.Count = 1);
    Check(Frame.UserRows.Items.Count = 0);
    Check(Pos('访问被拒绝',Frame.StateLabel.Caption)>0);
    Check(Pos('Software\Policy',Frame.ComputerPane.RecordDetails(0))>0);
    Check(Pos('AB CD',Frame.ComputerPane.RecordDetails(0))>0);
    Check(Frame.ComputerPane.RecordDetails(-1)='');
    Check(Frame.ComputerRows.Items[0].SubItems[1] = '未知类型 (987)');
    Check(Pos('AB CD', Frame.ComputerRows.Items[0].SubItems[2]) > 0);
    Value.UserStatus := grsMissing;
    Value.MachineRecords[0].ValueType := 4;
    Frame.ShowSnapshot(Value);
    Check(Frame.ComputerRows.Items[0].SubItems[1] = 'REG_DWORD');
    Check(Pos('其他扩展仍可能包含策略', Frame.Summary.Text) > 0);
    Value.MachineStatus := grsCorrupt;
    Value.GptStatus := grsMissing;
    Frame.ShowSnapshot(Value);
    Check(Frame.ComputerRows.Items.Count = 0, 'Failed read must clear stale records.');
    Check(Pos('版本比较：未知', Frame.Summary.Text) > 0);
    Check(Pos('未找到不等于空策略', Frame.Summary.Text) > 0);
    Check(GpoParseLdapVersion('-2147483648', Value.Container.Version));
    Value.GptVersion := $80000000;
    Value.GptStatus := grsOk;
    Frame.ShowSnapshot(Value);
    Check(Pos('2147483648（计算机 0 / 用户 32768）', Frame.Summary.Text) > 0);
    Check(Pos('版本比较：一致', Frame.Summary.Text) > 0);
    Check(GpoParseLdapVersion('-1', Value.Container.Version));
    Value.GptVersion := $ffffffff;
    Frame.ShowSnapshot(Value);
    Check(Pos('4294967295（计算机 65535 / 用户 65535）', Frame.Summary.Text) > 0);
    Check(Pos('版本比较：一致', Frame.Summary.Text) > 0);
    Frame.Update(nil);
    Check(Frame.ComputerRows.Items.Count = 0);
    Check(Pos('尚未加载', Frame.Summary.Text) > 0);
    Check(not Props.IsModified, 'Viewing must never stage LDAP writes.');
  finally Frame.Free; Props.Free; end;
end;
procedure TUnitTestGpoSettings.PagedRecordsAndReset;
var Frame: TFrmPropertyGpoSettings; Value: TGpoSettingsSnapshot; I: Integer;
begin
  Frame := TFrmPropertyGpoSettings.Create(nil);
  try
    Value := Default(TGpoSettingsSnapshot);
    Value.MachineStatus := grsOk; Value.UserStatus := grsOk;
    SetLength(Value.MachineRecords, 401);
    SetLength(Value.UserRecords, 201);
    for I := 0 to High(Value.MachineRecords) do
      Value.MachineRecords[I].ValueName := UnicodeString('Computer' + IntToStr(I));
    for I := 0 to High(Value.UserRecords) do
      Value.UserRecords[I].ValueName := UnicodeString('User' + IntToStr(I));
    Frame.ShowSnapshot(Value);
    Check(Frame.ComputerRows.Items.Count = GpoRegistryPageSize);
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer0');
    Check(Frame.ComputerRows.Items[199].SubItems[0] = 'Computer199');
    Check(Frame.ComputerPane.PageSelector.Items.Count = 3);
    Check(Frame.ComputerPane.RangeLabel.Caption = '第 1-200 条，共 401 条');
    Check(not Frame.ComputerPane.PreviousButton.Enabled);
    Check(Frame.ComputerPane.NextButton.Enabled);
    Frame.ComputerPane.NextButton.Click;
    Check(Frame.ComputerRows.Items.Count = 200);
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer200');
    Check(Frame.UserRows.Items[0].SubItems[0] = 'User0');
    Frame.ComputerPane.PageSelector.ItemIndex := 2;
    Frame.ComputerPane.PageSelector.OnChange(Frame.ComputerPane.PageSelector);
    Check(Frame.ComputerRows.Items.Count = 1);
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer400');
    Check(Frame.ComputerPane.RangeLabel.Caption = '第 401-401 条，共 401 条');
    Check(not Frame.ComputerPane.NextButton.Enabled);
    Frame.ComputerPane.PreviousButton.Click;
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer200');
    Frame.UserPane.SelectPage(1);
    Check(Frame.UserRows.Items.Count = 1);
    Check(Frame.UserRows.Items[0].SubItems[0] = 'User200');
    Frame.ComputerPane.SelectPage(-1);
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer0');
    Frame.ComputerPane.SelectPage(High(Integer));
    Check(Frame.ComputerRows.Items[0].SubItems[0] = 'Computer400');
    Value.MachineStatus := grsAccessDenied;
    Frame.ShowSnapshot(Value);
    Check(Frame.ComputerRows.Items.Count = 0);
    Check(Frame.ComputerPane.PageSelector.Items.Count = 0);
    Check(not Frame.ComputerPane.NextButton.Enabled);
    Check(not Frame.ComputerPane.PreviousButton.Enabled);
    Check(Frame.UserRows.Items[0].SubItems[0] = 'User0');
    Frame.Update(nil);
    Check(Frame.UserRows.Items.Count = 0);
    Check(Frame.UserPane.RangeLabel.Caption = '共 0 条');
    Check(not Frame.UserPane.PageSelector.Enabled);
    Value.MachineStatus := grsOk;
    SetLength(Value.MachineRecords, 200);
    Value.UserRecords := nil;
    Frame.ShowSnapshot(Value);
    Check(Frame.ComputerPane.PageSelector.Items.Count = 1);
    Check(not Frame.ComputerPane.PageSelector.Enabled);
    Check(not Frame.ComputerPane.NextButton.Enabled);
    Check(Frame.ComputerRows.Items.Count = 200);
  finally Frame.Free; end;
end;
procedure TUnitTestGpoSettings.CancelledJobsAndConcurrencyCap;
var A,B,C:IGpoSettingsRead; Value:TGpoSettingsSnapshot; Client:TLdapSessionProbe;
begin
  Client:=TLdapSessionProbe.Create;
  try
  Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Client.SessionToken;
  A:=GpoCreateSettingsRead(Value); B:=GpoCreateSettingsRead(Value);
  Check(Assigned(A) and Assigned(B));
  Check(A.ReadStatus=grsOk); Check(B.ReadStatus=grsOk);
  C:=GpoCreateSettingsRead(Value); Check(not Assigned(C));
  A.Cancel; A.Execute; Check(A.Finished); Check(A.ReadStatus=grsCancelled);
  Value:=A.Snapshot;
  Check(Value.GptStatus=grsCancelled); Check(Value.MachineStatus=grsCancelled);
  Check(Value.UserStatus=grsCancelled); Check(Length(Value.MachineRecords)=0);
  Check(Length(Value.UserRecords)=0);
  C:=GpoCreateSettingsRead(Value); Check(Assigned(C));
  // Destroying an unstarted job releases its reservation too.
  B:=nil; B:=GpoCreateSettingsRead(Value); Check(Assigned(B));
  A:=nil; B:=nil; C:=nil;
  A:=GpoCreateSettingsRead(Value); B:=GpoCreateSettingsRead(Value);
  Check(Assigned(A) and Assigned(B));
  // A completed result must not reappear if Cancel is pressed before UI polling.
  A.Execute; Check(A.Finished); A.Cancel;
  Check(A.ReadStatus=grsCancelled); Value:=A.Snapshot;
  Check(Value.GptStatus=grsCancelled); Check(Length(Value.MachineRecords)=0);
  A:=nil; B:=nil;
  finally A:=nil; B:=nil; C:=nil; Client.Free; end;
end;
procedure TUnitTestGpoSettings.BaselineJobLifecycle;
var Client:TLdapSessionProbe; Frame:TTestGpoFrame; Job,Other:IGpoBaselineJob;
  Request:TGpoBaselineRequest; Probe:TBaselineProbe; Transport:IGpoBaselineTransport; Token:IInterface;
  Block:TBlockingBaseline; Worker:TBaselineTestThread;
begin
  Client:=TLdapSessionProbe.Create; Frame:=TTestGpoFrame.Create(nil);
  try
    Client.ResetSameSocket('A'); Token:=Client.SessionToken; Frame.TestToken:=Token;
    Request:=Default(TGpoBaselineRequest); Request.SessionToken:=Token; SetLength(Request.ObjectGuid,16); Request.ObjectGuid[0]:=7;
    Probe:=TBaselineProbe.Create; Probe.Client:=Client; Transport:=Probe;
    Job:=GpoCreateBaselineJob(Request,Transport); Request.ObjectGuid[0]:=8;
    Check(Assigned(Job)); Check(Job.AcceptsSession(Token)); Job.Execute;
    Check(Job.Finished); Check(Probe.FirstGuid=7); Check(Job.ResultText='simulated baseline');
    Frame.TestAttachBaseline(Job); Client.ResetSameSocket('A'); Frame.TestToken:=Client.SessionToken;
    Frame.PollBaselineNow; Check(Pos('丢弃',Frame.Summary.Text)>0,'Reconnect discards completed result');
    Job:=nil; Transport:=nil;
    Request.SessionToken:=Client.SessionToken; Probe:=TBaselineProbe.Create; Probe.Client:=Client; Probe.Revoke:=True; Transport:=Probe;
    Job:=GpoCreateBaselineJob(Request,Transport); Job.Execute;
    Check(Job.Finished); Check(Job.ReadStatus=grsCancelled); Check(Job.ResultText='');
    Job:=nil; Transport:=nil;
    Request.SessionToken:=Client.SessionToken; Job:=GpoCreateBaselineJob(Request); Other:=GpoCreateBaselineJob(Request);
    Check(Assigned(Job) and Assigned(Other)); Check(not Assigned(GpoCreateBaselineJob(Request)));
    Frame.TestAttachBaseline(Job); Frame.Update(nil); Check(Job.ReadStatus=grsCancelled);
    Job:=nil; Other:=nil;
    Job:=GpoCreateBaselineJob(Request); Frame.TestAttachBaseline(Job); Frame.Free; Frame:=nil;
    Check(Job.ReadStatus=grsCancelled,'Closing the frame cancels the independent worker');
    Job:=nil; Frame:=TTestGpoFrame.Create(nil); Block:=TBlockingBaseline.Create; Transport:=Block;
    Job:=GpoCreateBaselineJob(Request,Transport); Worker:=TBaselineTestThread.Create(True);
    Worker.Job:=Job; Worker.Start;
    try
      Check(Block.Entered.WaitFor(2000)=wrSignaled,'Background worker must enter transport');
      Frame.TestAttachBaseline(Job); Frame.Free; Frame:=nil;
      Check(Job.ReadStatus=grsCancelled); Check(not Job.Finished,'Cancellation waits for blocked call');
      Other:=GpoCreateBaselineJob(Request); Check(Assigned(Other));
      Check(not Assigned(GpoCreateBaselineJob(Request)),'Blocked worker retains its slot');
    finally Block.Release.SetEvent; Worker.WaitFor; Worker.Free; end;
    Check(Job.Finished); Check(Job.ResultText='','Late result must not be published after close');
  finally Job:=nil; Other:=nil; Transport:=nil; Frame.Free; Client.Free; end;
end;
procedure TUnitTestGpoSettings.DomainDraftJobLifecycle;
var Client:TLdapSessionProbe; Frame:TTestGpoFrame; Job:IGpoDomainDraftJob;
  Request:TGpoBaselineRequest; Probe:TDomainProbe; Backend:IGpoDomainDraftBackend;
  Worker:TDomainTestThread; User,Machine,CopyUser,CopyMachine:TGpoPolicyImage; I:Integer;
begin
  Client:=TLdapSessionProbe.Create; Frame:=TTestGpoFrame.Create(nil); Worker:=nil;
  try
    Client.ResetSameSocket('A'); Request:=Default(TGpoBaselineRequest); Request.SessionToken:=Client.SessionToken;
    SetLength(Request.ObjectGuid,16); Request.ObjectGuid[0]:=7;
    Probe:=TDomainProbe.Create; Backend:=Probe; Job:=GpoCreateDomainDraftJob(Request,Backend);
    Request.ObjectGuid[0]:=8; Check(Assigned(Job)); Worker:=TDomainTestThread.Create(True); Worker.Job:=Job; Worker.Start;
    for I:=1 to 200 do begin if Job.State=gddsReady then Break; Sleep(10); end;
    Check(Job.State=gddsReady); Check(Probe.FirstGuid=7); Check(Job.Initial(User,Machine));
    Check(not User.Exists and Machine.Exists); Machine.Data[0]:=0;
    Check(Job.Initial(CopyUser,CopyMachine)); Check(CopyMachine.Data[0]=Ord('P'),'Initial snapshot is independently owned');
    User.Exists:=True; User.Data:=TBytes.Create(1,2,3); Check(Job.Submit(User,CopyMachine));
    Check(Probe.Entered.WaitFor(2000)=wrSignaled); User.Data[0]:=9; Check(Probe.FirstUserByte=1);
    Frame.TestAttachDomain(Job); Frame.Update(nil); Check(Job.State=gddsStopped,'Target change cancels domain job');
    Probe.Release.SetEvent; Worker.WaitFor; FreeAndNil(Worker);
    Check(Job.State=gddsStopped); Check(Pos('失效',Job.ResultText)>0,'Late conflict cannot be published after cancel');
    Job:=nil; Backend:=nil;
    Request.SessionToken:=Client.SessionToken; Probe:=TDomainProbe.Create; Backend:=Probe;
    Job:=GpoCreateDomainDraftJob(Request,Backend); Worker:=TDomainTestThread.Create(True); Worker.Job:=Job; Worker.Start;
    for I:=1 to 200 do begin if Job.State=gddsReady then Break; Sleep(10); end;
    Check(Job.State=gddsReady); Check(Job.Initial(User,Machine)); Check(Job.Submit(User,Machine));
    Check(Probe.Entered.WaitFor(2000)=wrSignaled); Probe.Release.SetEvent;
    for I:=1 to 200 do begin if Job.State=gddsResult then Break; Sleep(10); end;
    Check(Job.State=gddsResult); Check(Pos('基线已变化',Job.ResultText)>0);
    Client.ResetSameSocket('B'); Check(Job.State=gddsStopped,'Reconnect revokes an idle draft');
    Worker.WaitFor; FreeAndNil(Worker);
    Job:=nil; Backend:=nil;
    Request.SessionToken:=Client.SessionToken; Probe:=TDomainProbe.Create; Probe.BlockOpen:=True; Backend:=Probe;
    Job:=GpoCreateDomainDraftJob(Request,Backend); Worker:=TDomainTestThread.Create(True); Worker.Job:=Job; Worker.Start;
    Check(Probe.Entered.WaitFor(2000)=wrSignaled); Frame.TestAttachDomain(Job); Frame.Free; Frame:=nil;
    Check(Job.State=gddsStopped,'Closing during capture revokes the draft'); Probe.Release.SetEvent;
    Worker.WaitFor; FreeAndNil(Worker); Check(Probe.AfterReleaseStatus=grsCancelled,'Cancellation reaches active capture control');
    Check(not Job.Initial(User,Machine),'Late capture cannot be published');
  finally
    if Assigned(Job) then Job.Cancel;
    if Assigned(Worker) then begin Probe.Release.SetEvent; Worker.WaitFor; Worker.Free; end;
    Job:=nil; Backend:=nil; Frame.Free; Client.Free;
  end;
end;
procedure TUnitTestGpoSettings.DiagnosticBackendLifecycle;
var Client:TLdapSessionProbe; Request:TGpoBaselineRequest; Probe:TDomainDiagnosticProbe;
  Backend:IGpoDomainDraftBackend; Job:IGpoDomainDraftJob; Worker:TDomainTestThread;
  User,Machine:TGpoPolicyImage; I,Mode:Integer; Original:Pointer;
begin
  Client:=TLdapSessionProbe.Create; Worker:=nil; Job:=nil;
  try
    Client.ResetSameSocket('A'); Request:=Default(TGpoBaselineRequest); Request.SessionToken:=Client.SessionToken;
    SetLength(Request.ObjectGuid,16); Request.ObjectGuid[0]:=7;
    Probe:=TDomainDiagnosticProbe.Create; Backend:=Probe; Job:=GpoCreateDomainDraftJob(Request,Backend);
    Worker:=TDomainTestThread.Create(True); Worker.Job:=Job; Worker.Start;
    for I:=1 to 200 do begin if Job.State=gddsReady then Break; Sleep(10); end;
    Check(Job.Initial(User,Machine)); Check(Job.Submit(User,Machine));
    Check(Probe.Entered.WaitFor(2000)=wrSignaled); Check(not Job.Submit(User,Machine));
    Probe.Release.SetEvent;
    for I:=1 to 200 do begin if Job.State=gddsResult then Break; Sleep(10); end;
    Check(Job.State=gddsResult); Check(Pos('信息不完整',Job.ResultText)>0);
    Check(Pos('其他值（冲突）',Job.ResultText)>0);
    Original:=Pointer(Probe.Evidence); SetLength(Probe.Evidence,Length(Probe.Evidence));
    Check(Pointer(Probe.Evidence)=Original,'Idle job must release raw report evidence');
    Client.ResetSameSocket('B'); Check(Job.State=gddsStopped);
    Check(Pos('失效',Job.ResultText)>0,'Revoked session cannot expose diagnostics');
    Worker.WaitFor; FreeAndNil(Worker);
    Job:=nil; Backend:=nil;
    for Mode:=0 to 1 do begin
      Request.SessionToken:=Client.SessionToken;
      Probe:=TDomainDiagnosticProbe.Create; Probe.FailAfter:=Mode=1; Backend:=Probe;
      Job:=GpoCreateDomainDraftJob(Request,Backend); Worker:=TDomainTestThread.Create(True);
      Worker.Job:=Job; Worker.Start;
      for I:=1 to 200 do begin if Job.State=gddsReady then Break; Sleep(10); end;
      Check(Job.Initial(User,Machine)); Check(Job.Submit(User,Machine));
      Check(Probe.Entered.WaitFor(2000)=wrSignaled);
      if Mode=0 then Job.Cancel;
      Probe.Release.SetEvent; Worker.WaitFor; FreeAndNil(Worker);
      Check(Job.State=gddsStopped);
      Original:=Pointer(Probe.Evidence); SetLength(Probe.Evidence,Length(Probe.Evidence));
      Check(Pointer(Probe.Evidence)=Original,'Cancelled or failed job releases raw evidence');
      Job:=nil; Backend:=nil;
    end;
  finally
    if Assigned(Job) then Job.Cancel;
    if Assigned(Worker) then begin Probe.Release.SetEvent; Worker.WaitFor; Worker.Free; end;
    Job:=nil; Backend:=nil; Client.Free;
  end;
end;
procedure TUnitTestGpoSettings.SessionChangesRejectDelayedJobs;
var Client:TLdapSessionProbe; Job:IGpoSettingsRead; Value:TGpoSettingsSnapshot;
  Token,TokenB:IInterface; Socket:TObject;
begin
  Client:=TLdapSessionProbe.Create;
  try
    Client.ResetSameSocket('A'); Socket:=Client.Sock;
    Token:=Client.SessionToken;
    Check(Assigned(Token)); Value:=Default(TGpoSettingsSnapshot);
    Value.SessionToken:=Token; Job:=GpoCreateSettingsRead(Value);
    Check(Job.AcceptsSession(Client.SessionToken)); Check(not Job.AcceptsSession(nil));
    Client.ResetSameSocket('A');
    Check(Client.Sock=Socket); Check(Client.BoundUser='A');
    Check(not Job.AcceptsSession(Client.SessionToken),'Same socket and user, different session');
    Token:=Client.SessionToken; Value.SessionToken:=Token; Job:=nil;
    Job:=GpoCreateSettingsRead(Value);
    Client.ResetSameSocket('B'); TokenB:=Client.SessionToken;
    Check(not Job.AcceptsSession(TokenB));
    Client.ResetSameSocket('A');
    Check(Client.Sock=Socket); Check(Client.BoundUser='A');
    Check(Client.SessionToken<>TokenB);
    Check(not Job.AcceptsSession(Client.SessionToken),'A to B to A must remain stale');
    // Complete after the session has changed: the same gate used by Poll rejects it.
    Job.Execute; Check(Job.Finished);
    Check(not Job.AcceptsSession(Client.SessionToken));
    Token:=Client.SessionToken; Client.Close;
    Check(Client.SessionToken<>Token);
    Check(not Assigned(Client.SessionToken));
    Client.Free; Client:=TLdapSessionProbe.Create;
    Check(Client.SessionToken<>Token,'Retained token prevents allocator address reuse');
  finally Job:=nil; Client.Free; end;
end;
procedure TUnitTestGpoSettings.ClosingAndReopeningCancelsRead;
var Frame:TTestGpoFrame; A,B,C:IGpoSettingsRead; Value:TGpoSettingsSnapshot;
  Client:TLdapSessionProbe;
begin
  Client:=TLdapSessionProbe.Create;
  try
  Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Client.SessionToken;
  A:=GpoCreateSettingsRead(Value); Check(A.ReadStatus=grsOk);
  Frame:=TTestGpoFrame.Create(nil);
  Frame.TestAttachRead(A); Frame.Free;
  Check(A.ReadStatus=grsCancelled); Check(not A.Finished);
  B:=GpoCreateSettingsRead(Value); Frame:=TTestGpoFrame.Create(nil);
  try
    Frame.TestAttachRead(B); Check(B.ReadStatus=grsOk);
    C:=GpoCreateSettingsRead(Value); Check(not Assigned(C),'Cap includes closed-page job');
    Frame.Update(nil); Check(B.ReadStatus=grsCancelled);
    A.Execute; Check(A.Finished);
    C:=GpoCreateSettingsRead(Value); Check(Assigned(C));
  finally Frame.Free; A:=nil; B:=nil; C:=nil; end;
  finally A:=nil; B:=nil; C:=nil; Client.Free; end;
end;
procedure TUnitTestGpoSettings.RevokedSessionStopsWorkerWithoutPoll;
var Client:TLdapSessionProbe; Job:IGpoSettingsRead; Transport:TRevokingTransport;
  TransportRef:IGpoSettingsTransport; Value:TGpoSettingsSnapshot; Old:IInterface;
  Token:ILdapSessionToken;
begin
  Client:=TLdapSessionProbe.Create;
  try
    Client.ResetSameSocket('A'); Old:=Client.SessionToken;
    Check(Supports(Old,ILdapSessionToken,Token)); Check(Token.IsValid);
    Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Old;
    Transport:=TRevokingTransport.Create; Transport.Client:=Client;
    Transport.RevokeOnFirstRead:=True; TransportRef:=Transport;
    Job:=GpoCreateSettingsRead(Value,TransportRef); Check(Assigned(Job));
    Job.Execute;
    Check(Job.Finished); Check(not Token.IsValid);
    Check(Transport.Calls=1,'Revoked worker must not start the next file before Poll');
    Check(Job.ReadStatus=grsCancelled);
    Value:=Job.Snapshot;
    Check(Value.GptStatus=grsCancelled); Check(Value.MachineStatus=grsCancelled);
    Check(Value.UserStatus=grsCancelled); Check(Length(Value.MachineRecords)=0);
    Job:=nil; TransportRef:=nil; Token:=nil; Old:=nil;

    // A stable session still reads all three artifacts; revocation is not a
    // blanket disabling of the viewer.
    Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Client.SessionToken;
    Transport:=TRevokingTransport.Create; Transport.Client:=Client; TransportRef:=Transport;
    Job:=GpoCreateSettingsRead(Value,TransportRef); Check(Job.ReadStatus=grsOk);
    Job.Execute; Check(Transport.Calls=3); Check(Job.ReadStatus=grsOk);
    Value:=Job.Snapshot; Check(Value.GptStatus=grsMissing);
    Client.Close; Check(Job.ReadStatus=grsCancelled);
    Value:=Job.Snapshot; Check(Value.GptStatus=grsCancelled);
    Job:=nil; TransportRef:=nil;

    // The retained token outlives the LDAP object; its destruction revokes it.
    Client.Free; Client:=TLdapSessionProbe.Create;
    Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=Client.SessionToken;
    Transport:=TRevokingTransport.Create; TransportRef:=Transport;
    Job:=GpoCreateSettingsRead(Value,TransportRef);
    Client.Free; Client:=nil;
    Job.Execute; Check(Transport.Calls=0); Check(Job.ReadStatus=grsCancelled);
    Job:=nil; TransportRef:=nil;

    // Missing or unrelated identities are rejected, not treated as valid.
    Value:=Default(TGpoSettingsSnapshot); Value.SessionToken:=TInterfacedObject.Create;
    Transport:=TRevokingTransport.Create; TransportRef:=Transport;
    Job:=GpoCreateSettingsRead(Value,TransportRef); Job.Execute;
    Check(Transport.Calls=0); Check(Job.ReadStatus=grsCancelled);
    Job:=nil; TransportRef:=nil;
    Value.SessionToken:=nil; Transport:=TRevokingTransport.Create; TransportRef:=Transport;
    Job:=GpoCreateSettingsRead(Value,TransportRef); Job.Execute;
    Check(Transport.Calls=0); Check(Job.ReadStatus=grsCancelled);
  finally Job:=nil; TransportRef:=nil; Token:=nil; Old:=nil; Client.Free; end;
end;
procedure TUnitTestGpoSettings.FullRecordAndEmptyStatus;
var Frame:TFrmPropertyGpoSettings; Value:TGpoSettingsSnapshot;
  Detail:string; I:Integer; LongKey:UnicodeString;
begin
  Frame:=TFrmPropertyGpoSettings.Create(nil);
  try
    Check(Frame.LoadButton.Parent=Frame.CancelButton.Parent);
    Value:=Default(TGpoSettingsSnapshot); Value.GptStatus:=grsOk;
    Value.MachineStatus:=grsMissing; Value.UserStatus:=grsMissing;
    Frame.ShowSnapshot(Value);
    Check(Pos('未找到',Frame.StateLabel.Caption)>0);
    Value.MachineStatus:=grsOk;
    SetLength(Value.MachineRecords,1);
    LongKey:=UnicodeString(StringOfChar('K',500))+WideChar($4e2d);
    Value.MachineRecords[0].Key:=LongKey;
    Value.MachineRecords[0].ValueName:='FullValue';
    Value.MachineRecords[0].ValueType:=3;
    SetLength(Value.MachineRecords[0].Data,300);
    for I:=0 to 299 do Value.MachineRecords[0].Data[I]:=I mod 256;
    Value.MachineRecords[0].Data[299]:=$ed;
    Frame.ShowSnapshot(Value);
    Detail:=Frame.ComputerPane.RecordDetails(0);
    Check(Pos(UTF8Encode(LongKey),Detail)>0);
    Check(Pos('FullValue',Detail)>0);
    Check(Pos('300',Detail)>0);
    Check(Pos('EA EB EC ED',Detail)>0,'Detail must include bytes beyond preview limit');
    Check(Frame.ComputerPane.RecordDetails(1)='');
    Check(Pos('文件存在，1 条',Frame.StateLabel.Caption)>0);
    Check(Pos('用户：文件未找到',Frame.StateLabel.Caption)>0);
    Value.MachineStatus:=grsAccessDenied;
    Frame.ShowSnapshot(Value);
    Check(Pos('访问被拒绝',Frame.StateLabel.Caption)>0);
    Check(Frame.ComputerRows.Items.Count=0);
  finally Frame.Free; end;
end;
procedure TUnitTestGpoSettings.CombinedSnapshotStates;
var F:TFrmPropertyGpoSettings; V:TGpoSettingsSnapshot; D:string;
begin
  F:=TFrmPropertyGpoSettings.Create(nil);
  try
    V:=Default(TGpoSettingsSnapshot); V.GptStatus:=grsOk;
    V.Container.Version:=4; V.GptVersion:=3;
    V.MachineStatus:=grsMissing; V.UserStatus:=grsMissing;
    F.ShowSnapshot(V);
    Check(Pos('版本不一致',F.StateLabel.Caption)>0,'Mismatch remains visible when both files missing');
    Check(Pos('计算机：文件未找到',F.StateLabel.Caption)>0);
    Check(Pos('用户：文件未找到',F.StateLabel.Caption)>0);
    V.GptVersion:=4; V.MachineStatus:=grsOk; V.UserStatus:=grsOk;
    F.ShowSnapshot(V); Check(Pos('文件存在，0 条',F.StateLabel.Caption)>0);
    V.UserStatus:=grsAccessDenied; F.ShowSnapshot(V);
    Check(Pos('访问被拒绝',F.StateLabel.Caption)>0);
    V.GptStatus:=grsCancelled; V.MachineStatus:=grsCancelled; V.UserStatus:=grsCancelled;
    F.ShowSnapshot(V); Check(Pos('已取消，可以重新加载',F.StateLabel.Caption)>0);
    V.GptStatus:=grsTimedOut; V.MachineStatus:=grsTimedOut; V.UserStatus:=grsTimedOut;
    F.ShowSnapshot(V); Check(Pos('已超时，可以重新加载',F.StateLabel.Caption)>0);
    V.GptStatus:=grsOk; V.MachineStatus:=grsOk; SetLength(V.MachineRecords,1);
    V.MachineRecords[0].Key:='Key'; V.MachineRecords[0].ValueType:=4;
    F.ShowSnapshot(V); D:=F.ComputerPane.RecordDetails(0);
    Check(Pos('默认值 / 无名称',D)>0); Check(Pos('REG_DWORD',D)>0); Check(Pos('4',D)>0);
    Check(Assigned(F.ComputerPane.ViewButton.OnClick)); Check(Assigned(F.ComputerRows.OnKeyDown));
  finally F.Free; end;
end;
procedure TUnitTestGpoSettings.CancelPollStates;
var F:TTestGpoFrame; Client:TLdapSessionProbe; V:TGpoSettingsSnapshot; Job:IGpoSettingsRead;
begin
  Client:=TLdapSessionProbe.Create; F:=TTestGpoFrame.Create(nil);
  try
    V:=Default(TGpoSettingsSnapshot); V.SessionToken:=Client.SessionToken;
    F.TestToken:=V.SessionToken; Job:=GpoCreateSettingsRead(V);
    F.TestAttachRead(Job); Job.Cancel; F.PollNow;
    Check(Pos('等待系统',F.StateLabel.Caption)>0,'Cancelled job still waiting for worker');
    Job.Execute; Check(Job.Finished); F.PollNow;
    Check(Pos('已取消，可以重新加载',F.StateLabel.Caption)>0,'Finished cancelled job must be explicit');
    Check(not F.CancelButton.Enabled);
  finally F.Free; Job:=nil; Client.Free; end;
end;
end.
