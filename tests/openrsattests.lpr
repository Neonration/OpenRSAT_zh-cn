program openrsattests;

uses
  {$IFDEF UNIX}
    cthreads,
    cwstring, // Match the GUI's Unicode conversion support for UTF-8 comparisons.
  {$ENDIF}
  mormot.core.test,
  {$IFDEF INTEGRATION}
  integrationtest.uadvancedsecuritypresenter,
  integrationtest.ugeneralpropertysitelink,
  {$ENDIF INTEGRATION}
  unittest.uadvancedsecuritypresenter,
  unittest.ugeneratekeytab,
  unittest.uviewkeytabpresenter,
  unittest.udoublelistlogic,
  unittest.udnoperations,
  unittest.ucomputerdelete,
  unittest.ursatoption,
  unittest.umoduleaducoption,
  unittest.udns,
  unittest.uldapwritesafety,
  unittest.ugporeadonly,
  unittest.ugpooffline,
  unittest.ugpowritemodel,
  unittest.ugporeplaymodel,
  unittest.ugpojournalfile,
  unittest.ugpolocalbackend,
  unittest.advancedsearch;

type

  { TOpenRSATTests }

  TOpenRSATTests = class(TSynTestsLogged)
  published
    procedure Units;
    {$IFDEF INTEGRATION}
    procedure Integrations;
    {$ENDIF INTEGRATION}
    procedure Performances;
    procedure Security;
  end;

{ TOpenRSATTests }

procedure TOpenRSATTests.Units;
begin
  AddCase([
    TTestAdvancedSecurityPresenter,
    TUnitTestGenerateKeyTab,
    TUnitTestViewKeyTabPresenter,
    TUnitTestDoubleListLogic,
    TUnitTestDNOperations,
    TUnitTestComputerDelete,
    TUnitTestRSATOption,
    TUnitTestModuleADUCOption,
    TUnitTestDNSRecord,
    TUnitTestLdapWriteSafety,
    TUnitTestGpoReadOnly,
    TUnitTestGpoOffline,
    TUnitTestGpoWriteModel,
    TUnitTestGpoReplayModel,
    TUnitTestGpoJournalFile,
    TUnitTestGpoLocalBackend,
    TUnitTestAdvancedSearch
  ]);
end;

{$IFDEF INTEGRATION}
procedure TOpenRSATTests.Integrations;
begin
  AddCase([
    TIntegrationTestAdvancedSecurityPresenter,
    TIntegrationTestGeneralPropertySiteLink
  ]);
end;
{$ENDIF INTEGRATION}

procedure TOpenRSATTests.Performances;
begin
  AddCase([
  ]);
end;

procedure TOpenRSATTests.Security;
begin
  AddCase([
  ]);
end;

begin
  TOpenRSATTests.RunAsConsole('OpenRSAT Regression Tests');
end.

