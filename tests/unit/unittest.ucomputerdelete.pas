unit unittest.ucomputerdelete;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.test,
  mormot.net.ldap,
  ucomputerdelete;

type
  TUnitTestComputerDelete = class(TSynTestCase)
  published
    procedure ControllerScope;
    procedure ComputerIdentity;
  end;

implementation

procedure TUnitTestComputerDelete.ControllerScope;
var
  Available, Selected: TRawUtf8DynArray;
  InvalidHost: RawUtf8;
begin
  Available := ['dc1.example.test', 'dc2.example.test'];
  Check(ResolveDeleteControllers('', Available, Selected, InvalidHost));
  Check(Length(Selected) = 2);
  Check(Selected[0] = Available[0]);
  Check(Selected[1] = Available[1]);
  Check(ResolveDeleteControllers(' DC2.EXAMPLE.TEST ; dc2.example.test ; dc1.example.test ',
    Available, Selected, InvalidHost));
  Check(Length(Selected) = 2, 'Repeated controllers must not trigger duplicate deletion.');
  Check(Selected[0] = Available[1]);
  Check(Selected[1] = Available[0]);
  Check(InvalidHost = '');
  Check(not ResolveDeleteControllers('dc1.example.test;unknown.example.test',
    Available, Selected, InvalidHost));
  Check(Length(Selected) = 0, 'An invalid explicit scope must not partially resolve.');
  Check(InvalidHost = 'unknown.example.test');
  Check(not ResolveDeleteControllers('; ;', Available, Selected, InvalidHost));
  Check(Length(Selected) = 0);
  Check(not ResolveDeleteControllers('', nil, Selected, InvalidHost));
  Check(Length(Selected) = 0, 'No discovered controller must not select another host.');
end;

procedure TUnitTestComputerDelete.ComputerIdentity;
var
  Entry: TLdapResult;
  Guid: TGuid;
  RawGuid: RawByteString;
  GuidDN: RawUtf8;
  Attribute: TLdapAttribute;

  procedure SetFlags(const Flags: RawUtf8);
  begin
    Attribute := Entry.FindOrAdd('userAccountControl');
    Attribute.Clear;
    if Flags <> '' then
      Attribute.Add(Flags);
  end;

begin
  Check(not ComputerGuidDN(nil, GuidDN));
  Check(GuidDN = '');
  Entry := TLdapResult.Create;
  try
    Entry.FindOrAdd('objectClass').Add('user');
    Entry.FindOrAdd('objectClass').Add('computer');
    Guid := StringToGUID('{00112233-4455-6677-8899-AABBCCDDEEFF}');
    SetString(RawGuid, PAnsiChar(@Guid), SizeOf(Guid));
    Entry.FindOrAdd('objectGUID').Add(RawGuid);
    SetFlags('4096');
    Check(ComputerGuidDN(Entry, GuidDN));
    Check(GuidDN = '<GUID=00112233-4455-6677-8899-AABBCCDDEEFF>',
      'GUID addressing must use the objectGUID bytes in standard GUID order.');
    SetFlags('4098');
    Check(ComputerGuidDN(Entry, GuidDN), 'Disabled member computers remain valid cleanup targets.');
    SetFlags('8192');
    Check(not ComputerGuidDN(Entry, GuidDN), 'Writable domain controllers must be rejected.');
    SetFlags('67112960');
    Check(not ComputerGuidDN(Entry, GuidDN), 'RODC accounts must be rejected even with workstation flags.');
    SetFlags('12288');
    Check(not ComputerGuidDN(Entry, GuidDN), 'A DC flag cannot be masked by the workstation flag.');
    SetFlags('');
    Check(not ComputerGuidDN(Entry, GuidDN), 'Missing flags must fail closed.');
    SetFlags('invalid');
    Check(not ComputerGuidDN(Entry, GuidDN), 'Invalid flags must fail closed.');
    SetFlags('4096');
    Entry.FindOrAdd('objectClass').Clear;
    Entry.FindOrAdd('objectClass').Add('user');
    Check(not ComputerGuidDN(Entry, GuidDN), 'A noncomputer must be rejected.');
    Entry.FindOrAdd('objectClass').Add('computer');
    Entry.FindOrAdd('objectGUID').Clear;
    Check(not ComputerGuidDN(Entry, GuidDN), 'Missing identity must fail closed.');
    Entry.FindOrAdd('objectGUID').Add('bad-guid');
    Check(not ComputerGuidDN(Entry, GuidDN), 'Malformed identity must fail closed.');
    Check(GuidDN = '');
  finally
    Entry.Free;
  end;
end;

end.
