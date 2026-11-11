unit unittest.udns;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.test,
  udns;

type
  TUnitTestDNSRecord = class(TSynTestCase)
  published
    procedure BinaryPayloadRoundTrip;
    procedure PayloadLengthBoundaries;
  end;

implementation

procedure TUnitTestDNSRecord.BinaryPayloadRoundTrip;
var
  Source, Decoded: TDNSRecord;
  Bytes: RawByteString;
begin
  Source := Default(TDNSRecord);
  Source.DataLength := 4;
  Source.RecType := 1;
  Source.Version := 5;
  Source.Rank := $f0;
  Source.Serial := 42;
  Source.TtlSeconds := 3600;
  Source.RData[0] := 10;
  Source.RData[3] := 1;
  Bytes := DNSRecordToRaw(Source);
  Check(Length(Bytes) = 28, 'An A record includes the 24-byte header and 4-byte address.');
  Check(Copy(Bytes, 25, 4) = #10#0#0#1);
  Check(Copy(Bytes, 13, 4) = #0#0#14#16, 'TTL is stored in network byte order.');
  Check(DNSRecordBytesToRecord(Decoded, PByteArray(Pointer(Bytes))^));
  Check(Decoded.DataLength = Source.DataLength);
  Check(Decoded.RecType = Source.RecType);
  Check(Decoded.Version = Source.Version);
  Check(Decoded.Rank = Source.Rank);
  Check(Decoded.Serial = Source.Serial);
  Check(Decoded.TtlSeconds = Source.TtlSeconds);
  Check(CompareMem(@Decoded.RData[0], @Source.RData[0], Source.DataLength));

  Source.RData[0] := 0;
  Source.RData[1] := $ff;
  Source.RData[2] := $80;
  Source.RData[3] := 0;
  Bytes := DNSRecordToRaw(Source);
  Check(Length(Bytes) = 28);
  Check(Copy(Bytes, 25, 4) = #0#$ff#$80#0, 'Binary bytes and trailing zeros must survive.');
end;

procedure TUnitTestDNSRecord.PayloadLengthBoundaries;
var
  Source, Decoded: TDNSRecord;
  Bytes: RawByteString;
begin
  Source := Default(TDNSRecord);
  Bytes := DNSRecordToRaw(Source);
  Check(Length(Bytes) = 24, 'An empty payload still has a complete header.');
  Check(DNSRecordBytesToRecord(Decoded, PByteArray(Pointer(Bytes))^));
  Check(Decoded.DataLength = 0);

  Source.DataLength := High(Word);
  Source.RData[0] := $ff;
  Source.RData[High(Word) - 1] := $80;
  Bytes := DNSRecordToRaw(Source);
  Check(Length(Bytes) = 24 + High(Word));
  Check(Ord(Bytes[25]) = $ff);
  Check(Ord(Bytes[Length(Bytes)]) = $80);
  Check(DNSRecordBytesToRecord(Decoded, PByteArray(Pointer(Bytes))^));
  Check(Decoded.DataLength = Source.DataLength);
  Check(CompareMem(@Decoded.RData[0], @Source.RData[0], Source.DataLength));
end;

end.
