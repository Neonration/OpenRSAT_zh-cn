unit ufrmpropertygposettings;

{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls, ExtCtrls,
  upropertyframe, uproperty, ugpoformats, ugposysvol, ugpodiagnostic, mormot.net.ldap;

const
  GpoRegistryPageSize = 200;
  GpoMaxPendingReads = 2;

resourcestring
  SGpoStateError = '读取未完成或失败，请展开详情查看原因。';
  SGpoScope = 'Registry.pol 原始记录（只读）；非最终生效策略。';
  SGpoStateInitial = '尚未加载。点击“加载 / 刷新”读取只读快照。';
  SGpoStateLoading = '正在读取 Registry.pol 原始记录…';
  SGpoStateWaitingCancel = '已请求取消，正在等待系统读取返回。';
  SGpoStateWaitingTimeout = '读取已超时，正在等待系统调用返回。';
  SGpoStateCancelled = '读取已取消，可以重新加载。';
  SGpoStateTimeout = '读取已超时，可以重新加载。';
  SGpoStateMismatch = '警告：GPC 与 GPT 版本不一致。';
  SGpoSideComputer = '计算机：';
  SGpoSideUser = '用户：';
  SGpoNoFile = '文件未找到（其他扩展仍可能有策略）';
  SGpoPresent = '文件存在，%d 条原始记录';
  SGpoViewRecord = '查看记录…';
  SGpoNoName = '（默认值 / 无名称）';
  SGpoTypeNumber = '%s（%u）';

type
  TGpoRegistryPane = class(TPanel)
  private
    fRecords: TGpoRegistryRecords;
    fList: TListView;
    fSelect: TComboBox;
    fPrevious, fNext, fView: TButton;
    fRange: TLabel;
    fUpdating: Boolean;
    procedure PageChanged(Sender: TObject);
    procedure StepPage(Sender: TObject);
    procedure Render;
    procedure ResizeColumns(Sender:TObject);
    procedure DetailClick(Sender: TObject);
    procedure DetailKey(Sender: TObject; var Key: Word; Shift:TShiftState);
    procedure RowsSelected(Sender:TObject; Item:TListItem; Selected:Boolean);
  public
    constructor Create(TheOwner: TComponent); override;
    procedure Bind(const Records: TGpoRegistryRecords);
    procedure SelectPage(Page: Integer);
    function RecordDetails(Index: Integer): string;
    property Rows: TListView read fList;
    property PageSelector: TComboBox read fSelect;
    property ViewButton: TButton read fView;
    property PreviousButton: TButton read fPrevious;
    property NextButton: TButton read fNext;
    property RangeLabel: TLabel read fRange;
  end;

  TGpoSettingsSnapshot = record
    SessionToken: IInterface;
    Container: TGpoContainer;
    Domain, DC, Port, BoundUser: string;
    ObjectGuid: RawByteString;
    NeedsMetadata: Boolean;
    DisplayNamePresent: Boolean;
    MetadataStatus: TGpoReadStatus;
    MetadataError: string;
    GptVersion: Cardinal;
    GptStatus, MachineStatus, UserStatus: TGpoReadStatus;
    MachineRecords, UserRecords: TGpoRegistryRecords;
  end;
  // Injectable read-only transport for deterministic blocked-I/O tests.
  // The normal UI always uses the guarded SYSVOL reader (nil transport).
  IGpoSettingsTransport = interface
    ['{11C98BD0-264D-463F-B301-BF2E0B8D001E}']
    function Read(const Container: TGpoContainer; const Domain, DC: string;
      Artifact: TGpoFile; out Data: TBytes): TGpoReadStatus;
  end;
  IGpoSettingsMetadataTransport = interface
    ['{8BD81EC1-7EB6-4BA7-9E73-3D4E1A9D9E2F}']
    function Prepare(var Value:TGpoSettingsSnapshot; Control:TGpoReadControl):TGpoReadStatus;
  end;
  IGpoSettingsRead = interface
    ['{4E0CCB3C-9EC9-4C28-8D53-A22C229A95FD}']
    procedure Execute;
    procedure Cancel;
    function ReadStatus: TGpoReadStatus;
    function AcceptsSession(const Token: IInterface): Boolean;
    function Finished: Boolean;
    function Snapshot: TGpoSettingsSnapshot;
  end;
  TGpoBaselineRequest = record
    SessionToken:IInterface;
    DC,Port,DN,Guid,User:string;
    ObjectGuid:TBytes;
  end;
  IGpoBaselineTransport = interface
    ['{EBEB5A4F-166D-4BC9-8C6A-96D88A321D25}']
    function Check(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
  end;
  IGpoBaselineJob = interface
    ['{EEB7F8F1-C942-4A68-B514-E00FEF58393C}']
    procedure Execute;
    procedure Cancel;
    function Finished:Boolean;
    function ReadStatus:TGpoReadStatus;
    function AcceptsSession(const Token:IInterface):Boolean;
    function ResultText:string;
  end;
  TGpoDomainDraftState = (gddsLoading,gddsReady,gddsChecking,gddsResult,gddsStopped);
  IGpoDomainDraftBackend = interface
    ['{45AC1D9D-A2C7-49D2-AE43-931E5EF5D3BC}']
    function Open(const Request:TGpoBaselineRequest; Control:TGpoReadControl; out User,Machine:TGpoPolicyImage):Boolean;
    function Check(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl):TGpoPreflightResult;
  end;
  IGpoDomainDiagnosticBackend = interface
    ['{B97675AE-1876-4211-B663-626A86E8707D}']
    function Diagnose(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl;
      out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
  end;
  IGpoDomainDraftJob = interface
    ['{F838258C-8D43-44D8-9EB0-1EDB471EAC1A}']
    procedure Execute;
    procedure Cancel;
    function State:TGpoDomainDraftState;
    function Initial(out User,Machine:TGpoPolicyImage):Boolean;
    function Submit(const User,Machine:TGpoPolicyImage):Boolean;
    function ResultText:string;
  end;

  TFrmPropertyGpoSettings = class(TPropertyFrame)
  private
    fProperty: TProperty;
    fSummary: TMemo;
    fState: TLabel;
    fDetails: TButton;
    fLoad, fCancel, fBaseline, fDomainDraft: TButton;
    fPages: TPageControl;
    fMachine, fUser: TListView;
    fComputerPane, fUserPane: TGpoRegistryPane;
    fTimer, fBaselineTimer, fDomainDraftTimer: TTimer;
  protected
    fJob: IGpoSettingsRead;
    fBaselineJob:IGpoBaselineJob;
    fDomainDraftJob:IGpoDomainDraftJob;
    procedure Poll(Sender: TObject);
    procedure PollBaseline(Sender:TObject);
    procedure PollDomainDraft(Sender:TObject);
    function CurrentSessionToken: IInterface; virtual;
  private
    fClient, fSocket: TObject;
    fSessionToken: IInterface;
    fTarget, fDN, fGuid, fBoundUser, fPort, fServer, fDomain: string;
    fObjectGuid:RawByteString;
    fDomainDraftWindowOpen:Boolean;
    fDomainDraftStarted:QWord;
    function SameConnection: Boolean;
    function CanCheckBaseline:Boolean;
    procedure SetSummary(const Value:string; const State:string = '');
    procedure ToggleDetails(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure BaselineClick(Sender:TObject);
    procedure DomainDraftClick(Sender:TObject);
    procedure LoadSettings;
    procedure ClearRows;
    function NewList(const Title: string; out Pane: TGpoRegistryPane): TListView;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure Update(Props: TProperty); override;
    procedure ShowSnapshot(const Value: TGpoSettingsSnapshot);
    property Summary: TMemo read fSummary;
    property StateLabel: TLabel read fState;
    property DetailsButton: TButton read fDetails;
    property ComputerRows: TListView read fMachine;
    property UserRows: TListView read fUser;
    property ComputerPane: TGpoRegistryPane read fComputerPane;
    property UserPane: TGpoRegistryPane read fUserPane;
    property LoadButton: TButton read fLoad;
    property CancelButton: TButton read fCancel;
    property BaselineButton:TButton read fBaseline;
    property DomainDraftButton:TButton read fDomainDraft;
  end;

// Returns nil while two previous jobs still own their OS resources.
function GpoCreateSettingsRead(const Value: TGpoSettingsSnapshot;
  const Transport: IGpoSettingsTransport = nil): IGpoSettingsRead;
function GpoCreateBaselineJob(const Request:TGpoBaselineRequest;
  const Transport:IGpoBaselineTransport=nil):IGpoBaselineJob;
function GpoCreateDomainDraftJob(const Request:TGpoBaselineRequest;
  const Backend:IGpoDomainDraftBackend=nil):IGpoDomainDraftJob;
function GpoLdapFailureText(ResultCode: Integer): string;
function GpoDiagnosticReportText(const Report:TGpoDiagnosticReport):string;
function GpoMatchesSelectedObject(Entry:TLdapResult; const DN,Guid:string; const ObjectGuid:RawByteString):Boolean;
function GpoSupportsBackgroundSettings(BoundAs:TLdapClientBound; Password,UsesTls:Boolean):Boolean;
function GpoBackgroundSettingsRestriction(BoundAs:TLdapClientBound; Password,UsesTls:Boolean):string;

implementation

uses Dialogs, SyncObjs, ufrmgpoofflinedraft
  {$IFDEF WINDOWS}, Windows, CommCtrl{$ENDIF};

{$R *.lfm}

resourcestring
  SGpoSettingsCaption = 'Registry.pol 原始记录（只读）';
  SGpoSettingsLoad = '加载 / 刷新';
  SGpoComputer = '计算机配置';
  SGpoUser = '用户配置';
  SGpoMissingRegistry = '未找到 Registry.pol；其他扩展仍可能包含策略';
  SGpoUnknownType = '未知类型 (%u)';

type
  {$IFDEF WINDOWS}
  TGpoListView = class(TListView)
  protected
    procedure CreateWnd; override;
  end;
  {$ENDIF}
  TGpoSettingsRead = class(TInterfacedObject, IGpoSettingsRead)
  private
    fValue: TGpoSettingsSnapshot;
    fDone: LongInt;
    fControl: TGpoReadControl;
    fTransport: IGpoSettingsTransport;
    fSlot: Boolean;
    fCompletedStatus: TGpoReadStatus;
    procedure ReleaseSlot;
  public
    constructor Create(const Value: TGpoSettingsSnapshot;
      const Transport: IGpoSettingsTransport);
    destructor Destroy; override;
    procedure Execute;
    procedure Cancel;
    function ReadStatus: TGpoReadStatus;
    function AcceptsSession(const Token: IInterface): Boolean;
    function Finished: Boolean;
    function Snapshot: TGpoSettingsSnapshot;
  end;
  TGpoReadThread = class(TThread)
  private
    fJob: IGpoSettingsRead;
  protected
    procedure Execute; override;
  public
    constructor Create(const Job: IGpoSettingsRead);
  end;
  TGpoBaselineJob = class(TInterfacedObject,IGpoBaselineJob)
  private
    fRequest:TGpoBaselineRequest;
    fControl:TGpoReadControl;
    fTransport:IGpoBaselineTransport;
    fDone:LongInt;
    fSlot:Boolean;
    fText:string;
  public
    constructor Create(const Request:TGpoBaselineRequest; const Transport:IGpoBaselineTransport);
    destructor Destroy; override;
    procedure Execute;
    procedure Cancel;
    function Finished:Boolean;
    function ReadStatus:TGpoReadStatus;
    function AcceptsSession(const Token:IInterface):Boolean;
    function ResultText:string;
  end;
  TGpoBaselineThread = class(TThread)
  private fJob:IGpoBaselineJob;
  protected procedure Execute; override;
  public constructor Create(const Job:IGpoBaselineJob);
  end;
  TGpoDomainBackend = class(TInterfacedObject,IGpoDomainDraftBackend,IGpoDomainDiagnosticBackend)
  private
    fClient:TLdapClient;
    fDraft:TGpoObservedDraft;
    fDN,fGuid:string;
  public
    destructor Destroy; override;
    function Open(const Request:TGpoBaselineRequest; Control:TGpoReadControl; out User,Machine:TGpoPolicyImage):Boolean;
    function Check(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl):TGpoPreflightResult;
    function Diagnose(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl;
      out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
  end;
  TGpoDomainDraftJob = class(TInterfacedObject,IGpoDomainDraftJob)
  private
    fRequest:TGpoBaselineRequest;
    fSource:ILdapSessionToken;
    fBackend:IGpoDomainDraftBackend;
    fLock:SyncObjs.TCriticalSection;
    fWake:SyncObjs.TEvent;
    fControl:TGpoReadControl;
    fState:TGpoDomainDraftState;
    fCancelled:LongInt;
    fSlot:Boolean;
    fUser,fMachine,fNewUser,fNewMachine:TGpoPolicyImage;
    fResult:string;
    function Active:Boolean;
    function BeginOperation:TGpoReadControl;
    procedure EndOperation;
  public
    constructor Create(const Request:TGpoBaselineRequest; const Backend:IGpoDomainDraftBackend);
    destructor Destroy; override;
    procedure Execute;
    procedure Cancel;
    function State:TGpoDomainDraftState;
    function Initial(out User,Machine:TGpoPolicyImage):Boolean;
    function Submit(const User,Machine:TGpoPolicyImage):Boolean;
    function ResultText:string;
  end;
  TGpoDomainDraftThread = class(TThread)
  private fJob:IGpoDomainDraftJob;
  protected procedure Execute; override;
  public constructor Create(const Job:IGpoDomainDraftJob);
  end;

var
  GpoPendingReads: LongInt;

function GpoDiagnosticReportText(const Report:TGpoDiagnosticReport):string;
const Names:array[TGpoDiagnosticResource] of string=('计算机 Registry.pol','用户 Registry.pol','GPT.INI',
  'GPC 版本','GPC 标志','计算机扩展','用户扩展','LDAP 安全描述符','LDAP USN',
  '计算机文件元数据','用户文件元数据','GPT.INI 元数据');
  States:array[TGpoDiagnosticState] of string=('未采集','不可读','确认缺失','有值');
  Matches:array[TGpoDiagnosticMatch] of string=('不完整','基线','候选','两者一致','其他值（冲突）');
var R:TGpoDiagnosticResource;
begin
  if Report.Summary=gduIncomplete then Result:='逐项诊断：信息不完整。' else Result:='逐项诊断：可比较的证据已列出。';
  if Report.HasOther then Result:=Result+' 发现其他值冲突。';
  Result:=Result+LineEnding;
  for R:=Low(R) to High(R) do begin
    Result:=Result+Names[R]+'：基线='+States[Report.Items[R].Baseline.State]+
    '；候选='+States[Report.Items[R].Candidate.State]+'；观察='+States[Report.Items[R].Observed.State]+
    '；比较='+Matches[Report.Items[R].Match];
    if Report.Items[R].ObservedDiffersFromBaseline then
      Result:=Result+'；观察与基线不同（不代表写入结果）';
    Result:=Result+LineEnding;
  end;
  Result:=Result+'匹配仅表示采集时状态及字节相符，不证明内容有效、操作成功、执行者或持久化；不授权重试、回滚或写入。';
end;

destructor TGpoDomainBackend.Destroy;
begin fDraft.Free; fClient.Free; inherited Destroy; end;
function TGpoDomainBackend.Open(const Request:TGpoBaselineRequest; Control:TGpoReadControl; out User,Machine:TGpoPolicyImage):Boolean;
var R:TGpoPreflightResult;
begin
  Result:=False; User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
  fClient:=TLdapClient.Create; fDN:=Request.DN; fGuid:=Request.Guid;
  fClient.Settings.TargetHost:=Request.DC; fClient.Settings.TargetPort:=Request.Port;
  fClient.Settings.AutoReconnect:=False; fClient.Settings.AutoBind:=lcbNone;
  fClient.Settings.KerberosSignSeal:=lksForced;
  if (Control.Status<>grsOk) or not fClient.Connect([lccNoDiscovery],0) or (Control.Status<>grsOk) or not fClient.BindSaslKerberos or
    (fClient.Transmission<>lctEncrypted) or not SameText(fClient.BoundUser,Request.User) then Exit;
  if Control.Status<>grsOk then Exit;
  R:=GpoCaptureObservedDraft(fClient,fDN,fGuid,fDraft,Control);
  Result:=(R=gprEvidenceIncomplete) and Assigned(fDraft) and
    (Control.Status=grsOk) and fDraft.MatchesObjectGuid(Request.ObjectGuid) and fDraft.GetBaseline(User,Machine);
end;
function TGpoDomainBackend.Check(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl):TGpoPreflightResult;
var Bound:TGpoBoundPlan;
begin
  Bound:=nil;
  try
    Result:=GpoBindObservedDraftPlan(fClient,fDN,fGuid,fDraft,User,Machine,Bound,Control);
    if (Result=gprEvidenceIncomplete) and not Assigned(Bound) then Result:=gprReadUnavailable;
  finally Bound.Free; end;
end;
function TGpoDomainBackend.Diagnose(const User,Machine:TGpoPolicyImage; Control:TGpoReadControl;
  out Report:TGpoDiagnosticReport):TGpoDiagnosticStatus;
begin Result:=GpoDiagnoseObservedDraft(fClient,fDN,fGuid,fDraft,User,Machine,Control,Report); end;
constructor TGpoDomainDraftJob.Create(const Request:TGpoBaselineRequest; const Backend:IGpoDomainDraftBackend);
begin
  inherited Create; fRequest:=Request; fRequest.ObjectGuid:=Copy(Request.ObjectGuid);
  Supports(Request.SessionToken,ILdapSessionToken,fSource); fBackend:=Backend;
  fLock:=SyncObjs.TCriticalSection.Create; fWake:=SyncObjs.TEvent.Create(nil,False,False,''); fSlot:=True;
end;
destructor TGpoDomainDraftJob.Destroy;
begin
  if fSlot then InterlockedDecrement(GpoPendingReads);
  fControl.Free; fWake.Free; fLock.Free; inherited Destroy;
end;
function TGpoDomainDraftJob.Active:Boolean;
begin Result:=(InterlockedCompareExchange(fCancelled,0,0)=0) and Assigned(fSource) and fSource.IsValid; end;
procedure TGpoDomainDraftJob.Cancel;
begin
  InterlockedExchange(fCancelled,1);
  fLock.Acquire; try if Assigned(fControl) then fControl.Cancel; finally fLock.Release; end;
  fWake.SetEvent;
end;
function TGpoDomainDraftJob.BeginOperation:TGpoReadControl;
begin
  Result:=nil; fLock.Acquire;
  try if Active then begin fControl:=TGpoReadControl.Create(30000,fSource); Result:=fControl; end;
  finally fLock.Release; end;
end;
procedure TGpoDomainDraftJob.EndOperation;
begin fLock.Acquire; try FreeAndNil(fControl); finally fLock.Release; end; end;
function TGpoDomainDraftJob.State:TGpoDomainDraftState;
begin
  if not Active then Exit(gddsStopped);
  fLock.Acquire; try Result:=fState; finally fLock.Release; end;
end;
function TGpoDomainDraftJob.Initial(out User,Machine:TGpoPolicyImage):Boolean;
begin
  User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage); Result:=False;
  if not Active then Exit;
  fLock.Acquire;
  try
    if fState<>gddsReady then Exit;
    User.Exists:=fUser.Exists; User.Data:=Copy(fUser.Data);
    Machine.Exists:=fMachine.Exists; Machine.Data:=Copy(fMachine.Data);
    Result:=Active;
    if not Result then begin User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage); end;
  finally fLock.Release; end;
end;
function TGpoDomainDraftJob.Submit(const User,Machine:TGpoPolicyImage):Boolean;
begin
  Result:=False;
  if not Active or (Length(User.Data)>GpoMaxFileBytes) or (Length(Machine.Data)>GpoMaxFileBytes) then Exit;
  fLock.Acquire;
  try
    if not Active or not (fState in [gddsReady,gddsResult]) then Exit;
    fNewUser.Exists:=User.Exists; fNewUser.Data:=Copy(User.Data);
    fNewMachine.Exists:=Machine.Exists; fNewMachine.Data:=Copy(Machine.Data);
    fResult:=''; fState:=gddsChecking; Result:=True;
  finally fLock.Release; end;
  if Result then fWake.SetEvent;
end;
function TGpoDomainDraftJob.ResultText:string;
begin
  if not Active then Exit('域会话已失效；草稿仍可导出，不能继续域检查。');
  fLock.Acquire; try Result:=fResult; finally fLock.Release; end;
end;
procedure TGpoDomainDraftJob.Execute;
var U,M:TGpoPolicyImage; R:TGpoPreflightResult; Work,Ok:Boolean; Control:TGpoReadControl;
  Diagnostics:IGpoDomainDiagnosticBackend; DStatus:TGpoDiagnosticStatus; Report:TGpoDiagnosticReport; DiagnosticText:string;
begin
  try
    try
      if not Active then Exit;
      if not Assigned(fBackend) then fBackend:=TGpoDomainBackend.Create;
      Control:=BeginOperation; if not Assigned(Control) then Exit;
      try Ok:=fBackend.Open(fRequest,Control,U,M) and (Control.Status=grsOk); finally EndOperation; end;
      if not Ok or not Active then Exit;
      fLock.Acquire;
      try fUser:=U; fMachine:=M; fState:=gddsReady; finally fLock.Release; end;
      while Active do
      begin
        fWake.WaitFor(200);
        if not Active then Break;
        fLock.Acquire;
        try Work:=fState=gddsChecking; if Work then begin U:=fNewUser; M:=fNewMachine; end;
        finally fLock.Release; end;
        if not Work then Continue;
        Control:=BeginOperation; if not Assigned(Control) then Break;
        Diagnostics:=nil; DiagnosticText:='';
        try
          if Supports(fBackend,IGpoDomainDiagnosticBackend,Diagnostics) then begin
            try
              DStatus:=Diagnostics.Diagnose(U,M,Control,Report);
              if DStatus=gdtOk then DiagnosticText:=GpoDiagnosticReportText(Report)
              else if DStatus=gdtTargetMismatch then DiagnosticText:='域控或目标身份已变化；本次检查阻断，草稿保留。'
              else if DStatus=gdtChangedDuringCapture then DiagnosticText:='采集期间 LDAP 状态已变化；本次结果已丢弃。'
              else DiagnosticText:='只读复核未完成，证据不足或会话失效；草稿保留。';
            finally Report:=Default(TGpoDiagnosticReport); end;
          end else R:=fBackend.Check(U,M,Control);
          Ok:=Control.Status=grsOk;
        finally EndOperation; end;
        if not Ok then begin Cancel; Break; end;
        if not Active then Break;
        fLock.Acquire;
        try
          if Assigned(Diagnostics) then fResult:=DiagnosticText
          else if R=gprEvidenceIncomplete then fResult:='候选计划与原域基线的只读复核一致；安全证据仍不完整，不能授权写入。'
          else if R=gprConflict then fResult:='域基线已变化；本次检查阻断，草稿保留，可导出后重新采集。'
          else if R=gprTargetMismatch then fResult:='域控或目标身份已变化；本次检查阻断，草稿保留。'
          else fResult:='只读复核未完成，证据不足或会话失效；草稿保留。';
          fState:=gddsResult;
        finally fLock.Release; end;
      end;
    except
      fLock.Acquire; try fResult:='后台只读检查失败；草稿保留。'; finally fLock.Release; end;
    end;
  finally
    fBackend:=nil;
    fLock.Acquire; try fState:=gddsStopped; finally fLock.Release; end;
    if fSlot then begin fSlot:=False; InterlockedDecrement(GpoPendingReads); end;
  end;
end;
constructor TGpoDomainDraftThread.Create(const Job:IGpoDomainDraftJob);
begin inherited Create(True); FreeOnTerminate:=True; fJob:=Job; Start; end;
procedure TGpoDomainDraftThread.Execute; begin fJob.Execute; end;
function GpoCreateDomainDraftJob(const Request:TGpoBaselineRequest;
  const Backend:IGpoDomainDraftBackend):IGpoDomainDraftJob;
var Token:ILdapSessionToken;
begin
  Result:=nil;
  if not Assigned(Request.SessionToken) or not Supports(Request.SessionToken,ILdapSessionToken,Token) or not Token.IsValid then Exit;
  if InterlockedIncrement(GpoPendingReads)>GpoMaxPendingReads then
  begin InterlockedDecrement(GpoPendingReads); Exit; end;
  try Result:=TGpoDomainDraftJob.Create(Request,Backend);
  except InterlockedDecrement(GpoPendingReads); raise; end;
end;

function CheckBaseline(const Request:TGpoBaselineRequest; Control:TGpoReadControl):string;
var Client:TLdapClient; Draft:TGpoObservedDraft; Bound:TGpoBoundPlan;
  User,Machine:TGpoPolicyImage; R:TGpoPreflightResult;
begin
  Result:='只读检查未完成：无法验证独立连接、目标或所需证据。';
  if Control.Status<>grsOk then Exit;
  Client:=TLdapClient.Create; Draft:=nil; Bound:=nil;
  try
    Client.Settings.TargetHost:=Request.DC; Client.Settings.TargetPort:=Request.Port;
    Client.Settings.AutoReconnect:=False; Client.Settings.AutoBind:=lcbNone;
    Client.Settings.KerberosSignSeal:=lksForced;
    if not Client.Connect([lccNoDiscovery],0) or (Control.Status<>grsOk) or
      not Client.BindSaslKerberos or (Client.Transmission<>lctEncrypted) or
      not SameText(Client.BoundUser,Request.User) or (Control.Status<>grsOk) then Exit;
    R:=GpoCaptureObservedDraft(Client,Request.DN,Request.Guid,Draft,Control);
    if (R<>gprEvidenceIncomplete) or not Assigned(Draft) or (Control.Status<>grsOk) then Exit;
    if not Draft.MatchesObjectGuid(Request.ObjectGuid) then
    begin Result:='只读检查已阻断：当前对象标识与打开属性时不同。'; Exit; end;
    if not Draft.GetBaseline(User,Machine) then Exit;
    R:=GpoBindObservedDraftPlan(Client,Request.DN,Request.Guid,Draft,User,Machine,Bound,Control);
    if Control.Status<>grsOk then Exit;
    if (R=gprEvidenceIncomplete) and Assigned(Bound) then
      Result:='当前 GPO 的双侧基线在两次只读采集中一致；安全证据仍不完整，不能授权写入。'+LineEnding+
        '已比较 LDAP 返回的双侧扩展属性原值；未返回可能是不存在或不可见。没有检查本地草稿、扩展具体内容或复制，也没有修改域。'
    else if R=gprConflict then Result:='只读检查已阻断：采集期间基线发生变化，请重新检查。'
    else if R=gprTargetMismatch then Result:='只读检查已阻断：域控制器或目标身份不一致。';
  finally Bound.Free; Draft.Free; Client.Free; end;
end;

constructor TGpoBaselineJob.Create(const Request:TGpoBaselineRequest; const Transport:IGpoBaselineTransport);
begin
  inherited Create; fRequest:=Request; fRequest.ObjectGuid:=Copy(Request.ObjectGuid);
  fControl:=TGpoReadControl.Create(30000,Request.SessionToken); fTransport:=Transport; fSlot:=True;
end;
destructor TGpoBaselineJob.Destroy;
begin
  if fSlot then InterlockedDecrement(GpoPendingReads);
  fControl.Free; inherited Destroy;
end;
procedure TGpoBaselineJob.Execute;
begin
  try
    try
      if fControl.Status=grsOk then
        if Assigned(fTransport) then fText:=fTransport.Check(fRequest,fControl)
        else fText:=CheckBaseline(fRequest,fControl);
    except fText:='只读检查失败，请检查连接后重试。'; end;
  finally
    if fSlot then begin fSlot:=False; InterlockedDecrement(GpoPendingReads); end;
    InterlockedExchange(fDone,1);
  end;
end;
procedure TGpoBaselineJob.Cancel; begin fControl.Cancel; end;
function TGpoBaselineJob.Finished:Boolean; begin Result:=InterlockedCompareExchange(fDone,0,0)<>0; end;
function TGpoBaselineJob.ReadStatus:TGpoReadStatus; begin Result:=fControl.Status; end;
function TGpoBaselineJob.AcceptsSession(const Token:IInterface):Boolean;
begin Result:=Assigned(Token) and (Token=fRequest.SessionToken) and (fControl.Status=grsOk); end;
function TGpoBaselineJob.ResultText:string;
begin if Finished and (fControl.Status=grsOk) then Result:=fText else Result:=''; end;
constructor TGpoBaselineThread.Create(const Job:IGpoBaselineJob);
begin inherited Create(True); FreeOnTerminate:=True; fJob:=Job; Start; end;
procedure TGpoBaselineThread.Execute; begin fJob.Execute; end;

function GpoCreateBaselineJob(const Request:TGpoBaselineRequest;
  const Transport:IGpoBaselineTransport):IGpoBaselineJob;
begin
  Result:=nil;
  if not Assigned(Request.SessionToken) then Exit;
  if InterlockedIncrement(GpoPendingReads)>GpoMaxPendingReads then
  begin InterlockedDecrement(GpoPendingReads); Exit; end;
  try Result:=TGpoBaselineJob.Create(Request,Transport);
  except InterlockedDecrement(GpoPendingReads); raise; end;
end;

{$IFDEF WINDOWS}
function GpoHeaderDraw(Window: HWND; Msg: UINT; WParam: Windows.WPARAM;
  LParam: Windows.LPARAM; Id: UINT_PTR; Data: DWORD_PTR): LRESULT; stdcall;
var
  Draw: PNMCustomDraw;
  View: TGpoListView;
  R, ItemRect: Windows.TRect;
  Caption: UnicodeString;
  Saved, I: Integer;
begin
  if (Msg = WM_NOTIFY) and (LParam <> 0) then
  begin
    Draw := PNMCustomDraw(LParam);
    if (Draw^.hdr.hwndFrom = ListView_GetHeader(Window)) and
       (LongInt(Draw^.hdr.code) = NM_CUSTOMDRAW) then
      case Draw^.dwDrawStage of
        CDDS_PREPAINT: Exit(CDRF_NOTIFYITEMDRAW or CDRF_NOTIFYPOSTPAINT);
        CDDS_ITEMPREPAINT:
        begin
          View := TGpoListView(Pointer(Data));
          if Draw^.dwItemSpec < DWORD_PTR(View.Columns.Count) then
          begin
            R := Draw^.rc;
            Saved := SaveDC(Draw^.hdc);
            FillRect(Draw^.hdc, R, GetSysColorBrush(COLOR_BTNFACE));
            SetTextColor(Draw^.hdc, GetSysColor(COLOR_BTNTEXT));
            SetBkMode(Draw^.hdc, TRANSPARENT);
            InflateRect(R, -5, 0);
            Caption := UTF8Decode(View.Columns[Draw^.dwItemSpec].Caption);
            DrawTextW(Draw^.hdc, PWideChar(Caption), Length(Caption), R,
              DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
            RestoreDC(Draw^.hdc, Saved);
            Exit(CDRF_SKIPDEFAULT);
          end;
        end;
        CDDS_POSTPAINT:
        begin
          Saved := SaveDC(Draw^.hdc);
          if Saved <> 0 then
          begin
            Windows.GetClientRect(Draw^.hdr.hwndFrom, R);
            for I := 0 to Header_GetItemCount(Draw^.hdr.hwndFrom) - 1 do
              if Header_GetItemRect(Draw^.hdr.hwndFrom, I, Windows.LPARAM(@ItemRect)) then
                ExcludeClipRect(Draw^.hdc, ItemRect.Left, ItemRect.Top,
                  ItemRect.Right, ItemRect.Bottom);
            FillRect(Draw^.hdc, R, GetSysColorBrush(COLOR_BTNFACE));
            RestoreDC(Draw^.hdc, Saved);
          end;
          Exit(CDRF_DODEFAULT);
        end;
      end;
  end;
  Result := DefSubclassProc(Window, Msg, WParam, LParam);
end;

procedure TGpoListView.CreateWnd;
begin
  inherited CreateWnd;
  SetWindowSubclass(Handle, @GpoHeaderDraw, 1, DWORD_PTR(Self));
end;
{$ENDIF}

function GpoCreateSettingsRead(const Value: TGpoSettingsSnapshot;
  const Transport: IGpoSettingsTransport): IGpoSettingsRead;
var Job: TGpoSettingsRead;
begin
  Result := nil;
  if InterlockedIncrement(GpoPendingReads) > GpoMaxPendingReads then
  begin InterlockedDecrement(GpoPendingReads); Exit; end;
  try
    Job := TGpoSettingsRead.Create(Value, Transport);
  except
    InterlockedDecrement(GpoPendingReads);
    raise;
  end;
  Job.fSlot := True;
  Result := Job;
end;

  function RegistryType(ValueType: Cardinal): string;
  begin
    case ValueType of
      0: Result := 'REG_NONE';
      1: Result := 'REG_SZ';
      2: Result := 'REG_EXPAND_SZ';
      3: Result := 'REG_BINARY';
      4: Result := 'REG_DWORD';
      5: Result := 'REG_DWORD_BIG_ENDIAN';
      6: Result := 'REG_LINK';
      7: Result := 'REG_MULTI_SZ';
      8: Result := 'REG_RESOURCE_LIST';
      9: Result := 'REG_FULL_RESOURCE_DESCRIPTOR';
      10: Result := 'REG_RESOURCE_REQUIREMENTS_LIST';
      11: Result := 'REG_QWORD';
      else Result := Format(SGpoUnknownType, [ValueType]);
    end;
  end;

constructor TGpoRegistryPane.Create(TheOwner: TComponent);
var Bar: TPanel;
  procedure Column(const Title: string; AWidth: Integer);
  begin with fList.Columns.Add do begin Caption := Title; Width := AWidth; end; end;
begin
  inherited Create(TheOwner);
  BevelOuter := bvNone;
  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alBottom;
  Bar.Height := 32;
  Bar.BevelOuter := bvNone;
  fPrevious := TButton.Create(Self);
  fPrevious.Parent := Bar;
  fPrevious.Align := alLeft;
  fPrevious.Width := 75;
  fPrevious.Caption := '上一页';
  fPrevious.Tag := -1;
  fPrevious.OnClick := @StepPage;
  fSelect := TComboBox.Create(Self);
  fSelect.Parent := Bar;
  fSelect.Align := alLeft;
  fSelect.Width := 100;
  fSelect.Left := 75;
  fSelect.Style := csDropDownList;
  fSelect.Hint := '每页 200 条记录';
  fSelect.ShowHint := True;
  fSelect.OnChange := @PageChanged;
  fNext := TButton.Create(Self);
  fNext.Parent := Bar;
  fNext.Align := alLeft;
  fNext.Width := 65;
  fNext.Left := 175;
  fNext.Caption := '下一页';
  fNext.Tag := 1;
  fNext.OnClick := @StepPage;
  fView:=TButton.Create(Self); fView.Parent:=Bar; fView.Align:=alRight;
  fView.Width:=100; fView.Caption:=SGpoViewRecord; fView.OnClick:=@DetailClick; fView.Enabled:=False;
  fRange := TLabel.Create(Self);
  fRange.Parent := Bar;
  fRange.Align := alClient;
  fRange.Layout := tlCenter;
  {$IFDEF WINDOWS}fList := TGpoListView.Create(Self);{$ELSE}fList := TListView.Create(Self);{$ENDIF}
  fList.Parent := Self;
  fList.Align := alClient;
  fList.ViewStyle := vsReport;
  fList.ReadOnly := True;
  fList.RowSelect := True;
  fList.OnDblClick := @DetailClick;
  fList.OnKeyDown := @DetailKey;
  fList.OnSelectItem := @RowsSelected;

  fList.ShowHint := True;
  fList.Hint := '双击记录查看完整路径和值';
  Column('注册表键路径', 300);
  Column('值名称', 160);
  Column('类型', 130);
  Column('数据（十六进制预览）', 260);
  fList.OnResize:=@ResizeColumns; ResizeColumns(nil);
  Bind(nil);
end;

procedure TGpoRegistryPane.ResizeColumns(Sender:TObject);
var Available,KeyWidth,Total:Integer;
begin
  if fList.Columns.Count<4 then Exit;
  Available:=fList.ClientWidth-fList.Columns[1].Width-fList.Columns[2].Width-24;
  if Available<260 then Available:=260;
  Total:=fList.Columns[0].Width+fList.Columns[3].Width;
  if Total<=0 then Total:=1;
  KeyWidth:=Available*fList.Columns[0].Width div Total;
  if KeyWidth<140 then KeyWidth:=140;
  if KeyWidth>Available-120 then KeyWidth:=Available-120;
  fList.Columns[0].Width:=KeyWidth; fList.Columns[3].Width:=Available-KeyWidth;
end;
procedure TGpoRegistryPane.Bind(const Records: TGpoRegistryRecords);
var I, Count: Integer;
begin
  fUpdating := True;
  try
    fRecords := Records;
    fSelect.Items.BeginUpdate;
    try
      fSelect.Items.Clear;
      Count := (Length(fRecords) + GpoRegistryPageSize - 1) div GpoRegistryPageSize;
      for I := 1 to Count do fSelect.Items.Add(Format('第 %d 页', [I]));
      if Count > 0 then fSelect.ItemIndex := 0 else fSelect.ItemIndex := -1;
    finally fSelect.Items.EndUpdate; end;
  finally fUpdating := False; end;
  Render;
end;

procedure TGpoRegistryPane.SelectPage(Page: Integer);
begin
  if Page < 0 then Page := 0;
  if Page >= fSelect.Items.Count then Page := fSelect.Items.Count - 1;
  fUpdating := True;
  try fSelect.ItemIndex := Page; finally fUpdating := False; end;
  Render;
end;

procedure TGpoRegistryPane.PageChanged(Sender: TObject);
begin if not fUpdating then Render; end;

procedure TGpoRegistryPane.StepPage(Sender: TObject);
begin SelectPage(fSelect.ItemIndex + TControl(Sender).Tag); end;

procedure TGpoRegistryPane.Render;
var I, J, N, First, Last: Integer; Item: TListItem; Hex: string;
begin
  First := fSelect.ItemIndex * GpoRegistryPageSize;
  Last := First + GpoRegistryPageSize - 1;
  if Last >= Length(fRecords) then Last := High(fRecords);
  fView.Enabled:=False;
  fList.Items.BeginUpdate;
  try
    fList.Items.Clear;
    if (First >= 0) and (First < Length(fRecords)) then
      for I := First to Last do
      begin
        Item := fList.Items.Add;
        Item.Caption := UTF8Encode(fRecords[I].Key);
        Item.SubItems.Add(UTF8Encode(fRecords[I].ValueName));
        Item.SubItems.Add(RegistryType(fRecords[I].ValueType));
        Hex := ''; N := Length(fRecords[I].Data);
        if N > 128 then N := 128;
        for J := 0 to N-1 do Hex := Hex + IntToHex(fRecords[I].Data[J], 2) + ' ';
        if Length(fRecords[I].Data) > N then Hex := Hex + '...';
        Item.SubItems.Add(Hex + ' (' + IntToStr(Length(fRecords[I].Data)) + ' 字节)');
      end;
  finally fList.Items.EndUpdate; end;
  if fList.Items.Count > 0 then
    fRange.Caption := Format('第 %d-%d 条，共 %d 条', [First+1, Last+1, Length(fRecords)])
  else fRange.Caption := '共 0 条';
  fSelect.Enabled := fSelect.Items.Count > 1;
  fPrevious.Enabled := fSelect.ItemIndex > 0;
  fNext.Enabled := (fSelect.ItemIndex >= 0) and (fSelect.ItemIndex < fSelect.Items.Count-1);
end;

function TypedRegistryValue(const R:TGpoRegistryRecord):string;
const PreviewLimit=4096;
var I,N,C,Next,Items:Integer; V:QWord; U:UnicodeString; Truncated:Boolean;
  function UnitAt(Index:Integer):Word;
  begin Result:=Word(R.Data[Index*2]) or (Word(R.Data[Index*2+1]) shl 8); end;
  procedure AppendUnit(Value:Word);
  begin
    if Length(U)>=PreviewLimit then begin Truncated:=True; Exit; end;
    case Value of
      9: U:=U+'\t';
      10: U:=U+'\n';
      13: U:=U+'\r';
      92: U:=U+'\\';
      else if Value<32 then U:=U+'\u'+UnicodeString(IntToHex(Value,4))
      else U:=U+WideChar(Value);
    end;
  end;
begin
  if Copy(R.ValueName,1,2)='**' then Exit('策略指令：仅显示原始数据，不执行。');
  case R.ValueType of
    4,5,11:
    begin
      if R.ValueType=11 then N:=8 else N:=4;
      if Length(R.Data)<>N then Exit('无效数据：整数长度不正确。');
      V:=0;
      if R.ValueType=5 then
        for I:=0 to N-1 do V:=(V shl 8) or R.Data[I]
      else
        for I:=N-1 downto 0 do V:=(V shl 8) or R.Data[I];
      Exit('数值：'+UIntToStr(V)+' (0x'+IntToHex(V,N*2)+')');
    end;
    1,2,7:
    begin
      if (Length(R.Data) and 1)<>0 then Exit('无效数据：UTF-16 字节数为奇数。');
      N:=Length(R.Data) div 2;
      if (R.ValueType=7) then begin
        if (N<2) or (UnitAt(N-1)<>0) or (UnitAt(N-2)<>0) then
          Exit('无效数据：MULTI_SZ 缺少双 NUL 终止符。');
      end else if (N<1) or (UnitAt(N-1)<>0) then
        Exit('无效数据：字符串缺少 NUL 终止符。');
      U:=''; Truncated:=False; I:=0; Items:=0;
      while I<N-1 do
      begin
        C:=UnitAt(I);
        if C=0 then
        begin
          if R.ValueType<>7 then Exit('无效数据：字符串包含嵌入 NUL。');
          if (I=0) and (N=2) then begin Inc(I); Break; end;
          if (I=0) or (I<>N-2) and (UnitAt(I+1)=0) then
            Exit('无效数据：MULTI_SZ 包含空项目或多余终止符。');
          if Length(U)<PreviewLimit then U:=U+LineEnding else Truncated:=True;
          Inc(Items); Inc(I); Continue;
        end;
        if (C >= $D800) and (C <= $DBFF) then
        begin
          if I+1>=N-1 then Exit('无效数据：UTF-16 代理项不完整。');
          Next:=UnitAt(I+1);
          if (Next<$DC00) or (Next>$DFFF) then Exit('无效数据：UTF-16 代理项无效。');
          if Length(U)+2<=PreviewLimit then begin U:=U+WideChar(C)+WideChar(Next); end
          else Truncated:=True;
          Inc(I,2); Continue;
        end;
        if (C >= $DC00) and (C <= $DFFF) then Exit('无效数据：UTF-16 代理项无效。');
        AppendUnit(C); Inc(I);
      end;
      if R.ValueType=7 then begin
        if (N>2) and (I<>N-1) then Exit('无效数据：MULTI_SZ 终止符无效。');
        Result:='项目数：'+IntToStr(Items)+LineEnding+UTF8Encode(U);
      end else begin
        Result:='文本：'+UTF8Encode(U);
        if R.ValueType=2 then Result:=Result+LineEnding+'环境变量未展开。';
      end;
      if Truncated then Result:=Result+LineEnding+'（文本预览已截断；下方保留完整原始数据。）';
    end;
    else Result:='此类型仅显示原始数据。';
  end;
end;

function TGpoRegistryPane.RecordDetails(Index: Integer): string;
const HexChars='0123456789ABCDEF';
var R:TGpoRegistryRecord; S:RawByteString; I,P:SizeInt;
begin
  Result:='';
  if (Index<0) or (Index>=Length(fRecords)) then Exit;
  R:=fRecords[Index];
  SetLength(S,Length(R.Data)*3); P:=1;
  for I:=0 to High(R.Data) do
  begin
    S[P]:=HexChars[(R.Data[I] shr 4)+1]; S[P+1]:=HexChars[(R.Data[I] and 15)+1];
    S[P+2]:=' '; Inc(P,3);
  end;
  if R.ValueName='' then R.ValueName:=UTF8Decode(SGpoNoName);
  Result:=UTF8Encode(UnicodeString('键路径：')+R.Key+LineEnding+
    UnicodeString('值名称：')+R.ValueName+LineEnding+UnicodeString('类型：')+
    UnicodeString(Format(SGpoTypeNumber,[RegistryType(R.ValueType),R.ValueType]))+LineEnding+UnicodeString('字节数：')+
    UnicodeString(IntToStr(Length(R.Data)))+LineEnding+UTF8Decode(TypedRegistryValue(R))+LineEnding+UnicodeString('完整数据（十六进制）：')+
    LineEnding+UnicodeString(S));
end;
procedure TGpoRegistryPane.RowsSelected(Sender:TObject; Item:TListItem; Selected:Boolean);
begin fView.Enabled:=Selected; end;
procedure TGpoRegistryPane.DetailKey(Sender:TObject; var Key:Word; Shift:TShiftState);
begin if (Key=13) and (Shift=[]) then begin DetailClick(Sender); Key:=0; end; end;
procedure TGpoRegistryPane.DetailClick(Sender: TObject);
var W:TForm; M:TMemo; B:TButton; Index:Integer;
begin
  if not Assigned(fList.Selected) then Exit;
  Index:=fSelect.ItemIndex*GpoRegistryPageSize+fList.Selected.Index;
  W:=TForm.CreateNew(Self,0);
  try
    W.Caption:='Registry.pol 原始记录详情（只读）'; W.Width:=850; W.Height:=500;
    W.Position:=poScreenCenter;
    B:=TButton.Create(W); B.Parent:=W; B.Align:=alBottom; B.Caption:='关闭'; B.ModalResult:=mrClose;
    M:=TMemo.Create(W); M.Parent:=W; M.Align:=alClient; M.ReadOnly:=True;
    M.ScrollBars:=ssAutoBoth; M.WordWrap:=False; M.Text:=RecordDetails(Index);
    W.ShowModal;
  finally W.Free; end;
end;

function GpoLocalStatus(Status:TGpoReadStatus):string;
const Names:array[TGpoReadStatus] of string=('成功','未找到','访问被拒绝','格式损坏',
  '不支持','路径无效','超出大小限制','I/O 错误','重解析点被阻止','已取消','已超时');
begin Result:=Names[Status]; end;

function GpoLdapFailureText(ResultCode: Integer): string;
begin
  case ResultCode of
    LDAP_RES_NO_SUCH_OBJECT: Result := 'GPC：对象不存在。';
    LDAP_RES_INSUFFICIENT_ACCESS_RIGHTS: Result := 'GPC：访问被拒绝。';
    LDAP_RES_SUCCESS: Result := 'GPC：所选对象不是可读取的 groupPolicyContainer。';
    else Result := Format('GPC 读取失败（LDAP 结果 %d）。', [ResultCode]);
  end;
end;

function GpoMatchesSelectedObject(Entry:TLdapResult; const DN,Guid:string; const ObjectGuid:RawByteString):Boolean;
var NameAttr,GuidAttr:TLdapAttribute; I:Integer; Nonzero:Boolean;
begin
  Result:=False;
  if not Assigned(Entry) or (DN='') or not GpoValidGuid(Guid) or (Length(ObjectGuid)<>16) then Exit;
  Nonzero:=False;
  for I:=1 to Length(ObjectGuid) do if ObjectGuid[I]<>#0 then Nonzero:=True;
  if not Nonzero or not SameText(Entry.ObjectName,DN) then Exit;
  NameAttr:=Entry.Find('name'); GuidAttr:=Entry.Find('objectGUID');
  Result:=Assigned(NameAttr) and (NameAttr.Count=1) and SameText(NameAttr.GetReadable,Guid) and
    Assigned(GuidAttr) and (GuidAttr.Count=1) and (GuidAttr.GetRaw=ObjectGuid);
end;

function GpoSupportsBackgroundSettings(BoundAs:TLdapClientBound; Password,UsesTls:Boolean):Boolean;
begin Result:=(BoundAs=lcbKerberos) and not Password and not UsesTls; end;
function GpoBackgroundSettingsRestriction(BoundAs:TLdapClientBound; Password,UsesTls:Boolean):string;
begin
  if UsesTls then Exit('后台只读加载暂不支持 TLS 连接；不会关闭证书验证或回退明文。');
  if Password then Exit('后台只读加载暂不支持显式密码；不会复制或保存密码。');
  if BoundAs<>lcbKerberos then Exit('后台只读加载仅支持当前 Windows 身份的 Kerberos 连接。');
  Result:='';
end;

constructor TGpoSettingsRead.Create(const Value: TGpoSettingsSnapshot;
  const Transport: IGpoSettingsTransport);
begin
  inherited Create;
  fValue := Value;
  fTransport := Transport;
  fControl := TGpoReadControl.Create(30000, Value.SessionToken);
  if not Assigned(Value.SessionToken) then fControl.Cancel;
end;

procedure TGpoSettingsRead.ReleaseSlot;
begin
  if not fSlot then Exit;
  fSlot := False; InterlockedDecrement(GpoPendingReads);
end;

destructor TGpoSettingsRead.Destroy;
begin
  fControl.Free; ReleaseSlot;
  inherited Destroy;
end;

procedure TGpoSettingsRead.Cancel;
begin fControl.Cancel; end;

function TGpoSettingsRead.ReadStatus: TGpoReadStatus;
begin
  if fControl.Cancelled or not fControl.SessionValid then Exit(grsCancelled);
  if Finished then Result := fCompletedStatus else Result := fControl.Status;
end;

function TGpoSettingsRead.AcceptsSession(const Token: IInterface): Boolean;
begin Result := Assigned(Token) and (Token = fValue.SessionToken); end;

function ReadSettingsMetadata(var Value:TGpoSettingsSnapshot; Control:TGpoReadControl):TGpoReadStatus;
var Client:TLdapClient; Root:TLdapResult; DisplayName:TLdapAttribute; Domain,DC,SafePath:string;
begin
  Result:=grsIoError; Value.MetadataError:='无法完成后台 LDAP 只读查询。';
  if Control.Status<>grsOk then Exit(Control.Status);
  Client:=TLdapClient.Create;
  try
    Client.Settings.TargetHost:=Value.DC; Client.Settings.TargetPort:=Value.Port;
    Client.Settings.AutoReconnect:=False; Client.Settings.AutoBind:=lcbNone;
    Client.Settings.KerberosSignSeal:=lksForced;
    if not Client.Connect([lccNoDiscovery],0) then Exit;
    if Control.Status<>grsOk then Exit(Control.Status);
    if not Client.BindSaslKerberos or (Client.Transmission<>lctEncrypted) or
      not SameText(Client.BoundUser,Value.BoundUser) then begin
      Value.MetadataError:='后台 Kerberos 身份或加密连接不匹配。'; Exit;
    end;
    if Control.Status<>grsOk then Exit(Control.Status);
    Root:=Client.SearchObject('','',['dnsHostName','defaultNamingContext']);
    if Control.Status<>grsOk then Exit(Control.Status);
    if not Assigned(Root) or not Assigned(Root.Find('dnsHostName')) or
      not Assigned(Root.Find('defaultNamingContext')) then begin
      Value.MetadataError:='无法读取域控制器身份。'; Exit;
    end;
    Domain:=DNToCN(Root.Find('defaultNamingContext').GetReadable,True,[dnDC]);
    DC:=Root.Find('dnsHostName').GetReadable;
    if (DC='') or SameText(DC,Domain) or not SameText(DC,Value.DC) or
      not SameText(Domain,Value.Domain) then begin
      Value.MetadataError:='域或域控制器身份不匹配。'; Exit;
    end;
    Root:=Client.SearchObject(Value.Container.DistinguishedName,'(objectClass=groupPolicyContainer)',
      ['name','objectGUID','displayName','gPCFileSysPath','versionNumber','flags']);
    if Control.Status<>grsOk then Exit(Control.Status);
    if not Assigned(Root) then begin Value.MetadataError:=GpoLdapFailureText(Client.ResultCode); Exit; end;
    if not GpoMatchesSelectedObject(Root,Value.Container.DistinguishedName,Value.Container.Guid,Value.ObjectGuid) then begin
      Value.MetadataError:='返回的 GPO 对象身份不匹配。'; Exit;
    end;
    if not Assigned(Root.Find('gPCFileSysPath')) or not Assigned(Root.Find('versionNumber')) or
      not Assigned(Root.Find('flags')) then begin Value.MetadataError:='GPO 必要属性缺失。'; Exit; end;
    DisplayName:=Root.Find('displayName');
    if Assigned(DisplayName) then begin
      if DisplayName.Count<>1 then begin Value.MetadataError:='GPO 显示名称无效。'; Exit; end;
      Value.DisplayNamePresent:=True; Value.Container.DisplayName:=DisplayName.GetReadable;
    end;
    Value.Container.FileSysPath:=Root.Find('gPCFileSysPath').GetReadable;
    if not GpoParseLdapVersion(Root.Find('versionNumber').GetReadable,Value.Container.Version) or
      not GpoParseUnsigned(Root.Find('flags').GetReadable,Value.Container.Flags) or
      (GpoBuildSafePath(Value.Container.FileSysPath,Value.Domain,Value.DC,Value.Container.Guid,gfGptIni,SafePath)<>grsOk) then begin
      Value.MetadataError:='GPO 版本、标志或 SYSVOL 路径无效。'; Exit;
    end;
    if Control.Status<>grsOk then Exit(Control.Status);
    Value.MetadataError:=''; Result:=grsOk;
  finally Client.Free; end;
end;

procedure TGpoSettingsRead.Execute;
var Data: TBytes; Status: TGpoReadStatus; Metadata:IGpoSettingsMetadataTransport; After:TGpoSettingsSnapshot;
  function Prepare(var Value:TGpoSettingsSnapshot):TGpoReadStatus;
  begin
    Value.DisplayNamePresent:=False; Value.Container.DisplayName:='';
    if Assigned(fTransport) then begin
      if Supports(fTransport,IGpoSettingsMetadataTransport,Metadata) then Result:=Metadata.Prepare(Value,fControl)
      else begin Value.MetadataError:='后台元数据读取不可用。'; Result:=grsUnsupported; end;
    end else Result:=ReadSettingsMetadata(Value,fControl);
    if fControl.Status<>grsOk then Result:=fControl.Status;
  end;
  function SameMetadata(const A,B:TGpoSettingsSnapshot):Boolean;
  begin
    Result:=SameText(A.Domain,B.Domain) and SameText(A.DC,B.DC) and
      SameText(A.Container.DistinguishedName,B.Container.DistinguishedName) and
      SameText(A.Container.Guid,B.Container.Guid) and (A.ObjectGuid=B.ObjectGuid) and
      (A.DisplayNamePresent=B.DisplayNamePresent) and (A.Container.DisplayName=B.Container.DisplayName) and
      SameText(A.Container.FileSysPath,B.Container.FileSysPath) and
      (A.Container.Version=B.Container.Version) and (A.Container.Flags=B.Container.Flags);
  end;
  function ReadArtifact(Artifact: TGpoFile): TGpoReadStatus;
  var Stop: TGpoReadStatus;
  begin
    Data := nil;
    Result := fControl.Status;
    if Result <> grsOk then Exit;
    if Assigned(fTransport) then
      Result := fTransport.Read(fValue.Container, fValue.Domain, fValue.DC, Artifact, Data)
    else
      Result := GpoReadFile(fValue.Container.FileSysPath, fValue.Domain,
        fValue.DC, fValue.Container.Guid, Artifact, Data, fControl);
    Stop := fControl.Status;
    if Stop <> grsOk then begin Data := nil; Result := Stop; end;
  end;
begin
  try
    if fValue.NeedsMetadata then begin
      fValue.MetadataStatus:=Prepare(fValue);
      if fValue.MetadataStatus<>grsOk then begin
        fValue.GptStatus:=fValue.MetadataStatus; fValue.MachineStatus:=fValue.MetadataStatus;
        fValue.UserStatus:=fValue.MetadataStatus;
      end;
    end;
    if not fValue.NeedsMetadata or (fValue.MetadataStatus=grsOk) then begin
      fValue.GptStatus := ReadArtifact(gfGptIni);
      if fValue.GptStatus = grsOk then
        fValue.GptStatus := ParseGptIni(Data, fValue.GptVersion);
      fValue.MachineStatus := ReadArtifact(gfMachineRegistry);
      if fValue.MachineStatus = grsOk then
        fValue.MachineStatus := ParseRegistryPol(Data, fValue.MachineRecords);
      fValue.UserStatus := ReadArtifact(gfUserRegistry);
      if fValue.UserStatus = grsOk then
        fValue.UserStatus := ParseRegistryPol(Data, fValue.UserRecords);
      if fValue.NeedsMetadata and (fControl.Status=grsOk) then begin
        After:=fValue; After.MachineRecords:=nil; After.UserRecords:=nil;
        After.MetadataStatus:=Prepare(After);
        if (After.MetadataStatus<>grsOk) or not SameMetadata(fValue,After) then begin
          fValue.MetadataStatus:=After.MetadataStatus;
          if fValue.MetadataStatus=grsOk then begin
            fValue.MetadataStatus:=grsIoError;
            fValue.MetadataError:='读取期间 GPO 身份或元数据变化，结果已丢弃。';
          end else fValue.MetadataError:='读取后无法再次核验 GPO 身份，结果已丢弃。';
          fValue.GptStatus:=fValue.MetadataStatus; fValue.MachineStatus:=fValue.MetadataStatus;
          fValue.UserStatus:=fValue.MetadataStatus; fValue.MachineRecords:=nil; fValue.UserRecords:=nil;
        end;
      end;
    end;
  except
    if fValue.NeedsMetadata then begin fValue.MetadataStatus:=grsIoError; fValue.MetadataError:='后台读取失败。'; end;
    fValue.GptStatus := grsIoError;
    fValue.MachineStatus := grsIoError;
    fValue.UserStatus := grsIoError;
    fValue.MachineRecords := nil;
    fValue.UserRecords := nil;
  end;
  Status := fControl.Status;
  fCompletedStatus := Status;
  if Status <> grsOk then
  begin
    if fValue.NeedsMetadata then fValue.MetadataStatus:=Status;
    fValue.GptStatus := Status; fValue.MachineStatus := Status; fValue.UserStatus := Status;
    fValue.MachineRecords := nil; fValue.UserRecords := nil;
  end;
  ReleaseSlot;
  InterlockedExchange(fDone, 1);
end;

function TGpoSettingsRead.Finished: Boolean;
begin Result := InterlockedCompareExchange(fDone, 0, 0) = 1; end;
function TGpoSettingsRead.Snapshot: TGpoSettingsSnapshot;
begin
  if not Finished then
  begin
    Result := Default(TGpoSettingsSnapshot);
    Result.GptStatus := grsIoError; Result.MachineStatus := grsIoError;
    Result.UserStatus := grsIoError; Exit;
  end;
  Result := fValue;
  // Cancellation can arrive after the worker publishes completion, before Poll.
  if fControl.Cancelled or not fControl.SessionValid then
  begin
    if Result.NeedsMetadata then Result.MetadataStatus:=grsCancelled;
    Result.GptStatus := grsCancelled; Result.MachineStatus := grsCancelled;
    Result.UserStatus := grsCancelled;
    Result.MachineRecords := nil; Result.UserRecords := nil;
  end;
end;
constructor TGpoReadThread.Create(const Job: IGpoSettingsRead);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  fJob := Job;
  Start;
end;
procedure TGpoReadThread.Execute;
begin fJob.Execute; end;

constructor TFrmPropertyGpoSettings.Create(TheOwner: TComponent);
var Bar:TPanel;
begin
  // This frame intentionally contains only read controls.
  inherited Create(TheOwner);
  Caption := SGpoSettingsCaption;
  Bar:=TPanel.Create(Self); Bar.Parent:=Self; Bar.Align:=alTop; Bar.Height:=38; Bar.BevelOuter:=bvNone;
  fLoad := TButton.Create(Self); fLoad.Parent:=Bar; fLoad.Align:=alLeft; fLoad.Width:=110;
  fLoad.Caption:=SGpoSettingsLoad; fLoad.OnClick:=@LoadClick;
  fBaseline:=TButton.Create(Self); fBaseline.Parent:=Bar; fBaseline.Align:=alLeft; fBaseline.Width:=145;
  fBaseline.Caption:='只读基线检查'; fBaseline.OnClick:=@BaselineClick;
  fBaseline.ShowHint:=True; fBaseline.Hint:='仅支持当前 Windows 身份的 Kerberos（无显式凭据、无 TLS），并要求对象 GUID 和有效连接。';
  fDomainDraft:=TButton.Create(Self); fDomainDraft.Parent:=Bar; fDomainDraft.Align:=alLeft; fDomainDraft.Width:=115;
  fDomainDraft.Caption:='建立域草稿'; fDomainDraft.OnClick:=@DomainDraftClick;
  fDomainDraft.ShowHint:=True; fDomainDraft.Hint:=fBaseline.Hint;
  fCancel := TButton.Create(Self); fCancel.Parent:=Bar; fCancel.Align:=alLeft; fCancel.Width:=90;
  fCancel.Caption:='取消读取'; fCancel.Enabled:=False; fCancel.OnClick:=@CancelClick;
  fDetails:=TButton.Create(Self); fDetails.Parent:=Bar; fDetails.Align:=alRight; fDetails.Width:=105;
  fDetails.Caption:='显示详情'; fDetails.OnClick:=@ToggleDetails;
  fState:=TLabel.Create(Self); fState.Parent:=Self; fState.Align:=alTop; fState.AutoSize:=False;
  fState.Height:=72; fState.Layout:=tlCenter; fState.WordWrap:=True;
  with TLabel.Create(Self) do begin Parent:=Self; Align:=alTop; AutoSize:=False;
    Height:=22; Caption:=SGpoScope; end;
  fSummary := TMemo.Create(Self);
  fSummary.Parent := Self;
  fSummary.Align := alTop;
  fSummary.Height := 120;
  fSummary.Visible:=False;
  fSummary.ReadOnly := True;
  fSummary.ScrollBars := ssAutoBoth;
  fSummary.WordWrap := False;
  fPages := TPageControl.Create(Self);
  fPages.Parent := Self;
  fPages.Align := alClient;
  fMachine := NewList(SGpoComputer, fComputerPane);
  fUser := NewList(SGpoUser, fUserPane);
  fTimer := TTimer.Create(Self);
  fTimer.Enabled := False;
  fTimer.Interval := 100;
  fTimer.OnTimer := @Poll;
  fBaselineTimer:=TTimer.Create(Self); fBaselineTimer.Enabled:=False;
  fBaselineTimer.Interval:=100; fBaselineTimer.OnTimer:=@PollBaseline;
  fDomainDraftTimer:=TTimer.Create(Self); fDomainDraftTimer.Enabled:=False;
  fDomainDraftTimer.Interval:=100; fDomainDraftTimer.OnTimer:=@PollDomainDraft;
  Update(nil);
end;

procedure TFrmPropertyGpoSettings.ToggleDetails(Sender:TObject);
begin
  fSummary.Visible:=not fSummary.Visible;
  if fSummary.Visible then fDetails.Caption:='隐藏详情' else fDetails.Caption:='显示详情';
end;
procedure TFrmPropertyGpoSettings.SetSummary(const Value:string; const State:string);
begin
  fSummary.Text:=Value;
  if State='' then fState.Caption:=SGpoStateError else fState.Caption:=State;
end;

destructor TFrmPropertyGpoSettings.Destroy;
begin
  if Assigned(fTimer) then fTimer.Enabled := False;
  if Assigned(fBaselineTimer) then fBaselineTimer.Enabled:=False;
  if Assigned(fDomainDraftTimer) then fDomainDraftTimer.Enabled:=False;
  if Assigned(fJob) then fJob.Cancel;
  if Assigned(fBaselineJob) then fBaselineJob.Cancel;
  if Assigned(fDomainDraftJob) then fDomainDraftJob.Cancel;
  fJob := nil;
  fBaselineJob:=nil;
  fDomainDraftJob:=nil;
  inherited Destroy;
end;

procedure TFrmPropertyGpoSettings.CancelClick(Sender: TObject);
begin
  if Assigned(fJob) then fJob.Cancel
  else if Assigned(fBaselineJob) then fBaselineJob.Cancel
  else if Assigned(fDomainDraftJob) then fDomainDraftJob.Cancel else Exit;
  fCancel.Enabled := False;
  ClearRows;
  SetSummary('已请求取消，正在等待系统 LDAP/SMB 调用返回；可以关闭窗口。', SGpoStateWaitingCancel);
end;

function TFrmPropertyGpoSettings.NewList(const Title: string;
  out Pane: TGpoRegistryPane): TListView;
var Tab: TTabSheet;
begin
  Tab := TTabSheet.Create(Self);
  Tab.PageControl := fPages;
  Tab.Caption := Title;
  Pane := TGpoRegistryPane.Create(Self);
  Pane.Parent := Tab;
  Pane.Align := alClient;
  Result := Pane.Rows;
end;

procedure TFrmPropertyGpoSettings.ClearRows;
begin fComputerPane.Bind(nil); fUserPane.Bind(nil); end;

procedure TFrmPropertyGpoSettings.Update(Props: TProperty);
var Attr:TLdapAttribute;
begin
  fTimer.Enabled := False;
  fBaselineTimer.Enabled:=False;
  fDomainDraftTimer.Enabled:=False;
  // Stop further work after any in-flight OS call and discard obsolete results.
  if Assigned(fJob) then fJob.Cancel;
  if Assigned(fBaselineJob) then fBaselineJob.Cancel;
  if Assigned(fDomainDraftJob) then fDomainDraftJob.Cancel;
  fJob := nil;
  fBaselineJob:=nil;
  fDomainDraftJob:=nil; fDomainDraftWindowOpen:=False;
  fCancel.Enabled := False;
  fProperty := Props;
  fSessionToken := nil;
  fClient := nil; fSocket := nil; fTarget := ''; fDN := ''; fGuid := ''; fObjectGuid:='';
  fBoundUser := ''; fPort := ''; fServer := ''; fDomain := '';
  if Assigned(Props) and Assigned(Props.LdapClient) then
  begin
    fClient := Props.LdapClient;
    fSessionToken := Props.LdapClient.SessionToken;
    fSocket := Props.LdapClient.Sock;
    fTarget := Props.LdapClient.Settings.TargetHost;
    fPort := Props.LdapClient.Settings.TargetPort;
    fBoundUser := Props.LdapClient.BoundUser;
    if Assigned(Props.LdapClient.Sock) then fServer := Props.LdapClient.Sock.Server;
    if Props.LdapClient.Bound then fDomain := DNToCN(Props.LdapClient.DefaultDN, True, [dnDC]);
    fDN := Props.distinguishedName;
    fGuid := Props.GetReadable('name');
    if Assigned(Props.Attributes) then begin Attr:=Props.Attributes.Find('objectGUID'); if Assigned(Attr) then fObjectGuid:=Attr.GetRaw; end;
  end;
  ClearRows;
  SetSummary('只读查看 Registry.pol 原始记录，不显示其他扩展或最终生效策略。' + LineEnding +
    '尚未加载；点击加载前不会读取 SYSVOL。' + LineEnding +
    'SMB 使用当前 Windows 身份，不使用保存的 LDAP 凭据。' + LineEnding +
    '基线检查仅支持当前 Windows 身份的 Kerberos（无显式凭据、无 TLS）且需要对象 GUID。', SGpoStateInitial);
  fLoad.Enabled := Assigned(Props);
  fBaseline.Enabled:=CanCheckBaseline;
  fDomainDraft.Enabled:=CanCheckBaseline;
end;

function TFrmPropertyGpoSettings.CanCheckBaseline:Boolean;
begin
  {$ifdef windows}
  Result:=SameConnection and (Length(fObjectGuid)=16) and (fBoundUser<>'') and
    (fProperty.LdapClient.Settings.AutoBind=lcbKerberos) and
    (fProperty.LdapClient.Settings.UserName='') and (fProperty.LdapClient.Settings.Password='') and
    not fProperty.LdapClient.Settings.Tls;
  {$else}
  Result:=False;
  {$endif}
end;

function TFrmPropertyGpoSettings.SameConnection: Boolean;
var Attr:TLdapAttribute; CurrentGuid:RawByteString;
begin
  Result := Assigned(fProperty) and Assigned(fProperty.LdapClient) and
    Assigned(fProperty.LdapClient.Settings) and
    (fProperty.LdapClient = fClient) and Assigned(fSessionToken) and
    (fProperty.LdapClient.SessionToken = fSessionToken) and fProperty.LdapClient.Connected and fProperty.LdapClient.Bound and
    (fProperty.LdapClient.Sock = fSocket) and
    (fProperty.LdapClient.Settings.TargetHost = fTarget) and
    (fProperty.LdapClient.Settings.TargetPort = fPort) and
    (fBoundUser <> '') and (fProperty.LdapClient.BoundUser = fBoundUser) and
    Assigned(fProperty.LdapClient.Sock) and (fProperty.LdapClient.Sock.Server = fServer) and
    (fProperty.distinguishedName = fDN) and (fProperty.GetReadable('name') = fGuid);
  if not Result then Exit;
  CurrentGuid:='';
  if Assigned(fProperty.Attributes) then begin Attr:=fProperty.Attributes.Find('objectGUID'); if Assigned(Attr) then CurrentGuid:=Attr.GetRaw; end;
  Result:=CurrentGuid=fObjectGuid;
end;

procedure TFrmPropertyGpoSettings.BaselineClick(Sender:TObject);
var Request:TGpoBaselineRequest;
begin
  if Assigned(fJob) or Assigned(fBaselineJob) or Assigned(fDomainDraftJob) then Exit;
  if not SameConnection then begin SetSummary('连接或对象已变化，请重新打开属性。'); Exit; end;
  {$ifndef windows}
  SetSummary('当前平台不支持独立 Windows Kerberos 只读基线检查。'); Exit;
  {$endif}
  if not CanCheckBaseline then
  begin SetSummary('只读基线检查仅支持当前 Windows 身份的 Kerberos 连接，并要求对象 GUID 可用；当前认证方式不受支持。'); Exit; end;
  Request:=Default(TGpoBaselineRequest); Request.SessionToken:=fSessionToken;
  Request.DC:=fTarget; Request.Port:=fPort; Request.DN:=fDN; Request.Guid:=fGuid; Request.User:=fBoundUser;
  SetLength(Request.ObjectGuid,16); Move(fObjectGuid[1],Request.ObjectGuid[0],16);
  try
    fBaselineJob:=GpoCreateBaselineJob(Request);
    if not Assigned(fBaselineJob) then begin SetSummary('已有读取仍在等待系统调用，请稍后重试。'); Exit; end;
    fLoad.Enabled:=False; fBaseline.Enabled:=False; fDomainDraft.Enabled:=False; fCancel.Enabled:=True;
    SetSummary('后台独立连接正在只读检查当前 GPO 基线；可以关闭窗口。','正在只读检查当前 GPO…');
    TGpoBaselineThread.Create(fBaselineJob); fBaselineTimer.Enabled:=True;
  except
    if Assigned(fBaselineJob) then fBaselineJob.Cancel;
    fBaselineJob:=nil; fLoad.Enabled:=Assigned(fProperty); fBaseline.Enabled:=CanCheckBaseline; fDomainDraft.Enabled:=CanCheckBaseline;
    fCancel.Enabled:=False; SetSummary('无法启动只读检查，请稍后重试。');
  end;
end;

procedure TFrmPropertyGpoSettings.PollBaseline(Sender:TObject);
var Token:IInterface; S:TGpoReadStatus; MessageText:string;
begin
  if not Assigned(fBaselineJob) then Exit;
  Token:=CurrentSessionToken;
  if not fBaselineJob.AcceptsSession(Token) then fBaselineJob.Cancel;
  if not fBaselineJob.Finished then
  begin
    S:=fBaselineJob.ReadStatus;
    if S<>grsOk then begin fCancel.Enabled:=False; SetSummary('检查已取消或超时，正在等待系统 LDAP/SMB 调用返回。',SGpoStateWaitingCancel); end;
    Exit;
  end;
  fBaselineTimer.Enabled:=False; fCancel.Enabled:=False;
  if fBaselineJob.AcceptsSession(Token) then
  begin MessageText:=fBaselineJob.ResultText; SetSummary(MessageText,MessageText); end
  else SetSummary('结果已丢弃：检查取消、超时、连接或对象变化。');
  fBaselineJob:=nil; fLoad.Enabled:=Assigned(fProperty); fBaseline.Enabled:=CanCheckBaseline; fDomainDraft.Enabled:=CanCheckBaseline;
end;

procedure TFrmPropertyGpoSettings.DomainDraftClick(Sender:TObject);
var Request:TGpoBaselineRequest;
begin
  if Assigned(fJob) or Assigned(fBaselineJob) or Assigned(fDomainDraftJob) then Exit;
  if not CanCheckBaseline then begin SetSummary('当前连接不支持建立域草稿，请重新打开属性并检查认证方式。'); Exit; end;
  Request:=Default(TGpoBaselineRequest); Request.SessionToken:=fSessionToken;
  Request.DC:=fTarget; Request.Port:=fPort; Request.DN:=fDN; Request.Guid:=fGuid; Request.User:=fBoundUser;
  SetLength(Request.ObjectGuid,16); Move(fObjectGuid[1],Request.ObjectGuid[0],16);
  try
    fDomainDraftJob:=GpoCreateDomainDraftJob(Request);
    if not Assigned(fDomainDraftJob) then begin SetSummary('已有读取仍在等待系统调用，或连接已失效。'); Exit; end;
    fLoad.Enabled:=False; fBaseline.Enabled:=False; fDomainDraft.Enabled:=False; fCancel.Enabled:=True;
    fDomainDraftWindowOpen:=False;
    fDomainDraftStarted:=GetTickCount64;
    SetSummary('后台独立连接正在采集域草稿基线；关闭页面会取消。','正在建立只读域草稿…');
    TGpoDomainDraftThread.Create(fDomainDraftJob); fDomainDraftTimer.Enabled:=True;
  except
    if Assigned(fDomainDraftJob) then fDomainDraftJob.Cancel;
    fDomainDraftJob:=nil; fCancel.Enabled:=False; fLoad.Enabled:=Assigned(fProperty);
    fBaseline.Enabled:=CanCheckBaseline; fDomainDraft.Enabled:=CanCheckBaseline;
    SetSummary('无法启动域草稿采集。');
  end;
end;

procedure TFrmPropertyGpoSettings.PollDomainDraft(Sender:TObject);
var Window:TFrmGpoOfflineDraft;
begin
  if not Assigned(fDomainDraftJob) then Exit;
  if not SameConnection then fDomainDraftJob.Cancel;
  if (fDomainDraftJob.State=gddsLoading) and (GetTickCount64-fDomainDraftStarted>=30000) then fDomainDraftJob.Cancel;
  if (fDomainDraftJob.State=gddsReady) and not fDomainDraftWindowOpen then
  begin
    if not SameConnection then begin fDomainDraftJob.Cancel; Exit; end;
    Window:=TFrmGpoOfflineDraft.Create(Application);
    try
      if not Window.InitializeDomainDraft(fDomainDraftJob,fTarget,fDN) then
      begin Window.Free; fDomainDraftJob.Cancel; Exit; end;
      fDomainDraftWindowOpen:=True; fCancel.Enabled:=False; Window.Show;
      SetSummary('域草稿已独立打开；关闭或切换属性页将使域复核失效，草稿仍可本地导出。','域草稿已建立（只读）');
    except Window.Free; fDomainDraftJob.Cancel; SetSummary('无法打开域草稿；未修改域。'); end;
  end;
  if fDomainDraftJob.State=gddsStopped then
  begin
    fDomainDraftTimer.Enabled:=False; fDomainDraftJob:=nil; fDomainDraftWindowOpen:=False;
    fCancel.Enabled:=False; fLoad.Enabled:=Assigned(fProperty); fBaseline.Enabled:=CanCheckBaseline; fDomainDraft.Enabled:=CanCheckBaseline;
    SetSummary('域草稿会话已结束或失效；已打开的草稿仍可本地导出。后台系统调用可能仍在等待返回，并在返回前占用读取名额。');
  end;
end;

procedure TFrmPropertyGpoSettings.LoadClick(Sender: TObject);
begin
  try
    LoadSettings;
  except
    // Do not expose exception text that could contain LDAP/session details.
    ClearRows;
    SetSummary('读取失败，请检查 LDAP 连接并重新打开属性。');
    if Assigned(fJob) then fJob.Cancel;
    fJob := nil;
    fCancel.Enabled := False;
    fTimer.Enabled := False;
    fLoad.Enabled := Assigned(fProperty);
    fBaseline.Enabled:=CanCheckBaseline;
    fDomainDraft.Enabled:=CanCheckBaseline;
  end;
end;

procedure TFrmPropertyGpoSettings.LoadSettings;
var Value: TGpoSettingsSnapshot; I:Integer; Nonzero:Boolean;
begin
  if Assigned(fJob) or Assigned(fBaselineJob) or Assigned(fDomainDraftJob) or not Assigned(fProperty) then Exit;
  ClearRows;
  if not Assigned(fProperty.LdapClient) or not fProperty.LdapClient.Connected or
     not Assigned(fProperty.LdapClient.Settings) then
  begin SetSummary('无法读取：没有已连接的 LDAP 会话。'); Exit; end;
  if not SameConnection then
  begin SetSummary('连接或对象已变化，请重新打开属性。'); Exit; end;
  if Length(fObjectGuid)<>16 then
  begin SetSummary('无法读取：所选 GPO 缺少有效的对象 GUID，请重新打开属性。'); Exit; end;
  Nonzero:=False; for I:=1 to 16 do if fObjectGuid[I]<>#0 then Nonzero:=True;
  if not Nonzero then begin SetSummary('无法读取：所选 GPO 的对象 GUID 无效，请重新打开属性。'); Exit; end;
  {$ifdef windows}
  if not GpoSupportsBackgroundSettings(fProperty.LdapClient.BoundAs,
    fProperty.LdapClient.Settings.Password<>'',fProperty.LdapClient.Settings.Tls) then begin
    SetSummary(GpoBackgroundSettingsRestriction(fProperty.LdapClient.BoundAs,
      fProperty.LdapClient.Settings.Password<>'',fProperty.LdapClient.Settings.Tls)); Exit;
  end;
  {$else}
  SetSummary('当前平台暂不支持安全的后台 GPO 只读加载。'); Exit;
  {$endif}
  Value := Default(TGpoSettingsSnapshot);
  Value.SessionToken := fSessionToken;
  Value.Container.Guid := fGuid;
  Value.Container.DistinguishedName := fDN;
  Value.Domain:=fDomain; Value.DC:=fTarget; Value.Port:=fPort; Value.BoundUser:=fBoundUser;
  Value.ObjectGuid:=fObjectGuid; Value.NeedsMetadata:=True; Value.MetadataStatus:=grsIoError;
  Value.GptStatus := grsIoError;
  Value.MachineStatus := grsIoError;
  Value.UserStatus := grsIoError;
  SetSummary('正在后台从域控制器读取：' + Value.DC + LineEnding +
    '使用当前 Windows 身份；取消后系统调用可能仍需等待返回。', SGpoStateLoading);
  fLoad.Enabled := False;
  fBaseline.Enabled:=False;
  fDomainDraft.Enabled:=False;
  fJob := GpoCreateSettingsRead(Value);
  if not Assigned(fJob) then
  begin
    SetSummary('前两次读取仍在等待系统 LDAP/SMB 调用，请稍后重试。');
    fLoad.Enabled := True; fBaseline.Enabled:=CanCheckBaseline; fDomainDraft.Enabled:=CanCheckBaseline; Exit;
  end;
  fCancel.Enabled := True;
  TGpoReadThread.Create(fJob);
  fTimer.Enabled := True;
end;

function TFrmPropertyGpoSettings.CurrentSessionToken: IInterface;
begin
  Result := nil;
  if SameConnection then Result := fProperty.LdapClient.SessionToken;
end;

procedure TFrmPropertyGpoSettings.Poll(Sender: TObject);
var Token: IInterface;
begin
  if not Assigned(fJob) then Exit;
  Token := CurrentSessionToken;
  if not fJob.AcceptsSession(Token) then fJob.Cancel;
  if not fJob.Finished then
  begin
    if fJob.ReadStatus <> grsOk then
    begin
      fCancel.Enabled := False;
      if fJob.ReadStatus=grsTimedOut then
        SetSummary(GpoLocalStatus(fJob.ReadStatus)+'：正在等待系统 LDAP/SMB 调用返回；可以关闭窗口。', SGpoStateWaitingTimeout)
      else
        SetSummary(GpoLocalStatus(fJob.ReadStatus)+'：正在等待系统 LDAP/SMB 调用返回；可以关闭窗口。', SGpoStateWaitingCancel);
    end;
    Exit;
  end;
  fTimer.Enabled := False;
  fCancel.Enabled := False;
  if fJob.AcceptsSession(Token) then
    ShowSnapshot(fJob.Snapshot)
  else begin ClearRows; SetSummary('已丢弃读取结果：连接或对象已变化，请重新打开属性。'); end;
  fJob := nil;
  fLoad.Enabled := Assigned(fProperty);
  fBaseline.Enabled:=CanCheckBaseline;
  fDomainDraft.Enabled:=CanCheckBaseline;
end;

procedure TFrmPropertyGpoSettings.ShowSnapshot(const Value: TGpoSettingsSnapshot);
  function RegistryStatus(Status: TGpoReadStatus): string;
  begin
    if Status = grsMissing then Result := SGpoMissingRegistry
    else Result := GpoLocalStatus(Status);
  end;
  function SideStatus(Status: TGpoReadStatus; Count:Integer):string;
  begin
    if Status=grsOk then Result:=Format(SGpoPresent,[Count])
    else if Status=grsMissing then Result:=SGpoNoFile
    else Result:=GpoLocalStatus(Status);
  end;
  function Versions(V: Cardinal): string;
  begin Result := Format('%u（计算机 %u / 用户 %u）', [V, GpoMachineVersion(V), GpoUserVersion(V)]); end;
  function YesNo(Value:Boolean):string;
  begin if Value then Result:='是' else Result:='否'; end;
begin
  ClearRows;
  if Value.NeedsMetadata and (Value.MetadataStatus<>grsOk) then begin
    if Value.MetadataStatus=grsCancelled then SetSummary('后台读取已取消。',SGpoStateCancelled)
    else if Value.MetadataStatus=grsTimedOut then SetSummary('后台读取已超时。',SGpoStateTimeout)
    else if Value.MetadataError<>'' then SetSummary(Value.MetadataError)
    else SetSummary('后台 LDAP 读取未完成。');
    Exit;
  end;
  fSummary.Lines.BeginUpdate;
  try
    fSummary.Clear;
    fSummary.Lines.Add('只读快照：' + Value.Container.DisplayName);
    fSummary.Lines.Add('GUID：' + Value.Container.Guid);
    fSummary.Lines.Add('SYSVOL 路径：' + Value.Container.FileSysPath);
    fSummary.Lines.Add('域控制器：' + Value.DC + ' / 域：' + Value.Domain);
    fSummary.Lines.Add('GPC（LDAP 最新读取）：' + Versions(Value.Container.Version));
    fSummary.Lines.Add('GPT.INI：' + GpoLocalStatus(Value.GptStatus));
    if Value.GptStatus = grsOk then
    begin
      fSummary.Lines.Add('GPT（SYSVOL）：' + Versions(Value.GptVersion));
      if Value.Container.Version = Value.GptVersion then
        fSummary.Lines.Add('版本比较：一致（不代表内容完整性）。')
      else fSummary.Lines.Add('警告：GPC 与 GPT 版本不一致，复制可能尚未完成。');
    end
    else fSummary.Lines.Add('版本比较：未知，无法读取 GPT。');
    fSummary.Lines.Add(Format('计算机 Registry.pol：%s；%d 条；已禁用=%s',
      [RegistryStatus(Value.MachineStatus), Length(Value.MachineRecords), YesNo((Value.Container.Flags and 2) <> 0)]));
    fSummary.Lines.Add(Format('用户 Registry.pol：%s；%d 条；已禁用=%s',
      [RegistryStatus(Value.UserStatus), Length(Value.UserRecords), YesNo((Value.Container.Flags and 1) <> 0)]));
    fSummary.Lines.Add('未找到不等于空策略；未知类型保留原始编号和字节。');
    fSummary.Lines.Add('仅显示 Registry.pol 原始记录，不代表最终生效策略。');
  finally fSummary.Lines.EndUpdate; end;
  if (Value.GptStatus=grsCancelled) and (Value.MachineStatus=grsCancelled) and
     (Value.UserStatus=grsCancelled) then
    fState.Caption:=SGpoStateCancelled
  else if (Value.GptStatus=grsTimedOut) and (Value.MachineStatus=grsTimedOut) and
          (Value.UserStatus=grsTimedOut) then
    fState.Caption:=SGpoStateTimeout
  else
  begin
    fState.Caption:=SGpoSideComputer+SideStatus(Value.MachineStatus,Length(Value.MachineRecords))+
      '；'+SGpoSideUser+SideStatus(Value.UserStatus,Length(Value.UserRecords));
    if (Value.GptStatus=grsOk) and (Value.Container.Version<>Value.GptVersion) then
      fState.Caption:=fState.Caption+LineEnding+SGpoStateMismatch
    else if Value.GptStatus<>grsOk then
      fState.Caption:=fState.Caption+LineEnding+'GPT.INI：'+GpoLocalStatus(Value.GptStatus);
  end;
  if Value.MachineStatus = grsOk then fComputerPane.Bind(Value.MachineRecords);
  if Value.UserStatus = grsOk then fUserPane.Bind(Value.UserRecords);
end;

end.
