unit urender;

{ Pure text-rendering helpers for the browser UI: word-wrap and turning a
  recipe into display lines. Kept free of the video/keyboard units so it is
  unit-testable headless. All output is transliterated to ASCII (via uutf8)
  so it fits the one-byte-per-cell console. }

{$mode objfpc}{$H+}

interface

uses
  urecipe;

type
  TDisplayLines = array of string;

{ Transliterate to display-safe ASCII. }
function Disp(const S: string): string;

{ Soft-wrap one logical line (no embedded newlines) to Width columns, breaking
  on spaces; over-long words are hard-split. Always returns at least one line. }
function WrapText(const S: string; Width: Integer): TDisplayLines;

{ The recipe's detail body as wrapped, transliterated display lines. The title
  is not included (the UI shows it in a persistent title bar). }
function BuildDetailLines(const R: TRecipe; Width: Integer): TDisplayLines;

{ A one-line list entry: transliterated title, keywords appended if they fit,
  truncated to Width. }
function ListLabel(const R: TRecipe; Width: Integer): string;

implementation

uses
  SysUtils, Classes, uutf8;

function Disp(const S: string): string;
begin
  Result := Utf8Transliterate(S);
end;

procedure Add(var A: TDisplayLines; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

procedure AddAll(var A: TDisplayLines; const B: TDisplayLines);
var
  i: Integer;
begin
  for i := 0 to High(B) do Add(A, B[i]);
end;

function WrapText(const S: string; Width: Integer): TDisplayLines;
var
  words: TStringList;
  i: Integer;
  cur, w: string;
begin
  Result := nil;
  if Width < 1 then Width := 1;
  words := TStringList.Create;
  try
    words.Delimiter := ' ';
    words.StrictDelimiter := True;
    words.DelimitedText := S;

    cur := '';
    for i := 0 to words.Count - 1 do
    begin
      w := words[i];
      if w = '' then Continue;              { collapse runs of spaces }
      { a word longer than the width is hard-split }
      while Length(w) > Width do
      begin
        if cur <> '' then begin Add(Result, cur); cur := ''; end;
        Add(Result, Copy(w, 1, Width));
        Delete(w, 1, Width);
      end;
      if cur = '' then
        cur := w
      else if Length(cur) + 1 + Length(w) <= Width then
        cur := cur + ' ' + w
      else
      begin
        Add(Result, cur);
        cur := w;
      end;
    end;
    Add(Result, cur);   { the last (possibly empty) line }
  finally
    words.Free;
  end;
end;

{ Wrap Text with a prefix on the first line and matching indent on the rest. }
procedure AddWrappedIndented(var A: TDisplayLines; const First, Text: string;
  Width: Integer);
var
  cont: string;
  body: TDisplayLines;
  i, w: Integer;
begin
  cont := StringOfChar(' ', Length(First));
  w := Width - Length(First);
  if w < 1 then w := 1;
  body := WrapText(Text, w);
  for i := 0 to High(body) do
    if i = 0 then Add(A, First + body[i])
    else Add(A, cont + body[i]);
end;

{ Render a value like "4 Servings" as-is, a bare "4" as "Serves 4". }
function ServingsLine(const S: string): string;
begin
  if (Pos('serv', LowerCase(S)) > 0) or (Pos('make', LowerCase(S)) > 0)
     or (Pos('yield', LowerCase(S)) > 0) then
    Result := S
  else
    Result := 'Serves ' + S;
end;

function KeywordText(const R: TRecipe): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(R.Keywords) do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + R.Keywords[i];
  end;
end;

{ Split a string on LF into paragraphs (double-LF -> a blank paragraph). }
procedure SplitParagraphs(const S: string; Dest: TStringList);
begin
  Dest.TextLineBreakStyle := tlbsLF;
  Dest.Text := StringReplace(StringReplace(S, #13#10, #10, [rfReplaceAll]),
                             #13, #10, [rfReplaceAll]);
end;

function BuildDetailLines(const R: TRecipe; Width: Integer): TDisplayLines;
var
  i, n: Integer;
  meta: string;
  paras: TStringList;
begin
  Result := nil;
  if Width < 1 then Width := 1;

  meta := '';
  if R.Servings <> '' then meta := ServingsLine(R.Servings);
  if Length(R.Keywords) > 0 then
  begin
    if meta <> '' then meta := meta + '  -  ';
    meta := meta + KeywordText(R);
  end;
  if meta <> '' then
    AddAll(Result, WrapText(Disp(meta), Width));

  if R.Description <> '' then
  begin
    Add(Result, '');
    paras := TStringList.Create;
    try
      SplitParagraphs(R.Description, paras);
      for i := 0 to paras.Count - 1 do
        AddAll(Result, WrapText(Disp(paras[i]), Width));
    finally
      paras.Free;
    end;
  end;

  if Length(R.Ingredients) > 0 then
  begin
    Add(Result, '');
    Add(Result, 'Ingredients');
    for i := 0 to High(R.Ingredients) do
      if R.Ingredients[i].IsSection then
      begin
        Add(Result, '');
        Add(Result, '  -- ' + Disp(R.Ingredients[i].Text) + ' --');
      end
      else
        AddWrappedIndented(Result, '  ', Disp(R.Ingredients[i].Text), Width);
  end;

  if Length(R.Steps) > 0 then
  begin
    Add(Result, '');
    Add(Result, 'Steps');
    for i := 0 to High(R.Steps) do
    begin
      paras := TStringList.Create;
      try
        SplitParagraphs(R.Steps[i], paras);
        n := 0;
        while (n < paras.Count) and (Trim(paras[n]) = '') do Inc(n);
        if n < paras.Count then
          AddWrappedIndented(Result, IntToStr(i + 1) + '. ',
                             Disp(paras[n]), Width);
        Inc(n);
        while n < paras.Count do
        begin
          if Trim(paras[n]) = '' then Add(Result, '')
          else AddWrappedIndented(Result, '   ', Disp(paras[n]), Width);
          Inc(n);
        end;
      finally
        paras.Free;
      end;
    end;
  end;

  if R.SourceUrl <> '' then
  begin
    Add(Result, '');
    AddWrappedIndented(Result, 'Source: ', Disp(R.SourceUrl), Width);
  end;
end;

function ListLabel(const R: TRecipe; Width: Integer): string;
var
  title, kw, tail: string;
begin
  if Width < 1 then Width := 1;
  title := Disp(R.Title);
  kw := Disp(KeywordText(R));
  Result := title;
  if kw <> '' then
  begin
    tail := '  [' + kw + ']';
    { append keywords only if the whole thing still fits }
    if Length(title) + Length(tail) <= Width then
      Result := title + tail;
  end;
  if Length(Result) > Width then
    Result := Copy(Result, 1, Width);
end;

end.
