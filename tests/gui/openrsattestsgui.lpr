program openrsattestsgui;

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  interfaces,
  Forms,
  mormot.core.test,
  unittest.optionsswitch,
  unittest.uprofileconfiguration,
  unittest.searchsafety,
  unittest.upropertiessafety,
  unittest.ugposettings,
  unittest.ugpoofflinedraft;

type

  { TOpenRSATTests }

  TOpenRSATTestsGUI = class(TSynTestsLogged)
  published
    procedure GUI;
  end;

{ TOpenRSATTests }

procedure TOpenRSATTestsGUI.GUI;
begin
  AddCase([
    TUnitTestOptionsSwitch,
    TUnitTestProfileConfiguration,
    TUnitTestSearchSafety,
    TUnitTestPropertiesSafety,
    TUnitTestGpoSettings,
    TUnitTestGpoOfflineDraftUI
  ]);
end;

begin
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.ShowMainForm := False;
  TOpenRSATTestsGUI.RunAsConsole('OpenRSAT GUI Regression Tests');
end.

