unit unittest.ugpoofflinedraft;
{$mode ObjFPC}{$H+}{$codepage UTF8}
interface
uses mormot.core.test;
type
  TUnitTestGpoOfflineDraftUI=class(TSynTestCase)
  published
    procedure TypeAndHexValidation;
    procedure LocalDraftInteraction;
    procedure LocalFileBoundaries;
    procedure UnicodeAndConcurrentCreate;
    procedure PagedRecordEditing;
    procedure FindRecords;
    procedure CloseAndDiffAfter64;
    procedure LocalPlanRehearsal;
  end;
implementation
uses SysUtils, Classes, SyncObjs, Forms, StdCtrls, ExtCtrls, LCLType, ugpoformats, ugporegistrydraft, ugpolocalfiles,
  ufrmgpoofflinedraft
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
    constructor Create(TheOwner:TComponent); override;
  protected
    function ConfirmDiscard:Boolean; override;
    function ConfirmClose(const Branches:string):TGpoCloseChoice; override;
    function ConfirmRestore:Boolean; override;
    function ChooseLocalFile(SaveCopy:Boolean; out Path:string):Boolean; override;
    function ChooseGptFile(out Path:string):Boolean; override;
    function RequestGpcVersion(out Value:string):Boolean; override;
    function EditRecord(var Item:TGpoRegistryRecord; Adding:Boolean):Boolean; override;
    procedure ShowError(const MessageText:string); override;
    procedure ShowPreview; override;
    procedure ShowPlanReport(const Report:string); override;
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
constructor TTestOfflineForm.Create(TheOwner:TComponent);
var H:PtrUInt;
begin inherited Create(TheOwner); H:=Pane.Rows.Handle; H:=Tree.Handle; end;
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
procedure TUnitTestGpoOfflineDraftUI.LocalPlanRehearsal;
{$ifdef windows}
var F:TTestOfflineForm; Dir,UserPath,MachinePath,GptPath,E:string;
  Empty,Ini,ReadBack,Base:TBytes; S:RawByteString;
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
    Check(Pos('未重新读取基线文件',F.PlanReport)>0);
    Check(F.Draft(gdsUser).Dirty and not F.Draft(gdsComputer).Dirty);
    Check(F.Draft(gdsUser).Baseline(Base)=grsOk); Check(EqualBytes(Base,Empty));
    Base[0]:=0; Check(F.Draft(gdsUser).Baseline(Base)=grsOk); Check(EqualBytes(Base,Empty));
    F.SelectSide(gdsComputer); F.NextRecord:=Item('QA\Machine','V',3,[2]); F.AddButton.Click;
    F.PlanButton.Click; Check(F.PlanReports=3);
    Check(Pos('计算机策略：替换',F.PlanReport)>0); Check(Pos('用户策略：替换',F.PlanReport)>0);
    Check(Pos('GPT 版本：1 → 65538',F.PlanReport)>0);
    F.GptPath:=UserPath; F.PlanButton.Click; Check(F.PlanReports=3); Check(Pos('无法解析',F.LastError)>0);
    F.GptPath:=GptPath; F.VersionInput:='2'; F.PlanButton.Click;
    Check(F.PlanReports=3); Check(Pos('不一致',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    Check(GpoLoadLocalFile(UserPath,ReadBack,E)); Check(EqualBytes(ReadBack,Empty));
    Check(GpoLoadLocalFile(MachinePath,ReadBack,E)); Check(EqualBytes(ReadBack,Empty));
    Check(GpoLoadLocalFile(GptPath,ReadBack,E)); Check(EqualBytes(ReadBack,Ini));
    F.VersionInput:='1'; F.VersionChoice:=False; F.PlanButton.Click; Check(F.PlanReports=3);
    F.VersionChoice:=True; F.GptChoice:=False; F.PlanButton.Click; Check(F.PlanReports=3);
    F.GptChoice:=True; F.NextRecord:=Item('QA\DuringVersion','V',3,[3]);
    F.InjectedEditOk:=False; F.MutateOnVersion:=True; F.PlanButton.Click;
    Check(F.InjectedEditOk); Check(F.PlanReports=3); Check(Pos('输入期间',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    F.NextRecord:=Item('QA\DuringGpt','V',3,[4]); F.InjectedEditOk:=False; F.MutateOnGpt:=True; F.PlanButton.Click;
    Check(F.InjectedEditOk); Check(F.PlanReports=3); Check(Pos('输入期间',F.LastError)>0);
    Check(F.Draft(gdsUser).Dirty);
    F.Choice:=True; F.RebaseOnGpt:=True; F.PlanButton.Click;
    Check(F.PlanReports=3); Check(Pos('输入期间',F.LastError)>0);
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
