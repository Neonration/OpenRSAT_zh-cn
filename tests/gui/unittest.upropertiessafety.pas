unit unittest.upropertiessafety;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, Forms, Controls, mormot.core.test;

type
  TUnitTestPropertiesSafety = class(TSynTestCase)
  private
    fCloseCount: Integer;
    procedure DialogClosing(Sender: TObject; var CloseAction: TCloseAction);
  published
    procedure FailedSaveKeepsDialogAndEdits;
  end;

implementation

uses
  SysUtils, mormot.core.base, mormot.net.ldap, uproperty,
  ursatldapclient, uvisproperties, unittest.searchsafety;

type
  TFailingPropertyClient = class(TRsatLdapClient)
  public
    AcceptWrite: Boolean;
    Writes: Integer;
    function Modify(const Obj: RawUtf8; Op: TLdapModifyOp;
      Attribute: TLdapAttribute): Boolean; override;
    function SearchObject(const ObjectDN, Filter: RawUtf8;
      const Attributes: array of RawUtf8;
      Scope: TLdapSearchScope = lssBaseObject): TLdapResult; override;
  end;

  TTestProperties = class(TVisProperties)
  public
    property Model: TProperty read fProperty;
  end;

function TFailingPropertyClient.Modify(const Obj: RawUtf8; Op: TLdapModifyOp;
  Attribute: TLdapAttribute): Boolean;
begin
  Inc(Writes);
  result := AcceptWrite;
end;

function TFailingPropertyClient.SearchObject(const ObjectDN, Filter: RawUtf8;
  const Attributes: array of RawUtf8; Scope: TLdapSearchScope): TLdapResult;
begin
  if not AcceptWrite then
    raise Exception.Create('A failed save must not refresh over pending edits.');
  result := nil;
end;

procedure TUnitTestPropertiesSafety.DialogClosing(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  Inc(fCloseCount);
  CloseAction := caHide;
end;

procedure TUnitTestPropertiesSafety.FailedSaveKeepsDialogAndEdits;
var
  Context: TSearchTestContext;
  Client: TFailingPropertyClient;
  Dialog: TTestProperties;
  Attributes: TLdapAttributeList;
begin
  Context := TSearchTestContext.Create;
  try
    Context.GetRSAT.LdapClient.Free;
    Client := TFailingPropertyClient.Create;
    Context.GetRSAT.LdapClient := Client;
    Dialog := TTestProperties.Create(Context, 'CN=Test,DC=example,DC=com');
    Dialog.OnShow := nil;
    Dialog.OnClose := @DialogClosing;
    Dialog.IniPropStorage1.Active := False;
    Attributes := TLdapAttributeList.Create;
    try
      Attributes.Add('distinguishedName', 'CN=Test,DC=example,DC=com');
      Attributes.Add('description', 'Original');
      Dialog.Model.Attributes := Attributes;
    finally
      Attributes.Free;
    end;
    Dialog.Model.Add('description', 'Keep this edit');
    fCloseCount := 0;

    Dialog.Btn_BottomOK.Click;
    Check(Client.Writes = 1);
    Check(Dialog.ModalResult = mrNone, 'The button must not close a failed modal save.');
    Check(fCloseCount = 0);
    Check(Dialog.Model.IsModified);
    Check(Dialog.Model.GetRaw('description') = 'Keep this edit');
    Dialog.Action_ApplyUpdate(nil);
    Check(Dialog.Action_Apply.Enabled);

    Client.AcceptWrite := True;
    Dialog.Btn_BottomOK.Click;
    Check(Client.Writes = 2);
    Check(Dialog.ModalResult = mrOK);
    Check(not Dialog.Model.IsModified);
    Check(fCloseCount = 1);
  finally
    Context.Free;
  end;
end;

end.
