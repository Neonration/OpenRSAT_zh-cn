unit unittest.udnoperations;

{$mode ObjFPC}{$H+}
{$codepage utf8}

interface

uses
  mormot.core.base,
  mormot.core.test,
  ucommon;

type
  TUnitTestDNOperations = class(TSynTestCase)
  published
    procedure PreserveNames;
    procedure RejectInvalidDestinations;
    procedure SplitEscapedSeparators;
    procedure MoveChildrenBeforeParents;
  end;

implementation

procedure TUnitTestDNOperations.PreserveNames;
var
  NewDN: RawUtf8;
begin
  Check(TryBuildMoveDN('CN=电脑一,OU=旧部门,DC=example,DC=com',
    'OU=新部门,DC=example,DC=com', NewDN));
  Check(NewDN = 'CN=电脑一,OU=新部门,DC=example,DC=com');
  Check(TryBuildMoveDN('CN=Last\, First,OU=Old,DC=example,DC=com',
    'OU=New,DC=example,DC=com', NewDN));
  Check(NewDN = 'CN=Last\, First,OU=New,DC=example,DC=com');
  Check(TryBuildMoveDN('CN=PC+UID=42,OU=Old,DC=example,DC=com',
    'OU=New,DC=example,DC=com', NewDN));
  Check(NewDN = 'CN=PC+UID=42,OU=New,DC=example,DC=com');
end;

procedure TUnitTestDNOperations.RejectInvalidDestinations;
var
  NewDN: RawUtf8;
begin
  Check(not TryBuildMoveDN('', 'OU=New,DC=example,DC=com', NewDN));
  Check(NewDN = '');
  Check(not TryBuildMoveDN('not a DN', 'OU=New,DC=example,DC=com', NewDN));
  Check(not TryBuildMoveDN('OU=Old,DC=example,DC=com', '', NewDN));
  Check(not TryBuildMoveDN('OU=Old,DC=example,DC=com',
    'ou=old,dc=EXAMPLE,dc=com', NewDN));
  Check(not TryBuildMoveDN('OU=Old,DC=example,DC=com',
    'OU=Child,ou=old,DC=example,DC=com', NewDN));
  Check(TryBuildMoveDN('OU=Old,DC=example,DC=com',
    'OU=Other\,OU=Old,DC=example,DC=com', NewDN),
    'An escaped comma in a name is not an ancestor boundary.');
end;

procedure TUnitTestDNOperations.SplitEscapedSeparators;
var
  RDN, ParentDN: RawUtf8;
begin
  Check(SplitObjectDN('CN=Last\, First,OU=People,DC=example,DC=com', RDN, ParentDN));
  Check(RDN = 'CN=Last\, First');
  Check(ParentDN = 'OU=People,DC=example,DC=com');
  Check(SplitObjectDN('CN=Trailing\\,OU=People,DC=example,DC=com', RDN, ParentDN));
  Check(RDN = 'CN=Trailing\\');
  Check(ParentDN = 'OU=People,DC=example,DC=com');
  Check(GetParentDN('CN=Trailing\\,OU=People,DC=example,DC=com') = ParentDN);
  Check(not SplitObjectDN('CN=Root', RDN, ParentDN));
  Check(ParentDN = '');
  Check(not SplitObjectDN('CN=Empty,', RDN, ParentDN));
end;

procedure TUnitTestDNOperations.MoveChildrenBeforeParents;
var
  DNs: TRawUtf8DynArray;
  Order: TIntegerDynArray;
begin
  DNs := ['OU=父,DC=example,DC=com',
    'CN=测试\,PC,OU=父,DC=example,DC=com',
    'OU=子,OU=父,DC=example,DC=com',
    'CN=Trailing\\,OU=子,OU=父,DC=example,DC=com'];
  Order := GetDNMoveOrder(DNs);
  Check(Length(Order) = 4);
  Check(Order[0] = 3);
  Check(Order[1] = 1);
  Check(Order[2] = 2);
  Check(Order[3] = 0);
  Check(DNs[0] = 'OU=父,DC=example,DC=com', 'The original selection must not change.');
  Check(DNs[1] = 'CN=测试\,PC,OU=父,DC=example,DC=com', 'Escaped names must remain exact.');
  Check(DNs[3] = 'CN=Trailing\\,OU=子,OU=父,DC=example,DC=com');
  Check(Length(GetDNMoveOrder(nil)) = 0);
end;

end.
