unit unittest.umoduleaducoption;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  IniFiles,
  mormot.core.test,
  umoduleaducoption;

type
  TUnitTestModuleADUCOption = class(TSynTestCase)
  published
    procedure MultiDCDeleteDefaultsAndPersistence;
  end;

implementation

procedure TUnitTestModuleADUCOption.MultiDCDeleteDefaultsAndPersistence;
var
  FileName: String;
  Ini: TIniFile;
  ADUCOptions: TModuleADUCOption;
begin
  FileName := GetTempFileName(GetTempDir, 'rsat');
  Ini := TIniFile.Create(FileName);
  ADUCOptions := TModuleADUCOption.Create;
  try
    ADUCOptions.Load(Ini);
    Check(not ADUCOptions.EnableMultiDCDelete, 'Existing configurations must not enable multi-controller deletion.');
    Check(ADUCOptions.DeleteDomainControllers = '', 'No controller scope is configured by default.');
    ADUCOptions.EnableMultiDCDelete := True;
    ADUCOptions.DeleteDomainControllers := 'dc1.example.test;dc2.example.test';
    ADUCOptions.ShowGPO := True;
    Check(ADUCOptions.Changed, 'Changing deletion settings must mark options changed.');
    ADUCOptions.Save(Ini);
    FreeAndNil(ADUCOptions);
    FreeAndNil(Ini);
    Ini := TIniFile.Create(FileName);
    ADUCOptions := TModuleADUCOption.Create;
    ADUCOptions.Load(Ini);
    Check(ADUCOptions.EnableMultiDCDelete, 'The opt-in must survive reopening the configuration.');
    Check(ADUCOptions.DeleteDomainControllers = 'dc1.example.test;dc2.example.test', 'The controller scope must survive reopening.');
    Check(ADUCOptions.ShowGPO, 'Existing settings must be preserved.');
    ADUCOptions.EnableMultiDCDelete := False;
    ADUCOptions.Save(Ini);
    ADUCOptions.Load(Ini);
    Check(not ADUCOptions.EnableMultiDCDelete, 'Disabling must be saved.');
    Check(ADUCOptions.DeleteDomainControllers = 'dc1.example.test;dc2.example.test', 'Disabling must preserve the configured scope.');
  finally
    ADUCOptions.Free;
    Ini.Free;
    DeleteFile(FileName);
  end;
end;

end.
