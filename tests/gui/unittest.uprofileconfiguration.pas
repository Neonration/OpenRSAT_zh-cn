unit unittest.uprofileconfiguration;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.test;

type
  TUnitTestProfileConfiguration = class(TSynTestCase)
  published
    procedure PreserveCustomPorts;
  end;

implementation

uses
  mormot.net.ldap, uldapconfigs, uvisprofileconfiguration;

procedure TUnitTestProfileConfiguration.PreserveCustomPorts;
var
  Settings: TMLdapClientSettings;
  Dialog: TVisProfileConfiguration;
  Tls, CustomPort: Boolean;
begin
  for Tls := False to True do
  for CustomPort := False to True do
  begin
    Settings := TMLdapClientSettings.Create;
    try
      Settings.Tls := Tls;
      Settings.TargetHost := 'dc.example.com';
      if CustomPort then
        Settings.TargetPort := '1636'
      else if Tls then
        Settings.TargetPort := LDAP_TLS_PORT
      else
        Settings.TargetPort := LDAP_PORT;
      Dialog := TVisProfileConfiguration.Create(nil, Settings);
      try
        Dialog.FormShow(nil);
        if CustomPort then
          Check(Dialog.ComboBox_DomainControllers.Text = 'dc.example.com:1636')
        else
          Check(Dialog.ComboBox_DomainControllers.Text = 'dc.example.com');
        Dialog.OKButtonClick(nil);
        Check(Settings.TargetHost = 'dc.example.com');
        if CustomPort then
          Check(Settings.TargetPort = '1636')
        else if Tls then
          Check(Settings.TargetPort = LDAP_TLS_PORT)
        else
          Check(Settings.TargetPort = LDAP_PORT);
        Check(Settings.Tls = Tls);
      finally
        Dialog.Free;
      end;
    finally
      Settings.Free;
    end;
  end;
end;

end.
