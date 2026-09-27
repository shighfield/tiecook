unit uutf8;

{ UTF-8 -> displayable-ASCII transliteration for the one-byte-per-cell
  `video` console. Decodes UTF-8, then maps each code point to ASCII:
  accented Latin to its base letter (e-acute -> e), common punctuation and
  cooking glyphs (fractions, degree) to ASCII, and anything unmapped to '?'.
  The result is pure ASCII, so it renders with correct cell alignment on both
  the Linux and Windows video drivers. Library files and exported HTML keep
  full UTF-8; only on-screen text is folded through this.

  Ported from tiejoplin; no UI dependency, so it stays unit-testable. }

{$mode objfpc}{$H+}

interface

function Utf8Transliterate(const S: ansistring): ansistring;

implementation

{ Maps one Unicode code point to a short ASCII string. }
function MapCP(cp: LongWord): ansistring;
begin
  if (cp >= 32) and (cp < 127) then
    Exit(Chr(cp));
  if cp < 32 then
    Exit(' ');            { stray control char -> space }
  case cp of
    $A0: Exit(' ');       { nbsp }
    $A9: Exit('(c)');
    $AE: Exit('(R)');
    $B0: Exit('');        { degree sign -> drop (e.g. "180 C") }
    $B7: Exit('*');
    $BC: Exit('1/4');
    $BD: Exit('1/2');
    $BE: Exit('3/4');
    $C0..$C5: Exit('A');
    $C6: Exit('AE');
    $C7: Exit('C');
    $C8..$CB: Exit('E');
    $CC..$CF: Exit('I');
    $D0: Exit('D');
    $D1: Exit('N');
    $D2..$D6, $D8: Exit('O');
    $D7: Exit('x');
    $D9..$DC: Exit('U');
    $DD: Exit('Y');
    $DE: Exit('Th');
    $DF: Exit('ss');
    $E0..$E5: Exit('a');
    $E6: Exit('ae');
    $E7: Exit('c');
    $E8..$EB: Exit('e');
    $EC..$EF: Exit('i');
    $F0: Exit('d');
    $F1: Exit('n');
    $F2..$F6, $F8: Exit('o');
    $F7: Exit('/');
    $F9..$FC: Exit('u');
    $FD, $FF: Exit('y');
    $FE: Exit('th');
    { Latin Extended-A }
    $152: Exit('OE');  $153: Exit('oe');
    $160: Exit('S');   $161: Exit('s');
    $178: Exit('Y');
    $17D: Exit('Z');   $17E: Exit('z');
    { general punctuation }
    $2013, $2014: Exit('-');       { en/em dash }
    $2018, $2019: Exit('''');      { curly single quotes }
    $201C, $201D: Exit('"');       { curly double quotes }
    $2022: Exit('*');              { bullet }
    $2026: Exit('...');            { ellipsis }
    $20AC: Exit('EUR');            { euro }
    { vulgar fractions (common in recipes) }
    $2153: Exit('1/3');  $2154: Exit('2/3');
    $215B: Exit('1/8');  $215C: Exit('3/8');
    $215D: Exit('5/8');  $215E: Exit('7/8');
  else
    Exit('?');
  end;
end;

function Utf8Transliterate(const S: ansistring): ansistring;
var
  i, n, len: Integer;
  b0, b1, b2, b3: Byte;
  cp: LongWord;
begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    b0 := Byte(S[i]);
    if b0 < $80 then
    begin
      cp := b0; len := 1;
    end
    else if (b0 >= $C2) and (b0 <= $DF) and (i + 1 <= n) then
    begin
      b1 := Byte(S[i + 1]);
      if (b1 and $C0) = $80 then
      begin
        cp := ((b0 and $1F) shl 6) or (b1 and $3F); len := 2;
      end
      else begin cp := $FFFD; len := 1; end;
    end
    else if (b0 >= $E0) and (b0 <= $EF) and (i + 2 <= n) then
    begin
      b1 := Byte(S[i + 1]); b2 := Byte(S[i + 2]);
      if ((b1 and $C0) = $80) and ((b2 and $C0) = $80) then
      begin
        cp := ((b0 and $0F) shl 12) or ((b1 and $3F) shl 6) or (b2 and $3F);
        len := 3;
      end
      else begin cp := $FFFD; len := 1; end;
    end
    else if (b0 >= $F0) and (b0 <= $F4) and (i + 3 <= n) then
    begin
      b1 := Byte(S[i + 1]); b2 := Byte(S[i + 2]); b3 := Byte(S[i + 3]);
      if ((b1 and $C0) = $80) and ((b2 and $C0) = $80) and ((b3 and $C0) = $80) then
      begin
        cp := ((b0 and $07) shl 18) or ((b1 and $3F) shl 12) or
              ((b2 and $3F) shl 6) or (b3 and $3F);
        len := 4;
      end
      else begin cp := $FFFD; len := 1; end;
    end
    else
    begin
      cp := $FFFD; len := 1;   { lone continuation / invalid lead byte }
    end;
    Result := Result + MapCP(cp);
    Inc(i, len);
  end;
end;

end.
