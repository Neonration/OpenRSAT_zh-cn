unit ucomputerdelete;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, mormot.core.base, mormot.net.ldap;

type
  TComputerDeleteTarget = record
    DN, GuidDN: RawUtf8;
  end;
  TComputerDeleteTargets = array of TComputerDeleteTarget;
  TComputerDeleteStatus = (cdsDeleted, cdsAbsent, cdsFailed);
  TComputerDeleteResult = record
    Status: TComputerDeleteStatus;
    Detail: RawUtf8;
  end;
  TComputerDeleteResults = array of TComputerDeleteResult;

  // Each controller owns its connection; no LDAP state is shared by workers.
  TComputerDeleteThread = class(TThread)
  private
    fClient: TLdapClient;
    fDomainDN: RawUtf8;
    fTargets: TComputerDeleteTargets;
    fResults: TComputerDeleteResults;
  protected
    procedure Execute; override;
  public
    constructor Create(Source: TLdapClient; const Host, DomainDN: RawUtf8;
      const Targets: TComputerDeleteTargets);
    destructor Destroy; override;
    property Results: TComputerDeleteResults read fResults;
  end;

function ComputerGuidDN(Entry: TLdapResult; out GuidDN: RawUtf8): Boolean;
function ResolveDeleteControllers(const Configured: RawUtf8;
  const Available: TRawUtf8DynArray; out Selected: TRawUtf8DynArray;
  out InvalidHost: RawUtf8): Boolean;

resourcestring
  rsComputerDeleteWrongDomain = 'The controller belongs to a different domain.';
  rsComputerDeleteInvalidIdentity = 'The object is not a workstation/member server computer, or its identity cannot be verified.';
  rsComputerDeleteNotStarted = 'Deletion did not complete.';
  rsComputerDeleteIncomplete = 'Some child objects may have been deleted, but the computer deletion is not confirmed.';

implementation

uses
  mormot.core.text;

function ComputerGuidDN(Entry: TLdapResult; out GuidDN: RawUtf8): Boolean;
var
  Guid: TGuid;
  Attribute: TLdapAttribute;
  I, Flags: Integer;
  IsComputer: Boolean;
begin
  Result := False;
  GuidDN := '';
  if not Assigned(Entry) then
    Exit;
  Attribute := Entry.Find('objectClass');
  if not Assigned(Attribute) then
    Exit;
  IsComputer := False;
  for I := 0 to Attribute.Count - 1 do
    IsComputer := IsComputer or SameText(Attribute.GetReadable(I), 'computer');
  if not IsComputer or not TryStrToInt(Entry[atUserAccountControl], Flags) then
    Exit;
  // Domain controller accounts must never be removed by a workstation cleanup.
  if ((Flags and (8192 or 67108864)) <> 0) or ((Flags and 4096) = 0) then
    Exit;
  if not Entry.CopyObjectGuid(Guid) then
    Exit;
  GuidDN := '<GUID=' + ToUtf8(Guid) + '>';
  Result := True;
end;

function ResolveDeleteControllers(const Configured: RawUtf8;
  const Available: TRawUtf8DynArray; out Selected: TRawUtf8DynArray;
  out InvalidHost: RawUtf8): Boolean;
var
  Hosts, ResultHosts: TStringList;
  Host, Known, Value: String;
  Found: Boolean;
  I: Integer;
begin
  Result := False;
  Selected := nil;
  InvalidHost := '';
  Hosts := TStringList.Create;
  ResultHosts := TStringList.Create;
  try
    ResultHosts.CaseSensitive := False;
    if Trim(Configured) = '' then
      for Known in Available do
        Hosts.Add(Known)
    else
    begin
      Hosts.StrictDelimiter := True;
      Hosts.Delimiter := ';';
      Hosts.DelimitedText := StringReplace(String(Configured), LineEnding, ';', [rfReplaceAll]);
    end;
    for Value in Hosts do
    begin
      Host := Trim(Value);
      if Host = '' then
        Continue;
      Found := False;
      for Known in Available do
        if SameText(Host, Known) then
        begin
          Host := Known;
          Found := True;
          Break;
        end;
      if not Found then
      begin
        InvalidHost := Host;
        Exit;
      end;
      if ResultHosts.IndexOf(Host) < 0 then
        ResultHosts.Add(Host);
    end;
    SetLength(Selected, ResultHosts.Count);
    for I := 0 to ResultHosts.Count - 1 do
      Selected[I] := ResultHosts[I];
    Result := Length(Selected) > 0;
  finally
    ResultHosts.Free;
    Hosts.Free;
  end;
end;

constructor TComputerDeleteThread.Create(Source: TLdapClient;
  const Host, DomainDN: RawUtf8; const Targets: TComputerDeleteTargets);
var
  I: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fDomainDN := DomainDN;
  fTargets := Copy(Targets);
  SetLength(fResults, Length(Targets));
  for I := 0 to High(fResults) do
  begin
    fResults[I].Status := cdsFailed;
    fResults[I].Detail := rsComputerDeleteNotStarted;
  end;
  fClient := TLdapClient.Create(Source.Settings);
  fClient.TlsContext^.IgnoreCertificateErrors := Source.TlsContext^.IgnoreCertificateErrors;
  fClient.Settings.TargetHost := Host;
  fClient.Settings.KerberosSpn := '';
  fClient.Settings.AutoReconnect := False;
end;

destructor TComputerDeleteThread.Destroy;
begin
  // TThread.Destroy waits before the connection is released.
  inherited Destroy;
  fClient.Free;
end;

procedure TComputerDeleteThread.Execute;
var
  I: Integer;
  Entry: TLdapResult;
  GuidDN, Error: RawUtf8;
begin
  if Terminated then
    Exit;
  Error := '';
  try
    if not fClient.Connect([lccNoDiscovery]) then
      Error := rsComputerDeleteNotStarted + ' ' + fClient.ResultString
    else if not SameText(fClient.DefaultDN, fDomainDN) then
      Error := rsComputerDeleteWrongDomain;
  except
    on E: Exception do
      Error := E.Message;
  end;
  if Error <> '' then
  begin
    for I := 0 to High(fResults) do
      fResults[I].Detail := Error;
    Exit;
  end;

  for I := 0 to High(fTargets) do
    try
      Entry := fClient.SearchObject(fTargets[I].GuidDN, '',
        ['objectGUID', 'objectClass', 'userAccountControl']);
      if not Assigned(Entry) then
      begin
        if fClient.ResultError = leNoSuchObject then
          fResults[I].Status := cdsAbsent
        else
          fResults[I].Detail := fClient.ResultString;
        Continue;
      end;
      if not ComputerGuidDN(Entry, GuidDN) or (GuidDN <> fTargets[I].GuidDN) then
      begin
        fResults[I].Detail := rsComputerDeleteInvalidIdentity;
        Continue;
      end;
      // A GUID DN survives moves and cannot address a replacement at the old DN.
      if fClient.Delete(GuidDN, True) then
        fResults[I].Status := cdsDeleted
      else if fClient.ResultError = leNoSuchObject then
      begin
        // A missing child during recursive deletion does not prove the parent is gone.
        Entry := fClient.SearchObject(GuidDN, '', ['objectGUID']);
        if not Assigned(Entry) and (fClient.ResultError = leNoSuchObject) then
          fResults[I].Status := cdsAbsent
        else
          fResults[I].Detail := rsComputerDeleteIncomplete;
      end
      else
        fResults[I].Detail := fClient.ResultString;
    except
      on E: Exception do
        fResults[I].Detail := E.Message;
    end;
end;

end.
