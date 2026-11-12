unit ufrmgpoofflinedraft;
{$mode ObjFPC}{$H+}{$codepage UTF8}
interface

uses Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls, ExtCtrls,
  ugpoformats, ugporegistrydraft, ufrmpropertygposettings;

type
  TGpoDraftSide = (gdsComputer, gdsUser);
  TGpoCloseChoice = (gccExport, gccDiscard, gccReturn);
  TFrmGpoOfflineDraft = class(TForm)
  private
    fDrafts: array[TGpoDraftSide] of TGpoRegistryDraft;
    fPaths: array[TGpoDraftSide] of string;
    fDomainJob:IGpoDomainDraftJob;
    fDomain:Boolean;
    fDomainExists:array[TGpoDraftSide] of Boolean;
    fDomainTarget:string;
    fDomainTimer:TTimer;
    fDomainWaiting:Boolean;
    fDomainStarted:QWord;
    fPendingUser,fPendingMachine:TGpoPolicyImage;
    fSide: TGpoDraftSide;
    fValidSide:Boolean;
    fSavedPage, fSavedIndex:array[TGpoDraftSide] of Integer;
    fTree: TTreeView;
    fComputerNode, fUserNode: TTreeNode;
    fPane: TGpoRegistryPane;
    fStatus: TLabel;
    fFindText:TEdit;
    fFindButton:TButton;
    fFindStatus:TLabel;
    fNew, fOpen, fSave, fAdd, fEdit, fDelete, fUndo, fReset, fPreview, fPlan: TButton;
    procedure TreeChanged(Sender:TObject; Node:TTreeNode);
    procedure RowSelected(Sender:TObject; Item:TListItem; Selected:Boolean);
    function ExportCurrent:Boolean;
    procedure NewClick(Sender:TObject);
    procedure OpenClick(Sender:TObject);
    procedure SaveClick(Sender:TObject);
    procedure AddClick(Sender:TObject);
    procedure EditClick(Sender:TObject);
    procedure DeleteClick(Sender:TObject);
    procedure UndoClick(Sender:TObject);
    procedure ResetClick(Sender:TObject);
    procedure PreviewClick(Sender:TObject);
    procedure PlanClick(Sender:TObject);
    procedure DomainPlanClick;
    procedure DomainClosed(Sender:TObject; var CloseAction:TCloseAction);
    function DomainCandidates(out User,Machine:TGpoPolicyImage):Boolean;
    procedure FindClick(Sender:TObject);
    procedure FindChanged(Sender:TObject);
    procedure FindKeyDown(Sender:TObject; var Key:Word; Shift:TShiftState);
    procedure RowDblClick(Sender:TObject);
    procedure Closing(Sender:TObject; var CanClose:Boolean);
    procedure RefreshView(SelectedIndex:Integer=-1; PreserveCurrent:Boolean=True);
    function SelectedIndex:Integer;
    function Current:TGpoRegistryDraft;
    function PreviewSummary:string;
  protected
    procedure PollDomainPlan(Sender:TObject);
    function ConfirmDiscard:Boolean; virtual;
    function ConfirmClose(const Branches:string):TGpoCloseChoice; virtual;
    function ConfirmRestore:Boolean; virtual;
    function ChooseLocalFile(SaveCopy:Boolean; out Path:string):Boolean; virtual;
    function ChooseGptFile(out Path:string):Boolean; virtual;
    function RequestGpcVersion(out Value:string):Boolean; virtual;
    function EditRecord(var Item:TGpoRegistryRecord; Adding:Boolean):Boolean; virtual;
    function ExecuteRecordDialog(Dialog:TForm):TModalResult; virtual;
    procedure ShowError(const MessageText:string); virtual;
    procedure ShowPreview; virtual;
    procedure ShowPlanReport(const Report:string); virtual;
  public
    constructor Create(TheOwner:TComponent); override;
    destructor Destroy; override;
    procedure SelectSide(Side:TGpoDraftSide);
    function Draft(Side:TGpoDraftSide):TGpoRegistryDraft;
    function PreviewText(Page:Integer=0):string;
    function CreatePreviewWindow:TForm;
    function InitializeDomainDraft(const Job:IGpoDomainDraftJob; const DC,DN:string):Boolean;
    property Tree:TTreeView read fTree;
    property Pane:TGpoRegistryPane read fPane;
    property StatusLabel:TLabel read fStatus;
    property NewButton:TButton read fNew;
    property OpenButton:TButton read fOpen;
    property SaveButton:TButton read fSave;
    property AddButton:TButton read fAdd;
    property EditButton:TButton read fEdit;
    property DeleteButton:TButton read fDelete;
    property UndoButton:TButton read fUndo;
    property ResetButton:TButton read fReset;
    property PreviewButton:TButton read fPreview;
    property PlanButton:TButton read fPlan;
    property FindText:TEdit read fFindText;
    property FindButton:TButton read fFindButton;
    property FindStatus:TLabel read fFindStatus;
  end;

function GpoParseHex(const S:string; out Data:TBytes; out Error:string):Boolean;
function GpoValidateDraftRecord(const Item:TGpoRegistryRecord; out Error:string):Boolean;
function GpoEncodeFriendly(ValueType:Cardinal; const Text:string; out Data:TBytes; out Error:string):Boolean;

implementation
uses Dialogs, LazUTF8, LCLType, ugpolocalfiles;

type
  TFriendlyInput = class(TComponent)
    TypeBox:TComboBox;
    HexMemo:TMemo;
    procedure Click(Sender:TObject);
  end;

resourcestring
  SDirty = ' * 未导出';
  SComputer = '计算机配置 — 注册表';
  SUser = '用户配置 — 注册表';
  SChooseSide = '请选择计算机或用户分支；本地 Registry.pol 草稿不会应用到域。';
  SRestoreBaseline = '还原基线…';
  SRestoreQuestion = '将放弃当前分支的全部修改并还原最近载入或导出的基线，确定吗？';
  SCloseTitle = '本地草稿尚未导出';
  SCloseQuestion = '以下分支尚未导出：%s。是：逐项导出并关闭；否：放弃并关闭；取消：返回编辑。';
  SCloseYes = '是，导出';
  SCloseNo = '否，放弃';
  SCloseCancel = '取消';
  SDiffOffset = '  首个不同字节偏移（从 0 计）：%d；原：%s；新：%s';
  SNoByte = '（无字节）';
  SExported = '已导出 %s，已设为基线：%s';

function GpoParseHex(const S:string; out Data:TBytes; out Error:string):Boolean;
var I,N,Half,V:Integer; C:Char;
  function HexDigit(A:Char):Integer;
  begin
    case A of
      '0'..'9':Result:=Ord(A)-Ord('0');
      'a'..'f':Result:=Ord(A)-Ord('a')+10;
      'A'..'F':Result:=Ord(A)-Ord('A')+10;
      else Result:=-1;
    end;
  end;
begin
  Result:=False; Data:=nil; Error:=''; N:=0;
  for I:=1 to Length(S) do
  begin
    C:=S[I]; if C in [' ',#9,#10,#13] then Continue;
    if HexDigit(C)<0 then begin Error:='数据只能包含十六进制数字和空白。'; Exit; end;
    Inc(N); if N>GpoMaxValueBytes*2 then begin Error:='值数据超过 65535 字节。'; Exit; end;
  end;
  if Odd(N) then begin Error:='十六进制数字必须成对。'; Exit; end;
  SetLength(Data,N div 2); N:=0; Half:=-1;
  for I:=1 to Length(S) do
  begin
    V:=HexDigit(S[I]); if V<0 then Continue;
    if Half<0 then Half:=V else begin Data[N]:=Half*16+V; Inc(N); Half:=-1; end;
  end;
  Result:=True;
end;

function GpoValidateDraftRecord(const Item:TGpoRegistryRecord; out Error:string):Boolean;
var Values:TGpoRegistryRecords; Buffer:TBytes; Status:TGpoReadStatus;
  I,Units:Integer; C,N:Word; PreviousZero:Boolean;
  function UnitAt(Index:Integer):Word;
  begin Result:=Word(Item.Data[Index*2]) or (Word(Item.Data[Index*2+1]) shl 8); end;
begin
  Result:=False; Error:=''; SetLength(Values,1); Values[0]:=Item;
  Status:=SerializeRegistryPol(Values,Buffer);
  if Status<>grsOk then
  begin Error:='无效记录：键名不能为空，名称须为有效 UTF-16，且不能超过格式限制。'; Exit; end;
  case Item.ValueType of
    4,5: if Length(Item.Data)<>4 then begin Error:='DWORD 数据必须恰好为 4 字节。'; Exit; end;
    11: if Length(Item.Data)<>8 then begin Error:='QWORD 数据必须恰好为 8 字节。'; Exit; end;
    1,2,6,7:
    begin
      if Odd(Length(Item.Data)) or (Length(Item.Data)<2) then
      begin Error:='字符串数据必须为带终止符的 UTF-16LE。'; Exit; end;
      Units:=Length(Item.Data) div 2;
      if UnitAt(Units-1)<>0 then begin Error:='字符串缺少 UTF-16 终止符。'; Exit; end;
      if (Item.ValueType=7) and ((Units<2) or (UnitAt(Units-2)<>0)) then
      begin Error:='MULTI_SZ 必须以两个 UTF-16 NUL 终止。'; Exit; end;
      if (Item.ValueType=7) and (UnitAt(0)=0) and (Units<>2) then
      begin Error:='MULTI_SZ 不能包含前导空字符串。'; Exit; end;
      I:=0; PreviousZero:=False;
      while I<Units do
      begin
        C:=UnitAt(I);
        if C=0 then
        begin
          if (Item.ValueType<>7) and (I<>Units-1) then
          begin Error:='字符串中不能包含内部 NUL。'; Exit; end;
          if (Item.ValueType=7) and PreviousZero and (I<>Units-1) then
          begin Error:='MULTI_SZ 的双 NUL 只能出现在结尾。'; Exit; end;
          PreviousZero:=True;
        end else
        begin
          PreviousZero:=False;
          if (C >= $d800) and (C <= $dbff) then
          begin
            Inc(I);
            if I>=Units then begin Error:='UTF-16 代理项无效。'; Exit; end;
            N:=UnitAt(I);
            if (N<$dc00) or (N>$dfff) then begin Error:='UTF-16 代理项无效。'; Exit; end;
          end else if (C >= $dc00) and (C <= $dfff) then
          begin Error:='UTF-16 代理项无效。'; Exit; end;
        end;
        Inc(I);
      end;
    end;
  end;
  Result:=True;
end;

function HexPreview(const Data:TBytes; Limit:Integer):string;
const Digits='0123456789ABCDEF';
var I,N,P:Integer;
begin
  N:=Length(Data); if N>Limit then N:=Limit;
  SetLength(Result,N*3); P:=1;
  for I:=0 to N-1 do
  begin
    Result[P]:=Digits[(Data[I] shr 4)+1]; Result[P+1]:=Digits[(Data[I] and 15)+1];
    Result[P+2]:=' '; Inc(P,3);
  end;
  if N<Length(Data) then Result:=Result+'... ';
end;

function GpoEncodeFriendly(ValueType:Cardinal; const Text:string; out Data:TBytes; out Error:string):Boolean;
var I,N:Integer; V:QWord; U:UnicodeString; R:TGpoRegistryRecord;
begin
  Result:=False; Data:=nil; Error:='';
  case ValueType of
    4,11:
    begin
      if Text='' then begin Error:='请输入无符号十进制整数。'; Exit; end;
      for I:=1 to Length(Text) do if not (Text[I] in ['0'..'9']) then
      begin Error:='请输入无符号十进制整数。'; Exit; end;
      if not TryStrToQWord(Text,V) or ((ValueType=4) and (V>High(Cardinal))) then
      begin Error:='数值超出类型范围。'; Exit; end;
      if ValueType=4 then N:=4 else N:=8;
      SetLength(Data,N);
      for I:=0 to N-1 do begin Data[I]:=Byte(V and $ff); V:=V shr 8; end;
    end;
    1:
    begin
      U:=UTF8Decode(Text);
      if Length(U)>(GpoMaxValueBytes div 2)-1 then
      begin Error:='文本超过数据长度限制。'; Exit; end;
      SetLength(Data,(Length(U)+1)*2);
      for I:=1 to Length(U) do begin Data[(I-1)*2]:=Ord(U[I]) and $ff; Data[(I-1)*2+1]:=Ord(U[I]) shr 8; end;
      Data[Length(Data)-2]:=0; Data[Length(Data)-1]:=0;
      R:=Default(TGpoRegistryRecord); R.Key:='K'; R.ValueType:=1; R.Data:=Data;
      if not GpoValidateDraftRecord(R,Error) then begin Data:=nil; Exit; end;
    end;
    else begin Error:='此类型请继续使用原始十六进制数据。'; Exit; end;
  end;
  Result:=True;
end;

procedure TFriendlyInput.Click(Sender:TObject);
var Text,Error,Prompt:string; Data:TBytes; Kind:Integer;
begin
  Kind:=TypeBox.ItemIndex;
  if not (Kind in [1,4,11]) then
  begin MessageDlg('本地草稿','仅 REG_SZ、REG_DWORD 和 REG_QWORD 支持此输入方式；其他类型请使用原始十六进制。',mtInformation,[mbOK],0); Exit; end;
  if Kind=1 then Prompt:='输入文本（可为空）:' else Prompt:='输入无符号十进制整数:';
  Text:=''; if not InputQuery('替换原始数据',Prompt,Text) then Exit;
  if not GpoEncodeFriendly(Kind,Text,Data,Error) then
  begin MessageDlg('本地草稿',Error,mtError,[mbOK],0); Exit; end;
  HexMemo.Text:=HexPreview(Data,GpoMaxValueBytes);
end;

function BuildPreview(const Changes:TGpoRegistryChanges; Page:Integer; const Summary:string):string;
var I,J,N,First,Last,Pages:Integer; C:TGpoRegistryChange; S:TStringList; OldByte,NewByte:string;
  function Describe(const R:TGpoRegistryRecord):UnicodeString;
  begin
    Result:=R.Key+' | '+R.ValueName+' | 类型 '+
      UnicodeString(UIntToStr(R.ValueType))+' | '+UnicodeString(HexPreview(R.Data,64))+
      '('+UnicodeString(IntToStr(Length(R.Data)))+' 字节)';
  end;
begin
  Pages:=(Length(Changes)+199) div 200; if Pages=0 then Pages:=1;
  if Page<0 then Page:=0; if Page>=Pages then Page:=Pages-1;
  First:=Page*200; Last:=First+199; if Last>High(Changes) then Last:=High(Changes);
  S:=TStringList.Create;
  try
    S.Add(Summary);
    S.Add('本地草稿原始记录位置差异；不表示最终生效策略。每条数据最多显示前 64 字节。');
    S.Add('差异数：'+IntToStr(Length(Changes))+'。中间插入/删除可能使后续行显示为修改。');
    S.Add(Format('第 %d / %d 页；每页最多 200 条差异。',[Page+1,Pages]));
    for I:=First to Last do
    begin
      C:=Changes[I]; S.Add('记录 '+IntToStr(C.Index+1)+':');
      if C.Kind<>gckAdded then S.Add(UTF8Encode(UnicodeString('  原：')+Describe(C.BeforeValue)));
      if C.Kind<>gckRemoved then S.Add(UTF8Encode(UnicodeString('  新：')+Describe(C.AfterValue)));
      if C.Kind=gckChanged then
      begin
        N:=Length(C.BeforeValue.Data); if Length(C.AfterValue.Data)<N then N:=Length(C.AfterValue.Data);
        J:=0; while (J<N) and (C.BeforeValue.Data[J]=C.AfterValue.Data[J]) do Inc(J);
        if (J<N) or (Length(C.BeforeValue.Data)<>Length(C.AfterValue.Data)) then
        begin
          OldByte:=SNoByte; NewByte:=SNoByte;
          if J<Length(C.BeforeValue.Data) then OldByte:=IntToHex(C.BeforeValue.Data[J],2);
          if J<Length(C.AfterValue.Data) then NewByte:=IntToHex(C.AfterValue.Data[J],2);
          S.Add(Format(SDiffOffset,[J,OldByte,NewByte]));
        end;
      end;
    end;
    Result:=S.Text;
  finally S.Free; end;
end;

type
  TGpoPreviewWindow=class(TForm)
  private
    fChanges:TGpoRegistryChanges;
    fSummary:string;
    fPage, fPages:Integer;
    fMemo:TMemo;
    fPrevious, fNext:TButton;
    procedure Step(Sender:TObject);
    procedure Render;
  public
    constructor CreatePreview(TheOwner:TComponent; const Changes:TGpoRegistryChanges; const Summary:string);
  end;

constructor TGpoPreviewWindow.CreatePreview(TheOwner:TComponent; const Changes:TGpoRegistryChanges; const Summary:string);
var Bar:TPanel; Button:TButton;
begin
  inherited CreateNew(TheOwner,0);
  fChanges:=Changes; fSummary:=Summary; fPages:=(Length(Changes)+199) div 200; if fPages=0 then fPages:=1;
  Caption:='本地草稿：原始记录变更预览'; Width:=900; Height:=600; Position:=poScreenCenter;
  Bar:=TPanel.Create(Self); Bar.Parent:=Self; Bar.Align:=alBottom; Bar.Height:=36; Bar.BevelOuter:=bvNone;
  fPrevious:=TButton.Create(Self); fPrevious.Parent:=Bar; fPrevious.SetBounds(8,3,100,29);
  fPrevious.Name:='GpoPreviewPrevious';
  fPrevious.Caption:='上一页'; fPrevious.Tag:=-1; fPrevious.OnClick:=@Step;
  fNext:=TButton.Create(Self); fNext.Parent:=Bar; fNext.SetBounds(116,3,100,29);
  fNext.Name:='GpoPreviewNext';
  fNext.Caption:='下一页'; fNext.Tag:=1; fNext.OnClick:=@Step;
  Button:=TButton.Create(Self); Button.Parent:=Bar; Button.Align:=alRight;
  Button.Width:=100; Button.Caption:='关闭'; Button.ModalResult:=mrClose;
  fMemo:=TMemo.Create(Self); fMemo.Parent:=Self; fMemo.Align:=alClient;
  fMemo.Name:='GpoPreviewMemo';
  fMemo.ScrollBars:=ssAutoBoth; fMemo.WordWrap:=False; fMemo.ReadOnly:=True;
  Render;
end;
procedure TGpoPreviewWindow.Render;
begin
  fMemo.Text:=BuildPreview(fChanges,fPage,fSummary);
  fPrevious.Enabled:=fPage>0; fNext.Enabled:=fPage<fPages-1;
end;
procedure TGpoPreviewWindow.Step(Sender:TObject);
begin
  Inc(fPage,TControl(Sender).Tag);
  if fPage<0 then fPage:=0 else if fPage>=fPages then fPage:=fPages-1;
  Render;
end;

constructor TFrmGpoOfflineDraft.Create(TheOwner:TComponent);
var LeftPanel,ToolPanel:TPanel; Root:TTreeNode; Side:TGpoDraftSide; Empty:TBytes;
  function MakeButton(const Text:string; Col,Row:Integer; Handler:TNotifyEvent):TButton;
  begin
    Result:=TButton.Create(Self); Result.Parent:=ToolPanel;
    Result.Caption:=Text; Result.SetBounds(Col*132+6,Row*32+3,126,27);
    Result.OnClick:=Handler;
  end;
begin
  inherited CreateNew(TheOwner,0);
  Caption:='本地离线 GPO 草稿（不会应用到域）'; Width:=1110; Height:=720;
  Constraints.MinWidth:=940; Constraints.MinHeight:=500; Position:=poScreenCenter;
  OnCloseQuery:=@Closing;
  for Side:=Low(TGpoDraftSide) to High(TGpoDraftSide) do
  begin
    fDrafts[Side]:=TGpoRegistryDraft.Create;
    if SerializeRegistryPol(nil,Empty)<>grsOk then raise Exception.Create('Cannot initialize draft');
    if fDrafts[Side].Load(Empty)<>grsOk then raise Exception.Create('Cannot initialize draft');
  end;
  LeftPanel:=TPanel.Create(Self); LeftPanel.Parent:=Self; LeftPanel.Align:=alLeft; LeftPanel.Width:=300;
  with TSplitter.Create(Self) do begin Parent:=Self; Left:=LeftPanel.Width; Align:=alLeft; MinSize:=180; end;
  fTree:=TTreeView.Create(Self); fTree.Parent:=LeftPanel; fTree.Align:=alClient;
  Root:=fTree.Items.Add(nil,'本地策略草稿');
  fComputerNode:=fTree.Items.AddChild(Root,SComputer);
  fUserNode:=fTree.Items.AddChild(Root,SUser);
  Root.Expand(False); fTree.OnChange:=@TreeChanged;
  ToolPanel:=TPanel.Create(Self); ToolPanel.Parent:=Self; ToolPanel.Align:=alTop;
  ToolPanel.Height:=100; ToolPanel.BevelOuter:=bvNone;
  fNew:=MakeButton('新建草稿',0,0,@NewClick);
  fOpen:=MakeButton('打开本地文件',1,0,@OpenClick);
  fSave:=MakeButton('导出本地新文件',2,0,@SaveClick);
  fAdd:=MakeButton('添加记录',3,0,@AddClick);
  fEdit:=MakeButton('修改记录',4,0,@EditClick);
  fDelete:=MakeButton('删除记录',0,1,@DeleteClick);
  fUndo:=MakeButton('撤销一步',1,1,@UndoClick);
  fReset:=MakeButton(SRestoreBaseline,2,1,@ResetClick);
  fPreview:=MakeButton('预览记录变更',3,1,@PreviewClick);
  fPlan:=MakeButton('本地计划预演…',4,1,@PlanClick);
  with TLabel.Create(Self) do begin Parent:=ToolPanel; Caption:='查找记录：'; SetBounds(8,72,80,24); end;
  fFindText:=TEdit.Create(Self); fFindText.Parent:=ToolPanel; fFindText.SetBounds(88,68,240,26);
  fFindText.OnChange:=@FindChanged; fFindText.OnKeyDown:=@FindKeyDown;
  fFindButton:=TButton.Create(Self); fFindButton.Parent:=ToolPanel; fFindButton.Caption:='查找下一个';
  fFindButton.SetBounds(335,67,110,27); fFindButton.OnClick:=@FindClick;
  fFindStatus:=TLabel.Create(Self); fFindStatus.Parent:=ToolPanel; fFindStatus.SetBounds(452,72,300,24);
  fStatus:=TLabel.Create(Self); fStatus.Parent:=Self; fStatus.Align:=alBottom;
  fStatus.AutoSize:=False; fStatus.Height:=44; fStatus.Layout:=tlCenter;
  fStatus.WordWrap:=True;
  fPane:=TGpoRegistryPane.Create(Self); fPane.Parent:=Self; fPane.Align:=alClient;
  fPane.Rows.OnDblClick:=@RowDblClick;
  fPane.Rows.OnKeyDown:=nil; fPane.Rows.OnSelectItem:=@RowSelected; fPane.ViewButton.Visible:=False;
  fSavedIndex[gdsComputer]:=-1; fSavedIndex[gdsUser]:=-1;
  fSide:=gdsComputer; fValidSide:=True; fTree.Selected:=fComputerNode; RefreshView;
end;
function TFrmGpoOfflineDraft.ChooseGptFile(out Path:string):Boolean;
var D:TOpenDialog;
begin
  Path:=''; D:=TOpenDialog.Create(Self);
  try
    D.Title:='选择本地 GPT.INI 快照'; D.Filter:='INI 文件 (*.ini)|*.ini|所有文件 (*.*)|*.*';
    D.Options:=D.Options+[ofFileMustExist];
    Result:=D.Execute; if Result then Path:=D.FileName;
  finally D.Free; end;
end;
function TFrmGpoOfflineDraft.RequestGpcVersion(out Value:string):Boolean;
begin
  Value:='';
  Result:=InputQuery('本地计划预演','输入快照中 LDAP versionNumber 的有符号十进制值：',Value);
end;
procedure TFrmGpoOfflineDraft.ShowPlanReport(const Report:string);
var Window:TForm; Memo:TMemo; CloseButton:TButton;
begin
  Window:=TForm.CreateNew(Self,0);
  try
    if fDomain then Window.Caption:='域草稿只读复核（不会应用到域）'
    else Window.Caption:='本地计划预演（不会应用到域）'; Window.Width:=900; Window.Height:=500;
    Window.Position:=poScreenCenter;
    CloseButton:=TButton.Create(Window); CloseButton.Parent:=Window; CloseButton.Align:=alBottom;
    CloseButton.Height:=36; CloseButton.Caption:='关闭'; CloseButton.ModalResult:=mrClose;
    Memo:=TMemo.Create(Window); Memo.Parent:=Window; Memo.Align:=alClient; Memo.ReadOnly:=True;
    Memo.ScrollBars:=ssAutoBoth; Memo.WordWrap:=False; Memo.Text:=Report;
    Window.ShowModal;
  finally Window.Free; end;
end;
procedure TFrmGpoOfflineDraft.PlanClick(Sender:TObject);
var Input,Path,Err,Report,UserPath,MachinePath:string; Gpc,Gpt:Cardinal;
  Ini,OldUser,NewUser,OldMachine,NewMachine,Disk:TBytes; P:TGpoOfflinePlan; Status:TGpoOfflinePlanStatus;
  function SameBytes(const A,B:TBytes):Boolean;
  begin
    Result:=Length(A)=Length(B);
    if Result and (Length(A)>0) then Result:=CompareMem(@A[0],@B[0],Length(A));
  end;
  function SameDraft(Side:TGpoDraftSide; const Baseline,Current:TBytes; const SourcePath:string):Boolean;
  var B,C:TBytes;
  begin
    Result:=(fPaths[Side]=SourcePath) and (fDrafts[Side].Baseline(B)=grsOk) and
      (fDrafts[Side].Export(C)=grsOk) and SameBytes(B,Baseline) and SameBytes(C,Current);
  end;
  function ActionText(Action:TGpoPolicyAction):string;
  begin
    case Action of
      gpaNone:Result:='无变化'; gpaCreate:Result:='创建';
      gpaReplace:Result:='替换'; gpaDelete:Result:='删除';
    end;
  end;
begin
  if fDomain then begin DomainPlanClick; Exit; end;
  if (fPaths[gdsUser]='') or (fPaths[gdsComputer]='') then
  begin ShowError('请先为计算机和用户两侧分别打开或导出本地 Registry.pol 基线。'); Exit; end;
  UserPath:=fPaths[gdsUser]; MachinePath:=fPaths[gdsComputer];
  if (fDrafts[gdsUser].Baseline(OldUser)<>grsOk) or (fDrafts[gdsUser].Export(NewUser)<>grsOk) or
     (fDrafts[gdsComputer].Baseline(OldMachine)<>grsOk) or (fDrafts[gdsComputer].Export(NewMachine)<>grsOk) then
  begin ShowError('无法读取本地草稿快照。'); Exit; end;
  if not RequestGpcVersion(Input) then Exit;
  if not GpoParseLdapVersion(Input,Gpc) then begin ShowError('LDAP versionNumber 必须是有效的有符号 32 位十进制数。'); Exit; end;
  if not ChooseGptFile(Path) then Exit;
  if not SameDraft(gdsUser,OldUser,NewUser,UserPath) or
     not SameDraft(gdsComputer,OldMachine,NewMachine,MachinePath) then
  begin ShowError('输入期间本地草稿或基线已变化，请重新开始预演。'); Exit; end;
  if not GpoLoadLocalFile(MachinePath,Disk,Err) then
  begin ShowError('无法重新读取计算机基线：'+Err); Exit; end;
  if not SameBytes(Disk,OldMachine) then
  begin ShowError('计算机基线文件已变化，请重新加载后再预演。'); Exit; end;
  if not GpoLoadLocalFile(UserPath,Disk,Err) then
  begin ShowError('无法重新读取用户基线：'+Err); Exit; end;
  if not SameBytes(Disk,OldUser) then
  begin ShowError('用户基线文件已变化，请重新加载后再预演。'); Exit; end;
  if not GpoLoadLocalFile(Path,Ini,Err) then begin ShowError(Err); Exit; end;
  if ParseGptIni(Ini,Gpt)<>grsOk then begin ShowError('无法解析本地 GPT.INI 版本。'); Exit; end;
  Status:=GpoBuildOfflinePlan(Gpc,Gpt,Ini,OldUser,NewUser,OldMachine,NewMachine,P);
  if Status<>gopOk then
  begin
    if Status=gopBaselineMismatch then ShowError('输入的 LDAP 版本与本地 GPT.INI 版本不一致。')
    else ShowError('本地快照无效或包含不支持的 GPT.INI 格式，无法生成预演。');
    Exit;
  end;
  Report:='仅本地预演：来源未经验证，不构成域写入授权，不会应用到域。'+LineEnding+
    '计算机基线：'+MachinePath+LineEnding+'用户基线：'+UserPath+LineEnding+
    'GPT.INI 快照：'+Path+LineEnding+'输入 LDAP versionNumber：'+Input+LineEnding+
    '计算机策略：'+ActionText(P.MachineAction)+LineEnding+'用户策略：'+ActionText(P.UserAction)+LineEnding+
    'GPT 版本：'+UIntToStr(Gpt)+' → '+P.Version.GptValue+LineEnding+
    'LDAP versionNumber：'+Input+' → '+P.Version.LdapValue+LineEnding+
    '两侧基线文件已重新读取并与内存快照逐字节比较；之后仍可能变化。'+LineEnding+
    '未验证文件身份、域控、权限、并发或复制；不执行写入。';
  ShowPlanReport(Report);
end;

function TFrmGpoOfflineDraft.InitializeDomainDraft(const Job:IGpoDomainDraftJob; const DC,DN:string):Boolean;
var Empty,UserBytes,MachineBytes:TBytes; User,Machine:TGpoPolicyImage;
begin
  Result:=False;
  if not Assigned(Job) or (Job.State<>gddsReady) or not Job.Initial(User,Machine) or (DC='') or (DN='') or
    (SerializeRegistryPol(nil,Empty)<>grsOk) then Exit;
  if ((not User.Exists) and (Length(User.Data)<>0)) or
    ((not Machine.Exists) and (Length(Machine.Data)<>0)) then Exit;
  if User.Exists then UserBytes:=Copy(User.Data) else UserBytes:=Copy(Empty);
  if Machine.Exists then MachineBytes:=Copy(Machine.Data) else MachineBytes:=Copy(Empty);
  if (fDrafts[gdsUser].Load(UserBytes)<>grsOk) or (fDrafts[gdsComputer].Load(MachineBytes)<>grsOk) then Exit;
  if Job.State<>gddsReady then Exit;
  fDomain:=True; fDomainJob:=Job; fDomainExists[gdsUser]:=User.Exists;
  fDomainExists[gdsComputer]:=Machine.Exists; fDomainTarget:=DC+' / '+DN;
  Caption:='域目标绑定草稿（只读，不会应用到域）';
  fPlan.Caption:='只读复核草稿…'; fTree.Items[0].Text:='域目标绑定草稿';
  OnClose:=@DomainClosed;
  fDomainTimer:=TTimer.Create(Self); fDomainTimer.Interval:=100; fDomainTimer.OnTimer:=@PollDomainPlan; fDomainTimer.Enabled:=True;
  RefreshView; Result:=True;
end;

function TFrmGpoOfflineDraft.DomainCandidates(out User,Machine:TGpoPolicyImage):Boolean;
begin
  User:=Default(TGpoPolicyImage); Machine:=Default(TGpoPolicyImage);
  User.Exists:=fDomainExists[gdsUser] or fDrafts[gdsUser].Dirty;
  Machine.Exists:=fDomainExists[gdsComputer] or fDrafts[gdsComputer].Dirty;
  Result:=(fDrafts[gdsUser].Export(User.Data)=grsOk) and (fDrafts[gdsComputer].Export(Machine.Data)=grsOk);
  if not User.Exists then User.Data:=nil;
  if not Machine.Exists then Machine.Data:=nil;
end;

procedure TFrmGpoOfflineDraft.DomainPlanClick;
begin
  if fDomainWaiting or not Assigned(fDomainJob) then Exit;
  if not DomainCandidates(fPendingUser,fPendingMachine) then begin ShowError('无法读取域草稿内容。'); Exit; end;
  if not fDomainJob.Submit(fPendingUser,fPendingMachine) then
  begin ShowError('域会话已失效或后台仍在工作；草稿可继续编辑和本地导出。'); Exit; end;
  fDomainWaiting:=True; fPlan.Enabled:=False;
  fDomainStarted:=GetTickCount64;
  fStatus.Caption:='正在后台只读复核原域目标；关闭属性页或连接变化会使结果失效。';
end;

procedure TFrmGpoOfflineDraft.PollDomainPlan(Sender:TObject);
var User,Machine:TGpoPolicyImage; MessageText:string;
  function SameImage(const A,B:TGpoPolicyImage):Boolean;
  begin
    Result:=(A.Exists=B.Exists) and (Length(A.Data)=Length(B.Data));
    if Result and (Length(A.Data)>0) then Result:=CompareMem(@A.Data[0],@B.Data[0],Length(A.Data));
  end;
  function ActionText(Side:TGpoDraftSide; const Candidate:TGpoPolicyImage):string;
  begin
    if not fDomainExists[Side] and Candidate.Exists then Exit('创建');
    if fDomainExists[Side] and fDrafts[Side].Dirty then Exit('替换');
    Result:='无变化';
  end;
begin
  if not Assigned(fDomainJob) then Exit;
  if fDomainWaiting and (GetTickCount64-fDomainStarted>=30000) then fDomainJob.Cancel;
  if fDomainJob.State=gddsStopped then
  begin
    fPlan.Enabled:=False; fDomainWaiting:=False;
    fStatus.Caption:='域会话已失效；草稿仍可编辑和导出，不可继续域复核。后台系统调用可能仍在等待返回。'; Exit;
  end;
  if not fDomainWaiting or (fDomainJob.State<>gddsResult) then Exit;
  fDomainWaiting:=False; fPlan.Enabled:=True;
  if not DomainCandidates(User,Machine) or not SameImage(User,fPendingUser) or not SameImage(Machine,fPendingMachine) then
  begin ShowError('复核期间草稿已变化，旧结果已丢弃；请重新复核。'); Exit; end;
  MessageText:=fDomainJob.ResultText;
  if MessageText='' then MessageText:='只读复核未完成；草稿保留。';
  ShowPlanReport(MessageText+LineEnding+'目标：'+fDomainTarget+LineEnding+
    '计算机文件：'+ActionText(gdsComputer,Machine)+'；用户文件：'+ActionText(gdsUser,User)+LineEnding+
    '结果仅反映本次采集，之后可能发生变化；不会执行域写入。');
end;

procedure TFrmGpoOfflineDraft.DomainClosed(Sender:TObject; var CloseAction:TCloseAction);
begin
  if Assigned(fDomainJob) then fDomainJob.Cancel;
  fDomainJob:=nil; CloseAction:=caFree;
end;

destructor TFrmGpoOfflineDraft.Destroy;
var Side:TGpoDraftSide;
begin
  if Assigned(fDomainTimer) then fDomainTimer.Enabled:=False;
  if Assigned(fDomainJob) then fDomainJob.Cancel;
  fDomainJob:=nil;
  for Side:=Low(TGpoDraftSide) to High(TGpoDraftSide) do fDrafts[Side].Free;
  inherited Destroy;
end;

function TFrmGpoOfflineDraft.Current:TGpoRegistryDraft;
begin Result:=fDrafts[fSide]; end;
function TFrmGpoOfflineDraft.Draft(Side:TGpoDraftSide):TGpoRegistryDraft;
begin Result:=fDrafts[Side]; end;
procedure TFrmGpoOfflineDraft.SelectSide(Side:TGpoDraftSide);
var Node:TTreeNode;
begin
  if Side=gdsComputer then Node:=fComputerNode else Node:=fUserNode;
  fTree.Selected:=Node;
  if (fSide<>Side) or not fValidSide then TreeChanged(fTree,Node);
end;
procedure TFrmGpoOfflineDraft.TreeChanged(Sender:TObject; Node:TTreeNode);
var NewSide:TGpoDraftSide;
begin
  fFindStatus.Caption:='';
  if fValidSide then begin fSavedPage[fSide]:=fPane.PageSelector.ItemIndex; fSavedIndex[fSide]:=SelectedIndex; end;
  if (Node<>fUserNode) and (Node<>fComputerNode) then begin fValidSide:=False; RefreshView; Exit; end;
  if Node=fUserNode then NewSide:=gdsUser else NewSide:=gdsComputer;
  fSide:=NewSide; fValidSide:=True; RefreshView(fSavedIndex[fSide],False);
end;
procedure TFrmGpoOfflineDraft.RowSelected(Sender:TObject; Item:TListItem; Selected:Boolean);
begin
  fFindStatus.Caption:='';
  fEdit.Enabled:=fValidSide and Selected;
  fDelete.Enabled:=fEdit.Enabled;
end;
function TFrmGpoOfflineDraft.SelectedIndex:Integer;
begin
  Result:=-1;
  if Assigned(fPane.Rows.Selected) and (fPane.PageSelector.ItemIndex>=0) then
    Result:=fPane.PageSelector.ItemIndex*GpoRegistryPageSize+fPane.Rows.Selected.Index;
end;
procedure TFrmGpoOfflineDraft.RefreshView(SelectedIndex:Integer; PreserveCurrent:Boolean);
var Rows:TGpoRegistryRecords; State,SideName,Path:string; Row:Integer;
begin
  fComputerNode.Text:=SComputer; if fDrafts[gdsComputer].Dirty then fComputerNode.Text:=SComputer+SDirty;
  fUserNode.Text:=SUser; if fDrafts[gdsUser].Dirty then fUserNode.Text:=SUser+SDirty;
  fNew.Enabled:=fValidSide and not fDomain; fOpen.Enabled:=fValidSide and not fDomain; fSave.Enabled:=fValidSide;
  fAdd.Enabled:=fValidSide; fPreview.Enabled:=fValidSide; fFindButton.Enabled:=fValidSide;
  if not fValidSide then begin
    fPane.Bind(nil); fStatus.Caption:=SChooseSide; fEdit.Enabled:=False; fDelete.Enabled:=False;
    fUndo.Enabled:=False; fReset.Enabled:=False; Exit;
  end;
  if (SelectedIndex<0) and PreserveCurrent then SelectedIndex:=Self.SelectedIndex;
  Rows:=Current.Records; fPane.Bind(Rows);
  if (SelectedIndex<0) and (fSavedPage[fSide]>=0) then fPane.SelectPage(fSavedPage[fSide]);
  if (SelectedIndex>=0) and (SelectedIndex<Length(Rows)) then
  begin
    fPane.SelectPage(SelectedIndex div GpoRegistryPageSize);
    Row:=SelectedIndex mod GpoRegistryPageSize;
    if Row<fPane.Rows.Items.Count then fPane.Rows.Items[Row].Selected:=True;
  end;
  if fSide=gdsComputer then SideName:='计算机配置' else SideName:='用户配置';
  if Current.Dirty then State:='有未保存修改' else State:='无未保存修改';
  Path:=fPaths[fSide]; if Path='' then Path:='新建空草稿';
  fStatus.Caption:='本地离线草稿 | '+SideName+' | '+State+' | '+Path+
    '。仅原始 Registry.pol；不会应用到域。';
  if fDomain then
  begin
    if fDomainExists[fSide] then Path:='域基线文件存在'
    else Path:='域基线文件缺失；增加记录后候选为创建';
    fStatus.Caption:='域目标绑定草稿 | '+SideName+' | '+State+' | '+Path+
      '。'+fDomainTarget+'；只读，不会应用到域。';
    fPlan.Enabled:=not fDomainWaiting and Assigned(fDomainJob) and (fDomainJob.State in [gddsReady,gddsResult]);
  end;
  fEdit.Enabled:=Assigned(fPane.Rows.Selected); fDelete.Enabled:=fEdit.Enabled;
  fUndo.Enabled:=Current.CanUndo; fReset.Enabled:=Current.Dirty;
end;
function TFrmGpoOfflineDraft.ConfirmDiscard:Boolean;
begin
  Result:=MessageDlg('未保存的本地草稿','存在未保存的修改，确定放弃吗？',
    mtConfirmation,[mbYes,mbNo],0)=mrYes;
end;
function TFrmGpoOfflineDraft.ConfirmClose(const Branches:string):TGpoCloseChoice;
var Choice:Integer;
begin
  Choice:=QuestionDlg(SCloseTitle,Format(SCloseQuestion,[Branches]),mtConfirmation,
    [mrYes,SCloseYes,mrNo,SCloseNo,mrCancel,SCloseCancel,'IsCancel','IsDefault'],0);
  case Choice of mrYes:Result:=gccExport; mrNo:Result:=gccDiscard; else Result:=gccReturn; end;
end;
function TFrmGpoOfflineDraft.ConfirmRestore:Boolean;
begin
  Result:=MessageDlg(SRestoreBaseline,SRestoreQuestion,
    mtConfirmation,[mbYes,mbNo],0)=mrYes;
end;
function TFrmGpoOfflineDraft.ChooseLocalFile(SaveCopy:Boolean; out Path:string):Boolean;
var D:TOpenDialog;
begin
  Path:='';
  if SaveCopy then D:=TSaveDialog.Create(Self) else D:=TOpenDialog.Create(Self);
  try
    D.Filter:='Registry.pol (*.pol)|*.pol|所有文件 (*.*)|*.*';
    if SaveCopy then
    begin
      D.Title:='导出本地新文件（不会覆盖已有文件）';
      D.Options:=D.Options-[ofOverwritePrompt];
      D.FileName:='Registry-copy.pol';
    end else begin D.Title:='打开本地 Registry.pol 文件'; D.Options:=D.Options+[ofFileMustExist]; end;
    Result:=D.Execute; if Result then Path:=D.FileName;
  finally D.Free; end;
end;
procedure TFrmGpoOfflineDraft.ShowError(const MessageText:string);
begin MessageDlg('本地草稿',MessageText,mtError,[mbOK],0); end;
procedure TFrmGpoOfflineDraft.ShowPreview;
var Window:TForm;
begin
  Window:=CreatePreviewWindow;
  try
    Window.ShowModal;
  finally Window.Free; end;
end;
function TFrmGpoOfflineDraft.CreatePreviewWindow:TForm;
var Changes:TGpoRegistryChanges;
begin
  Changes:=Current.Preview;
  Result:=TGpoPreviewWindow.CreatePreview(Self,Changes,PreviewSummary);
end;

function TFrmGpoOfflineDraft.PreviewSummary:string;
var Side:TGpoDraftSide; SideName,State,Source:string;
begin
  if fSide=gdsComputer then SideName:='计算机配置' else SideName:='用户配置';
  Result:='当前差异：'+SideName+LineEnding;
  for Side:=Low(TGpoDraftSide) to High(TGpoDraftSide) do
  begin
    if Side=gdsComputer then SideName:='计算机配置' else SideName:='用户配置';
    if fDrafts[Side].Dirty then State:='有未导出修改' else State:='无未导出修改';
    if fDomain then begin if fDomainExists[Side] then Source:='域文件快照' else Source:='域文件缺失'; end
    else if fPaths[Side]='' then Source:='新建空草稿' else Source:='本地文件 '+fPaths[Side];
    Result:=Result+SideName+'：'+State+'；基线：'+Source+LineEnding;
  end;
  if fDomain then Result:=Result+'域目标：'+fDomainTarget+'；只能只读复核，不授权写入。'
  else Result:=Result+'域版本：未知；本地草稿没有域基线，不能生成域变更计划。';
end;

procedure TFrmGpoOfflineDraft.Closing(Sender:TObject; var CanClose:Boolean);
var Branches:string; Choice:TGpoCloseChoice; Side:TGpoDraftSide;
begin
  CanClose:=False; Branches:='';
  if fDrafts[gdsComputer].Dirty then Branches:=SComputer;
  if fDrafts[gdsUser].Dirty then begin if Branches<>'' then Branches:=Branches+'、'; Branches:=Branches+SUser; end;
  if Branches='' then begin CanClose:=True; Exit; end;
  Choice:=ConfirmClose(Branches);
  if Choice=gccReturn then Exit;
  if Choice=gccDiscard then begin CanClose:=True; Exit; end;
  for Side:=Low(TGpoDraftSide) to High(TGpoDraftSide) do
    if fDrafts[Side].Dirty then begin SelectSide(Side); if not ExportCurrent then Exit; end;
  CanClose:=True;
end;
procedure TFrmGpoOfflineDraft.NewClick(Sender:TObject);
var Empty:TBytes;
begin
  if Current.Dirty and not ConfirmDiscard then Exit;
  if (SerializeRegistryPol(nil,Empty)<>grsOk) or (Current.Load(Empty)<>grsOk) then
  begin ShowError('无法新建草稿。'); Exit; end;
  fPaths[fSide]:=''; RefreshView;
end;
procedure TFrmGpoOfflineDraft.OpenClick(Sender:TObject);
var Path,Err:string; Data:TBytes; Status:TGpoReadStatus;
begin
  if Current.Dirty and not ConfirmDiscard then Exit;
  if not ChooseLocalFile(False,Path) then Exit;
  if not GpoLoadLocalFile(Path,Data,Err) then begin ShowError(Err); Exit; end;
  Status:=Current.Load(Data);
  if Status<>grsOk then begin ShowError('无法载入 Registry.pol：'+GpoStatusText(Status)); Exit; end;
  fPaths[fSide]:=Path; RefreshView;
end;
function TFrmGpoOfflineDraft.ExportCurrent:Boolean;
var Path,Err,SideName:string; Data:TBytes;
begin
  Result:=False;
  if not ChooseLocalFile(True,Path) then Exit;
  if Current.Export(Data)<>grsOk then begin ShowError('无法导出草稿。'); Exit; end;
  if not GpoSaveNewLocalFile(Path,Data,Err) then begin ShowError(Err); Exit; end;
  if not fDomain then
  begin
    if Current.Load(Data)<>grsOk then begin ShowError('文件已创建，但无法更新草稿状态。'); Exit; end;
    fPaths[fSide]:=Path;
  end;
  RefreshView;
  if fSide=gdsComputer then SideName:=SComputer else SideName:=SUser;
  if fDomain then fStatus.Caption:='已导出 '+SideName+'：'+Path+'；域基线和草稿绑定未改变。'
  else fStatus.Caption:=Format(SExported,[SideName,Path]);
  Result:=True;
end;
procedure TFrmGpoOfflineDraft.SaveClick(Sender:TObject);
begin ExportCurrent; end;
procedure TFrmGpoOfflineDraft.AddClick(Sender:TObject);
var R:TGpoRegistryRecord; Err:string; Rows:TGpoRegistryRecords;
begin
  R:=Default(TGpoRegistryRecord); R.ValueType:=3;
  if not EditRecord(R,True) then Exit;
  if not GpoValidateDraftRecord(R,Err) then begin ShowError(Err); Exit; end;
  Rows:=Current.Records;
  if Current.Insert(Length(Rows),R)<>grsOk then begin ShowError('无法添加记录：超出格式限制。'); Exit; end;
  RefreshView(Length(Rows));
end;
procedure TFrmGpoOfflineDraft.EditClick(Sender:TObject);
var R:TGpoRegistryRecord; Rows:TGpoRegistryRecords; I:Integer; Err:string;
begin
  I:=SelectedIndex; Rows:=Current.Records;
  if (I<0) or (I>=Length(Rows)) then begin ShowError('请先选择一条记录。'); Exit; end;
  R:=Rows[I]; if not EditRecord(R,False) then Exit;
  if not GpoValidateDraftRecord(R,Err) then begin ShowError(Err); Exit; end;
  if Current.Replace(I,R)<>grsOk then begin ShowError('无法修改记录：超出格式限制。'); Exit; end;
  RefreshView(I);
end;
procedure TFrmGpoOfflineDraft.DeleteClick(Sender:TObject);
var I:Integer; Rows:TGpoRegistryRecords;
begin
  I:=SelectedIndex; Rows:=Current.Records;
  if (I<0) or (I>=Length(Rows)) then begin ShowError('请先选择一条记录。'); Exit; end;
  if Current.Delete(I)<>grsOk then begin ShowError('无法删除记录。'); Exit; end;
  if I>=Length(Rows)-1 then Dec(I);
  RefreshView(I);
end;
procedure TFrmGpoOfflineDraft.UndoClick(Sender:TObject);
begin Current.Undo; RefreshView; end;
procedure TFrmGpoOfflineDraft.ResetClick(Sender:TObject);
begin if Current.Dirty and ConfirmRestore then begin Current.Reset; RefreshView; end; end;
procedure TFrmGpoOfflineDraft.RowDblClick(Sender:TObject);
begin EditClick(Sender); end;
function TFrmGpoOfflineDraft.PreviewText(Page:Integer):string;
var Changes:TGpoRegistryChanges;
begin
  Changes:=Current.Preview;
  Result:=BuildPreview(Changes,Page,PreviewSummary);
end;
procedure TFrmGpoOfflineDraft.PreviewClick(Sender:TObject);
begin ShowPreview; end;

procedure TFrmGpoOfflineDraft.FindChanged(Sender:TObject);
begin fFindStatus.Caption:=''; end;

procedure TFrmGpoOfflineDraft.FindKeyDown(Sender:TObject; var Key:Word; Shift:TShiftState);
begin
  if (Key=VK_RETURN) and fFindButton.Enabled then begin FindClick(Sender); Key:=0; end;
end;

procedure TFrmGpoOfflineDraft.FindClick(Sender:TObject);
var Rows:TGpoRegistryRecords; Needle:string; Start,I,Index:Integer;
begin
  if not fValidSide then Exit;
  Needle:=UTF8LowerCase(fFindText.Text);
  if Needle='' then begin fFindStatus.Caption:='请输入键路径或值名称。'; Exit; end;
  Rows:=Current.Records;
  Start:=SelectedIndex+1;
  for I:=0 to Length(Rows)-1 do
  begin
    Index:=(Start+I) mod Length(Rows);
    if (Pos(Needle,UTF8LowerCase(UTF8Encode(Rows[Index].Key)))>0) or
       (Pos(Needle,UTF8LowerCase(UTF8Encode(Rows[Index].ValueName)))>0) then
    begin
      fPane.SelectPage(Index div GpoRegistryPageSize);
      fPane.Rows.Items[Index mod GpoRegistryPageSize].Selected:=True;
      fPane.Rows.Items[Index mod GpoRegistryPageSize].MakeVisible(False);
      fFindStatus.Caption:=Format('已定位第 %d / %d 条（循环查找）。',[Index+1,Length(Rows)]);
      Exit;
    end;
  end;
  fFindStatus.Caption:='当前分支没有匹配的记录。';
end;

function TFrmGpoOfflineDraft.ExecuteRecordDialog(Dialog:TForm):TModalResult;
begin Result:=Dialog.ShowModal; end;

function TFrmGpoOfflineDraft.EditRecord(var Item:TGpoRegistryRecord; Adding:Boolean):Boolean;
const TypeNames:array[0..11] of string = ('REG_NONE','REG_SZ','REG_EXPAND_SZ','REG_BINARY',
  'REG_DWORD','REG_DWORD_BIG_ENDIAN','REG_LINK','REG_MULTI_SZ','REG_RESOURCE_LIST',
  'REG_FULL_RESOURCE_DESCRIPTOR','REG_RESOURCE_REQUIREMENTS_LIST','REG_QWORD');
var Dialog:TForm; KeyEdit,NameEdit:TEdit; TypeBox:TComboBox; HexMemo:TMemo; Friendly:TFriendlyInput;
  Btn:TButton; I,Choice:Integer; Candidate:TGpoRegistryRecord; Err:string;
  procedure LabelAt(const Text:string; TopValue:Integer; Target:TWinControl);
  var L:TLabel;
  begin
    L:=TLabel.Create(Dialog); L.Parent:=Dialog; L.Caption:=Text;
    L.Name:=Target.Name+'Label'; L.FocusControl:=Target;
    L.SetBounds(12,TopValue,570,22);
  end;
begin
  Result:=False; Dialog:=TForm.CreateNew(Self,0);
  try
    if Adding then Dialog.Caption:='添加本地原始注册表记录' else Dialog.Caption:='修改本地原始注册表记录';
    Dialog.Width:=660; Dialog.Height:=510; Dialog.Position:=poScreenCenter; Dialog.BorderStyle:=bsDialog;
    KeyEdit:=TEdit.Create(Dialog); KeyEdit.Parent:=Dialog; KeyEdit.SetBounds(12,35,620,27); KeyEdit.Text:=UTF8Encode(Item.Key);
    KeyEdit.Name:='GpoRecordKey'; KeyEdit.TabOrder:=0;
    LabelAt('注册表键路径(&K)（不含 HKLM/HKCU；不得为空）',12,KeyEdit);
    NameEdit:=TEdit.Create(Dialog); NameEdit.Parent:=Dialog; NameEdit.SetBounds(12,93,620,27); NameEdit.Text:=UTF8Encode(Item.ValueName);
    NameEdit.Name:='GpoRecordValueName'; NameEdit.TabOrder:=1;
    LabelAt('值名称(&N)（可以为空）',70,NameEdit);
    TypeBox:=TComboBox.Create(Dialog); TypeBox.Parent:=Dialog; TypeBox.SetBounds(12,151,620,27); TypeBox.Style:=csDropDownList;
    TypeBox.Name:='GpoRecordType'; TypeBox.TabOrder:=2;
    LabelAt('类型(&T)',128,TypeBox);
    for I:=Low(TypeNames) to High(TypeNames) do TypeBox.Items.Add(TypeNames[I]);
    if Item.ValueType<=11 then TypeBox.ItemIndex:=Item.ValueType
    else begin TypeBox.Items.Add('未知类型 '+UIntToStr(Item.ValueType)); TypeBox.ItemIndex:=12; end;
    HexMemo:=TMemo.Create(Dialog); HexMemo.Parent:=Dialog; HexMemo.SetBounds(12,210,620,190);
    HexMemo.ScrollBars:=ssVertical; HexMemo.Text:=HexPreview(Item.Data,GpoMaxValueBytes);
    HexMemo.Name:='GpoRecordHex'; HexMemo.TabOrder:=3;
    LabelAt('原始数据(&D)：十六进制字节',187,HexMemo);
    Friendly:=TFriendlyInput.Create(Dialog); Friendly.TypeBox:=TypeBox; Friendly.HexMemo:=HexMemo;
    Btn:=TButton.Create(Dialog); Btn.Parent:=Dialog; Btn.SetBounds(280,182,352,27);
    Btn.Name:='GpoRecordFriendly'; Btn.TabOrder:=4;
    Btn.Caption:='用十进制或文本替换数据(&F)…'; Btn.OnClick:=@Friendly.Click;
    Btn:=TButton.Create(Dialog); Btn.Parent:=Dialog; Btn.SetBounds(428,420,95,30);
    Btn.Name:='GpoRecordOK'; Btn.TabOrder:=5;
    Btn.Caption:='确定(&O)'; Btn.ModalResult:=mrOk; Btn.Default:=True;
    Btn:=TButton.Create(Dialog); Btn.Parent:=Dialog; Btn.SetBounds(537,420,95,30);
    Btn.Name:='GpoRecordCancel'; Btn.TabOrder:=6;
    Btn.Caption:='取消(&C)'; Btn.ModalResult:=mrCancel; Btn.Cancel:=True;
    Dialog.ActiveControl:=KeyEdit;
    repeat
      if ExecuteRecordDialog(Dialog)<>mrOk then Exit;
      Candidate:=Item; Candidate.Key:=UTF8Decode(KeyEdit.Text); Candidate.ValueName:=UTF8Decode(NameEdit.Text);
      Choice:=TypeBox.ItemIndex;
      if Choice<0 then begin ShowError('请选择类型。'); Continue; end;
      if Choice<=11 then Candidate.ValueType:=Choice;
      if not GpoParseHex(HexMemo.Text,Candidate.Data,Err) then begin ShowError(Err); Continue; end;
      if not GpoValidateDraftRecord(Candidate,Err) then begin ShowError(Err); Continue; end;
      Item:=Candidate; Result:=True; Exit;
    until False;
  finally Dialog.Free; end;
end;
end.
