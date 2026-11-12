unit ufrmpropertygposettings;

{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls, ExtCtrls,
  upropertyframe, uproperty, ugpoformats, ugposysvol;

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
    Domain, DC: string;
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
  IGpoSettingsRead = interface
    ['{4E0CCB3C-9EC9-4C28-8D53-A22C229A95FD}']
    procedure Execute;
    procedure Cancel;
    function ReadStatus: TGpoReadStatus;
    function AcceptsSession(const Token: IInterface): Boolean;
    function Finished: Boolean;
    function Snapshot: TGpoSettingsSnapshot;
  end;

  TFrmPropertyGpoSettings = class(TPropertyFrame)
  private
    fProperty: TProperty;
    fSummary: TMemo;
    fState: TLabel;
    fDetails: TButton;
    fLoad, fCancel: TButton;
    fPages: TPageControl;
    fMachine, fUser: TListView;
    fComputerPane, fUserPane: TGpoRegistryPane;
    fTimer: TTimer;
  protected
    fJob: IGpoSettingsRead;
    procedure Poll(Sender: TObject);
    function CurrentSessionToken: IInterface; virtual;
  private
    fClient, fSocket: TObject;
    fSessionToken: IInterface;
    fTarget, fDN, fGuid, fBoundUser, fPort, fServer, fDomain: string;
    function SameConnection: Boolean;
    procedure SetSummary(const Value:string; const State:string = '');
    procedure ToggleDetails(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
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
  end;

// Returns nil while two previous jobs still own their OS resources.
function GpoCreateSettingsRead(const Value: TGpoSettingsSnapshot;
  const Transport: IGpoSettingsTransport = nil): IGpoSettingsRead;
function GpoLdapFailureText(ResultCode: Integer): string;

implementation

uses mormot.net.ldap, Dialogs
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

var
  GpoPendingReads: LongInt;

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
    UnicodeString(IntToStr(Length(R.Data)))+LineEnding+UnicodeString('完整数据（十六进制）：')+
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

procedure TGpoSettingsRead.Execute;
var Data: TBytes; Status: TGpoReadStatus;
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
    fValue.GptStatus := ReadArtifact(gfGptIni);
    if fValue.GptStatus = grsOk then
      fValue.GptStatus := ParseGptIni(Data, fValue.GptVersion);
    fValue.MachineStatus := ReadArtifact(gfMachineRegistry);
    if fValue.MachineStatus = grsOk then
      fValue.MachineStatus := ParseRegistryPol(Data, fValue.MachineRecords);
    fValue.UserStatus := ReadArtifact(gfUserRegistry);
    if fValue.UserStatus = grsOk then
      fValue.UserStatus := ParseRegistryPol(Data, fValue.UserRecords);
  except
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
  if Assigned(fJob) then fJob.Cancel;
  fJob := nil;
  inherited Destroy;
end;

procedure TFrmPropertyGpoSettings.CancelClick(Sender: TObject);
begin
  if not Assigned(fJob) then Exit;
  fJob.Cancel;
  fCancel.Enabled := False;
  ClearRows;
  SetSummary('已请求取消，正在等待系统 SMB 调用返回；可以关闭窗口。', SGpoStateWaitingCancel);
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
begin
  fTimer.Enabled := False;
  // Stop further work after any in-flight OS call and discard obsolete results.
  if Assigned(fJob) then fJob.Cancel;
  fJob := nil;
  fCancel.Enabled := False;
  fProperty := Props;
  fSessionToken := nil;
  fClient := nil; fSocket := nil; fTarget := ''; fDN := ''; fGuid := '';
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
  end;
  ClearRows;
  SetSummary('只读查看 Registry.pol 原始记录，不显示其他扩展或最终生效策略。' + LineEnding +
    '尚未加载；点击加载前不会读取 SYSVOL。' + LineEnding +
    'SMB 使用当前 Windows 身份，不使用保存的 LDAP 凭据。', SGpoStateInitial);
  fLoad.Enabled := Assigned(Props);
end;

function TFrmPropertyGpoSettings.SameConnection: Boolean;
begin
  Result := Assigned(fProperty) and Assigned(fProperty.LdapClient) and
    (fProperty.LdapClient = fClient) and Assigned(fSessionToken) and
    (fProperty.LdapClient.SessionToken = fSessionToken) and fProperty.LdapClient.Connected and fProperty.LdapClient.Bound and
    (fProperty.LdapClient.Sock = fSocket) and
    (fProperty.LdapClient.Settings.TargetHost = fTarget) and
    (fProperty.LdapClient.Settings.TargetPort = fPort) and
    (fBoundUser <> '') and (fProperty.LdapClient.BoundUser = fBoundUser) and
    Assigned(fProperty.LdapClient.Sock) and (fProperty.LdapClient.Sock.Server = fServer) and
    (fProperty.distinguishedName = fDN) and (fProperty.GetReadable('name') = fGuid);
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
  end;
end;

procedure TFrmPropertyGpoSettings.LoadSettings;
var Value: TGpoSettingsSnapshot; SafePath: string; Root: TLdapResult;
begin
  if Assigned(fJob) or not Assigned(fProperty) then Exit;
  ClearRows;
  if not Assigned(fProperty.LdapClient) or not fProperty.LdapClient.Connected or
     not Assigned(fProperty.LdapClient.Settings) then
  begin SetSummary('无法读取：没有已连接的 LDAP 会话。'); Exit; end;
  if not SameConnection then
  begin SetSummary('连接或对象已变化，请重新打开属性。'); Exit; end;
  Value := Default(TGpoSettingsSnapshot);
  Value.SessionToken := fSessionToken;
  Value.Container.Guid := fGuid;
  Value.Container.DistinguishedName := fDN;
  // Ask the bound LDAP peer, not a domain alias or the untrusted GPC path.
  Root := fProperty.LdapClient.SearchObject('', '', ['dnsHostName', 'defaultNamingContext']);
  if not Assigned(Root) or not SameConnection then
  begin SetSummary('无法读取：无法从 RootDSE 验证当前域控制器。'); Exit; end;
  if not Assigned(Root.Find('dnsHostName')) or not Assigned(Root.Find('defaultNamingContext')) then
  begin SetSummary('无法读取：RootDSE 身份属性缺失。'); Exit; end;
  Value.Domain := DNToCN(Root.Find('defaultNamingContext').GetReadable, True, [dnDC]);
  Value.DC := Root.Find('dnsHostName').GetReadable;
  if not SameText(Value.Domain, fDomain) then
  begin SetSummary('无法读取：域身份已变化，请重新打开属性。'); Exit; end;
  if not SameText(Value.DC, fTarget) then
  begin SetSummary('无法读取：请使用与 RootDSE dnsHostName 一致的域控制器完整名称。'); Exit; end;
  if (Value.DC = '') or SameText(Value.DC, Value.Domain) then
  begin SetSummary('无法读取：LDAP 未标识具体域控制器。'); Exit; end;
  // Fresh committed values, never the editable property's staged attributes.
  Root := fProperty.LdapClient.SearchObject(fDN, '(objectClass=groupPolicyContainer)',
    ['name', 'displayName', 'gPCFileSysPath', 'versionNumber', 'flags']);
  if not SameConnection then
  begin SetSummary('无法读取：读取 GPC 期间连接已变化。'); Exit; end;
  if not Assigned(Root) then
  begin SetSummary(GpoLdapFailureText(fProperty.LdapClient.ResultCode)); Exit; end;
  if not Assigned(Root.Find('name')) or not SameText(Root.Find('name').GetReadable, fGuid) or
     not SameText(Root.ObjectName, fDN) then
  begin SetSummary('无法读取：返回的 GPC 身份与所选对象不一致。'); Exit; end;
  if not Assigned(Root.Find('gPCFileSysPath')) or not Assigned(Root.Find('versionNumber')) or
     not Assigned(Root.Find('flags')) then
  begin SetSummary('无法读取：缺少必要的 GPC 属性。'); Exit; end;
  if Assigned(Root.Find('displayName')) then Value.Container.DisplayName := Root.Find('displayName').GetReadable;
  Value.Container.FileSysPath := Root.Find('gPCFileSysPath').GetReadable;
  if not GpoParseLdapVersion(Root.Find('versionNumber').GetReadable, Value.Container.Version) or
     not GpoParseUnsigned(Root.Find('flags').GetReadable, Value.Container.Flags) then
  begin SetSummary('无法读取：GPC versionNumber 或 flags 无效。'); Exit; end;
  if GpoBuildSafePath(Value.Container.FileSysPath, Value.Domain, Value.DC,
      Value.Container.Guid, gfGptIni, SafePath) <> grsOk then
  begin SetSummary('无法读取：SYSVOL 路径或域控制器不符合安全要求。'); Exit; end;
  Value.GptStatus := grsIoError;
  Value.MachineStatus := grsIoError;
  Value.UserStatus := grsIoError;
  SetSummary('正在从域控制器读取：' + Value.DC + LineEnding +
    '只读 SMB 使用当前 Windows 身份；可以关闭窗口。', SGpoStateLoading);
  fLoad.Enabled := False;
  fJob := GpoCreateSettingsRead(Value);
  if not Assigned(fJob) then
  begin
    SetSummary('前两次读取仍在等待系统 SMB 调用，请稍后重试。');
    fLoad.Enabled := True; Exit;
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
        SetSummary(GpoLocalStatus(fJob.ReadStatus)+'：正在等待系统 SMB 调用返回；可以关闭窗口。', SGpoStateWaitingTimeout)
      else
        SetSummary(GpoLocalStatus(fJob.ReadStatus)+'：正在等待系统 SMB 调用返回；可以关闭窗口。', SGpoStateWaitingCancel);
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
