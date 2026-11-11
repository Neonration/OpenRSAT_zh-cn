unit unittest.ursatoption;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  IniFiles,
  mormot.core.test,
  ursatoption;

type
  TUnitTestRSATOption = class(TSynTestCase)
  published
    procedure LanguageDefaultsAndPersistence;
  end;

implementation

procedure TUnitTestRSATOption.LanguageDefaultsAndPersistence;
const
  LanguageCodes: array[0..4] of String = ('zh', 'en', 'zh_CN', 'zh-CN', '');
var
  FileName, LanguageCode: String;
  Ini: TIniFile;
  RSATOptions: TRsatOption;
begin
  FileName := GetTempFileName(GetTempDir, 'rsat');
  Ini := TIniFile.Create(FileName);
  RSATOptions := TRsatOption.Create;
  try
    RSATOptions.Load(Ini);
    Check(RSATOptions.Lang = '', 'An unset language must retain the system default.');
    for LanguageCode in LanguageCodes do
    begin
      RSATOptions.BeginUpdate;
      try
        RSATOptions.Lang := LanguageCode;
        RSATOptions.Theme := tmDark;
        RSATOptions.AdvancedView := True;
      finally
        RSATOptions.EndUpdate;
      end;
      RSATOptions.Save(Ini);
      FreeAndNil(RSATOptions);
      FreeAndNil(Ini);
      Ini := TIniFile.Create(FileName);
      RSATOptions := TRsatOption.Create;
      RSATOptions.Load(Ini);
      Check(RSATOptions.Lang = LanguageCode, 'The language code must survive reopening, including legacy Chinese aliases.');
    end;
    Check(RSATOptions.Theme = tmDark, 'Saving language must preserve the theme.');
    Check(RSATOptions.AdvancedView, 'Saving language must preserve advanced view.');
  finally
    RSATOptions.Free;
    Ini.Free;
    DeleteFile(FileName);
  end;
end;

end.
