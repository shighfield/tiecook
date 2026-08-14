unit ufv;

interface

uses
  uapi;

procedure RunTUI(Client: TTandoorClient);

implementation

uses
  SysUtils, Objects, Drivers, Views, Dialogs, Editors, Menus, App, FVConsts,
  umodels, uopen;

const
  cmDoSearch = 100;

type
  PRecipeListBox = ^TRecipeListBox;
  TRecipeListBox = object(TListBox)
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PQueryLine = ^TQueryLine;
  TQueryLine = object(TInputLine)
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDetailWindow = ^TDetailWindow;
  TDetailWindow = object(TDialog)
    Url: PString;
    constructor Init(const ATitle, ABody, AUrl: string);
    destructor Done; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PTiecookApp = ^TTiecookApp;
  TTiecookApp = object(TApplication)
    Client: TTandoorClient;
    ListBox: PRecipeListBox;
    QueryLine: PQueryLine;
    MessageLine: PStaticText;
    Results: TRecipeOverviewArray;
    LastQuery: string;
    Page: Integer;
    HasNext, HasPrevious: Boolean;
    CurSortOrder: string;
    CurRatingGte: Integer;
    CurKeywordId: Integer;
    CurKeywordName: string;
    constructor Init(AClient: TTandoorClient);
    function GetPalette: PPalette; virtual;
    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure SetMessage(const S: string);
    procedure DoSearch(const Query: string; APage: Integer);
    procedure OpenRecipe(Index: Integer);
    procedure OpenRecipeDetail(AId: Integer);
    procedure DoRandom;
    procedure DoFilterDialog;
    procedure DoKeywordDialog;
  end;

function BuildDetailText(const D: TRecipeDetail): string;
var
  I, J: Integer;
  Ing: TIngredient;
  Step: TStep;
  ServingsDisp, AmountStr, KwLine: string;
begin
  Result := D.Name + #13#13;

  if D.Description <> '' then
    Result := Result + D.Description + #13#13;

  if D.ServingsText <> '' then
    ServingsDisp := D.ServingsText
  else
    ServingsDisp := IntToStr(D.Servings);
  Result := Result + Format('Servings: %s   Prep: %d min   Cook: %d min   Rating: %.1f',
    [ServingsDisp, D.WaitingTime, D.WorkingTime, D.Rating]) + #13#13;

  if Length(D.Keywords) > 0 then
  begin
    KwLine := '';
    for I := 0 to High(D.Keywords) do
    begin
      if I > 0 then
        KwLine := KwLine + ', ';
      KwLine := KwLine + D.Keywords[I].Name;
    end;
    Result := Result + 'Keywords: ' + KwLine + #13#13;
  end;

  Result := Result + 'Ingredients:' + #13;
  for I := 0 to High(D.Steps) do
  begin
    Step := D.Steps[I];
    for J := 0 to High(Step.Ingredients) do
    begin
      Ing := Step.Ingredients[J];
      if Ing.IsHeader then
      begin
        if Ing.FoodName <> '' then
          Result := Result + '-- ' + Ing.FoodName + ' --' + #13
        else if Ing.Note <> '' then
          Result := Result + '-- ' + Ing.Note + ' --' + #13;
        Continue;
      end;

      if Ing.OriginalText <> '' then
        Result := Result + '  * ' + Ing.OriginalText + #13
      else
      begin
        AmountStr := '';
        if Ing.Amount <> 0 then
          AmountStr := FloatToStrF(Ing.Amount, ffGeneral, 4, 2) + ' ';
        Result := Result + '  * ' + AmountStr;
        if Ing.UnitName <> '' then
          Result := Result + Ing.UnitName + ' ';
        Result := Result + Ing.FoodName;
        if Ing.Note <> '' then
          Result := Result + ' (' + Ing.Note + ')';
        Result := Result + #13;
      end;
    end;
  end;
  Result := Result + #13;

  Result := Result + 'Steps:' + #13;
  for I := 0 to High(D.Steps) do
  begin
    Step := D.Steps[I];
    if Step.Name <> '' then
      Result := Result + Format('%d. %s', [I + 1, Step.Name]) + #13
    else
      Result := Result + Format('Step %d:', [I + 1]) + #13;

    if Step.Instruction <> '' then
      Result := Result + Step.Instruction + #13;
    Result := Result + #13;
  end;

  if D.SourceUrl <> '' then
    Result := Result + 'Source: ' + D.SourceUrl + #13;
end;

{ TRecipeListBox }

procedure TRecipeListBox.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) and (Range > 0) then
  begin
    SelectItem(Focused);
    ClearEvent(Event);
  end;
end;

{ TQueryLine }

procedure TQueryLine.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) then
  begin
    Message(Owner, evBroadcast, cmDoSearch, @Self);
    ClearEvent(Event);
  end;
end;

{ TDetailWindow }

constructor TDetailWindow.Init(const ATitle, ABody, AUrl: string);
var
  R, Inner, VR, MR: TRect;
  Memo: PMemo;
  VSB: PScrollBar;
begin
  Application^.GetExtent(R);
  R.Grow(-2, -1);
  inherited Init(R, ATitle);

  Url := NewStr(AUrl);

  GetExtent(Inner);
  Inner.Grow(-1, -1);

  VR.Assign(Inner.B.X - 1, Inner.A.Y, Inner.B.X, Inner.B.Y);
  VSB := New(PScrollBar, Init(VR));
  Insert(VSB);

  MR.Assign(Inner.A.X, Inner.A.Y, Inner.B.X - 1, Inner.B.Y);
  Memo := New(PMemo, Init(MR, nil, VSB, nil, Length(ABody) + 1));
  Memo^.IsReadOnly := True;
  Memo^.Word_Wrap := True;
  if Length(ABody) > 0 then
    Memo^.InsertText(@ABody[1], Length(ABody), False);
  Memo^.SetCurPtr(0, 0);
  Insert(Memo);
end;

destructor TDetailWindow.Done;
begin
  DisposeStr(Url);
  inherited Done;
end;

procedure TDetailWindow.HandleEvent(var Event: TEvent);
begin
  if Event.What = evKeyDown then
  begin
    if Event.KeyCode = kbEsc then
    begin
      ClearEvent(Event);
      Close;
      Exit;
    end;
    if UpCase(Event.CharCode) = 'O' then
    begin
      if (Url <> nil) and (Url^ <> '') then
        OpenUrl(Url^);
      ClearEvent(Event);
      Exit;
    end;
  end;
  inherited HandleEvent(Event);
end;

{ TTiecookApp }

const
  { CAppColor (app.pas) with the loud green/cyan panel backgrounds collapsed
    to blue, and low-contrast text on those panels bumped to light gray. }
  CAppColorCalm =
       #$71#$70#$78#$74#$17#$18#$14#$17#$1F#$1F#$17#$17#$1E#$71#$1F +
   #$17#$1F#$1F#$1F#$1F#$1E#$17#$1F#$70#$70#$70#$1F#$1F#$70#$70#$7E +
   #$70#$70#$70#$1F#$1F#$70#$70#$70#$7E#$17#$1F#$1F#$78#$1E#$70#$17 +
   #$1F#$1E#$1F#$1F#$1F#$17#$70#$17#$17#$17#$1F#$1E#$17#$1F#$18#$00 +
   #$17#$1F#$1F#$71#$71#$1E#$17#$1F#$1E#$17#$1F#$1F#$78#$1E#$17#$17 +
   #$1F#$1E#$70#$1F#$70#$17#$1F#$17#$17#$17#$1F#$1E#$17#$1F#$18#$00 +
   #$17#$1F#$1F#$1F#$1F#$1E#$17#$1F#$1E#$17#$1F#$1F#$78#$1E#$17#$70 +
   #$70#$7E#$1F#$1F#$1F#$17#$1F#$17#$71#$70#$1F#$7E#$71#$1F#$18#$00;

function TTiecookApp.GetPalette: PPalette;
const
  P: string[Length(CAppColorCalm)] = CAppColorCalm;
begin
  Result := PPalette(@P);
end;

constructor TTiecookApp.Init(AClient: TTandoorClient);
var
  R: TRect;
begin
  inherited Init;
  Client := AClient;
  Page := 1;
  HasNext := False;
  HasPrevious := False;
  CurSortOrder := '';
  CurRatingGte := 0;
  CurKeywordId := 0;
  CurKeywordName := '';

  GetExtent(R);
  R.Assign(0, 0, 9, 1);
  Insert(New(PStaticText, Init(R, 'Search:')));

  GetExtent(R);
  R.Assign(9, 0, R.B.X, 1);
  QueryLine := New(PQueryLine, Init(R, 100));
  Insert(QueryLine);

  GetExtent(R);
  R.Assign(0, R.B.Y - 2, R.B.X, R.B.Y - 1);
  MessageLine := New(PStaticText, Init(R, ''));
  Insert(MessageLine);

  GetExtent(R);
  R.Assign(2, 2, R.B.X - 2, R.B.Y - 2);
  ListBox := New(PRecipeListBox, Init(R, 1, nil));
  Insert(ListBox);

  QueryLine^.Select;
end;

procedure TTiecookApp.InitMenuBar;
begin
  MenuBar := nil;
end;

procedure TTiecookApp.InitStatusLine;
var
  R: TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  New(StatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Enter~ Open', kbNoKey, cmValid,
      NewStatusKey('~N~/~P~ Page', kbNoKey, cmValid,
      NewStatusKey('~R~ Random', kbNoKey, cmValid,
      NewStatusKey('~F~ Filter', kbNoKey, cmValid,
      NewStatusKey('~K~ Keyword', kbNoKey, cmValid,
      NewStatusKey('~O~ Browser', kbNoKey, cmValid,
      NewStatusKey('~Alt-X~ Exit', kbAltX, cmQuit,
      nil))))))), nil)));
end;

procedure TTiecookApp.SetMessage(const S: string);
begin
  if MessageLine = nil then
    Exit;
  DisposeStr(MessageLine^.Text);
  MessageLine^.Text := NewStr(S);
  MessageLine^.DrawView;
end;

procedure TTiecookApp.DoSearch(const Query: string; APage: Integer);
var
  Res: TSearchResult;
  P: TSearchParams;
  List: PStrCollection;
  I: Integer;
  Line, FilterInfo: string;
begin
  P.Query := Query;
  P.Page := APage;
  P.SortOrder := CurSortOrder;
  P.RatingGte := CurRatingGte;
  P.KeywordId := CurKeywordId;
  try
    Res := Client.SearchRecipes(P);
  except
    on E: ETandoorError do
    begin
      SetMessage('Error: ' + E.Message);
      SetLength(Results, 0);
      ListBox^.NewList(nil);
      Exit;
    end;
  end;

  Results := Res.Recipes;
  LastQuery := Query;
  Page := APage;
  HasNext := Res.HasNext;
  HasPrevious := Res.HasPrevious;

  List := New(PStrCollection, Init(Length(Results) + 1, 8));
  for I := 0 to High(Results) do
  begin
    Line := Results[I].Name;
    if Results[I].WorkingTime + Results[I].WaitingTime > 0 then
      Line := Line + Format('  (%d min)', [Results[I].WorkingTime + Results[I].WaitingTime]);
    if Results[I].Rating > 0 then
      Line := Line + Format('  [%.1f]', [Results[I].Rating]);
    List^.AtInsert(I, NewStr(Line));
  end;
  ListBox^.NewList(List);

  FilterInfo := '';
  if CurKeywordId > 0 then
    FilterInfo := FilterInfo + '  kw:' + CurKeywordName;
  if CurRatingGte > 0 then
    FilterInfo := FilterInfo + Format('  rating>=%d', [CurRatingGte]);
  if CurSortOrder <> '' then
    FilterInfo := FilterInfo + '  sort:' + CurSortOrder;

  if Res.Count > 0 then
    SetMessage(Format('Page %d - %d recipe(s) found', [APage, Res.Count]) + FilterInfo)
  else
    SetMessage(Format('No recipes found for ''%s''.', [Query]) + FilterInfo);
end;

procedure TTiecookApp.OpenRecipeDetail(AId: Integer);
var
  Detail: TRecipeDetail;
  Win: PDetailWindow;
begin
  try
    Detail := Client.GetRecipeDetail(AId);
  except
    on E: ETandoorError do
    begin
      SetMessage('Error: ' + E.Message);
      Exit;
    end;
  end;
  Win := New(PDetailWindow, Init(Detail.Name, BuildDetailText(Detail),
    Client.BaseUrl + '/view/recipe/' + IntToStr(Detail.Id)));
  Insert(Win);
end;

procedure TTiecookApp.OpenRecipe(Index: Integer);
begin
  if (Index < 0) or (Index > High(Results)) then
    Exit;
  OpenRecipeDetail(Results[Index].Id);
end;

procedure TTiecookApp.DoRandom;
var
  Ov: TRecipeOverview;
begin
  try
    Ov := Client.GetRandomRecipe;
  except
    on E: ETandoorError do
    begin
      SetMessage('Error: ' + E.Message);
      Exit;
    end;
  end;
  SetMessage('Random pick: ' + Ov.Name);
  OpenRecipeDetail(Ov.Id);
end;

procedure TTiecookApp.DoFilterDialog;
const
  SortLabels: array[0..4] of string =
    ('Best match', 'Name A-Z', 'Name Z-A', 'Highest rated', 'Lowest rated');
  SortValues: array[0..4] of string =
    ('', 'name', '-name', '-rating', 'rating');
  RatingLabels: array[0..5] of string =
    ('Any', '1 or more', '2 or more', '3 or more', '4 or more', '5 only');
var
  D: PDialog;
  R: TRect;
  SortRB, RatingRB: PRadioButtons;
  SortItems, RatingItems: PSItem;
  I, C, Sel, CX, CY: Integer;
begin
  { NewSItem prepends, so build the chains from the last label back to index 0. }
  SortItems := nil;
  for I := High(SortLabels) downto 0 do
    SortItems := NewSItem(SortLabels[I], SortItems);
  RatingItems := nil;
  for I := High(RatingLabels) downto 0 do
    RatingItems := NewSItem(RatingLabels[I], RatingItems);

  Application^.GetExtent(R);
  CX := (R.B.X - 48) div 2;
  CY := (R.B.Y - 12) div 2;
  if CX < 0 then CX := 0;
  if CY < 0 then CY := 0;
  R.Assign(CX, CY, CX + 48, CY + 12);
  D := New(PDialog, Init(R, 'Search Filters'));

  R.Assign(3, 2, 22, 3);
  D^.Insert(New(PStaticText, Init(R, 'Sort by')));
  R.Assign(3, 3, 23, 8);
  SortRB := New(PRadioButtons, Init(R, SortItems));
  D^.Insert(SortRB);

  R.Assign(25, 2, 45, 3);
  D^.Insert(New(PStaticText, Init(R, 'Minimum rating')));
  R.Assign(25, 3, 45, 9);
  RatingRB := New(PRadioButtons, Init(R, RatingItems));
  D^.Insert(RatingRB);

  R.Assign(9, 9, 21, 11);
  D^.Insert(New(PButton, Init(R, 'O~K~', cmOK, bfDefault)));
  R.Assign(25, 9, 37, 11);
  D^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

  { Preselect the current filter state by setting each cluster's Value. }
  Sel := 0;
  for I := 0 to High(SortValues) do
    if SortValues[I] = CurSortOrder then
    begin
      Sel := I;
      Break;
    end;
  SortRB^.Value := Sel;
  if (CurRatingGte >= 0) and (CurRatingGte <= High(RatingLabels)) then
    RatingRB^.Value := CurRatingGte
  else
    RatingRB^.Value := 0;

  SortRB^.Select;
  C := ExecView(D);
  if C = cmOK then
  begin
    { Read selections straight off the controls (they live until Dispose). }
    I := SortRB^.Value;
    if (I >= 0) and (I <= High(SortValues)) then
      CurSortOrder := SortValues[I];
    CurRatingGte := RatingRB^.Value;
    Dispose(D, Done);
    DoSearch(LastQuery, 1);
    Exit;
  end;
  Dispose(D, Done);
end;

procedure TTiecookApp.DoKeywordDialog;
var
  Keywords: TKeywordArray;
  D: PDialog;
  R: TRect;
  LB: PListBox;
  SB: PScrollBar;
  Coll: PStrCollection;
  I, C, CX, CY: Integer;
const
  W = 42;
  H = 20;
begin
  try
    Keywords := Client.ListKeywords;
  except
    on E: ETandoorError do
    begin
      SetMessage('Error: ' + E.Message);
      Exit;
    end;
  end;

  Application^.GetExtent(R);
  CX := (R.B.X - W) div 2;
  CY := (R.B.Y - H) div 2;
  if CX < 0 then CX := 0;
  if CY < 0 then CY := 0;
  R.Assign(CX, CY, CX + W, CY + H);
  D := New(PDialog, Init(R, 'Filter by Keyword'));

  R.Assign(W - 4, 2, W - 3, H - 4);
  SB := New(PScrollBar, Init(R));
  D^.Insert(SB);
  R.Assign(3, 2, W - 4, H - 4);
  LB := New(PListBox, Init(R, 1, SB));
  D^.Insert(LB);

  { Index 0 is the "clear filter" row; keyword i sits at row i+1. }
  Coll := New(PStrCollection, Init(Length(Keywords) + 1, 8));
  Coll^.AtInsert(0, NewStr('(no keyword filter)'));
  for I := 0 to High(Keywords) do
    Coll^.AtInsert(I + 1, NewStr(Keywords[I].Name));
  LB^.NewList(Coll);

  if CurKeywordId > 0 then
    for I := 0 to High(Keywords) do
      if Keywords[I].Id = CurKeywordId then
      begin
        LB^.FocusItem(I + 1);
        Break;
      end;

  R.Assign(6, H - 3, 18, H - 1);
  D^.Insert(New(PButton, Init(R, 'O~K~', cmOK, bfDefault)));
  R.Assign(22, H - 3, 34, H - 1);
  D^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

  LB^.Select;
  C := ExecView(D);
  if C = cmOK then
  begin
    I := LB^.Focused;
    if I <= 0 then
    begin
      CurKeywordId := 0;
      CurKeywordName := '';
    end
    else
    begin
      CurKeywordId := Keywords[I - 1].Id;
      CurKeywordName := Keywords[I - 1].Name;
    end;
    Dispose(D, Done);
    DoSearch(LastQuery, 1);
    Exit;
  end;
  Dispose(D, Done);
end;

procedure TTiecookApp.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  case Event.What of
    evBroadcast:
      case Event.Command of
        cmDoSearch:
          begin
            DoSearch(QueryLine^.Data^, 1);
            ClearEvent(Event);
          end;
        cmListItemSelected:
          if Event.InfoPtr = ListBox then
          begin
            OpenRecipe(ListBox^.Focused);
            ClearEvent(Event);
          end;
      end;
    evKeyDown:
      case Event.KeyCode of
        kbTab:
          begin
            FocusNext(False);
            ClearEvent(Event);
          end;
        kbShiftTab:
          begin
            FocusNext(True);
            ClearEvent(Event);
          end;
      else
        case UpCase(Event.CharCode) of
          'N':
            if HasNext then
            begin
              DoSearch(LastQuery, Page + 1);
              ClearEvent(Event);
            end;
          'P':
            if HasPrevious and (Page > 1) then
            begin
              DoSearch(LastQuery, Page - 1);
              ClearEvent(Event);
            end;
          'R':
            begin
              DoRandom;
              ClearEvent(Event);
            end;
          'F':
            begin
              DoFilterDialog;
              ClearEvent(Event);
            end;
          'K':
            begin
              DoKeywordDialog;
              ClearEvent(Event);
            end;
        end;
      end;
  end;
end;

procedure RunTUI(Client: TTandoorClient);
var
  MyApp: TTiecookApp;
begin
  MyApp.Init(Client);
  MyApp.Run;
  MyApp.Done;
  {$IFDEF UNIX}
  { Free Vision's Linux teardown homes the cursor but leaves the TUI frame on
    screen, so the shell prompt is buried until the user clears it manually.
    Reset attributes, clear the screen, home the cursor and make it visible. }
  Write(#27'[0m'#27'[2J'#27'[H'#27'[?25h');
  Flush(Output);
  {$ENDIF}
end;

end.
