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
    procedure CombinedSnapshotStates;
    procedure CancelPollStates;
    procedure BaselineJobLifecycle;
    procedure DomainDraftJobLifecycle;
    procedure HeaderUsesSystemColors;
  end;
implementation
uses Classes, SyncObjs, SysUtils, ugpoformats, ugposysvol, ufrmpropertygposettings, uproperty,
  mormot.net.ldap, mormot.net.sock
  {$IFDEF WINDOWS}, Windows, CommCtrl, Graphics, Forms{$ENDIF};
type
  TTestGpoFrame = class(TFrmPropertyGpoSettings)
  public
    TestToken:IInterface;
    procedure TestAttachRead(const Job: IGpoSettingsRead);
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
