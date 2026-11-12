unit unittest.ugpoofflinedraft;
{$mode ObjFPC}{$H+}{$codepage UTF8}
interface
uses mormot.core.test;
type
  TUnitTestGpoOfflineDraftUI=class(TSynTestCase)
  published
    procedure TypeAndHexValidation;
    procedure RecordEditorKeyboardLayout;
    procedure LocalDraftInteraction;
    procedure LocalFileBoundaries;
    procedure UnicodeAndConcurrentCreate;
    procedure PagedRecordEditing;
    procedure FindRecords;
    procedure CloseAndDiffAfter64;
    procedure LocalPlanRehearsal;
    procedure DomainDraftWorkflow;
    procedure DomainSummaryExport;
  end;
implementation
uses SysUtils, Classes, SyncObjs, Forms, Controls, StdCtrls, ExtCtrls, LCLType, ugpoformats, ugporegistrydraft, ugpolocalfiles,
  ufrmgpoofflinedraft, ufrmpropertygposettings
  {$ifdef windows},Windows{$endif};
{$ifdef windows}
function CreateTestSymbolicLinkW(LinkName, TargetName:PWideChar; Flags:DWORD):LongBool;
  stdcall; external 'kernel32.dll' name 'CreateSymbolicLinkW';
{$endif}
type
  TTestOfflineForm=class(TFrmGpoOfflineDraft)
  public
    Choice, RestoreChoice, EditChoice, SelectChoice, UseCloseAction, QueueExports:Boolean;
    CloseAction:TGpoCloseChoice;
    ExportCount:Integer; ExportPaths:array[0..1] of string; ExportChoices:array[0..1] of Boolean;
    BranchList:string;
    PromptCalls, RestoreCalls, ErrorCalls:Integer;
    NextRecord:TGpoRegistryRecord;
    NextPath, LastError, LastPreview:string;
    GptPath, VersionInput, PlanReport:string;
    GptChoice, VersionChoice:Boolean; PlanReports:Integer;
    MutateOnVersion, MutateOnGpt, RebaseOnGpt, InjectedEditOk:Boolean;
    SummaryChoice,MutateOnSummary,RebaseOnSummary:Boolean; SummaryPath:string; CancelOnSummary:IGpoDomainDraftJob;
    constructor Create(TheOwner:TComponent); override;
    procedure PollDomainNow;
  protected
    function ConfirmDiscard:Boolean; override;
    function ConfirmClose(const Branches:string):TGpoCloseChoice; override;
    function ConfirmRestore:Boolean; override;
    function ChooseLocalFile(SaveCopy:Boolean; out Path:string):Boolean; override;
    function ChooseSummaryFile(out Path:string):Boolean; override;
    function ChooseSummaryInput(out Path:string):Boolean; override;
    function ChooseGptFile(out Path:string):Boolean; override;
    function RequestGpcVersion(out Value:string):Boolean; override;
    function EditRecord(var Item:TGpoRegistryRecord; Adding:Boolean):Boolean; override;
    procedure ShowError(const MessageText:string); override;
    procedure ShowPreview; override;
    procedure ShowPlanReport(const Report:string); override;
  end;
  TKeyboardOfflineForm=class(TFrmGpoOfflineDraft)
  public
    Seen, FirstFocus, DefaultOK, CancelOK:Boolean;
    OrderOK:array[0..6] of Boolean;
    LabelOK:array[0..3] of Boolean;
    function InspectEditor(var R:TGpoRegistryRecord; Adding:Boolean):Boolean;
  protected
    function ExecuteRecordDialog(Dialog:TForm):TModalResult; override;
  end;
  TConcurrentWriter=class(TThread)
  public
    Path, Error:string;
    Payload:TBytes;
    Gate:TEvent;
    Succeeded:Boolean;
    constructor Create(const APath:string; const AData:TBytes; AGate:TEvent);
  protected
    procedure Execute; override;
  end;
  TFakeDomainJob=class(TInterfacedObject,IGpoDomainDraftJob)
    Current:TGpoDomainDraftState;
    LastUser,LastMachine:TGpoPolicyImage;
    InitialUser,InitialMachine:TGpoPolicyImage;
    Text:string;
    procedure Execute;
    procedure Cancel;
    function State:TGpoDomainDraftState;
    function Initial(out User,Machine:TGpoPolicyImage):Boolean;
    function Submit(const User,Machine:TGpoPolicyImage):Boolean;
    function ResultText:string;
  end;
procedure TFakeDomainJob.Execute; begin end;
procedure TFakeDomainJob.Cancel; begin Current:=gddsStopped; end;
function TFakeDomainJob.State:TGpoDomainDraftState; begin Result:=Current; end;
function TFakeDomainJob.Initial(out User,Machine:TGpoPolicyImage):Boolean;
begin User:=InitialUser;User.Data:=Copy(InitialUser.Data);Machine:=InitialMachine;Machine.Data:=Copy(InitialMachine.Data);Result:=Current=gddsReady; end;
function TFakeDomainJob.Submit(const User,Machine:TGpoPolicyImage):Boolean;
begin
  Result:=Current in [gddsReady,gddsResult]; if not Result then Exit;
  LastUser.Exists:=User.Exists; LastUser.Data:=Copy(User.Data);
  LastMachine.Exists:=Machine.Exists; LastMachine.Data:=Copy(Machine.Data); Current:=gddsChecking;
end;
function TFakeDomainJob.ResultText:string; begin if Text<>'' then Result:=Text else Result:='模拟复核：证据不完整'; end;
function TKeyboardOfflineForm.InspectEditor(var R:TGpoRegistryRecord; Adding:Boolean):Boolean;
begin Result:=EditRecord(R,Adding); end;
function TKeyboardOfflineForm.ExecuteRecordDialog(Dialog:TForm):TModalResult;
const Names:array[0..6] of string=('GpoRecordKey','GpoRecordValueName','GpoRecordType',
  'GpoRecordHex','GpoRecordFriendly','GpoRecordOK','GpoRecordCancel');
  Keys:array[0..3] of string=('&K','&N','&T','&D');
var I:Integer; C:TComponent; W:TWinControl; L:TLabel;
begin
  Seen:=True;
  for I:=0 to High(Names) do
  begin
    C:=Dialog.FindComponent(Names[I]);
    OrderOK[I]:=(C is TWinControl);
    if not OrderOK[I] then Continue;
    W:=TWinControl(C); OrderOK[I]:=W.TabStop and (W.TabOrder=I);
    if I=0 then FirstFocus:=Dialog.ActiveControl=W;
    if I<=High(LabelOK) then
    begin
      C:=Dialog.FindComponent(Names[I]+'Label'); LabelOK[I]:=C is TLabel;
      if LabelOK[I] then begin L:=TLabel(C); LabelOK[I]:=(L.FocusControl=W) and
        L.ShowAccelChar and (Pos(Keys[I],L.Caption)>0); end;
    end;
  end;
  C:=Dialog.FindComponent('GpoRecordOK');
  DefaultOK:=(C is TButton) and TButton(C).Default and (TButton(C).ModalResult=mrOk);
  C:=Dialog.FindComponent('GpoRecordCancel');
  CancelOK:=(C is TButton) and TButton(C).Cancel and (TButton(C).ModalResult=mrCancel);
  Result:=mrCancel;
end;
constructor TTestOfflineForm.Create(TheOwner:TComponent);
var H:PtrUInt;
begin inherited Create(TheOwner); H:=Pane.Rows.Handle; H:=Tree.Handle; end;
procedure TTestOfflineForm.PollDomainNow; begin PollDomainPlan(nil); end;
constructor TConcurrentWriter.Create(const APath:string; const AData:TBytes; AGate:TEvent);
begin inherited Create(True); FreeOnTerminate:=False; Path:=APath; Payload:=Copy(AData); Gate:=AGate; end;
procedure TConcurrentWriter.Execute;
begin
  if Gate.WaitFor(10000)=wrSignaled then Succeeded:=GpoSaveNewLocalFile(Path,Payload,Error);
end;
function TTestOfflineForm.ConfirmDiscard:Boolean;
begin Inc(PromptCalls); Result:=Choice; end;
function TTestOfflineForm.ConfirmClose(const Branches:string):TGpoCloseChoice;
begin
  BranchList:=Branches;
  if UseCloseAction then Result:=CloseAction else if Choice then Result:=gccDiscard else Result:=gccReturn;
end;
function TTestOfflineForm.ConfirmRestore:Boolean;
begin Inc(RestoreCalls); Result:=RestoreChoice; end;
function TTestOfflineForm.ChooseLocalFile(SaveCopy:Boolean; out Path:string):Boolean;
begin
  if QueueExports and SaveCopy then begin
    if ExportCount>1 then begin Result:=False; Exit; end;
    Path:=ExportPaths[ExportCount]; Result:=ExportChoices[ExportCount]; Inc(ExportCount);
  end else begin Path:=NextPath; Result:=SelectChoice; end;
end;
function TTestOfflineForm.ChooseSummaryFile(out Path:string):Boolean;
var Records:TGpoRegistryRecords; Encoded:TBytes;
begin
  Path:=SummaryPath; Result:=SummaryChoice;
  if MutateOnSummary then begin
    MutateOnSummary:=False;
    InjectedEditOk:=Draft(gdsUser).Insert(Length(Draft(gdsUser).Records),NextRecord)=grsOk;
  end;
  if RebaseOnSummary then begin
    RebaseOnSummary:=False; SetLength(Records,1); Records[0]:=NextRecord;
    InjectedEditOk:=(SerializeRegistryPol(Records,Encoded)=grsOk) and (Draft(gdsComputer).Load(Encoded)=grsOk);
  end;
  if Assigned(CancelOnSummary) then begin CancelOnSummary.Cancel; CancelOnSummary:=nil; end;
end;
function TTestOfflineForm.ChooseSummaryInput(out Path:string):Boolean;
begin Path:=SummaryPath; Result:=SummaryChoice; end;
function TTestOfflineForm.EditRecord(var Item:TGpoRegistryRecord; Adding:Boolean):Boolean;
begin Result:=EditChoice; if Result then Item:=NextRecord; end;
function TTestOfflineForm.ChooseGptFile(out Path:string):Boolean;
begin
  if MutateOnGpt then begin
    MutateOnGpt:=False;
    InjectedEditOk:=Draft(gdsUser).Insert(Length(Draft(gdsUser).Records),NextRecord)=grsOk;
  end;
  if RebaseOnGpt then begin RebaseOnGpt:=False; SelectSide(gdsUser); NewButton.Click; end;
  Path:=GptPath; Result:=GptChoice;
end;
function TTestOfflineForm.RequestGpcVersion(out Value:string):Boolean;
begin
  if MutateOnVersion then begin
    MutateOnVersion:=False;
    InjectedEditOk:=Draft(gdsUser).Insert(Length(Draft(gdsUser).Records),NextRecord)=grsOk;
  end;
  Value:=VersionInput; Result:=VersionChoice;
end;
procedure TTestOfflineForm.ShowError(const MessageText:string);
begin Inc(ErrorCalls); LastError:=MessageText; end;
procedure TTestOfflineForm.ShowPreview;
begin LastPreview:=PreviewText; end;
procedure TTestOfflineForm.ShowPlanReport(const Report:string);
begin Inc(PlanReports); PlanReport:=Report; end;
function Item(const Key,Name:UnicodeString; Kind:Cardinal; const Bytes:array of Byte):TGpoRegistryRecord;
var I:Integer;
begin
  Result.Key:=Key; Result.ValueName:=Name; Result.ValueType:=Kind; Result.Data:=nil;
  SetLength(Result.Data,Length(Bytes)); for I:=0 to High(Bytes) do Result.Data[I]:=Bytes[I];
end;
function EqualBytes(const A,B:TBytes):Boolean;
begin Result:=Length(A)=Length(B); if Result and (Length(A)>0) then Result:=CompareMem(@A[0],@B[0],Length(A)); end;
procedure TUnitTestGpoOfflineDraftUI.DomainDraftWorkflow;
var F:TTestOfflineForm; Job:TFakeDomainJob; Ref:IGpoDomainDraftJob; User,Machine:TGpoPolicyImage; Empty:TBytes; CanClose:Boolean;
  {$ifdef windows}Dir,Path:string;{$endif}
begin
  Job:=TFakeDomainJob.Create; Job.Current:=gddsReady; Ref:=Job; F:=TTestOfflineForm.Create(nil);
  try
    User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
    Check(SerializeRegistryPol(nil,Empty)=grsOk); Machine.Exists:=True; Machine.Data:=Copy(Empty);
    Job.InitialUser.Data:=Copy(Empty); Job.InitialMachine:=Machine;
    Check(not F.InitializeDomainDraft(Ref,'dc.example.test','CN=policy,DC=example,DC=test'),'Absent baseline cannot contain bytes');
    Job.InitialUser:=User; Job.InitialMachine:=Machine;
    Check(F.InitializeDomainDraft(Ref,'dc.example.test','CN=policy,DC=example,DC=test'));
    Check(not F.NewButton.Enabled); Check(F.OpenButton.Enabled); Check(F.PlanButton.Enabled);
    F.PlanButton.Click; Check(Job.Current=gddsChecking); Check(not Job.LastUser.Exists); Check(Job.LastMachine.Exists);
    Job.Current:=gddsResult; F.PollDomainNow; Check(F.PlanReports=1);
    Check(Pos('不会执行域写入',F.PlanReport)>0);
    F.OpenButton.Click; Check(Pos('候选文件缺失',F.StatusLabel.Caption)>0);
    Check(not F.SaveButton.Enabled); Check(F.UndoButton.Enabled); Check(F.ResetButton.Enabled);
    F.UseCloseAction:=True; F.CloseAction:=gccReturn; CanClose:=True; F.OnCloseQuery(F,CanClose);
    Check(not CanClose); Check(Pos('计算机',F.BranchList)>0);
    F.CloseAction:=gccExport; CanClose:=True; F.OnCloseQuery(F,CanClose); Check(not CanClose);
    F.PlanButton.Click; Check(not Job.LastMachine.Exists); Check(Length(Job.LastMachine.Data)=0);
    Job.Current:=gddsResult; F.PollDomainNow; Check(Pos('删除整个文件',F.PlanReport)>0);
    F.UndoButton.Click; Check(Pos('候选文件存在',F.StatusLabel.Caption)>0);
    F.SelectSide(gdsUser); Check(F.NewButton.Enabled); F.NewButton.Click;
    F.PlanButton.Click; Check(Job.LastUser.Exists); Check(EqualBytes(Job.LastUser.Data,Empty));
    F.OpenButton.Click; F.UndoButton.Click;
    Job.Current:=gddsResult; F.PollDomainNow; Check(Pos('结果已丢弃',F.LastError)>0);
    F.RestoreChoice:=True; F.ResetButton.Click; Check(Pos('候选文件缺失',F.StatusLabel.Caption)>0);
    F.SelectSide(gdsUser); F.EditChoice:=True; F.NextRecord:=Item('QA\User','V',3,[1]); F.AddButton.Click;
    F.UndoButton.Click; Check(Pos('候选文件缺失',F.StatusLabel.Caption)>0);
    F.AddButton.Click; F.Pane.Rows.Items[0].Selected:=True; F.DeleteButton.Click;
    Check(Pos('候选文件存在',F.StatusLabel.Caption)>0); Check(Length(F.Draft(gdsUser).Records)=0);
    F.UndoButton.Click; Check(Length(F.Draft(gdsUser).Records)=1);
    {$ifdef windows}
    Dir:=GetTempDir(False)+'openrsat-bound-export-'+IntToStr(GetCurrentProcessId);
    Check(CreateDir(Dir)); Path:=Dir+'\draft.pol'; F.SelectChoice:=True; F.NextPath:=Path;
    F.SaveButton.Click; Check(FileExists(Path)); Check(F.Draft(gdsUser).Dirty,'Export must not rebase the domain snapshot');
    Check(SysUtils.DeleteFile(Path)); Check(RemoveDir(Dir));
    {$endif}
    F.PlanButton.Click; Check(Job.LastUser.Exists,'Editing a missing side creates a candidate');
    F.NextRecord:=Item('QA\Later','V',3,[2]); F.AddButton.Click;
    Job.Current:=gddsResult; F.PollDomainNow; Check(F.PlanReports=2); Check(Pos('结果已丢弃',F.LastError)>0);
    F.PlanButton.Click; Check(Job.LastUser.Exists); Check(Length(Job.LastUser.Data)>Length(Empty));
    Job.Cancel; F.PollDomainNow; Check(not F.PlanButton.Enabled); Check(F.Draft(gdsUser).Dirty);
    Check(F.SaveButton.Enabled,'Expired domain draft remains exportable');
  finally F.Free; Ref:=nil; end;
end;
procedure TUnitTestGpoOfflineDraftUI.DomainSummaryExport;
{$ifdef windows}
var F:TTestOfflineForm; Job:TFakeDomainJob; Ref:IGpoDomainDraftJob; Machine:TGpoPolicyImage;
  Dir,Err,Report,Path,Fingerprint:string; Empty,Data,Original:TBytes; Id:TGUID; I:Integer; Exists:Boolean;
  function ReportBytes(const S:string):TBytes;
  begin
    SetLength(Result,Length(S)+3); Result[0]:=$ef; Result[1]:=$bb; Result[2]:=$bf;
    if Length(S)>0 then Move(S[1],Result[3],Length(S));
  end;
  function Name(N:Integer):string;
  begin Result:=Dir+'\'+IntToStr(N)+'.txt'; end;
  function ReadReport(N:Integer):string;
  var B:TBytes;
  begin
    Result:=''; if not GpoLoadLocalFile(Name(N),B,Err) or (Length(B)<=3) then Exit;
    if (B[0]<>$ef) or (B[1]<>$bb) or (B[2]<>$bf) then Exit;
    SetString(Result,PAnsiChar(@B[3]),Length(B)-3);
  end;
begin
  Check(CreateGUID(Id)=0); Dir:=GetTempDir(False)+'openrsat-summary-'+GUIDToString(Id); Check(CreateDir(Dir));
  Job:=TFakeDomainJob.Create; Job.Current:=gddsReady; Ref:=Job; F:=TTestOfflineForm.Create(nil);
  try
    Check(SerializeRegistryPol(nil,Empty)=grsOk); Machine:=Default(TGpoPolicyImage);
    Machine.Exists:=True; Machine.Data:=Copy(Empty); Job.InitialMachine:=Machine;
    Check(F.InitializeDomainDraft(Ref,'dc.example.test','CN=policy,DC=example,DC=test'));
    F.SummaryChoice:=True; F.SummaryPath:=Name(1); F.SummaryButton.Click; Report:=ReadReport(1);
    Check(Pos('dc.example.test',Report)>0); Check(Pos('CN=policy,DC=example,DC=test',Report)>0);
    Check(Pos('尚未完成只读复核',Report)>0); Check(Pos('不是 GPMC 备份',Report)>0);
    Check(Pos('计算机 Registry.pol：基线：存在；候选：存在；意图：无变化',Report)>0);
    Check(Pos('用户 Registry.pol：基线：缺失；候选：缺失；意图：无变化',Report)>0);
    Check(Pos('基线文件：8 字节；SHA-256：5BB1F21F806938A043563024B13B33D74A2B95B767C5F81BDE8456E9D0413A89',Report)>0);
    Check(Pos('候选文件：8 字节；SHA-256：5BB1F21F806938A043563024B13B33D74A2B95B767C5F81BDE8456E9D0413A89',Report)>0);
    Check(Pos('基线文件：缺失，无文件指纹',Report)>0); Check(Pos('候选文件：缺失，无文件指纹',Report)>0);
    F.SummaryChoice:=False; F.SummaryPath:=Name(2); F.SummaryButton.Click; Check(not FileExists(Name(2)));
    F.SummaryChoice:=True; F.MutateOnSummary:=True; F.NextRecord:=Item('Secret\NeverExport','Password',3,[7]);
    F.SummaryButton.Click; Check(F.InjectedEditOk); Check(not FileExists(Name(2))); Check(Pos('状态已变化',F.LastError)>0);
    F.Draft(gdsUser).Reset; F.SelectSide(gdsComputer); F.OpenButton.Click;
    F.SelectSide(gdsUser); F.EditChoice:=True; F.AddButton.Click;
    F.SummaryPath:=Name(2); F.SummaryButton.Click; Report:=ReadReport(2);
    Check(Pos('计算机 Registry.pol：基线：存在；候选：缺失；意图：删除整个文件',Report)>0);
    Check(Pos('用户 Registry.pol：基线：缺失；候选：存在；意图：创建',Report)>0);
    Check(Pos('Secret',Report)=0); Check(Pos('Password',Report)=0);
    Check(Pos('候选文件：85 字节；SHA-256：822A9A46BF9E799B090A659FC08C4D3C56770B89C44D66B3563291E552FD2F7F',Report)>0);
    Check(GpoSummaryCandidate(ReportBytes(Report),gdsUser,Exists,Fingerprint,Err)); Check(Exists);
    Check(not GpoSummaryCandidate(ReportBytes(StringReplace(Report,'意图：创建','意图：删除整个文件',[])),gdsUser,Exists,Fingerprint,Err));
    Check(not GpoSummaryCandidate(ReportBytes(StringReplace(Report,'822A9A46','Z22A9A46',[])),gdsUser,Exists,Fingerprint,Err));
    Check(not GpoSummaryCandidate(ReportBytes(Report+Report),gdsUser,Exists,Fingerprint,Err));
    F.SelectChoice:=True; F.NextPath:=Name(11); F.SaveButton.Click;
    Check(GpoLoadLocalFile(Name(11),Original,Err)); Check(F.Draft(gdsUser).Export(Data)=grsOk); Check(EqualBytes(Data,Original));
    F.SummaryPath:=Name(2); I:=F.PlanReports; F.VerifyButton.Click;
    Check(F.PlanReports=I+1); Check(Pos('与摘要候选一致',F.PlanReport)>0);
    F.NextPath:=Name(1); F.VerifyButton.Click; Check(Pos('不匹配',F.PlanReport)>0);
    F.SelectChoice:=False; I:=F.PlanReports; F.VerifyButton.Click; Check(F.PlanReports=I);
    F.SelectSide(gdsComputer); F.VerifyButton.Click;
    Check(Pos('候选为缺失',F.PlanReport)>0); Check(Pos('未检查域中',F.PlanReport)>0);
    F.SummaryPath:=Name(11); I:=F.ErrorCalls; F.VerifyButton.Click; Check(F.ErrorCalls=I+1);
    F.SummaryPath:=Name(99); F.VerifyButton.Click; Check(F.ErrorCalls=I+2);
    F.SummaryChoice:=False; I:=F.PlanReports; F.VerifyButton.Click; Check(F.PlanReports=I);
    F.SummaryChoice:=True; F.SelectChoice:=True; F.SelectSide(gdsUser);
    F.PlanButton.Click; F.SummaryPath:=Name(3); F.SummaryButton.Click; Report:=ReadReport(3);
    Check(Pos('复核进行中',Report)>0);
    Job.Text:='候选计划与原域基线的只读复核一致；安全证据仍不完整，不能授权写入。';
    Job.Current:=gddsResult; F.PollDomainNow;
    F.SummaryPath:=Name(4); F.SummaryButton.Click; Report:=ReadReport(4);
    Check(Pos('只读复核一致',Report)>0); Check(Pos('不能授权写入',Report)>0);
    F.PlanButton.Click; Job.Text:='域基线已变化；本次检查阻断，草稿保留，可导出后重新采集。';
    Job.Current:=gddsResult; F.PollDomainNow; F.SummaryPath:=Name(9); F.SummaryButton.Click; Report:=ReadReport(9);
    Check(Pos('域基线已变化',Report)>0); Check(Pos('只读复核一致',Report)=0);
    F.PlanButton.Click; Job.Text:='untrusted-secret-token'; Job.Current:=gddsResult; F.PollDomainNow;
    F.SummaryPath:=Name(10); F.SummaryButton.Click; Report:=ReadReport(10);
    Check(Pos('未得到可识别',Report)>0); Check(Pos('untrusted-secret-token',Report)=0);
    F.NextRecord:=Item('Second\NeverExport','Value',3,[8]); F.AddButton.Click;
    F.SummaryPath:=Name(5); F.SummaryButton.Click; Report:=ReadReport(5); Check(Pos('结果已过期',Report)>0);
    Check(GpoLoadLocalFile(Name(1),Original,Err)); F.SummaryPath:=Name(1); I:=F.ErrorCalls;
    F.SummaryButton.Click; Check(F.ErrorCalls=I+1); Check(GpoLoadLocalFile(Name(1),Data,Err)); Check(EqualBytes(Data,Original));
    F.SummaryPath:=Name(6); F.CancelOnSummary:=Ref; F.SummaryButton.Click;
    Check(not FileExists(Name(6))); Check(Pos('状态已变化',F.LastError)>0);
    F.SummaryPath:=Name(7); F.SummaryButton.Click; Report:=ReadReport(7); Check(Pos('会话失效',Report)>0);
    F.SelectSide(gdsComputer); F.UndoButton.Click; F.NextRecord:=Item('Machine\Hidden','Value',3,[1]); F.AddButton.Click;
    F.SummaryPath:=Name(8); F.SummaryButton.Click; Report:=ReadReport(8);
    Check(Pos('计算机 Registry.pol：基线：存在；候选：存在；意图：替换',Report)>0);
    Check(Pos('Machine\Hidden',Report)=0);
    F.SummaryPath:=Name(12); F.RebaseOnSummary:=True; F.SummaryButton.Click;
    Check(F.InjectedEditOk); Check(not FileExists(Name(12))); Check(Pos('状态已变化',F.LastError)>0);
    F.SummaryPath:=Name(13); F.SummaryButton.Click; Check(not FileExists(Name(13)));
    Check(Pos('基线不一致',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty,'summary exports must retain the draft');
  finally
    F.Free; Ref:=nil;
    for I:=1 to 13 do begin Path:=Name(I); if GetFileAttributesW(PWideChar(UTF8Decode(Path)))<>INVALID_FILE_ATTRIBUTES then
      Check(DeleteFileW(PWideChar(UTF8Decode(Path))),'remove summary'); end;
    Check(RemoveDir(Dir),'summary test directory cleaned');
  end;
end;
{$else}
begin Check(True,'local export unsupported on this platform'); end;
{$endif}
procedure TUnitTestGpoOfflineDraftUI.RecordEditorKeyboardLayout;
var F:TKeyboardOfflineForm; R:TGpoRegistryRecord; I,J:Integer;
begin
  F:=TKeyboardOfflineForm.Create(nil);
  try
    for J:=0 to 1 do
    begin
      R:=Item('Software\QA','Enabled',4,[1,0,0,0]);
      F.Seen:=False;
      Check(not F.InspectEditor(R,J=0)); Check(F.Seen); Check(F.FirstFocus);
      Check(F.DefaultOK); Check(F.CancelOK);
      for I:=0 to High(F.OrderOK) do Check(F.OrderOK[I]);
      for I:=0 to High(F.LabelOK) do Check(F.LabelOK[I]);
      Check(R.Key='Software\QA'); Check(R.ValueName='Enabled'); Check(R.ValueType=4);
      Check(EqualBytes(R.Data,TBytes.Create(1,0,0,0)));
      Check(not F.Draft(gdsComputer).Dirty and not F.Draft(gdsUser).Dirty);
    end;
  finally F.Free; end;
end;
procedure TUnitTestGpoOfflineDraftUI.LocalPlanRehearsal;
{$ifdef windows}
var F:TTestOfflineForm; Dir,UserPath,MachinePath,GptPath,E:string;
  Empty,Ini,ReadBack,Base:TBytes; S:RawByteString; FileStream:TFileStream;
begin
  Dir:=GetTempDir(False)+'openrsat-plan-ui-'+IntToStr(GetCurrentProcessId);
  if not CreateDir(Dir) then begin Check(False,'Cannot create fresh plan test directory'); Exit; end;
  F:=TTestOfflineForm.Create(nil);
  UserPath:=Dir+'\user.pol'; MachinePath:=Dir+'\machine.pol'; GptPath:=Dir+'\gpt.ini';
  try
    Check(SerializeRegistryPol(nil,Empty)=grsOk);
    S:='[General]'#13#10'Version=1'#13#10; SetLength(Ini,Length(S)); Move(S[1],Ini[0],Length(S));
    Check(GpoSaveNewLocalFile(UserPath,Empty,E)); Check(GpoSaveNewLocalFile(MachinePath,Empty,E));
    Check(GpoSaveNewLocalFile(GptPath,Ini,E));
    F.PlanButton.Click; Check(F.PlanReports=0); Check(Pos('请先',F.LastError)>0);
    F.SelectChoice:=True; F.NextPath:=MachinePath; F.OpenButton.Click;
    F.PlanButton.Click; Check(F.PlanReports=0); Check(Pos('请先',F.LastError)>0);
    F.SelectSide(gdsUser); F.NextPath:=UserPath; F.OpenButton.Click;
    F.PlanButton.Click; Check(F.PlanReports=0); // Cancel version input.
    F.VersionChoice:=True; F.VersionInput:='2147483648'; F.PlanButton.Click;
    Check(F.PlanReports=0); Check(Pos('有符号',F.LastError)>0);
    F.VersionInput:='1'; F.GptChoice:=False; F.PlanButton.Click; Check(F.PlanReports=0);
    F.GptChoice:=True; F.GptPath:=GptPath; F.PlanButton.Click;
    Check(F.PlanReports=1); Check(Pos('来源未经验证',F.PlanReport)>0);
    Check(Pos('计算机策略：无变化',F.PlanReport)>0); Check(Pos('用户策略：无变化',F.PlanReport)>0);
    Check(Pos('GPT 版本：1 → 1',F.PlanReport)>0);
    F.EditChoice:=True; F.NextRecord:=Item('QA\User','V',3,[1]); F.AddButton.Click;
    Check(F.Draft(gdsUser).Dirty); F.PlanButton.Click;
    Check(F.PlanReports=2); Check(Pos('计算机策略：无变化',F.PlanReport)>0);
    Check(Pos('用户策略：替换',F.PlanReport)>0); Check(Pos('GPT 版本：1 → 65537',F.PlanReport)>0);
    Check(Pos('LDAP versionNumber：1 → 65537',F.PlanReport)>0);
    Check(Pos('已重新读取',F.PlanReport)>0);
    Check(F.Draft(gdsUser).Dirty and not F.Draft(gdsComputer).Dirty);
    Check(F.Draft(gdsUser).Baseline(Base)=grsOk); Check(EqualBytes(Base,Empty));
    Base[0]:=0; Check(F.Draft(gdsUser).Baseline(Base)=grsOk); Check(EqualBytes(Base,Empty));
    F.SelectSide(gdsComputer); F.NextRecord:=Item('QA\Machine','V',3,[2]); F.AddButton.Click;
    F.PlanButton.Click; Check(F.PlanReports=3);
    Check(Pos('计算机策略：替换',F.PlanReport)>0); Check(Pos('用户策略：替换',F.PlanReport)>0);
    Check(Pos('GPT 版本：1 → 65538',F.PlanReport)>0);
    FileStream:=TFileStream.Create(UserPath,fmOpenReadWrite or fmShareExclusive);
    try FileStream.WriteBuffer(Ini[0],Length(Ini)); finally FileStream.Free; end;
    F.PlanButton.Click; Check(F.PlanReports=3); Check(Pos('用户基线文件已变化',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty and F.Draft(gdsComputer).Dirty);
    Check(SysUtils.DeleteFile(UserPath)); Check(GpoSaveNewLocalFile(UserPath,Empty,E));
    Check(SysUtils.DeleteFile(MachinePath)); F.PlanButton.Click;
    Check(F.PlanReports=3); Check(Pos('无法重新读取计算机基线',F.LastError)>0);
    Check(GpoSaveNewLocalFile(MachinePath,Empty,E));
    F.PlanButton.Click; Check(F.PlanReports=4);
    F.GptPath:=UserPath; F.PlanButton.Click; Check(F.PlanReports=4); Check(Pos('无法解析',F.LastError)>0);
    F.GptPath:=GptPath; F.VersionInput:='2'; F.PlanButton.Click;
    Check(F.PlanReports=4); Check(Pos('不一致',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    Check(GpoLoadLocalFile(UserPath,ReadBack,E)); Check(EqualBytes(ReadBack,Empty));
    Check(GpoLoadLocalFile(MachinePath,ReadBack,E)); Check(EqualBytes(ReadBack,Empty));
    Check(GpoLoadLocalFile(GptPath,ReadBack,E)); Check(EqualBytes(ReadBack,Ini));
    F.VersionInput:='1'; F.VersionChoice:=False; F.PlanButton.Click; Check(F.PlanReports=4);
    F.VersionChoice:=True; F.GptChoice:=False; F.PlanButton.Click; Check(F.PlanReports=4);
    F.GptChoice:=True; F.NextRecord:=Item('QA\DuringVersion','V',3,[3]);
    F.InjectedEditOk:=False; F.MutateOnVersion:=True; F.PlanButton.Click;
    Check(F.InjectedEditOk); Check(F.PlanReports=4); Check(Pos('输入期间',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    F.NextRecord:=Item('QA\DuringGpt','V',3,[4]); F.InjectedEditOk:=False; F.MutateOnGpt:=True; F.PlanButton.Click;
    Check(F.InjectedEditOk); Check(F.PlanReports=4); Check(Pos('输入期间',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    F.Choice:=True; F.RebaseOnGpt:=True; F.PlanButton.Click;
    Check(F.PlanReports=4); Check(Pos('输入期间',F.LastError)>0);
  finally
    F.Free;
    Check(SysUtils.DeleteFile(UserPath)); Check(SysUtils.DeleteFile(MachinePath));
    Check(SysUtils.DeleteFile(GptPath)); Check(RemoveDir(Dir));
  end;
end;
{$else}
begin Check(True,'Local file rehearsal is unavailable on this platform'); end;
{$endif}
procedure TUnitTestGpoOfflineDraftUI.TypeAndHexValidation;
var B:TBytes; E:string; R:TGpoRegistryRecord;
begin
  Check(GpoParseHex('',B,E)); Check(Length(B)=0);
  Check(GpoEncodeFriendly(4,'4294967295',B,E)); Check((Length(B)=4) and (B[0]=$ff) and (B[3]=$ff));
  Check(not GpoEncodeFriendly(4,'4294967296',B,E)); Check(Length(B)=0);
  Check(not GpoEncodeFriendly(4,'-1',B,E)); Check(not GpoEncodeFriendly(4,'0x10',B,E));
  Check(GpoEncodeFriendly(11,'18446744073709551615',B,E)); Check((Length(B)=8) and (B[7]=$ff));
  Check(not GpoEncodeFriendly(11,'18446744073709551616',B,E)); Check(Length(B)=0);
  Check(GpoEncodeFriendly(1,'中文😀',B,E));
  Check((Length(B)=10) and (B[0]=$2d) and (B[1]=$4e) and (B[4]=$3d) and (B[5]=$d8) and (B[8]=0) and (B[9]=0));
  Check(GpoEncodeFriendly(1,'',B,E)); Check((Length(B)=2) and (B[0]=0) and (B[1]=0));
  Check(not GpoEncodeFriendly(1,'a'+#0+'b',B,E)); Check(Length(B)=0);
  Check(not GpoEncodeFriendly(1,StringOfChar('a',32767),B,E));
  Check(not GpoEncodeFriendly($deadbeef,'1',B,E)); Check(Length(B)=0);
  Check(GpoParseHex('00 aB'+#13#10'Ff',B,E)); Check(Length(B)=3); Check(B[1]=$ab); Check(B[2]=$ff);
  Check(not GpoParseHex('0',B,E)); Check(Length(B)=0);
  Check(not GpoParseHex('00 ZZ',B,E)); Check(Length(B)=0);
  Check(not GpoParseHex(StringOfChar('f',2*(GpoMaxValueBytes+1)),B,E));
  R:=Item('','',3,[]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',4,[1,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  R.Data:=nil; Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',5,[0,0,0,1]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',11,[1,0,0,0,0,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  SetLength(R.Data,7); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',1,[65,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',1,[65,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',1,[65,0,0,0,66,0,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',1,[$00,$d8,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',1,[$3d,$d8,$00,$de,0,0]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[0,0,65,0,0,0,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[0,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[0,0,0,0,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[65,0,0,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[65,0,0,0,66,0,0,0,0,0]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[65,0,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',7,[65,0,0,0,0,0,66,0,0,0,0,0]); Check(not GpoValidateDraftRecord(R,E));
  R:=Item('K','',3,[0,1,2]); Check(GpoValidateDraftRecord(R,E));
  R:=Item('K','',$deadbeef,[0,59,93]); Check(GpoValidateDraftRecord(R,E));
end;
procedure TUnitTestGpoOfflineDraftUI.LocalDraftInteraction;
var F:TTestOfflineForm; R:TGpoRegistryRecord; Rows:TGpoRegistryRecords;
  Data,Prior:TBytes; E,Dir,Path:string; CanClose:Boolean;
  PreviewForm:TForm; PreviewMemo:TMemo;
  {$ifdef windows} LockedDraft:TBytes; LockHandle:THandle; ErrorsBefore:Integer; BeforePreview:string; {$endif}
begin
  F:=TTestOfflineForm.Create(nil); Dir:='';
  try
    Check(F.Tree.Parent.Width>=300, 'The branch labels need room for the unsaved marker.');
    F.EditChoice:=True; F.SelectChoice:=True;
    Check(not F.Draft(gdsComputer).Dirty); Check(not F.UndoButton.Enabled);
    Check(not F.ResetButton.Enabled); Check(Pos('本地离线',F.StatusLabel.Caption)>0);
    Check(Length(F.StatusLabel.Caption)>=3);
    Check(Ord(F.StatusLabel.Caption[1])=$e6);
    Check(Ord(F.StatusLabel.Caption[2])=$9c);
    Check(Ord(F.StatusLabel.Caption[3])=$ac);
    Check(Length(F.SaveButton.Caption)>=1); Check(Ord(F.SaveButton.Caption[1])=$e5);
    R:=Item('Software\Policies\Test','A',4,[1,0,0,0]); F.NextRecord:=R;
    F.EditChoice:=False; F.AddButton.Click;
    Check(not F.Draft(gdsComputer).Dirty); Check(Length(F.Draft(gdsComputer).Records)=0);
    F.EditChoice:=True;
    F.AddButton.Click; Check(F.Draft(gdsComputer).Dirty);
    Check(Length(F.Draft(gdsComputer).Records)=1); Check(F.Pane.Rows.Items.Count=1);
    Check(F.UndoButton.Enabled); Check(F.ResetButton.Enabled);
    // Ordered duplicate rows are retained, not merged.
    F.AddButton.Click; Rows:=F.Draft(gdsComputer).Records;
    Check(Length(Rows)=2); Check(Rows[0].Key=Rows[1].Key);
    Check(Assigned(F.Pane.Rows.Selected));
    F.PreviewButton.Click; Check(Pos('差异数：2',F.LastPreview)>0);
    F.NextRecord:=R; F.EditButton.Click; Check(F.Draft(gdsComputer).CanUndo);
    Check(Length(F.Draft(gdsComputer).Records)=2,'No-op edit preserves undo');
    F.UndoButton.Click; Check(Length(F.Draft(gdsComputer).Records)=1);
    Check(not F.Draft(gdsComputer).CanUndo);
    F.Pane.Rows.Items[0].Selected:=True;
    F.NextRecord:=Item('Software\Policies\Test','A',4,[1]);
    F.EditButton.Click; Check(Length(F.Draft(gdsComputer).Records[0].Data)=4);
    Check(Pos('DWORD',F.LastError)>0);
    F.NextRecord:=Item('Software\Policies\Test','A',4,[2,0,0,0]);
    F.EditButton.Click; Check(F.Draft(gdsComputer).Records[0].Data[0]=2);
    F.PreviewButton.Click; Check(Pos('02 00 00 00',F.LastPreview)>0);
    F.UndoButton.Click; Check(F.Draft(gdsComputer).Records[0].Data[0]=1);
    F.Pane.Rows.Items[0].Selected:=True; F.DeleteButton.Click;
    Check(Length(F.Draft(gdsComputer).Records)=0); Check(not F.Draft(gdsComputer).Dirty);
    F.UndoButton.Click; Check(Length(F.Draft(gdsComputer).Records)=1);
    Check(F.Draft(gdsComputer).Dirty);
    F.Choice:=False; F.NewButton.Click; Check(Length(F.Draft(gdsComputer).Records)=1);
    Check(F.PromptCalls=1);
    F.SelectChoice:=False; F.Choice:=True; F.OpenButton.Click;
    Check(Length(F.Draft(gdsComputer).Records)=1,'Cancelled file chooser preserves draft');
    F.SelectChoice:=True; F.RestoreChoice:=False; F.ResetButton.Click;
    Check(F.Draft(gdsComputer).Dirty); Check(F.RestoreCalls=1);
    F.SelectSide(gdsUser); Check(not F.Draft(gdsUser).Dirty);
    F.NextRecord:=Item('User\Policy','B',3,[7]); F.AddButton.Click;
    Check(F.Draft(gdsUser).Dirty); Check(F.Draft(gdsComputer).Dirty);
    F.PreviewButton.Click;
    Check(Pos('当前差异：用户配置',F.LastPreview)>0);
    Check(Pos('User\Policy',F.LastPreview)>0); Check(Pos('Software\Policies\Test',F.LastPreview)=0);
    Check(Pos('计算机配置：有未导出修改',F.LastPreview)>0);
    Check(Pos('用户配置：有未导出修改',F.LastPreview)>0);
    Check(Pos('本地草稿没有域基线，不能生成域变更计划',F.LastPreview)>0);
    Check(F.Draft(gdsUser).Dirty and F.Draft(gdsComputer).Dirty);
    F.SelectSide(gdsComputer); F.PreviewButton.Click;
    Check(Pos('当前差异：计算机配置',F.LastPreview)>0);
    Check(Pos('Software\Policies\Test',F.LastPreview)>0); Check(Pos('User\Policy',F.LastPreview)=0);
    F.SelectSide(gdsUser);
    F.Choice:=False; CanClose:=True; F.OnCloseQuery(F,CanClose); Check(not CanClose);
    F.Choice:=True; CanClose:=False; F.OnCloseQuery(F,CanClose); Check(CanClose);
    F.SelectSide(gdsComputer);
    {$ifdef windows}
    Dir:=GetTempDir(False)+'openrsat-draft-ui-'+IntToStr(GetCurrentProcessId)+'-'+StringOfChar('x',64);
    if not CreateDir(Dir) then begin Check(False,'Cannot create a fresh test directory'); Exit; end;
    Check(True); Path:=Dir+'\copy.pol'; F.NextPath:=Path;
    Check(F.Draft(gdsComputer).Export(Prior)=grsOk);
    F.SelectChoice:=False; F.SaveButton.Click;
    Check(F.Draft(gdsComputer).Dirty, 'Cancelled export keeps the draft dirty');
    Check(not FileExists(Path));
    F.SelectChoice:=True; F.NextPath:=Dir+'\missing\copy.pol'; F.SaveButton.Click;
    Check(F.Draft(gdsComputer).Dirty, 'Failed export keeps the draft dirty');
    Check(Length(F.Draft(gdsComputer).Records)=1);
    Check(F.Draft(gdsComputer).Export(Data)=grsOk); Check(EqualBytes(Prior,Data));
    Check(not FileExists(F.NextPath)); Check(F.LastError<>'');
    F.NextPath:=Path;
    F.SaveButton.Click; Check(FileExists(Path)); Check(not F.Draft(gdsComputer).Dirty);
    Check(GpoLoadLocalFile(Path,Data,E)); Check(EqualBytes(Prior,Data));
    F.PreviewButton.Click;
    Check(Pos('计算机配置：无未导出修改；基线：本地文件',F.LastPreview)>0);
    Check(Pos(Path,F.LastPreview)>0);
    Check(Pos('用户配置：有未导出修改',F.LastPreview)>0);
    PreviewForm:=F.CreatePreviewWindow;
    try
      PreviewMemo:=TMemo(PreviewForm.FindComponent('GpoPreviewMemo'));
      Check(Assigned(PreviewMemo));
      if Assigned(PreviewMemo) then begin
        Check(PreviewMemo.ReadOnly); Check(Pos(Path,PreviewMemo.Text)>0);
        Check(PreviewMemo.ScrollBars=ssAutoBoth);
      end;
    finally PreviewForm.Free; end;
    F.NextRecord:=Item('K','Changed',3,[9]); F.AddButton.Click;
    Check(F.Draft(gdsComputer).Dirty); F.SaveButton.Click;
    Check(F.Draft(gdsComputer).Dirty); Check(Pos('已存在',F.LastError)>0);
    Check(GpoLoadLocalFile(Path,Data,E)); Check(EqualBytes(Prior,Data));
    Check(F.Draft(gdsComputer).Export(LockedDraft)=grsOk); BeforePreview:=F.PreviewText;
    LockHandle:=CreateFileW(PWideChar(UTF8Decode(Path)),GENERIC_READ,0,nil,OPEN_EXISTING,0,0);
    Check(LockHandle<>INVALID_HANDLE_VALUE, 'Cannot exclusively lock the test file');
    if LockHandle<>INVALID_HANDLE_VALUE then
    try
      ErrorsBefore:=F.ErrorCalls; F.SaveButton.Click;
      Check(F.ErrorCalls=ErrorsBefore+1, 'Export to a locked file must fail');
      Check(F.Draft(gdsComputer).Dirty); Check(F.Draft(gdsUser).Dirty);
      ErrorsBefore:=F.ErrorCalls; F.Choice:=True; F.OpenButton.Click;
      Check(F.ErrorCalls=ErrorsBefore+1, 'Import from a locked file must fail');
      Check(F.Draft(gdsComputer).Dirty); Check(F.Draft(gdsUser).Dirty);
      Check(F.Draft(gdsComputer).CanUndo);
      Check(F.Draft(gdsComputer).Export(Data)=grsOk); Check(EqualBytes(LockedDraft,Data));
      Check(F.PreviewText=BeforePreview, 'Failed import must retain the baseline diff');
    finally CloseHandle(LockHandle); end;
    Check(GpoLoadLocalFile(Path,Data,E)); Check(EqualBytes(Prior,Data));
    F.NextPath:=Dir+'\bad.pol'; SetLength(Data,1); Data[0]:=42;
    Check(GpoSaveNewLocalFile(F.NextPath,Data,E)); F.Choice:=True;
    F.OpenButton.Click; Check(F.Draft(gdsComputer).Dirty);
    Check(Length(F.Draft(gdsComputer).Records)=2);
    Check(Pos('Corrupt',F.LastError)>0);
    Check(SysUtils.DeleteFile(F.NextPath)); F.NextPath:=Path;
    F.Choice:=False; F.OpenButton.Click; Check(F.Draft(gdsComputer).Dirty);
    F.Choice:=True; F.OpenButton.Click; Check(not F.Draft(gdsComputer).Dirty);
    Check(Length(F.Draft(gdsComputer).Records)=1);
    Check(SysUtils.DeleteFile(Path)); Check(RemoveDir(Dir)); Dir:='';
    {$endif}
    F.RestoreChoice:=True; F.SelectSide(gdsUser); F.ResetButton.Click;
    Check(not F.Draft(gdsUser).Dirty); Check(Length(F.Draft(gdsUser).Records)=0);
  finally F.Free; end;
end;
procedure TUnitTestGpoOfflineDraftUI.LocalFileBoundaries;
var Data,OutData:TBytes; E,Dir,Path,LinkPath:string;
  {$ifdef windows} WLink,WTarget:UnicodeString; {$endif}
begin
  {$ifdef windows}
  Dir:=GetTempDir(False)+'openrsat-draft-file-'+IntToStr(GetCurrentProcessId);
  if not CreateDir(Dir) then begin Check(False,'Cannot create a fresh test directory'); Exit; end;
  Check(True);
  try
    Path:=Dir+'\input.pol'; Check(SerializeRegistryPol(nil,Data)=grsOk);
    Check(GpoSaveNewLocalFile(Path,Data,E)); Check(GpoLoadLocalFile(Path,OutData,E));
    Check(EqualBytes(Data,OutData));
    Check(not GpoSaveNewLocalFile(Path,Data,E));
    Check(GpoLoadLocalFile(Path,OutData,E)); Check(EqualBytes(Data,OutData));
    Check(not GpoLoadLocalFile('\\server\SYSVOL\policy.pol',OutData,E));
    Check(not GpoSaveNewLocalFile('\\server\SYSVOL\policy.pol',Data,E));
    Check(not GpoSaveNewLocalFile(Dir+'\CON',Data,E));
    Check(not GpoSaveNewLocalFile(Dir+'\a:stream',Data,E));
    Check(not GpoSaveNewLocalFile(Dir+'\bad'+#0+'\new.pol',Data,E));
    Check(not GpoLoadLocalFile(Dir+'\bad'+#0+'\input.pol',OutData,E));
    LinkPath:=Dir+'\alias.pol'; WLink:=UTF8Decode(LinkPath); WTarget:=UTF8Decode(Path);
    if CreateTestSymbolicLinkW(PWideChar(WLink),PWideChar(WTarget),2) then
    begin
      Check(not GpoLoadLocalFile(LinkPath,OutData,E),'Final symbolic links must not be read');
      Check(not GpoSaveNewLocalFile(LinkPath,Data,E),'An existing symbolic link must not be replaced');
      Check(GpoLoadLocalFile(Path,OutData,E)); Check(EqualBytes(Data,OutData));
      Check(DeleteFileW(PWideChar(WLink)));
    end else Writeln('SKIP: local symbolic-link creation is unavailable');
    Check(SysUtils.DeleteFile(Path));
  finally Check(RemoveDir(Dir)); end;
  {$else}
  Check(not GpoLoadLocalFile('/tmp/local.pol',OutData,E));
  Check(not GpoSaveNewLocalFile('/tmp/local.pol',nil,E));
  {$endif}
end;
procedure TUnitTestGpoOfflineDraftUI.UnicodeAndConcurrentCreate;
var F:TTestOfflineForm; R:TGpoRegistryRecord; U:UnicodeString; E,Dir,Path:string;
  Data,ReadBack,A,B:TBytes; Gate:TEvent; W1,W2:TConcurrentWriter;
begin
  F:=TTestOfflineForm.Create(nil);
  try
    U:=UnicodeString(WideChar($4e2d))+WideChar($d83d)+WideChar($de00);
    R:=Item(U,U,$deadbeef,[0,59,93]); F.NextRecord:=R; F.EditChoice:=True;
    F.AddButton.Click;
    Check(F.Draft(gdsComputer).Records[0].Key=U);
    Check(F.Draft(gdsComputer).Records[0].ValueName=U);
    Check(F.Pane.Rows.Items[0].Caption=UTF8Encode(U));
    F.PreviewButton.Click; Check(Pos(UTF8Encode(U),F.LastPreview)>0);
    Check(F.Draft(gdsComputer).Export(Data)=grsOk);
    {$ifdef windows}
    Dir:=GetTempDir(False)+'openrsat-draft-unicode-'+IntToStr(GetCurrentProcessId);
    if not CreateDir(Dir) then begin Check(False,'Cannot create a fresh test directory'); Exit; end;
    Check(True);
    try
      Path:=Dir+'\'+UTF8Encode(U)+'.pol';
      F.NextPath:=Path; F.SelectChoice:=True; F.SaveButton.Click;
      Check(not F.Draft(gdsComputer).Dirty);
      Check(Pos(UTF8Encode(U),F.StatusLabel.Caption)>0);
      Check(GpoLoadLocalFile(Path,ReadBack,E)); Check(EqualBytes(Data,ReadBack));
      Check(DeleteFileW(PWideChar(UTF8Decode(Path))));
      Path:=Dir+'\race.pol'; SetLength(A,1); A[0]:=11; SetLength(B,1); B[0]:=22;
      Gate:=TEvent.Create(nil,True,False,''); W1:=TConcurrentWriter.Create(Path,A,Gate);
      W2:=TConcurrentWriter.Create(Path,B,Gate);
      try
        W1.Start; W2.Start; Gate.SetEvent; W1.WaitFor; W2.WaitFor;
        Check(W1.Succeeded xor W2.Succeeded,'Exactly one exclusive create must succeed');
        Check(GpoLoadLocalFile(Path,ReadBack,E)); Check(Length(ReadBack)=1);
        if Length(ReadBack)=1 then
          Check((W1.Succeeded and (ReadBack[0]=11)) or (W2.Succeeded and (ReadBack[0]=22)));
      finally W1.Free; W2.Free; Gate.Free; end;
      Check(SysUtils.DeleteFile(Path));
    finally Check(RemoveDir(Dir)); end;
    {$endif}
  finally F.Free; end;
end;
procedure TUnitTestGpoOfflineDraftUI.PagedRecordEditing;
var F:TTestOfflineForm; Rows:TGpoRegistryRecords; Data:TBytes; I:Integer;
  P:TForm; Memo:TMemo; Next,Previous:TButton;
begin
  F:=TTestOfflineForm.Create(nil);
  try
    SetLength(Rows,401);
    for I:=0 to High(Rows) do Rows[I]:=Item(UnicodeString('Key'+IntToStr(I)),'V',3,[1]);
    Check(SerializeRegistryPol(Rows,Data)=grsOk);
    Check(F.Draft(gdsComputer).Load(Data)=grsOk);
    F.SelectSide(gdsUser); F.SelectSide(gdsComputer);
    Check(F.Pane.PageSelector.Items.Count=3);
    F.Pane.SelectPage(2); Check(F.Pane.Rows.Items.Count=1);
    F.Pane.Rows.Items[0].Selected:=True;
    F.SelectSide(gdsUser); F.SelectSide(gdsComputer);
    Check(F.Pane.PageSelector.ItemIndex=2); Check(Assigned(F.Pane.Rows.Selected));
    F.NextRecord:=Item('LastChanged','V',3,[9]); F.EditChoice:=True;
    F.EditButton.Click; Rows:=F.Draft(gdsComputer).Records;
    Check(Rows[0].Key='Key0'); Check(Rows[399].Key='Key399');
    Check(Rows[400].Key='LastChanged'); Check(Rows[400].Data[0]=9);
    Check(F.Pane.PageSelector.ItemIndex=2); Check(Assigned(F.Pane.Rows.Selected));
    F.DeleteButton.Click; Rows:=F.Draft(gdsComputer).Records;
    Check(Length(Rows)=400); Check(Rows[399].Key='Key399');
    Check(Pos('记录 401:',F.PreviewText(0))>0);
    F.UndoButton.Click; Rows:=F.Draft(gdsComputer).Records;
    Check(Length(Rows)=401); Check(Rows[400].Key='LastChanged');
    F.Pane.SelectPage(0); F.Pane.Rows.Items[0].Selected:=True; F.DeleteButton.Click;
    Check(Pos('第 1 / 3 页',F.PreviewText(0))>0);
    Check(Pos('记录 1:',F.PreviewText(0))>0);
    Check(Pos('记录 201:',F.PreviewText(1))>0);
    Check(Pos('记录 401:',F.PreviewText(2))>0);
    Check(Pos('记录 401:',F.PreviewText(100))>0);
    P:=F.CreatePreviewWindow;
    try
      Memo:=TMemo(P.FindComponent('GpoPreviewMemo'));
      Next:=TButton(P.FindComponent('GpoPreviewNext'));
      Previous:=TButton(P.FindComponent('GpoPreviewPrevious'));
      Check(Assigned(Memo) and Assigned(Next) and Assigned(Previous));
      Check(Memo.ReadOnly); Check(Pos('域版本：未知',Memo.Text)>0);
      Check(not Previous.Enabled); Check(Next.Enabled);
      Check(Pos('记录 1:',Memo.Text)>0);
      Next.Click; Check(Pos('记录 201:',Memo.Text)>0);
      Next.Click; Check(Pos('记录 401:',Memo.Text)>0); Check(not Next.Enabled);
      Previous.Click; Check(Pos('记录 201:',Memo.Text)>0); Check(Next.Enabled);
    finally P.Free; end;
  finally F.Free; end;
end;
procedure TUnitTestGpoOfflineDraftUI.FindRecords;
var F:TTestOfflineForm; Rows:TGpoRegistryRecords; Data,Before,After:TBytes; I:Integer; Key:Word;
begin
  F:=TTestOfflineForm.Create(nil);
  try
    SetLength(Rows,401);
    for I:=0 to High(Rows) do Rows[I]:=Item(UnicodeString('Key'+IntToStr(I)),'V',3,[1]);
    Rows[10].ValueName:='测试名称'; Rows[250].Key:='Software\测试路径';
    Rows[400].ValueName:='TESTVALUE';
    Check(SerializeRegistryPol(Rows,Data)=grsOk);
    Check(F.Draft(gdsComputer).Load(Data)=grsOk);
    F.SelectSide(gdsUser); F.SelectSide(gdsComputer);
    Check(F.Draft(gdsComputer).Export(Before)=grsOk);
    F.FindText.Text:='测试'; Key:=VK_RETURN; F.FindText.OnKeyDown(F.FindText,Key,[]); Check(Key=0);
    Check(F.Pane.PageSelector.ItemIndex=0); Check(F.Pane.Rows.Selected.Index=10);
    F.FindButton.Click; Check(F.Pane.PageSelector.ItemIndex=1); Check(F.Pane.Rows.Selected.Index=50);
    F.FindButton.Click; Check(F.Pane.PageSelector.ItemIndex=0); Check(F.Pane.Rows.Selected.Index=10);
    F.FindText.Text:='testvalue'; F.FindButton.Click;
    Check(F.Pane.PageSelector.ItemIndex=2); Check(F.Pane.Rows.Selected.Index=0);
    F.FindText.Text:='not present'; F.FindButton.Click;
    Check(Pos('没有匹配',F.FindStatus.Caption)>0); Check(F.Pane.PageSelector.ItemIndex=2);
    Check(F.Pane.Rows.Selected.Index=0);
    F.FindText.Text:=''; F.FindButton.Click; Check(Pos('请输入',F.FindStatus.Caption)>0);
    Check(F.Draft(gdsComputer).Export(After)=grsOk);
    Check((Length(Before)=Length(After)) and CompareMem(@Before[0],@After[0],Length(Before)));
    Check(not F.Draft(gdsComputer).Dirty);
    F.FindText.Text:='测试路径'; F.FindButton.Click;
    F.NextRecord:=Item('Changed','V',3,[9]); F.EditChoice:=True; F.EditButton.Click;
    Rows:=F.Draft(gdsComputer).Records; Check(Rows[250].Key='Changed'); Check(Rows[400].ValueName='TESTVALUE');
    F.SelectSide(gdsUser); F.FindText.Text:='测试'; F.FindButton.Click;
    Check(Pos('没有匹配',F.FindStatus.Caption)>0); Check(not F.Draft(gdsUser).Dirty);
    F.Tree.Selected:=F.Tree.Items[0]; F.Tree.OnChange(F.Tree,F.Tree.Items[0]);
    Check(not F.FindButton.Enabled);
  finally F.Free; end;
end;

procedure TUnitTestGpoOfflineDraftUI.CloseAndDiffAfter64;
var F:TTestOfflineForm; R:TGpoRegistryRecord; Original,After:TBytes; Dir,Path,UserPath,Err:string;
  CanClose:Boolean; I:Integer; Splitter:TSplitter;
begin
  F:=TTestOfflineForm.Create(nil); Dir:='';
  try
    Splitter:=nil;
    for I:=0 to F.ComponentCount-1 do
      if F.Components[I] is TSplitter then Splitter:=TSplitter(F.Components[I]);
    Check(Assigned(Splitter));
    if Assigned(Splitter) then Check(Splitter.ResizeControl=F.Tree.Parent, 'The splitter must resize the tree panel.');
    F.EditChoice:=True; F.SelectChoice:=True;
    R:=Item('K','',3,[]); SetLength(R.Data,120); for I:=0 to 119 do R.Data[I]:=I;
    F.NextRecord:=R; F.AddButton.Click;
    Check(F.Draft(gdsComputer).Export(Original)=grsOk);
    Check(F.Draft(gdsComputer).Load(Original)=grsOk);
    R.Data[100]:=$ff; F.NextRecord:=R; F.Pane.Rows.Items[0].Selected:=True; F.EditButton.Click;
    Check(Pos('偏移（从 0 计）：100',F.PreviewText)>0);
    Check(Pos('原：64；新：FF',F.PreviewText)>0);
    F.SelectSide(gdsUser); F.NextRecord:=Item('U','',3,[1]); F.AddButton.Click;
    Check(F.Draft(gdsComputer).Dirty and F.Draft(gdsUser).Dirty);
    Check(Pos('未导出',F.Tree.Items[1].Text)>0); Check(Pos('未导出',F.Tree.Items[2].Text)>0);
    F.Tree.Selected:=F.Tree.Items[0];
    F.Tree.OnChange(F.Tree,F.Tree.Items[0]);
    Check(not F.AddButton.Enabled); Check(not F.EditButton.Enabled); Check(not F.DeleteButton.Enabled);
    F.SelectSide(gdsComputer); Check(F.AddButton.Enabled);
    F.UseCloseAction:=True; F.CloseAction:=gccReturn; CanClose:=True; F.OnCloseQuery(F,CanClose);
    Check(not CanClose); Check(Pos('计算机',F.BranchList)>0); Check(Pos('用户',F.BranchList)>0);
    {$ifdef windows}
    Dir:=GetTempDir(False)+'openrsat-close-ui-'+IntToStr(GetCurrentProcessId);
    if not CreateDir(Dir) then begin Check(False,'Cannot create fresh close test directory'); Exit; end;
    Path:=Dir+'\computer.pol'; F.CloseAction:=gccExport; F.QueueExports:=True;
    F.ExportPaths[0]:=Path; F.ExportChoices[0]:=True; F.ExportChoices[1]:=False;
    CanClose:=True; F.OnCloseQuery(F,CanClose);
    Check(not CanClose); Check(FileExists(Path)); Check(not F.Draft(gdsComputer).Dirty);
    Check(F.Draft(gdsUser).Dirty); Check(Length(F.Draft(gdsComputer).Records)=1);
    F.SelectSide(gdsComputer); Check(Pos(Path,F.StatusLabel.Caption)>0);
    Check(Pos('未导出',F.Tree.Items[1].Text)=0); Check(Pos('未导出',F.Tree.Items[2].Text)>0);
    Check(GpoLoadLocalFile(Path,Original,Err));
    F.ExportCount:=0; F.ExportPaths[0]:=Path; F.ExportChoices[0]:=True;
    CanClose:=True; F.OnCloseQuery(F,CanClose);
    Check(not CanClose); Check(F.Draft(gdsUser).Dirty);
    Check(GpoLoadLocalFile(Path,After,Err)); Check(EqualBytes(Original,After));
    UserPath:=Dir+'\user.pol'; F.ExportCount:=0; F.ExportPaths[0]:=UserPath;
    CanClose:=False; F.OnCloseQuery(F,CanClose);
    Check(CanClose); Check(FileExists(UserPath)); Check(not F.Draft(gdsUser).Dirty);
    Check(SysUtils.DeleteFile(UserPath)); Check(SysUtils.DeleteFile(Path)); Check(RemoveDir(Dir)); Dir:='';
    {$endif}
  finally F.Free; end;
end;
end.
