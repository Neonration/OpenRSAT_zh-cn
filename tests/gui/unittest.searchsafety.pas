unit unittest.searchsafety;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  Forms,
  IniPropStorage,
  mormot.core.base,
  mormot.core.test,
  uopenrsatuicontextinterface,
  ursat;

type
  TUnitTestSearchSafety = class(TSynTestCase)
  private
    procedure CheckSearchWindowInvalidation(AfterConnect: Boolean);
  published
    procedure DisconnectInvalidatesEverySearchWindow;
    procedure ReconnectInvalidatesEverySearchWindow;
    procedure AddedRulesKeepTheirOwnCondition;
  end;

  TSearchTestContext = class(TComponent, IOpenRSATUIContext)
  private
    fRSAT: TRSAT;
    fIni: TIniPropStorage;
    fIniFile: String;
  public
    ClosedSearches: Integer;
    OpenedProperties: Integer;
    constructor Create;
    destructor Destroy; override;
    function GetIniPropStorage: TIniPropStorage;
    function GetComponentOwner: TComponent;
    function GetRSAT: TRSAT;
    procedure OpenProperty(DistinguishedName: RawUtf8);
    procedure CloseProperty(DistinguishedName: RawUtf8);
    procedure ChangeDomainController(DomainController: RawUtf8);
    procedure SearchClosed(Sender: TObject; var CloseAction: TCloseAction);
  end;

implementation

uses
  SysUtils,
  mormot.core.variants,
  ucommon,
  ucoredatamodule,
  ufrmmoduleaduc,
  uvissearch;

constructor TSearchTestContext.Create;
begin
  inherited Create(nil);
  fIniFile := GetTempFileName(GetTempDir(False), 'ors');
  fIni := TIniPropStorage.Create(Self);
  fIni.IniFileName := fIniFile;
  fRSAT := TRSAT.Create(nil);
end;

destructor TSearchTestContext.Destroy;
begin
  // Frames still use the context during destruction.
  while ComponentCount > 0 do
    Components[ComponentCount - 1].Free;
  fRSAT.Free;
  DeleteFile(fIniFile);
  inherited Destroy;
end;

function TSearchTestContext.GetIniPropStorage: TIniPropStorage;
begin
  Result := fIni;
end;

function TSearchTestContext.GetComponentOwner: TComponent;
begin
  Result := Self;
end;

function TSearchTestContext.GetRSAT: TRSAT;
begin
  Result := fRSAT;
end;

procedure TSearchTestContext.OpenProperty(DistinguishedName: RawUtf8);
begin
  Inc(OpenedProperties);
end;

procedure TSearchTestContext.CloseProperty(DistinguishedName: RawUtf8);
begin
end;

procedure TSearchTestContext.ChangeDomainController(DomainController: RawUtf8);
begin
  raise Exception.Create('This offline test must never change a real connection.');
end;

procedure TSearchTestContext.SearchClosed(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  Inc(ClosedSearches);
  CloseAction := caHide; // Keep the real forms alive to inspect their invalidated data.
end;

procedure TUnitTestSearchSafety.DisconnectInvalidatesEverySearchWindow;
begin
  CheckSearchWindowInvalidation(False);
end;

procedure TUnitTestSearchSafety.ReconnectInvalidatesEverySearchWindow;
begin
  CheckSearchWindowInvalidation(True);
end;

procedure TUnitTestSearchSafety.CheckSearchWindowInvalidation(AfterConnect: Boolean);
var
  Context: TSearchTestContext;
  Module: TFrmModuleADUC;
  Search: array[0..1] of TVisSearch;
  Row: TDocVariantData;
  I: Integer;
  OwnDataModule: Boolean;
begin
  OwnDataModule := not Assigned(CoreDataModule);
  if OwnDataModule then
    CoreDataModule := TCoreDataModule.Create(nil);
  Context := TSearchTestContext.Create;
  try
    Module := TFrmModuleADUC.Create(Context);
    for I := 0 to High(Search) do
    begin
      Search[I] := TVisSearch.Create(Context, Module);
      Search[I].OnClose := @Context.SearchClosed;
      Row.Init;
      Row.AddValue('distinguishedName', 'CN=PC1,DC=example,DC=test');
      Row.AddValue('objectClassRaw', 'computer');
      Search[I].TisGrid_Result.Data.AddItem(Row);
      Search[I].TisGrid_Result.LoadData;
      Search[I].TisGrid_Result.SelectAll(False);
      Search[I].TisGrid_Result.FocusedNode := Search[I].TisGrid_Result.GetFirst;
      Check(Search[I].TisGrid_Result.SelectedCount = 1);
    end;
    // A failed LDAP unbind may skip OnClose despite disposing of the connection.
    // A later successful connection must invalidate old windows independently.
    if AfterConnect then
      Module.OnLdapConnect(Context.GetRSAT.LdapClient)
    else
      Module.OnLdapClose(Context.GetRSAT.LdapClient);
    Check(Context.ClosedSearches = 2, 'All nonmodal search windows must be closed.');
    for I := 0 to High(Search) do
    begin
      Check(Search[I].TisGrid_Result.Data.Count = 0);
      Check(Search[I].TisGrid_Result.SelectedCount = 0);
      Check(not Assigned(Search[I].TisGrid_Result.FocusedRow));
      Search[I].Action_DeleteUpdate(nil);
      Search[I].Action_BatchMoveOUUpdate(nil);
      Search[I].Action_DeleteComputerFromAllDCUpdate(nil);
      Check(not Search[I].Action_Delete.Enabled);
      Check(not Search[I].Action_BatchMoveOU.Enabled);
      Check(not Search[I].Action_DeleteComputerFromAllDC.Enabled);
      Search[I].Action_PropertiesExecute(nil);
    end;
    Check(Context.OpenedProperties = 0,
      'A queued property action must not open the old DN on the next connection.');
    Check(not Context.GetRSAT.LdapClient.Connected);
  finally
    Context.Free;
    if OwnDataModule then
      FreeAndNil(CoreDataModule);
  end;
end;

procedure TUnitTestSearchSafety.AddedRulesKeepTheirOwnCondition;
var
  Context: TSearchTestContext;
  Search: TVisSearch;
  OwnDataModule: Boolean;
begin
  OwnDataModule := not Assigned(CoreDataModule);
  if OwnDataModule then
    CoreDataModule := TCoreDataModule.Create(nil);
  Context := TSearchTestContext.Create;
  try
    Search := TVisSearch.Create(Context, nil);
    Search.ComboBox_AdvCondition.ItemIndex := 2;
    Search.TisSearchEdit_AdvKey.Text := 'name';
    Search.Edit_AdvValue.Text := 'PC1';
    Search.Action_AdvAddExecute(nil);
    Search.ComboBox_AdvCondition.ItemIndex := 4;
    Search.TisSearchEdit_AdvKey.Text := 'description';
    Search.Edit_AdvValue.Text := '';
    Search.Action_AdvAddExecute(nil);
    Check(BuildAdvancedSearchFilter(Search.TisGrid_AdvDetails.Data, True) =
      '(&(name=PC1)(description=*))');
    Search.ComboBox_AdvCondition.ItemIndex := 5;
    Check(BuildAdvancedSearchFilter(Search.TisGrid_AdvDetails.Data, True) =
      '(&(name=PC1)(description=*))',
      'Editing the pending condition must not alter rules that were already added.');
  finally
    Context.Free;
    if OwnDataModule then
      FreeAndNil(CoreDataModule);
  end;
end;

end.
