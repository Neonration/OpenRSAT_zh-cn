unit ufrmpropertyattributes;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  StdCtrls,
  Buttons, ExtCtrls, ActnList,
  tis.ui.grid.core,
  mormot.core.base,
  mormot.core.log, mormot.core.variants, mormot.net.ldap,
  uproperty,
  upropertyframe, VirtualTrees, Graphics, Menus;

type

  { TFrmPropertyAttributes }

  TFrmPropertyAttributes = class(TPropertyFrame)
    Action_Filter: TAction;
    Action_Modify: TAction;
    ActionList1: TActionList;
    BitBtn_Modify: TBitBtn;
    BitBtn_Filter: TBitBtn;
    Label_Attributes: TLabel;
    List_Attributes: TTisGrid;
    MenuItem1: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    MenuItem4: TMenuItem;
    MenuItem5: TMenuItem;
    MenuItem6: TMenuItem;
    MenuItem7: TMenuItem;
    MenuItem8: TMenuItem;
    MenuItem9: TMenuItem;
    Panel1: TPanel;
    PopupMenu1: TPopupMenu;
    Separator1: TMenuItem;
    Separator2: TMenuItem;
    Timer_SearchInGrid: TTimer;
    procedure Action_ModifyExecute(Sender: TObject);
    procedure Action_ModifyUpdate(Sender: TObject);
    procedure BitBtn_FilterClick(Sender: TObject);
    function List_AttributesCompareByRow(aSender: TTisGrid;
      const aPropertyName: RawUtf8; const aRow1, aRow2: PDocVariantData;
      var aHandled: Boolean): PtrInt;
    procedure List_AttributesDblClick(Sender: TObject);
    procedure List_AttributesDrawText(Sender: TBaseVirtualTree;
      TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      const CellText: String; const CellRect: TRect; var DefaultDraw: Boolean);
    procedure List_AttributesGetText(aSender: TBaseVirtualTree;
      aNode: PVirtualNode; const aCell: TDocVariantData; aColumn: TColumnIndex;
      aTextType: TVSTTextType; var aText: string);
    procedure List_AttributesKeyPress(Sender: TObject; var Key: char);
    procedure MenuItem1Click(Sender: TObject);
    procedure Timer_SearchInGridTimer(Sender: TObject);
  private
    fLog: TSynLog;
    fProperty: TProperty;
    fSearchWord: RawUtf8;
  public
    constructor Create(TheOwner: TComponent); override;
    procedure Update(Props: TProperty); override;
  end;

implementation
uses
  mormot.core.text,
  ucommon,
  ucommonui,
  uhelpersui,
  uvisproperties,
  uvisattributeeditor;

{$R *.lfm}

resourcestring
  rsAttrAccountExpires = 'Account expiration time';
  rsAttrAdminCount = 'Admin count';
  rsAttrBadPasswordTime = 'Last bad password time';
  rsAttrBadPwdCount = 'Bad password count';
  rsAttrCn = 'Common name';
  rsAttrCo = 'Country/region';
  rsAttrCompany = 'Company';
  rsAttrDepartment = 'Department';
  rsAttrDescription = 'Description';
  rsAttrDisplayName = 'Display name';
  rsAttrDistinguishedName = 'Distinguished name';
  rsAttrDNSHostName = 'DNS host name';
  rsAttrFacsimileTelephoneNumber = 'Fax number';
  rsAttrGivenName = 'First name';
  rsAttrHomePhone = 'Home phone';
  rsAttrInitials = 'Initials';
  rsAttrIpPhone = 'IP phone';
  rsAttrL = 'City';
  rsAttrLastLogon = 'Last logon';
  rsAttrLastLogonTimestamp = 'Last logon timestamp';
  rsAttrLockoutTime = 'Lockout time';
  rsAttrLogonCount = 'Logon count';
  rsAttrMail = 'Email';
  rsAttrManagedBy = 'Managed by';
  rsAttrMember = 'Member';
  rsAttrMemberOf = 'Member of';
  rsAttrMobile = 'Mobile';
  rsAttrMsDSAllowedToDelegateTo = 'Allowed to delegate to';
  rsAttrMsDSSupportedEncryptionTypes = 'Supported encryption types';
  rsAttrMsFVERecoveryGuid = 'BitLocker recovery GUID';
  rsAttrMsFVERecoveryPassword = 'BitLocker recovery password';
  rsAttrMsLAPSPassword = 'Windows LAPS password';
  rsAttrMsLAPSPasswordExpirationTime = 'Windows LAPS password expiration time';
  rsAttrMsMcsAdmPwd = 'LAPS local administrator password';
  rsAttrMsMcsAdmPwdExpirationTime = 'LAPS password expiration time';
  rsAttrName = 'Name';
  rsAttrNTSecurityDescriptor = 'Security descriptor';
  rsAttrObjectCategory = 'Object category';
  rsAttrObjectClass = 'Object class';
  rsAttrObjectGUID = 'Object GUID';
  rsAttrObjectSid = 'Object SID';
  rsAttrOperatingSystem = 'Operating system';
  rsAttrOperatingSystemVersion = 'Operating system version';
  rsAttrPager = 'Pager';
  rsAttrPhysicalDeliveryOfficeName = 'Office';
  rsAttrPostalCode = 'Postal code';
  rsAttrPrimaryGroupID = 'Primary group ID';
  rsAttrPwdLastSet = 'Password last set';
  rsAttrSAMAccountName = 'SAM account name';
  rsAttrSAMAccountType = 'SAM account type';
  rsAttrServicePrincipalName = 'Service principal name';
  rsAttrSn = 'Last name';
  rsAttrSt = 'State/province';
  rsAttrStreetAddress = 'Street address';
  rsAttrTelephoneNumber = 'Telephone number';
  rsAttrTitle = 'Job title';
  rsAttrUrl = 'URL';
  rsAttrUserAccountControl = 'User account control';
  rsAttrUserCertificate = 'User certificate';
  rsAttrUserPrincipalName = 'User principal name';
  rsAttrUSNChanged = 'USN changed';
  rsAttrUSNCreated = 'USN created';
  rsAttrWhenChanged = 'Changed time';
  rsAttrWhenCreated = 'Created time';
  rsAttrWWWHommePage = 'Web page';

function TranslateAttributeName(const AName: RawUtf8): String;
begin
  case AName of
    'accountExpires': Result := rsAttrAccountExpires;
    'adminCount': Result := rsAttrAdminCount;
    'badPasswordTime': Result := rsAttrBadPasswordTime;
    'badPwdCount': Result := rsAttrBadPwdCount;
    'cn': Result := rsAttrCn;
    'co': Result := rsAttrCo;
    'company': Result := rsAttrCompany;
    'department': Result := rsAttrDepartment;
    'description': Result := rsAttrDescription;
    'displayName': Result := rsAttrDisplayName;
    'distinguishedName': Result := rsAttrDistinguishedName;
    'dNSHostName': Result := rsAttrDNSHostName;
    'facsimileTelephoneNumber': Result := rsAttrFacsimileTelephoneNumber;
    'givenName': Result := rsAttrGivenName;
    'homePhone': Result := rsAttrHomePhone;
    'initials': Result := rsAttrInitials;
    'ipPhone': Result := rsAttrIpPhone;
    'l': Result := rsAttrL;
    'lastLogon': Result := rsAttrLastLogon;
    'lastLogonTimestamp': Result := rsAttrLastLogonTimestamp;
    'lockoutTime': Result := rsAttrLockoutTime;
    'logonCount': Result := rsAttrLogonCount;
    'mail': Result := rsAttrMail;
    'managedBy': Result := rsAttrManagedBy;
    'member': Result := rsAttrMember;
    'memberOf': Result := rsAttrMemberOf;
    'mobile': Result := rsAttrMobile;
    'msDS-AllowedToDelegateTo': Result := rsAttrMsDSAllowedToDelegateTo;
    'msDS-SupportedEncryptionTypes': Result := rsAttrMsDSSupportedEncryptionTypes;
    'msFVE-RecoveryGuid': Result := rsAttrMsFVERecoveryGuid;
    'msFVE-RecoveryPassword': Result := rsAttrMsFVERecoveryPassword;
    'msLAPS-Password': Result := rsAttrMsLAPSPassword;
    'msLAPS-PasswordExpirationTime': Result := rsAttrMsLAPSPasswordExpirationTime;
    'ms-Mcs-AdmPwd': Result := rsAttrMsMcsAdmPwd;
    'ms-Mcs-AdmPwdExpirationTime': Result := rsAttrMsMcsAdmPwdExpirationTime;
    'name': Result := rsAttrName;
    'nTSecurityDescriptor': Result := rsAttrNTSecurityDescriptor;
    'objectCategory': Result := rsAttrObjectCategory;
    'objectClass': Result := rsAttrObjectClass;
    'objectGUID': Result := rsAttrObjectGUID;
    'objectSid': Result := rsAttrObjectSid;
    'operatingSystem': Result := rsAttrOperatingSystem;
    'operatingSystemVersion': Result := rsAttrOperatingSystemVersion;
    'pager': Result := rsAttrPager;
    'physicalDeliveryOfficeName': Result := rsAttrPhysicalDeliveryOfficeName;
    'postalCode': Result := rsAttrPostalCode;
    'primaryGroupID': Result := rsAttrPrimaryGroupID;
    'pwdLastSet': Result := rsAttrPwdLastSet;
    'sAMAccountName': Result := rsAttrSAMAccountName;
    'sAMAccountType': Result := rsAttrSAMAccountType;
    'servicePrincipalName': Result := rsAttrServicePrincipalName;
    'sn': Result := rsAttrSn;
    'st': Result := rsAttrSt;
    'streetAddress': Result := rsAttrStreetAddress;
    'telephoneNumber': Result := rsAttrTelephoneNumber;
    'title': Result := rsAttrTitle;
    'url': Result := rsAttrUrl;
    'userAccountControl': Result := rsAttrUserAccountControl;
    'userCertificate': Result := rsAttrUserCertificate;
    'userPrincipalName': Result := rsAttrUserPrincipalName;
    'uSNChanged': Result := rsAttrUSNChanged;
    'uSNCreated': Result := rsAttrUSNCreated;
    'whenChanged': Result := rsAttrWhenChanged;
    'whenCreated': Result := rsAttrWhenCreated;
    'wWWHomePage': Result := rsAttrWWWHommePage;
  else
    Result := String(AName);
  end;
end;

{ TFrmPropertyAttributes }

procedure TFrmPropertyAttributes.Timer_SearchInGridTimer(Sender: TObject);
begin
  Timer_SearchInGrid.Enabled := False;
end;

procedure TFrmPropertyAttributes.List_AttributesKeyPress(Sender: TObject;
  var Key: char);
begin
  SearchInGrid(Timer_SearchInGrid, List_Attributes, fSearchWord, Key);
end;

procedure TFrmPropertyAttributes.MenuItem1Click(Sender: TObject);
begin
  (Owner as TVisProperties).IniPropStorage1.WriteBoolean('PropertyAttributesFilterHaveValue', MenuItem1.Checked);
  Update(fProperty);
end;

procedure TFrmPropertyAttributes.List_AttributesDblClick(Sender: TObject);
begin
  Action_Modify.Execute;
end;

procedure TFrmPropertyAttributes.Action_ModifyUpdate(Sender: TObject);
begin
  Action_Modify.Enabled := Assigned(List_Attributes.FocusedRow);
end;

procedure TFrmPropertyAttributes.BitBtn_FilterClick(Sender: TObject);
var
  P: TPoint;
begin
  P := Point(BitBtn_Filter.ClientRect.Left, BitBtn_Filter.ClientRect.Bottom);
  P := BitBtn_Filter.ControlToScreen(P);
  PopupMenu1.PopUp(P.X, P.Y);
end;

function TFrmPropertyAttributes.List_AttributesCompareByRow(aSender: TTisGrid;
  const aPropertyName: RawUtf8; const aRow1, aRow2: PDocVariantData;
  var aHandled: Boolean): PtrInt;
begin
  aHandled := Assigned(aRow1) and Assigned(aRow2) and (aPropertyName <> '') and aRow1^.Exists(aPropertyName) and aRow2^.Exists(aPropertyName);
  if aHandled then
    result := String.Compare(aRow1^.S[aPropertyName], aRow2^.S[aPropertyName], True);
end;

procedure TFrmPropertyAttributes.Action_ModifyExecute(Sender: TObject);
var
  vis: TVisAttributeEditor;
  Attribute: TLdapAttribute;
  i: Integer;
begin
  Attribute := fProperty.Get(List_Attributes.FocusedRow^.S['attribute']);

  vis := TVisAttributeEditor.Create(self, Attribute, List_Attributes.FocusedRow^.S['attribute']);
  try
    if (vis.ShowModal <> mrOK) then
      Exit;

    if Vis.Attr.Count <= 0 then
    begin
      fProperty.Add(Vis.Attr.AttributeName, '');
      Exit;
    end;
    fProperty.Add(Vis.Attr.AttributeName, Vis.Attr.GetReadable(0));
    for i := 1 to Vis.Attr.Count - 1 do
      fProperty.Add(Vis.Attr.AttributeName, Vis.Attr.GetReadable(i), aoAlways);
  finally
    FreeAndNil(vis);
  end;
end;

procedure TFrmPropertyAttributes.List_AttributesDrawText(
  Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode;
  Column: TColumnIndex; const CellText: String; const CellRect: TRect;
  var DefaultDraw: Boolean);
var
  NodeData: PDocVariantData;
  AttributeName: RawUtf8;
begin
  if Column <> 1 then
    Exit;

  NodeData := List_Attributes.GetNodeAsPDocVariantData(Node);
  if not Assigned(NodeData) then
    Exit;
  AttributeName := NodeData^.U['attribute'];


  if not fProperty.IsModified(AttributeName) then // check if diff exists
    Exit;

  if fProperty.GetReadable(AttributeName) = '' then
    TargetCanvas.Font.Style := [TFontStyle.fsItalic, TFontStyle.fsStrikeOut]
  else
    TargetCanvas.Font.Style := [TFontStyle.fsItalic, TFontStyle.fsBold];
end;

procedure TFrmPropertyAttributes.List_AttributesGetText(
  aSender: TBaseVirtualTree; aNode: PVirtualNode; const aCell: TDocVariantData;
  aColumn: TColumnIndex; aTextType: TVSTTextType; var aText: string);
var
  NodeData: PDocVariantData;
  AttributeName: RawUtf8;
  AttributeValues: TRawUtf8DynArray;
  len: SizeInt;
  GridColumn: TTisGridColumn;
begin
  NodeData := List_Attributes.GetNodeAsPDocVariantData(aNode);
  if not Assigned(NodeData) then
    Exit;
  AttributeName := NodeData^.U['attribute'];
  GridColumn := List_Attributes.FindColumnByIndex(aColumn);

  if Assigned(GridColumn) and (GridColumn.PropertyName = 'attribute') then
  begin
    aText := TranslateAttributeName(AttributeName);
    Exit;
  end;

  if (aColumn <> 1) or not Assigned(GridColumn) then
    Exit;

  AttributeValues := fProperty.GetAllReadable(AttributeName);

  aText := String.Join('; ', TStringArray(AttributeValues));
  if GridColumn.Width <= List_Attributes.Canvas.TextWidth(aText) then
  begin
    len := Length(AttributeValues);
    aText := FormatUtf8('%; range=0-%', [AttributeValues[0], Len]);
  end;
end;

constructor TFrmPropertyAttributes.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);

  fLog := TSynLog.Add;
  if Assigned(fLog) then
    fLog.Log(sllTrace, 'Create', Self);

  MenuItem1.Checked := (Owner as TVisProperties).IniPropStorage1.ReadBoolean('PropertyAttributesFilterHaveValue', True);
  Caption := 'Attributes';
end;

procedure TFrmPropertyAttributes.Update(Props: TProperty);
var
  Row: TDocVariantData;
  Attributes, value: TRawUtf8DynArray;
  Attribute: RawUtf8;
begin
  if Assigned(fLog) then
    fLog.Log(sllTrace, 'Update', Self);

  fProperty := Props;
  Attributes := fProperty.AttributesFromSchema;

  Row.Init();
  List_Attributes.Clear;
  List_Attributes.FocusedColumn := 0;
  List_Attributes.BeginUpdate;
  try
    for Attribute in Attributes do
    begin
      value := fProperty.GetAllReadable(Attribute);
      if (not MenuItem1.Checked) or (MenuItem1.Checked and Assigned(value)) then
      begin
        Row.AddOrUpdateValue('attribute', Attribute);
        List_Attributes.Data.AddItem(Row);
        Row.Clear;
      end;
    end;
  finally
    List_Attributes.EndUpdate;
    List_Attributes.LoadData();
  end;
end;

end.

