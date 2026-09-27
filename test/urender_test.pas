program urender_test;

{ Tests for the pure rendering core: UTF-8 transliteration, word wrap, and
  the recipe -> display-lines builder. }

{$mode objfpc}{$H+}

uses
  SysUtils, urecipe, uutf8, urender;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

function Contains(const Lines: TDisplayLines; const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Lines) do
    if Pos(S, Lines[i]) > 0 then Exit(True);
end;

function MaxLen(const Lines: TDisplayLines): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Lines) do
    if Length(Lines[i]) > Result then Result := Length(Lines[i]);
end;

const LF = #10;

procedure TestTransliterate;
begin
  Check(Utf8Transliterate('Cafe') = 'Cafe', 'ascii unchanged');
  Check(Utf8Transliterate('Cr'#$C3#$A8'me') = 'Creme', 'e-grave -> e');
  Check(Utf8Transliterate('Br'#$C3#$BB'l'#$C3#$A9'e') = 'Brulee', 'u-circ, e-acute');
  Check(Utf8Transliterate(#$C2#$BD' cup') = '1/2 cup', 'half fraction');
  Check(Utf8Transliterate('180 '#$C2#$B0'C') = '180 C', 'degree dropped');
  Check(Utf8Transliterate('a'#$E2#$80#$94'b') = 'a-b', 'em dash -> hyphen');
end;

procedure TestWrap;
var
  L: TDisplayLines;
begin
  L := WrapText('the quick brown fox jumps', 10);
  Check(MaxLen(L) <= 10, 'no line exceeds width');
  Check(Length(L) >= 3, 'wrapped into multiple lines');
  Check(L[0] = 'the quick', 'first line greedily filled');

  { a word longer than the width is hard-split }
  L := WrapText('supercalifragilistic', 8);
  Check(MaxLen(L) <= 8, 'long word hard-split within width');

  L := WrapText('', 10);
  Check((Length(L) = 1) and (L[0] = ''), 'empty input -> one empty line');
end;

procedure TestDetail;
var
  R: TRecipe;
  L: TDisplayLines;
begin
  InitRecipe(R);
  R.Title := 'Creme Test';
  R.Servings := '4';
  AddKeyword(R, 'Dessert');
  AddIngredient(R, 'Base', True);
  AddIngredient(R, '1 cup Cr'#$C3#$A8'me fraiche');   { UTF-8 in the body }
  AddIngredient(R, '1 cup flour');
  AddStep(R, 'Mix well and pour into a pan then bake until the top is golden and set.');
  AddStep(R, 'Cool.' + LF + LF + 'Then dust with sugar.');

  L := BuildDetailLines(R, 20);
  Check(MaxLen(L) <= 20, 'all detail lines within width');
  Check(not Contains(L, 'Creme Test'), 'title is NOT repeated in the body');
  Check(Contains(L, 'Creme'), 'body text transliterated (e-grave -> e)');
  Check(Contains(L, 'Serves 4'), 'bare servings -> Serves 4');
  Check(Contains(L, 'Dessert'), 'keyword shown');
  Check(Contains(L, 'Ingredients'), 'ingredients heading');
  Check(Contains(L, '-- Base --'), 'ingredient section heading');
  Check(Contains(L, '1 cup flour'), 'ingredient item');
  Check(Contains(L, 'Steps'), 'steps heading');
  Check(Contains(L, '1. Mix well'), 'first step numbered');
  Check(Contains(L, '2. Cool.'), 'second step numbered');
  Check(Contains(L, 'Then dust'), 'multi-paragraph step second paragraph');
end;

procedure TestListLabel;
var
  R: TRecipe;
begin
  InitRecipe(R);
  R.Title := 'Squash Soup';
  AddKeyword(R, 'Soup'); AddKeyword(R, 'Shawn');
  Check(ListLabel(R, 60) = 'Squash Soup  [Soup, Shawn]', 'label with keywords when it fits');
  Check(ListLabel(R, 11) = 'Squash Soup', 'keywords dropped when tight');
  Check(Length(ListLabel(R, 6)) = 6, 'label truncated to width');
end;

begin
  TestTransliterate;
  TestWrap;
  TestDetail;
  TestListLabel;
  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
