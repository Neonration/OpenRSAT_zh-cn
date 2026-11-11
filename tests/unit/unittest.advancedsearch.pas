unit unittest.advancedsearch;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  mormot.core.test,
  mormot.core.variants,
  mormot.net.ldap,
  ucommon;

type
  TUnitTestAdvancedSearch = class(TSynTestCase)
  published
    procedure MixedConditions;
    procedure LiteralValues;
    procedure InvalidRules;
  end;

implementation

procedure AddRule(var Rules: TDocVariantData; const Key, Value: RawUtf8;
  Condition: Integer);
var
  Rule: TDocVariantData;
begin
  Rule.Init;
  Rule.AddValue('key', Key);
  Rule.AddValue('value', Value);
  Rule.AddValue('conditionIndex', Condition);
  Rules.AddItem(Rule);
end;

procedure TUnitTestAdvancedSearch.MixedConditions;
var
  Rules: TDocVariantData;
  Filter: RawUtf8;
begin
  Rules.Init;
  AddRule(Rules, 'name', 'PC1', 2);
  AddRule(Rules, 'description', '', 4);
  Filter := BuildAdvancedSearchFilter(Rules, True);
  Check(Filter = '(&(name=PC1)(description=*))',
    'Adding a presence rule must not turn the existing equality rule into presence.');
  Check(RawLdapTranslateFilter(Filter) <> '');
  Check(BuildAdvancedSearchFilter(Rules, False) = '(|(name=PC1)(description=*))');

  Rules.Clear;
  AddRule(Rules, 'name', 'PC', 0);
  AddRule(Rules, 'description', 'office', 1);
  AddRule(Rules, 'sAMAccountName', 'disabled', 3);
  AddRule(Rules, 'location', '', 5);
  Filter := BuildAdvancedSearchFilter(Rules, True);
  Check(Filter = '(&(name=PC*)(description=*office)(!(sAMAccountName=disabled))(!(location=*)))');
  Check(RawLdapTranslateFilter(Filter) <> '');
end;

procedure TUnitTestAdvancedSearch.LiteralValues;
var
  Rules: TDocVariantData;
  Filter: RawUtf8;
begin
  Rules.Init;
  AddRule(Rules, 'description', '*)(name=*)\' + #0, 2);
  Filter := BuildAdvancedSearchFilter(Rules, True);
  Check(Filter = '(&(description=\2A\29\28name\3D\2A\29\5C\00))',
    'A value containing LDAP syntax must remain a literal assertion value.');
  Check(RawLdapTranslateFilter(Filter) <> '');

  Rules.Clear;
  AddRule(Rules, 'name', 'PC*', 0);
  AddRule(Rules, 'description', '*office', 1);
  Check(BuildAdvancedSearchFilter(Rules, True) = '(&(name=PC\2A*)(description=*\2Aoffice))',
    'Only the wildcard selected by the prefix/suffix operator is active.');

  Rules.Clear;
  AddRule(Rules, 'description', 'PC' + #0 + '*', 2);
  Check(BuildAdvancedSearchFilter(Rules, True) = '(&(description=PC\00\2A))',
    'An embedded NUL must not bypass escaping after an alphanumeric prefix.');
end;

procedure TUnitTestAdvancedSearch.InvalidRules;
var
  Rules, Rule: TDocVariantData;
begin
  Rules.Init;
  AddRule(Rules, 'name', 'PC1', 99);
  try
    BuildAdvancedSearchFilter(Rules, True);
    Check(False, 'Unknown operators must not broaden the query.');
  except
    on ELdap do
      Check(True);
  end;

  Rules.Clear;
  Rule.Init;
  Rule.AddValue('key', 'name');
  Rule.AddValue('value', 'PC1');
  Rules.AddItem(Rule);
  try
    BuildAdvancedSearchFilter(Rules, True);
    Check(False, 'A missing operator must not silently become starts-with.');
  except
    on ELdap do
      Check(True);
  end;

  Rules.Clear;
  AddRule(Rules, 'name)(objectClass', '*', 2);
  try
    BuildAdvancedSearchFilter(Rules, True);
    Check(False, 'Attribute input must not inject another assertion.');
  except
    on ELdap do
      Check(True);
  end;
end;

end.
