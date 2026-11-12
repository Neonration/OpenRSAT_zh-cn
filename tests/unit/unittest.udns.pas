unit unittest.udns;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.test,
  mormot.net.dns,
  udns;

type
  TUnitTestDNSRecord = class(TSynTestCase)
  published
    procedure BinaryPayloadRoundTrip;
    procedure PayloadLengthBoundaries;
    procedure PayloadBoundsDoNotTouchAdjacentBytes;
    procedure AAAADisplay;
  end;

implementation

procedure TUnitTestDNSRecord.AAAADisplay;
var Source,Decoded:TDNSRecord; Raw:RawByteString;
  function Display(const Payload:array of Byte):RawUtf8;
  var I:Integer;
  begin
    Source:=Default(TDNSRecord); Source.RecType:=Ord(drrAAAA); Source.DataLength:=Length(Payload);
    for I:=0 to High(Payload) do Source.RData[I]:=Payload[I];
    Raw:=DNSRecordToRaw(Source);
    if DNSRecordBytesToRecord(Decoded,PByteArray(Pointer(Raw))^) then
      Result:=DNSRecordDataToString(Decoded) else Result:='decode failed';
  end;
begin
  CheckEqual(DnsResourceRecordToStr(drrAAAA),'IPv6 Host (AAAA)');
  Source:=Default(TDNSRecord); Source.RecType:=Ord(drrA); Source.DataLength:=4;
  Source.RData[0]:=192; Source.RData[1]:=0; Source.RData[2]:=2; Source.RData[3]:=250;
  CheckEqual(DNSRecordDataToString(Source),'192.0.2.250');
  CheckEqual(Display([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]),'::1');
  CheckEqual(Display([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),'::');
  CheckEqual(Display([$20,$01,$0d,$b8,0,0,0,0,0,0,0,0,0,0,0,1]),'2001:db8::1');
  CheckEqual(Display([$20,$01,$0d,$b8,0,0,0,1,0,2,0,3,0,4,0,5]),'2001:db8:0:1:2:3:4:5');
  CheckEqual(Display([$fe,$80,0,0,0,0,0,0,$01,$ff,$fe,$23,$45,$67,$89,$0a]),'fe80::1ff:fe23:4567:890a');
  CheckEqual(Display([]),'');
  CheckEqual(Display([0,0,0,1]),'');
  CheckEqual(Display([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),'');
  CheckEqual(Display([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),'');
end;

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

procedure TUnitTestDNSRecord.PayloadBoundsDoNotTouchAdjacentBytes;
const
  Lengths: array[0..3] of Word = (0, 1, High(Word) - 1, High(Word));
var
  Source, Decoded: TDNSRecord;
  Buffer: array[0..24 + High(Word) + 1] of Byte;
  Pass, N, Len: Integer;
begin
  // Sentinels make an unsigned zero-length underflow fail deterministically,
  // even when an out-of-bounds read happens to land on mapped memory.
  for Pass := 1 to 10 do
    for N := Low(Lengths) to High(Lengths) do
    begin
      FillChar(Source, SizeOf(Source), $3c);
      Source.DataLength := Lengths[N];
      FillChar(Buffer, SizeOf(Buffer), $a5);
      Len := DNSRecordRecordToBytes(PByteArray(@Buffer[0])^, Source);
      Check(Len = 24 + Lengths[N]);
      Check(Buffer[Len] = 0, 'Preserve the encoder trailing-zero contract.');
      Check(Buffer[Len + 1] = $a5, 'Encoder must not write beyond its terminator.');
      FillChar(Decoded, SizeOf(Decoded), $a5);
      Check(DNSRecordBytesToRecord(Decoded, PByteArray(@Buffer[0])^));
      Check(Decoded.DataLength = Lengths[N]);
      Check(CompareMem(@Decoded.RData[0], @Source.RData[0], Lengths[N]));
      Check(Decoded.RData[Lengths[N]] = $a5,
        'Decoder must not write beyond the declared payload.');
    end;
end;
end.
