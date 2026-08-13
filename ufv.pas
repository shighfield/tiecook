unit ufv;

interface

uses
  uapi;

procedure RunTUI(Client: TTandoorClient);

implementation

uses
  SysUtils, Objects, Drivers, Views, Dialogs, Editors, Menus, App, FVConsts, umodels;

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
    constructor Init(const ATitle, ABody: string);
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
    constructor Init(AClient: TTandoorClient);
    function GetPalette: PPalette; virtual;
    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure SetMessage(const S: string);
    procedure DoSearch(const Query: string; APage: Integer);
    procedure OpenRecipe(Index: Integer);
  end;

function BuildDetailText(const D: TRecipeDetail): string;
var
  I, J: Integer;
  Ing: TIngredient;
  Step: TStep;
  ServingsDisp, AmountStr: string;
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

constructor TDetailWindow.Init(const ATitle, ABody: string);
var
  R, Inner, VR, MR: TRect;
  Memo: PMemo;
  VSB: PScrollBar;
begin
  Application^.GetExtent(R);
  R.Grow(-2, -1);
  inherited Init(R, ATitle);

  GetExtent(Inner);
  Inner.Grow(-1, -1);

  VR.Assign(Inner.B.X - 1, Inner.A.Y, Inner.B.X, Inner.B.Y);
  VSB := New(PScrollBar, Init(VR));
  Insert(VSB);

  MR.Assign(Inner.A.X, Inner.A.Y, Inner.B.X - 1, Inner.B.Y);
  Memo := New(PMemo, Init(MR, nil, VSB, nil, Length(ABody) + 1));
  Memo^.IsReadOnly := True;
  Memo^.Word_Wrap := True;
  Memo^.InsertText(@ABody[1], Length(ABody), False);
  Memo^.SetCurPtr(0, 0);
  Insert(Memo);
end;

procedure TDetailWindow.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEsc) then
  begin
    ClearEvent(Event);
    Close;
    Exit;
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
      NewStatusKey('~Enter~ Search/Open', kbNoKey, cmValid,
      NewStatusKey('~N~ Next page', kbNoKey, cmValid,
      NewStatusKey('~P~ Prev page', kbNoKey, cmValid,
      NewStatusKey('~Alt-X~ Exit', kbAltX, cmQuit,
      nil)))), nil)));
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
  List: PStrCollection;
  I: Integer;
  Line: string;
begin
  try
    Res := Client.SearchRecipes(Query, APage);
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

  if Res.Count > 0 then
    SetMessage(Format('Page %d - %d recipe(s) found', [APage, Res.Count]))
  else
    SetMessage(Format('No recipes found for ''%s''.', [Query]));
end;

procedure TTiecookApp.OpenRecipe(Index: Integer);
var
  Detail: TRecipeDetail;
  Win: PDetailWindow;
begin
  if (Index < 0) or (Index > High(Results)) then
    Exit;
  try
    Detail := Client.GetRecipeDetail(Results[Index].Id);
  except
    on E: ETandoorError do
    begin
      SetMessage('Error: ' + E.Message);
      Exit;
    end;
  end;
  Win := New(PDetailWindow, Init(Detail.Name, BuildDetailText(Detail)));
  Insert(Win);
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
end;

end.
