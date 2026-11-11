unit unittest.optionsswitch;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, IniFiles, ComCtrls, mormot.core.test,
  ursatoption, ufrmrsatoptions, ufrmmodules, uvisoptions;

type
  TUnitTestOptionsSwitch = class(TSynTestCase)
  published
    procedure SwitchingPagesKeepsUnsavedLanguage;
  end;

implementation

procedure TUnitTestOptionsSwitch.SwitchingPagesKeepsUnsavedLanguage;
var
  Model: TRsatOption;
  Modules: TFrmModules;
  OptionsForm: TVisOptions;
  GlobalFrame, OtherFrame: TFrmRSATOption;
  GlobalNode, OtherNode: TTreeNode;
  Ini: TIniFile;
  FileName: String;
begin
  FileName := GetTempFileName;
  Ini := TIniFile.Create(FileName);
  Model := TRsatOption.Create;
  Modules := TFrmModules.Create;
  OptionsForm := nil;
  try
    Ini.WriteString('General', 'lang', 'en');
    Model.Load(Ini);
    OptionsForm := TVisOptions.Create(nil, TFrmRSATOption, Model, Modules);
    GlobalNode := OptionsForm.TreeView1.Items[0];
    GlobalFrame := TFrmRSATOption(GlobalNode.Data);
    Check(GlobalFrame.ComboBox2.Text = 'en', 'Load each page when the dialog is created.');
    Check(not GlobalFrame.OptionChanged);

    OtherFrame := TFrmRSATOption.Create(nil, Model);
    OtherFrame.Name := 'OtherOptionsFrame';
    OptionsForm.InsertComponent(OtherFrame);
    OtherFrame.Parent := OptionsForm.PairSplitterSide2;
    OtherFrame.Visible := False;
    OtherNode := OptionsForm.TreeView1.Items.Add(nil, 'Other');
    OtherNode.Data := OtherFrame;

    GlobalFrame.ComboBox2.ItemIndex := GlobalFrame.ComboBox2.Items.Count - 1;
    GlobalFrame.ComboBox2Change(nil);
    Check(GlobalFrame.OptionChanged);
    OptionsForm.TreeView1.Selected := OtherNode;
    OptionsForm.TreeView1.Selected := GlobalNode;
    Check(GlobalFrame.ComboBox2.ItemIndex = GlobalFrame.ComboBox2.Items.Count - 1,
      'Switching pages must preserve the unsaved Chinese selection.');
    Check(GlobalFrame.OptionChanged, 'Returning to a page must preserve its dirty state.');
    OptionsForm.Action_ApplyUpdate(nil);
    Check(OptionsForm.Action_Apply.Enabled, 'The retained change must still be applicable.');
    Check(Model.Lang = 'en', 'Changing pages must not save the model implicitly.');
  finally
    OptionsForm.Free;
    Modules.Free;
    Model.Free;
    Ini.Free;
    DeleteFile(FileName);
  end;
end;

end.
