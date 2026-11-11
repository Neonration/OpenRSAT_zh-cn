unit ucommonui;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  controls,
  ExtCtrls,
  tis.ui.grid.core,
  VirtualTrees,
  mormot.core.base;

procedure SearchInGrid(const Timer: TTimer; const TisGrid: TTisGrid; var SearchWord: RawUtf8; const Key: Char);
procedure TTisGridClearSelection(grid: TTisGrid);
function TTisGridGetNextUnselected(grid: TTisGrid; Node: PVirtualNode): PVirtualNode;
procedure UnifyButtonsWidth(Butons: array of TControl; default: Integer = -1);
function ShowOperationDetails(const ACaption, Details: String;
  Confirm: Boolean = False): Boolean;

implementation
uses
  Forms,
  StdCtrls,
  ButtonPanel,
  mormot.core.variants;

function ShowOperationDetails(const ACaption, Details: String;
  Confirm: Boolean): Boolean;
var
  Dialog: TForm;
  Memo: TMemo;
  Buttons: TButtonPanel;
begin
  Dialog := TForm.CreateNew(nil);
  try
    Dialog.Caption := ACaption;
    Dialog.Position := poScreenCenter;
    Dialog.SetBounds(0, 0, 760, 520);
    Dialog.Constraints.MinWidth := 420;
    Dialog.Constraints.MinHeight := 280;
    Buttons := TButtonPanel.Create(Dialog);
    Buttons.Parent := Dialog;
    Buttons.Align := alBottom;
    Buttons.ShowButtons := [pbOK];
    if Confirm then
    begin
      Buttons.ShowButtons := [pbOK, pbCancel];
      Buttons.OKButton.Default := False;
      Buttons.CancelButton.Default := True;
      Dialog.ActiveControl := Buttons.CancelButton;
    end;
    Memo := TMemo.Create(Dialog);
    Memo.Parent := Dialog;
    Memo.Align := alClient;
    Memo.BorderSpacing.Around := 8;
    Memo.ReadOnly := True;
    Memo.ScrollBars := ssAutoBoth;
    Memo.WordWrap := False;
    Memo.Lines.Text := Details;
    result := Dialog.ShowModal = mrOK;
  finally
    Dialog.Free;
  end;
end;

procedure SearchInGrid(const Timer: TTimer;
  const TisGrid: TTisGrid; var SearchWord: RawUtf8; const Key: Char);
var
  RowData: PDocVariantData;
  ColumnName: RawUtf8;
  Node, NextNode: PVirtualNode;
begin
  case Timer.Enabled of
    True: Timer.Enabled := False;
    False: SearchWord := '';
  end;

  Insert(Key, SearchWord, Length(SearchWord) + 1);
  ColumnName := TisGrid.FocusedColumnObject.PropertyName;
  NextNode := TisGrid.GetFirst();
  TisGrid.FocusedNode := nil;
  TisGrid.ClearSelection;
  while Assigned(NextNode) do
  begin
    RowData := TisGrid.GetNodeAsPDocVariantData(NextNode);
    Node := NextNode;
    NextNode := TisGrid.GetNext(NextNode);
    if not Assigned(RowData) or not RowData^.Exists(ColumnName) then
      continue;

    if RowData^.S[ColumnName].StartsWith(SearchWord, True) then
    begin
      TisGrid.FocusedNode := Node;
      TisGrid.AddToSelection(Node);
      Break;
    end;
  end;
  Timer.Enabled := True;
  TisGrid.ScrollIntoView(TisGrid.FocusedNode, True);
end;

procedure TTisGridClearSelection(grid: TTisGrid);
var
  i: Integer;
  Selection: TNodeArray;
begin
  Selection := grid.GetSortedSelection(True);
  for i := Length(Selection) - 1 downto 0 do
    grid.RemoveFromSelection(Selection[i]);
  grid.FocusedNode := grid.RootNode;
end;

function TTisGridGetNextUnselected(grid: TTisGrid; Node: PVirtualNode
  ): PVirtualNode;
begin
  repeat
    Node := grid.GetNext(Node);
  until not grid.Selected[Node];
  result := Node;
end;

// Laz
procedure UnifyButtonsWidth(Butons: array of TControl; default: Integer);
var
  BtnWidth, i: Integer;
begin
  BtnWidth := 0;
  if default = -1 then
  begin
    for i := 0 to Length(Butons) - 1 do
      if BtnWidth < Butons[i].Width then
        BtnWidth := Butons[i].Width;
  end else
    BtnWidth := default;
  for i := 0 to Length(Butons) - 1 do
  begin
    Butons[i].Constraints.MinWidth := BtnWidth;
    Butons[i].Width := BtnWidth;
  end;
end;

end.

