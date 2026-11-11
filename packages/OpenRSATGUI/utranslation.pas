unit utranslation;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base;

procedure SetLanguage(const Lang: RawUtf8);

implementation
uses
  LCLTranslator,
  Forms,
  mormot.core.text;

function LocaleFolderPath: RawUtf8;
var
  AppFolder: String;
begin
  AppFolder := ExtractFilePath(Application.ExeName);
  {$IF Defined(WINDOWS)}
  result := MakePath([AppFolder, 'locale']);
  {$ELSEIF Defined(DARWIN)}
  result := MakePath([AppFolder, '..', 'Resources', 'locale']);
  {$ELSEIF Defined(LINUX)}
  result := '/usr/share/openrsat/locale/';
  {$ELSE}
  result := MakePath([AppFolder, 'locale']);
  {$ENDIF}
end;

procedure SetLanguage(const Lang: RawUtf8);
begin
  if SameText(Lang, 'zh_CN') or SameText(Lang, 'zh-CN') then
    SetDefaultLang('zh', LocaleFolderPath)
  else
    SetDefaultLang(Lang, LocaleFolderPath);
end;

end.
