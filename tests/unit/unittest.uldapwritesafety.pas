unit unittest.uldapwritesafety;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, mormot.core.base, mormot.core.os.security,
  mormot.core.test, mormot.net.ldap, ursatldapclient, ursat, umoduleaduc,
  uproperty;

type
  TUnitTestLdapWriteSafety = class(TSynTestCase)
  private
    fAcceptWarning, fAcceptPassword: Boolean;
    fPasswordPrompts, fNotifications: Integer;
    function ConfirmComputer(Sender: TObject): Boolean;
    function PasswordPrompt(const Locked: Boolean; out Password: RawUtf8;
      out MustChange, Unlock: Boolean): Boolean;
    procedure PasswordChanged(Sender: TObject);
  published
    procedure PartialObjectCreation;
    procedure TlsPolicyOnActualConnect;
    procedure CancelPasswordReset;
    procedure PasswordWriteFailure;
    procedure AtomicMultiValueFailure;
    procedure RetryOnlyUncommittedEdits;
    procedure RetryTemporaryEdits;
  end;

implementation

type
  TRecordingLdapClient = class(TRsatLdapClient)
  public
    AddCalls: Integer;
    AddFails: Boolean;
    Data: TLdapResult;
    Calls, SingleCalls, ArrayCalls, Searches, FailOnCall: Integer;
    LastModifications: TAsnObjects;
    WrittenNames: TRawUtf8DynArray;
    function Add(const Obj: RawUtf8; Value: TLdapAttributeList): Boolean; override;
    function Modify(const Obj: RawUtf8; Op: TLdapModifyOp; const AttrName: RawUtf8;
      const AttrValue: RawByteString): Boolean; override;
    constructor Create;
    destructor Destroy; override;
    function SearchObject(const ObjectDN, Filter: RawUtf8;
      const Attributes: array of RawUtf8;
      Scope: TLdapSearchScope = lssBaseObject): TLdapResult; override;
    function Modify(const Obj: RawUtf8;
      const Modifications: array of TAsnObject): Boolean; override;
    function Modify(const Obj: RawUtf8; Op: TLdapModifyOp;
      Attribute: TLdapAttribute): Boolean; override;
  end;

const
  OBJECT_DN = 'CN=Test,DC=example,DC=com';

function TRecordingLdapClient.Modify(const Obj: RawUtf8; Op: TLdapModifyOp;
  const AttrName: RawUtf8; const AttrValue: RawByteString): Boolean;
begin
  Inc(Calls);
  Result := Calls <> FailOnCall;
end;

function TRecordingLdapClient.Add(const Obj: RawUtf8;
  Value: TLdapAttributeList): Boolean;
begin
  Inc(AddCalls);
  Result := not AddFails;
end;

procedure TUnitTestLdapWriteSafety.PartialObjectCreation;
var
  Client: TRecordingLdapClient;
  Kind: Integer;
  DN: RawUtf8;
  Raised: Boolean;
const
  Parent = 'OU=Test,DC=example,DC=com';
  FirstGroup = 'CN=First,OU=Test,DC=example,DC=com';
  FailedGroup = 'CN=Missing,OU=Test,DC=example,DC=com';
  LastGroup = 'CN=Later,OU=Test,DC=example,DC=com';
begin
  for Kind := 0 to 1 do
  begin
    Client := TRecordingLdapClient.Create;
    try
      Client.FailOnCall := 2;
      Raised := False;
      try
        if Kind = 0 then
          DN := Client.CreateGroup('Created', Parent, [FirstGroup, FailedGroup, LastGroup])
        else
          DN := Client.CreateUser('Created', Parent, [FirstGroup, FailedGroup, LastGroup]);
      except
        on E: ELdapPartialCreation do
        begin
          Raised := True;
          CheckEqual(E.CreatedDN, 'cn=Created,' + Parent);
          CheckEqual(E.FailedGroupDN, FailedGroup);
          Check(Pos('still exists', E.Message) > 0);
          Check(Pos('not object creation', E.Message) > 0);
        end;
      end;
      Check(Raised, 'A failed membership must explicitly report partial creation.');
      CheckEqual(Client.AddCalls, 1, 'Never recreate the committed object.');
      CheckEqual(Client.Calls, 2, 'Stop at first failed membership.');
      Client.Calls := 0;
      Client.FailOnCall := 0;
      if Kind = 0 then
        DN := Client.CreateGroup('Complete', Parent, [FirstGroup, LastGroup])
      else
        DN := Client.CreateUser('Complete', Parent, [FirstGroup, LastGroup]);
      CheckEqual(DN, 'cn=Complete,' + Parent);
      CheckEqual(Client.Calls, 2);
      Client.AddFails := True;
      Client.Calls := 0;
      if Kind = 0 then
        DN := Client.CreateGroup('Failed', Parent, [FirstGroup])
      else
        DN := Client.CreateUser('Failed', Parent, [FirstGroup]);
      CheckEqual(DN, '');
      CheckEqual(Client.Calls, 0, 'No joins when creation failed.');
    finally
      Client.Free;
    end;
  end;
end;

constructor TRecordingLdapClient.Create;
begin
  inherited Create;
  Data := TLdapResult.Create;
  Data.Attributes.Add('distinguishedName', OBJECT_DN);
  Data.Attributes.Add('objectClass', 'user');
  Data.Attributes.Add('userAccountControl', '512');
end;

destructor TRecordingLdapClient.Destroy;
begin
  Data.Free;
  inherited Destroy;
end;

function TRecordingLdapClient.SearchObject(const ObjectDN, Filter: RawUtf8;
  const Attributes: array of RawUtf8; Scope: TLdapSearchScope): TLdapResult;
begin
  Inc(Searches);
  result := Data;
end;

function TRecordingLdapClient.Modify(const Obj: RawUtf8;
  const Modifications: array of TAsnObject): Boolean;
var
  i: Integer;
begin
  Inc(Calls);
  Inc(ArrayCalls);
  SetLength(LastModifications, Length(Modifications));
  for i := 0 to High(Modifications) do
    LastModifications[i] := Modifications[i];
  result := Calls <> FailOnCall;
end;

function TRecordingLdapClient.Modify(const Obj: RawUtf8; Op: TLdapModifyOp;
  Attribute: TLdapAttribute): Boolean;
begin
  Inc(Calls);
  Inc(SingleCalls);
  Insert(Attribute.AttributeName, WrittenNames, Length(WrittenNames));
  result := Calls <> FailOnCall;
end;

function NewRSAT(out Client: TRecordingLdapClient): TRSAT;
begin
  result := TRSAT.Create(nil);
  result.LdapClient.Free;
  Client := TRecordingLdapClient.Create;
  result.LdapClient := Client;
end;

function TUnitTestLdapWriteSafety.ConfirmComputer(Sender: TObject): Boolean;
begin
  result := fAcceptWarning;
end;

function TUnitTestLdapWriteSafety.PasswordPrompt(const Locked: Boolean;
  out Password: RawUtf8; out MustChange, Unlock: Boolean): Boolean;
begin
  Inc(fPasswordPrompts);
  Password := 'Test-password';
  MustChange := False;
  Unlock := False;
  result := fAcceptPassword;
end;

procedure TUnitTestLdapWriteSafety.PasswordChanged(Sender: TObject);
begin
  Inc(fNotifications);
end;

procedure TUnitTestLdapWriteSafety.TlsPolicyOnActualConnect;
var
  Client: TRsatLdapClient;
begin
  Client := TRsatLdapClient.Create;
  try
    // No host + no discovery returns before any socket or DNS operation.
    Client.Settings.TargetHost := '';
    Client.Settings.AllowUnsafePasswordBind := False;
    Check(not Client.Connect([lccNoDiscovery], 0));
    Check(not Client.TlsContext^.IgnoreCertificateErrors);
    Client.Settings.AllowUnsafePasswordBind := True;
    Check(not Client.Connect([lccNoDiscovery], 0));
    Check(Client.TlsContext^.IgnoreCertificateErrors);
    Client.Settings.AllowUnsafePasswordBind := False;
    Check(not Client.Connect([lccNoDiscovery], 0));
    Check(not Client.TlsContext^.IgnoreCertificateErrors,
      'Changing back to safe settings must restore verification.');
  finally
    Client.Free;
  end;
end;

procedure TUnitTestLdapWriteSafety.CancelPasswordReset;
var
  RSAT: TRSAT;
  Client: TRecordingLdapClient;
  Module: TModuleADUC;
begin
  RSAT := NewRSAT(Client);
  Module := TModuleADUC.Create(RSAT);
  try
    Client.Data.Attributes.Add('objectClass', 'computer', aoReplaceValue);
    fPasswordPrompts := 0;
    fNotifications := 0;
    fAcceptWarning := False;
    fAcceptPassword := True;
    Check(not Module.ResetPassword(@PasswordPrompt, OBJECT_DN,
      @ConfirmComputer, @PasswordChanged, @PasswordChanged));
    Check(fPasswordPrompts = 0, 'No/Cancel on computer warning stops the workflow.');
    Check(Client.Calls = 0);
    fAcceptWarning := True;
    fAcceptPassword := False;
    Check(not Module.ResetPassword(@PasswordPrompt, OBJECT_DN,
      @ConfirmComputer, @PasswordChanged, @PasswordChanged));
    Check(fPasswordPrompts = 1);
    Check(Client.Calls = 0, 'Cancel must never write credentials or account flags.');
    Check(fNotifications = 0);
  finally
    Module.Free;
    RSAT.Free;
  end;
end;

procedure TUnitTestLdapWriteSafety.PasswordWriteFailure;
var
  RSAT: TRSAT;
  Client: TRecordingLdapClient;
  Module: TModuleADUC;
begin
  RSAT := NewRSAT(Client);
  Module := TModuleADUC.Create(RSAT);
  try
    fAcceptWarning := True;
    fAcceptPassword := True;
    fNotifications := 0;
    Client.FailOnCall := 1;
    Check(not Module.ResetPassword(@PasswordPrompt, OBJECT_DN,
      @ConfirmComputer, nil, @PasswordChanged));
    Check(fNotifications = 0);
    Check(Module.ResetPassword(@PasswordPrompt, OBJECT_DN,
      @ConfirmComputer, nil, @PasswordChanged));
    Check(fNotifications = 1);
    Check(Client.Calls = 2);
  finally
    Module.Free;
    RSAT.Free;
  end;
end;

procedure TUnitTestLdapWriteSafety.AtomicMultiValueFailure;
var
  RSAT: TRSAT;
  Client: TRecordingLdapClient;
  Props: TProperty;
begin
  RSAT := NewRSAT(Client);
  Props := TProperty.Create(RSAT);
  try
    Client.Data.Attributes.Add('member', 'CN=A,DC=example,DC=com').Add('CN=C,DC=example,DC=com');
    Props.Attributes := Client.Data.Attributes;
    Props.Add('member', 'CN=B,DC=example,DC=com');
    Props.Add('member', 'CN=C,DC=example,DC=com', aoAlways);
    Client.FailOnCall := 1;
    Check(not Props.ApplyModification);
    Check(Client.Calls = 1, 'A rejected addition must not be followed by a separate deletion.');
    Check(Client.SingleCalls = 0);
    Check(Length(Client.LastModifications) = 2);
    Check(Client.LastModifications[0] = Modifier(lmoAdd, 'member', 'CN=B,DC=example,DC=com'));
    Check(Client.LastModifications[1] = Modifier(lmoDelete, 'member', 'CN=A,DC=example,DC=com'));
    Check(Props.IsModified);
    Check(Props.GetRaw('member') = 'CN=B,DC=example,DC=com');
    Check(Client.Searches = 0, 'Failure must not refresh over pending edits.');
    Check(Props.ApplyModification);
    Check(Client.Calls = 2);
    Check(not Props.IsModified);
  finally
    Props.Free;
    RSAT.Free;
  end;
end;

procedure TUnitTestLdapWriteSafety.RetryOnlyUncommittedEdits;
var
  RSAT: TRSAT;
  Client: TRecordingLdapClient;
  Props: TProperty;
begin
  RSAT := NewRSAT(Client);
  Props := TProperty.Create(RSAT);
  try
    Props.Attributes := Client.Data.Attributes;
    Props.Add('description', 'Saved once');
    Props.Add('displayName', 'Retry this');
    Client.FailOnCall := 2;
    Check(not Props.ApplyModification);
    Check(Props.IsModified);
    Check(not Props.IsModified('description'));
    Check(Props.IsModified('displayName'));
    Check(Props.GetRaw('description') = 'Saved once');
    Check(Props.ApplyModification);
    Check(Client.Calls = 3);
    Check(Client.WrittenNames[2] = 'displayName');
    Check(not Props.IsModified);
  finally
    Props.Free;
    RSAT.Free;
  end;
end;

procedure TUnitTestLdapWriteSafety.RetryTemporaryEdits;
var
  RSAT: TRSAT;
  Client: TRecordingLdapClient;
  Props: TProperty;
begin
  RSAT := NewRSAT(Client);
  Props := TProperty.Create(RSAT);
  try
    Props.Attributes := Client.Data.Attributes;
    Props.AddMemberOf(['CN=Group1,DC=example,DC=com', 'CN=Group2,DC=example,DC=com']);
    Client.FailOnCall := 2;
    Check(not Props.ApplyModification);
    Check(Props.IsModified);
    Check(Length(Props.GetTempModify('CN=Group1,DC=example,DC=com', 'member', lmoAdd)) = 0);
    Check(Length(Props.GetTempModify('CN=Group2,DC=example,DC=com', 'member', lmoAdd)) = 1);
    Check(Props.ApplyModification);
    Check(Client.Calls = 3, 'Retry must not add the successful membership twice.');
    Check(not Props.IsModified);
  finally
    Props.Free;
    RSAT.Free;
  end;
end;

end.
