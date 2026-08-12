unit utui;

{$mode objfpc}{$H+}

interface

uses
  uapi;

procedure RunTUI(Client: TTandoorClient);

implementation

uses
  SysUtils, ncurses, umodels;

type
  TAppState = (asSearch, asList, asDetail);
  TStrArray = array of string;

const
  KeyEsc = 27;
  KeyBackspaceAscii = 127;
  KeyBackspaceCtrl = 8;

  CPTitle = 1;
  CPSelected = 2;
  CPError = 3;
  CPInfo = 4;
  CPHeading = 5;
  CPGroup = 6;
  CPHint = 7;

var
  GHasColors: Boolean;
  GClient: TTandoorClient;
  GState: TAppState;
  GQuery: string;
  GPage: Integer;
  GResult: TSearchResult;
  GSelected: Integer;
  GListScroll: Integer;
  GStatus: string;
  GDetail: TRecipeDetail;
  GDetailLines: TStrArray;
  GDetailScroll: Integer;

function Clip(const S: string; MaxLen: Integer): string;
begin
  if MaxLen < 1 then
    Result := ''
  else if Length(S) <= MaxLen then
    Result := S
  else
    Result := Copy(S, 1, MaxLen);
end;

procedure PutStr(Y, X: Integer; const S: string);
begin
  if (Y < 0) or (Y >= LINES) then
    Exit;
  mvprintw(Y, X, PChar('%s'), PChar(S));
end;

procedure PutStrAttr(Y, X: Integer; const S: string; Attr: attr_t);
begin
  if Attr <> 0 then
    attron(Attr);
  PutStr(Y, X, S);
  if Attr <> 0 then
    attroff(Attr);
end;

function Pair(P: Integer): attr_t;
begin
  if GHasColors then
    Result := attr_t(COLOR_PAIR(P))
  else
    Result := 0;
end;

function WrapText(const S: string; MaxLen: Integer): TStrArray;
var
  Words: array of string;
  WCount, P, WStart, I: Integer;
  Word, Line: string;
begin
  SetLength(Result, 0);
  if MaxLen < 10 then
    MaxLen := 10;

  SetLength(Words, 0);
  WCount := 0;
  WStart := 1;
  P := 1;
  while P <= Length(S) + 1 do
  begin
    if (P > Length(S)) or (S[P] = ' ') then
    begin
      if P > WStart then
      begin
        Inc(WCount);
        SetLength(Words, WCount);
        Words[WCount - 1] := Copy(S, WStart, P - WStart);
      end;
      WStart := P + 1;
    end;
    Inc(P);
  end;

  Line := '';
  for I := 0 to WCount - 1 do
  begin
    Word := Words[I];
    if Line = '' then
      Line := Word
    else if Length(Line) + 1 + Length(Word) <= MaxLen then
      Line := Line + ' ' + Word
    else
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Line;
      Line := Word;
    end;
  end;
  if Line <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Line;
  end;

  if Length(Result) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := '';
  end;
end;

procedure BuildDetailLines;
var
  Lines: TStrArray;

  procedure AddLine(const S: string);
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := S;
  end;

var
  I, J, Width: Integer;
  Wrapped: TStrArray;
  Ing: TIngredient;
  Step: TStep;
  ServingsDisp, AmountStr, Line: string;
begin
  SetLength(Lines, 0);
  Width := COLS - 2;
  if Width < 20 then
    Width := 20;

  AddLine(GDetail.Name);
  AddLine('');

  if GDetail.Description <> '' then
  begin
    Wrapped := WrapText(GDetail.Description, Width);
    for I := 0 to High(Wrapped) do
      AddLine(Wrapped[I]);
    AddLine('');
  end;

  if GDetail.ServingsText <> '' then
    ServingsDisp := GDetail.ServingsText
  else
    ServingsDisp := IntToStr(GDetail.Servings);

  AddLine(Format('Servings: %s   Prep: %d min   Cook: %d min   Rating: %.1f',
    [ServingsDisp, GDetail.WaitingTime, GDetail.WorkingTime, GDetail.Rating]));
  AddLine('');

  AddLine('Ingredients:');
  for I := 0 to High(GDetail.Steps) do
  begin
    Step := GDetail.Steps[I];
    for J := 0 to High(Step.Ingredients) do
    begin
      Ing := Step.Ingredients[J];
      if Ing.IsHeader then
      begin
        if Ing.FoodName <> '' then
          AddLine('-- ' + Ing.FoodName + ' --')
        else if Ing.Note <> '' then
          AddLine('-- ' + Ing.Note + ' --');
        Continue;
      end;

      if Ing.OriginalText <> '' then
        AddLine('  * ' + Ing.OriginalText)
      else
      begin
        AmountStr := '';
        if Ing.Amount <> 0 then
          AmountStr := FloatToStrF(Ing.Amount, ffGeneral, 4, 2) + ' ';
        Line := '  * ' + AmountStr;
        if Ing.UnitName <> '' then
          Line := Line + Ing.UnitName + ' ';
        Line := Line + Ing.FoodName;
        if Ing.Note <> '' then
          Line := Line + ' (' + Ing.Note + ')';
        AddLine(Line);
      end;
    end;
  end;
  AddLine('');

  AddLine('Steps:');
  for I := 0 to High(GDetail.Steps) do
  begin
    Step := GDetail.Steps[I];
    if Step.Name <> '' then
      AddLine(Format('%d. %s', [I + 1, Step.Name]))
    else
      AddLine(Format('Step %d:', [I + 1]));

    if Step.Instruction <> '' then
    begin
      Wrapped := WrapText(Step.Instruction, Width);
      for J := 0 to High(Wrapped) do
        AddLine('   ' + Wrapped[J]);
    end;
    AddLine('');
  end;

  GDetailLines := Lines;
  GDetailScroll := 0;
end;

procedure DoSearch;
begin
  try
    GResult := GClient.SearchRecipes(GQuery, GPage);
    GStatus := '';
  except
    on E: ETandoorError do
    begin
      GStatus := 'Error: ' + E.Message;
      SetLength(GResult.Recipes, 0);
      GResult.Count := 0;
      GResult.HasNext := False;
      GResult.HasPrevious := False;
    end;
  end;
  GSelected := 0;
  GListScroll := 0;
end;

procedure OpenDetail(Id: Integer);
begin
  try
    GDetail := GClient.GetRecipeDetail(Id);
    GStatus := '';
    BuildDetailLines;
    GState := asDetail;
  except
    on E: ETandoorError do
      GStatus := 'Error: ' + E.Message;
  end;
end;

procedure DrawList;
var
  ListTop, ListHeight, I, Idx: Integer;
  R: TRecipeOverview;
  Line, PageInfo: string;
  SelectedAttr: attr_t;
begin
  if GHasColors then
    SelectedAttr := Pair(CPSelected) or A_BOLD
  else
    SelectedAttr := A_REVERSE;
  erase;

  if GState = asSearch then
    PutStrAttr(0, 0, Clip('Search: ' + GQuery + '_', COLS - 1), Pair(CPTitle) or A_BOLD)
  else
    PutStrAttr(0, 0, Clip('Search: ' + GQuery + '   (press / to edit)', COLS - 1), Pair(CPTitle) or A_BOLD);

  ListTop := 2;
  ListHeight := LINES - ListTop - 2;
  if ListHeight < 1 then
    ListHeight := 1;

  if Length(GResult.Recipes) = 0 then
  begin
    if (GStatus = '') and (GQuery <> '') then
      PutStr(ListTop, 0, Clip('No recipes found for ''' + GQuery + '''.', COLS - 1));
  end
  else
  begin
    if GSelected < GListScroll then
      GListScroll := GSelected;
    if GSelected >= GListScroll + ListHeight then
      GListScroll := GSelected - ListHeight + 1;
    if GListScroll < 0 then
      GListScroll := 0;

    for I := 0 to ListHeight - 1 do
    begin
      Idx := GListScroll + I;
      if Idx > High(GResult.Recipes) then
        Break;
      R := GResult.Recipes[Idx];
      Line := R.Name;
      if R.WorkingTime + R.WaitingTime > 0 then
        Line := Line + Format('  (%d min)', [R.WorkingTime + R.WaitingTime]);
      if R.Rating > 0 then
        Line := Line + Format('  [%.1f]', [R.Rating]);

      if Idx = GSelected then
        PutStrAttr(ListTop + I, 0, Clip(Line, COLS - 1), SelectedAttr)
      else
        PutStr(ListTop + I, 0, Clip(Line, COLS - 1));
    end;
  end;

  if GStatus <> '' then
    PageInfo := GStatus
  else if GResult.Count > 0 then
    PageInfo := Format('Page %d - %d recipe(s) found', [GPage, GResult.Count])
  else
    PageInfo := '';
  if GStatus <> '' then
    PutStrAttr(LINES - 2, 0, Clip(PageInfo, COLS - 1), Pair(CPError) or A_BOLD)
  else
    PutStrAttr(LINES - 2, 0, Clip(PageInfo, COLS - 1), Pair(CPInfo));

  PutStrAttr(LINES - 1, 0, Clip(
    'Up/Down: select  Enter: view  /: search  n/p: page  q: quit', COLS - 1), Pair(CPHint));

  refresh;
end;

function DetailLineAttr(Idx: Integer; const S: string): attr_t;
begin
  if Idx = 0 then
    Result := Pair(CPTitle) or A_BOLD
  else if (S = 'Ingredients:') or (S = 'Steps:') then
    Result := Pair(CPHeading) or A_BOLD
  else if (Length(S) > 6) and (Copy(S, 1, 3) = '-- ') and (Copy(S, Length(S) - 2, 3) = ' --') then
    Result := Pair(CPGroup) or A_BOLD
  else
    Result := 0;
end;

procedure DrawDetail;
var
  BodyHeight, I, Idx: Integer;
begin
  erase;

  BodyHeight := LINES - 1;
  if BodyHeight < 1 then
    BodyHeight := 1;

  if GDetailScroll > Length(GDetailLines) - BodyHeight then
    GDetailScroll := Length(GDetailLines) - BodyHeight;
  if GDetailScroll < 0 then
    GDetailScroll := 0;

  for I := 0 to BodyHeight - 1 do
  begin
    Idx := GDetailScroll + I;
    if Idx >= Length(GDetailLines) then
      Break;
    PutStrAttr(I, 0, Clip(GDetailLines[Idx], COLS - 1), DetailLineAttr(Idx, GDetailLines[Idx]));
  end;

  PutStrAttr(LINES - 1, 0, Clip('Up/Down: scroll  q/Esc: back', COLS - 1), Pair(CPHint));

  refresh;
end;

procedure HandleSearchKey(Key: Integer; var Running: Boolean);
begin
  case Key of
    10, 13, KEY_ENTER:
      begin
        GPage := 1;
        DoSearch;
        GState := asList;
      end;
    KeyEsc:
      if Length(GResult.Recipes) > 0 then
        GState := asList
      else
        Running := False;
    KeyBackspaceAscii, KeyBackspaceCtrl, KEY_BACKSPACE:
      if Length(GQuery) > 0 then
        Delete(GQuery, Length(GQuery), 1);
  else
    if (Key >= 32) and (Key < 127) then
      GQuery := GQuery + Chr(Key);
  end;
end;

procedure HandleListKey(Key: Integer; var Running: Boolean);
begin
  case Key of
    KEY_UP:
      if GSelected > 0 then
        Dec(GSelected);
    KEY_DOWN:
      if GSelected < High(GResult.Recipes) then
        Inc(GSelected);
    10, 13, KEY_ENTER:
      if Length(GResult.Recipes) > 0 then
        OpenDetail(GResult.Recipes[GSelected].Id);
    Ord('/'):
      GState := asSearch;
    Ord('n'), KEY_NPAGE:
      if GResult.HasNext then
      begin
        Inc(GPage);
        DoSearch;
      end;
    Ord('p'), KEY_PPAGE:
      if GResult.HasPrevious and (GPage > 1) then
      begin
        Dec(GPage);
        DoSearch;
      end;
    Ord('q'), KeyEsc:
      Running := False;
  end;
end;

procedure HandleDetailKey(Key: Integer);
begin
  case Key of
    KEY_UP, Ord('k'):
      if GDetailScroll > 0 then
        Dec(GDetailScroll);
    KEY_DOWN, Ord('j'):
      Inc(GDetailScroll);
    KEY_NPAGE:
      Inc(GDetailScroll, LINES - 1);
    KEY_PPAGE:
      Dec(GDetailScroll, LINES - 1);
    Ord('q'), KeyEsc, KeyBackspaceAscii, KeyBackspaceCtrl, KEY_BACKSPACE:
      GState := asList;
  end;
  if GDetailScroll < 0 then
    GDetailScroll := 0;
end;

procedure MainLoop(Client: TTandoorClient);
var
  Key: Integer;
  Running: Boolean;
begin
  GClient := Client;
  GState := asSearch;
  GQuery := '';
  GPage := 1;
  GSelected := 0;
  GListScroll := 0;
  GStatus := '';
  SetLength(GResult.Recipes, 0);
  GResult.Count := 0;
  GResult.HasNext := False;
  GResult.HasPrevious := False;

  Running := True;
  while Running do
  begin
    case GState of
      asSearch, asList: DrawList;
      asDetail: DrawDetail;
    end;

    Key := getch;

    case GState of
      asSearch: HandleSearchKey(Key, Running);
      asList: HandleListKey(Key, Running);
      asDetail: HandleDetailKey(Key);
    end;
  end;
end;

procedure RunTUI(Client: TTandoorClient);
begin
  initscr;
  try
    cbreak;
    noecho;
    keypad(stdscr, True);
    curs_set(0);

    GHasColors := has_colors;
    if GHasColors then
    begin
      start_color;
      use_default_colors;
      init_pair(CPTitle, COLOR_CYAN, -1);
      init_pair(CPSelected, COLOR_BLACK, COLOR_CYAN);
      init_pair(CPError, COLOR_RED, -1);
      init_pair(CPInfo, COLOR_GREEN, -1);
      init_pair(CPHeading, COLOR_YELLOW, -1);
      init_pair(CPGroup, COLOR_MAGENTA, -1);
      init_pair(CPHint, COLOR_BLUE, -1);
    end;

    MainLoop(Client);
  finally
    endwin;
  end;
end;

end.
