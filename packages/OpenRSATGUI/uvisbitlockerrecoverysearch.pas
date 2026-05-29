unit uvisbitlockerrecoverysearch;

{$mode ObjFPC}{$H+}

interface

uses
  ActnList,
  Buttons,
  Classes,
  Controls,
  ExtCtrls,
  Forms,
  Grids,
  StdCtrls,
  mormot.core.base,
  mormot.net.ldap,
  ursatldapclient;

type
  { TVisBitLockerRecoverySearch }

  TVisBitLockerRecoverySearch = class(TForm)
  private
    fLdapClient: TRsatLdapClient;
    fSelectedComputerDN: RawUtf8;
    fComputerDNs: TRawUtf8DynArray;

    PanelSearch: TPanel;
    LabelRecoveryID: TLabel;
    EditRecoveryID: TEdit;
    ButtonSearch: TBitBtn;
    GridResults: TStringGrid;
    PanelButtons: TPanel;
    ButtonCopy: TBitBtn;
    ButtonOpenComputer: TBitBtn;
    ButtonClose: TBitBtn;
    ActionList: TActionList;
    ActionSearch: TAction;
    ActionCopy: TAction;
    ActionOpenComputer: TAction;

    procedure ActionCopyExecute(Sender: TObject);
    procedure ActionCopyUpdate(Sender: TObject);
    procedure ActionOpenComputerExecute(Sender: TObject);
    procedure ActionOpenComputerUpdate(Sender: TObject);
    procedure ActionSearchExecute(Sender: TObject);
    procedure ActionSearchUpdate(Sender: TObject);
    procedure EditRecoveryIDKeyPress(Sender: TObject; var Key: char);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure GridResultsSelectCell(Sender: TObject; aCol, aRow: Integer;
      var CanSelect: Boolean);

    procedure AddResult(const RecoveryDN, RecoveryCN, RecoveryPassword: RawUtf8);
    procedure ClearResults;
    function CurrentRow: Integer;
    function RecoveryIDFilter: RawUtf8;
  public
    constructor Create(TheOwner: TComponent; ALdapClient: TRsatLdapClient); reintroduce;
    property SelectedComputerDN: RawUtf8 read fSelectedComputerDN;
  end;

implementation

uses
  Clipbrd,
  Dialogs,
  SysUtils,
  LCLType,
  mormot.core.text,
  ucommon,
  ucommonui;

resourcestring
  rsFindBitLockerRecoveryPassword = 'Find BitLocker Recovery Password';
  rsRecoveryPasswordID = 'Recovery Password ID:';
  rsRecoveryPasswordIDHint = 'Enter the first 8 characters or the full recovery password ID.';
  rsSearchBitLockerRecovery = 'Search';
  rsCopyPassword = 'Copy password';
  rsOpenComputer = 'Open Computer';
  rsComputer = 'Computer';
  rsRecoveryID = 'Recovery ID';
  rsDateAdded = 'Date Added';
  rsRecoveryPassword = 'Recovery Password';
  rsNoBitLockerRecoveryFound = 'No BitLocker recovery password was found for the specified ID.';
  rsEnterRecoveryID = 'Enter a recovery password ID.';

{ TVisBitLockerRecoverySearch }

constructor TVisBitLockerRecoverySearch.Create(TheOwner: TComponent;
  ALdapClient: TRsatLdapClient);
begin
  inherited CreateNew(TheOwner);

  fLdapClient := ALdapClient;
  fSelectedComputerDN := '';
  SetLength(fComputerDNs, 0);

  Caption := rsFindBitLockerRecoveryPassword;
  Position := poOwnerFormCenter;
  Width := 760;
  Height := 430;
  Constraints.MinWidth := 620;
  Constraints.MinHeight := 320;
  KeyPreview := True;
  OnKeyDown := @FormKeyDown;

  ActionList := TActionList.Create(Self);

  ActionSearch := TAction.Create(Self);
  ActionSearch.Caption := rsSearchBitLockerRecovery;
  ActionSearch.OnExecute := @ActionSearchExecute;
  ActionSearch.OnUpdate := @ActionSearchUpdate;
  ActionSearch.ActionList := ActionList;

  ActionCopy := TAction.Create(Self);
  ActionCopy.Caption := rsCopyPassword;
  ActionCopy.OnExecute := @ActionCopyExecute;
  ActionCopy.OnUpdate := @ActionCopyUpdate;
  ActionCopy.ActionList := ActionList;

  ActionOpenComputer := TAction.Create(Self);
  ActionOpenComputer.Caption := rsOpenComputer;
  ActionOpenComputer.OnExecute := @ActionOpenComputerExecute;
  ActionOpenComputer.OnUpdate := @ActionOpenComputerUpdate;
  ActionOpenComputer.ActionList := ActionList;

  PanelSearch := TPanel.Create(Self);
  PanelSearch.Parent := Self;
  PanelSearch.Align := alTop;
  PanelSearch.AutoSize := True;
  PanelSearch.BevelOuter := bvNone;
  PanelSearch.BorderSpacing.Around := 8;

  LabelRecoveryID := TLabel.Create(Self);
  LabelRecoveryID.Parent := PanelSearch;
  LabelRecoveryID.Caption := rsRecoveryPasswordID;
  LabelRecoveryID.Left := 0;
  LabelRecoveryID.Top := 6;

  EditRecoveryID := TEdit.Create(Self);
  EditRecoveryID.Parent := PanelSearch;
  EditRecoveryID.Left := LabelRecoveryID.Left + LabelRecoveryID.Width + 8;
  EditRecoveryID.Top := 0;
  EditRecoveryID.Width := 360;
  EditRecoveryID.Hint := rsRecoveryPasswordIDHint;
  EditRecoveryID.ShowHint := True;
  EditRecoveryID.OnKeyPress := @EditRecoveryIDKeyPress;

  ButtonSearch := TBitBtn.Create(Self);
  ButtonSearch.Parent := PanelSearch;
  ButtonSearch.Left := EditRecoveryID.Left + EditRecoveryID.Width + 8;
  ButtonSearch.Top := 0;
  ButtonSearch.Action := ActionSearch;
  ButtonSearch.Default := True;

  PanelSearch.Height := ButtonSearch.Height;

  GridResults := TStringGrid.Create(Self);
  GridResults.Parent := Self;
  GridResults.Align := alClient;
  GridResults.BorderSpacing.Around := 8;
  GridResults.ColCount := 4;
  GridResults.FixedCols := 0;
  GridResults.FixedRows := 1;
  GridResults.RowCount := 1;
  GridResults.Options := GridResults.Options + [goRowSelect, goColSizing] -
    [goEditing];
  GridResults.Cells[0, 0] := rsComputer;
  GridResults.Cells[1, 0] := rsRecoveryID;
  GridResults.Cells[2, 0] := rsDateAdded;
  GridResults.Cells[3, 0] := rsRecoveryPassword;
  GridResults.ColWidths[0] := 200;
  GridResults.ColWidths[1] := 235;
  GridResults.ColWidths[2] := 150;
  GridResults.ColWidths[3] := 260;
  GridResults.OnSelectCell := @GridResultsSelectCell;

  PanelButtons := TPanel.Create(Self);
  PanelButtons.Parent := Self;
  PanelButtons.Align := alBottom;
  PanelButtons.AutoSize := True;
  PanelButtons.BevelOuter := bvNone;
  PanelButtons.BorderSpacing.Around := 8;

  ButtonClose := TBitBtn.Create(Self);
  ButtonClose.Parent := PanelButtons;
  ButtonClose.Kind := bkClose;
  ButtonClose.Left := 0;
  ButtonClose.Top := 0;

  ButtonOpenComputer := TBitBtn.Create(Self);
  ButtonOpenComputer.Parent := PanelButtons;
  ButtonOpenComputer.Action := ActionOpenComputer;
  ButtonOpenComputer.Left := ButtonClose.Left + ButtonClose.Width + 8;
  ButtonOpenComputer.Top := 0;

  ButtonCopy := TBitBtn.Create(Self);
  ButtonCopy.Parent := PanelButtons;
  ButtonCopy.Action := ActionCopy;
  ButtonCopy.Left := ButtonOpenComputer.Left + ButtonOpenComputer.Width + 8;
  ButtonCopy.Top := 0;

  PanelButtons.Height := ButtonClose.Height;
  UnifyButtonsWidth([ButtonCopy, ButtonOpenComputer, ButtonClose]);
end;

function TVisBitLockerRecoverySearch.CurrentRow: Integer;
begin
  Result := GridResults.Row;
  if (Result <= 0) or (Result >= GridResults.RowCount) then
    Result := -1;
end;

function TVisBitLockerRecoverySearch.RecoveryIDFilter: RawUtf8;
var
  S: String;
begin
  S := Trim(EditRecoveryID.Text);
  S := StringReplace(S, '{', '', [rfReplaceAll]);
  S := StringReplace(S, '}', '', [rfReplaceAll]);
  Result := LdapEscape(RawUtf8(S));
end;

procedure TVisBitLockerRecoverySearch.ClearResults;
begin
  GridResults.RowCount := 1;
  SetLength(fComputerDNs, 0);
end;

procedure TVisBitLockerRecoverySearch.AddResult(const RecoveryDN, RecoveryCN,
  RecoveryPassword: RawUtf8);
var
  ComputerDN, ComputerName: RawUtf8;
  ComputerObj: TLdapResult;
  Row: Integer;
begin
  ComputerDN := GetParentDN(RecoveryDN);
  ComputerName := ComputerDN;
  ComputerObj := fLdapClient.SearchObject(ComputerDN, '',
    ['dNSHostName', 'name']);
  if Assigned(ComputerObj) then
  begin
    if Assigned(ComputerObj.Find('dNSHostName')) then
      ComputerName := ComputerObj.Find('dNSHostName').GetReadable()
    else if Assigned(ComputerObj.Find('name')) then
      ComputerName := ComputerObj.Find('name').GetReadable();
  end;

  Row := GridResults.RowCount;
  GridResults.RowCount := Row + 1;
  GridResults.Cells[0, Row] := String(ComputerName);
  GridResults.Cells[1, Row] := Copy(String(RecoveryCN), 27, 36);
  GridResults.Cells[2, Row] := Copy(String(RecoveryCN), 1, 25);
  GridResults.Cells[3, Row] := String(RecoveryPassword);
  SetLength(fComputerDNs, Length(fComputerDNs) + 1);
  fComputerDNs[High(fComputerDNs)] := ComputerDN;
end;

procedure TVisBitLockerRecoverySearch.ActionSearchExecute(Sender: TObject);
var
  Filter: RawUtf8;
  SearchResult: TLdapResult;
  RecoveryDN, RecoveryCN, RecoveryPassword: RawUtf8;
begin
  if RecoveryIDFilter = '' then
  begin
    MessageDlg(rsFindBitLockerRecoveryPassword, rsEnterRecoveryID,
      mtWarning, [mbOK], 0);
    Exit;
  end;

  ClearResults;
  Filter := FormatUtf8('(&(objectClass=msFVE-RecoveryInformation)(cn=*%*))',
    [RecoveryIDFilter]);

  fLdapClient.SearchBegin;
  try
    fLdapClient.SearchScope := lssWholeSubtree;
    repeat
      if not fLdapClient.Search(fLdapClient.DefaultDN, False, Filter,
        ['cn', 'distinguishedName', 'msFVE-RecoveryPassword']) then
        Exit;

      for SearchResult in fLdapClient.SearchResult.Items do
      begin
        if not Assigned(SearchResult) then
          Continue;
        RecoveryDN := SearchResult.ObjectName;
        if Assigned(SearchResult.Find('distinguishedName')) then
          RecoveryDN := SearchResult.Find('distinguishedName').GetReadable();
        RecoveryCN := SearchResult.Find('cn').GetReadable();
        RecoveryPassword := SearchResult.Find('msFVE-RecoveryPassword').GetReadable();
        AddResult(RecoveryDN, RecoveryCN, RecoveryPassword);
      end;
    until fLdapClient.SearchCookie = '';
  finally
    fLdapClient.SearchEnd;
  end;

  if GridResults.RowCount = 1 then
    MessageDlg(rsFindBitLockerRecoveryPassword, rsNoBitLockerRecoveryFound,
      mtInformation, [mbOK], 0)
  else
    GridResults.Row := 1;
end;

procedure TVisBitLockerRecoverySearch.ActionSearchUpdate(Sender: TObject);
begin
  ActionSearch.Enabled := Assigned(fLdapClient) and fLdapClient.Connected and
    (Trim(EditRecoveryID.Text) <> '');
end;

procedure TVisBitLockerRecoverySearch.ActionCopyExecute(Sender: TObject);
begin
  Clipboard.AsText := GridResults.Cells[3, CurrentRow];
end;

procedure TVisBitLockerRecoverySearch.ActionCopyUpdate(Sender: TObject);
begin
  ActionCopy.Enabled := CurrentRow <> -1;
end;

procedure TVisBitLockerRecoverySearch.ActionOpenComputerExecute(Sender: TObject);
begin
  if CurrentRow <> -1 then
  begin
    fSelectedComputerDN := fComputerDNs[CurrentRow - 1];
    ModalResult := mrOk;
  end;
end;

procedure TVisBitLockerRecoverySearch.ActionOpenComputerUpdate(Sender: TObject);
begin
  ActionOpenComputer.Enabled := CurrentRow <> -1;
end;

procedure TVisBitLockerRecoverySearch.EditRecoveryIDKeyPress(Sender: TObject;
  var Key: char);
begin
  if Key = #13 then
  begin
    Key := #0;
    if ActionSearch.Enabled then
      ActionSearch.Execute;
  end;
end;

procedure TVisBitLockerRecoverySearch.FormKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    Close;
end;

procedure TVisBitLockerRecoverySearch.GridResultsSelectCell(Sender: TObject;
  aCol, aRow: Integer; var CanSelect: Boolean);
begin
  CanSelect := aRow > 0;
end;

end.
