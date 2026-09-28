unit uui;

{ The read-only terminal browser: a list screen with live search and a
  scrollable detail screen, on FPC's video/keyboard/mouse units. Keyboard
  plus mouse (click to select/open, wheel to scroll). Non-ASCII text is
  transliterated for display (see urender/uutf8); files on disk keep UTF-8. }

{$mode objfpc}{$H+}

interface

uses
  ulibrary, uconfig;

procedure RunBrowser(Lib: TLibrary; Cfg: TConfig);

implementation

uses
  video, keyboard, mouse, SysUtils, Classes, Process,
  urecipe, urender, uopen, uimp_mealmaster;

const
  { attribute = foreground or (background shl 4) }
  AttrNormal  = 7;                 { light gray on black }
  AttrDim     = 8;                 { dark gray on black }
  AttrTitle   = 15 or (1 shl 4);   { white on blue }
  AttrStatus  = 0 or (7 shl 4);    { black on light gray }
  AttrSel     = 0 or (3 shl 4);    { black on cyan (dark text -> high contrast) }
  AttrHeading = 14;                { yellow on black }

type
  TMode = (mList, mDetail);

  TBrowser = class
  private
    FLib: TLibrary;
    FCfg: TConfig;
    FQuery: string;
    FFiltered: TIntArray;
    FSel: Integer;         { selected position within FFiltered }
    FTop: Integer;         { first visible list row }
    FMode: TMode;
    FDetailIdx: Integer;   { library index of the shown recipe }
    FLines: TDisplayLines; { detail display lines }
    FDetTop: Integer;      { first visible detail line }
    FHasMouse: Boolean;
    FQuit: Boolean;
    FDirty: Boolean;
    FForce: Boolean;       { next repaint must resend the whole screen }
    function ListRows: Integer;
    function DetailRows: Integer;
    procedure Refilter(ResetSel: Boolean);
    procedure MoveSel(Delta: Integer);
    procedure CancelOrBack;
    procedure OpenDetail;
    procedure DetailScroll(Delta: Integer);
    procedure DrawList;
    procedure DrawDetail;
    procedure Draw;
    function ConfirmYN(const Msg: string): Boolean;
    function PromptText(const Prompt: string; out Value: string): Boolean;
    procedure Flash(const Msg: string);
    procedure TeardownIO;
    procedure InitIO;
    procedure EditIndex(LibIdx: Integer);
    procedure DeleteIndex(LibIdx: Integer);
    procedure ImportMMInteractive;
    procedure HandleKey(K: TKeyEvent);
    procedure HandleMouse(const M: TMouseEvent);
  public
    constructor Create(Lib: TLibrary; Cfg: TConfig);
    procedure Run;
  end;

{ --- low-level screen writing --- }

procedure PutCell(x, y: Integer; ch: Char; Attr: Byte);
begin
  if (x < 0) or (y < 0) or (x >= ScreenWidth) or (y >= ScreenHeight) then Exit;
  VideoBuf^[y * ScreenWidth + x] := Ord(ch) or (Attr shl 8);
end;

procedure PutStr(x, y: Integer; const S: string; Attr: Byte);
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    PutCell(x + i - 1, y, S[i], Attr);
end;

procedure FillRow(y: Integer; Attr: Byte);
var
  x: Integer;
begin
  for x := 0 to ScreenWidth - 1 do PutCell(x, y, ' ', Attr);
end;

procedure ClearAll(Attr: Byte);
var
  i: Integer;
begin
  for i := 0 to ScreenWidth * ScreenHeight - 1 do
    VideoBuf^[i] := Ord(' ') or (Attr shl 8);
end;

{ --- TBrowser --- }

constructor TBrowser.Create(Lib: TLibrary; Cfg: TConfig);
begin
  inherited Create;
  FLib := Lib;
  FCfg := Cfg;
  FQuery := '';
  FSel := 0;
  FTop := 0;
  FMode := mList;
  FDirty := True;
end;

function TBrowser.ListRows: Integer;
begin
  Result := ScreenHeight - 4;      { rows 3 .. H-2 }
  if Result < 1 then Result := 1;
end;

function TBrowser.DetailRows: Integer;
begin
  Result := ScreenHeight - 2;      { rows 1 .. H-2 }
  if Result < 1 then Result := 1;
end;

procedure TBrowser.Refilter(ResetSel: Boolean);
begin
  FFiltered := FLib.Search(FQuery);
  if ResetSel then begin FSel := 0; FTop := 0; end;
  if FSel > High(FFiltered) then FSel := High(FFiltered);
  if FSel < 0 then FSel := 0;
  FDirty := True;
end;

procedure TBrowser.MoveSel(Delta: Integer);
var
  vis: Integer;
begin
  if Length(FFiltered) = 0 then Exit;
  FSel := FSel + Delta;
  if FSel < 0 then FSel := 0;
  if FSel > High(FFiltered) then FSel := High(FFiltered);
  vis := ListRows;
  if FSel < FTop then FTop := FSel;
  if FSel >= FTop + vis then FTop := FSel - vis + 1;
  if FTop < 0 then FTop := 0;
  FDirty := True;
end;

procedure TBrowser.OpenDetail;
begin
  if Length(FFiltered) = 0 then Exit;
  FDetailIdx := FFiltered[FSel];
  FLines := BuildDetailLines(FLib.Recipe(FDetailIdx), ScreenWidth - 2);
  FDetTop := 0;
  FMode := mDetail;
  FDirty := True;
end;

procedure TBrowser.DetailScroll(Delta: Integer);
var
  maxTop: Integer;
begin
  maxTop := Length(FLines) - DetailRows;
  if maxTop < 0 then maxTop := 0;
  FDetTop := FDetTop + Delta;
  if FDetTop > maxTop then FDetTop := maxTop;
  if FDetTop < 0 then FDetTop := 0;
  FDirty := True;
end;

procedure TBrowser.DrawList;
var
  i, y, idx, vis: Integer;
  attr: Byte;
  marker, title: string;
begin
  ClearAll(AttrNormal);

  { title bar }
  FillRow(0, AttrTitle);
  title := FCfg.SiteTitle;
  if Trim(title) = '' then title := 'Recipe Library';
  PutStr(1, 0, 'tiecook2  -  ' + Disp(title), AttrTitle);

  { search line + caret }
  PutStr(0, 1, 'Search: ' + Disp(FQuery), AttrNormal);
  PutCell(8 + Length(Disp(FQuery)), 1, '_', AttrNormal);

  { separator }
  PutStr(0, 2, StringOfChar('-', ScreenWidth), AttrDim);

  { list }
  vis := ListRows;
  for i := 0 to vis - 1 do
  begin
    idx := FTop + i;
    if idx > High(FFiltered) then Break;
    y := 3 + i;
    if idx = FSel then attr := AttrSel else attr := AttrNormal;
    FillRow(y, attr);
    if idx = FSel then marker := '> ' else marker := '  ';
    PutStr(0, y, marker + ListLabel(FLib.Recipe(FFiltered[idx]), ScreenWidth - 2), attr);
  end;

  { status bar }
  FillRow(ScreenHeight - 1, AttrStatus);
  PutStr(0, ScreenHeight - 1,
    Format(' %d/%d  Enter open  F4 edit  F5 import  F8 del  type=search  F10 quit',
           [Length(FFiltered), FLib.Count]), AttrStatus);
end;

procedure TBrowser.DrawDetail;
var
  i, y, li: Integer;
  attr: Byte;
  line, status: string;
begin
  ClearAll(AttrNormal);

  FillRow(0, AttrTitle);
  PutStr(1, 0, Disp(FLib.Recipe(FDetailIdx).Title), AttrTitle);

  for i := 0 to DetailRows - 1 do
  begin
    li := FDetTop + i;
    if li > High(FLines) then Break;
    y := 1 + i;
    line := FLines[li];
    if (line = 'Ingredients') or (line = 'Steps') then attr := AttrHeading
    else attr := AttrNormal;
    PutStr(1, y, line, attr);
  end;

  FillRow(ScreenHeight - 1, AttrStatus);
  status := ' scroll  e edit  d delete';
  if FLib.Recipe(FDetailIdx).SourceUrl <> '' then status := status + '  o source';
  if FLib.ImageBasename(FDetailIdx) <> '' then status := status + '  i image';
  status := status + '  Bksp back  q quit';
  PutStr(0, ScreenHeight - 1, status, AttrStatus);
end;

procedure TBrowser.Draw;
begin
  if FMode = mList then DrawList else DrawDetail;
  UpdateScreen(FForce);
  FForce := False;
  FDirty := False;
end;

function TBrowser.ConfirmYN(const Msg: string): Boolean;
var
  K: TKeyEvent;
  ch: Char;
begin
  FillRow(ScreenHeight - 1, AttrSel);
  PutStr(1, ScreenHeight - 1, Msg + '    y = yes, any other key = no', AttrSel);
  UpdateScreen(True);
  K := TranslateKeyEvent(GetKeyEvent);   { translate so the char is populated }
  ch := GetKeyEventChar(K);
  Result := (ch = 'y') or (ch = 'Y');
  FForce := True;
  FDirty := True;
end;

{ Open the recipe file in the external editor. Tears the console down so the
  editor owns it, waits, then re-initialises and reloads the recipe. }
procedure TBrowser.EditIndex(LibIdx: Integer);
var
  P: TProcess;
  parts: TStringList;
  fn: string;
  i: Integer;
begin
  if (LibIdx < 0) or (LibIdx >= FLib.Count) then Exit;
  fn := FLib.FilePath(LibIdx);
  TeardownIO;
  try
    P := TProcess.Create(nil);
    parts := TStringList.Create;
    try
      parts.Delimiter := ' ';
      parts.StrictDelimiter := True;
      parts.DelimitedText := FCfg.EditorCommand;
      if parts.Count = 0 then parts.Add(FCfg.EditorCommand);
      P.Executable := parts[0];
      for i := 1 to parts.Count - 1 do
        if parts[i] <> '' then P.Parameters.Add(parts[i]);
      P.Parameters.Add(fn);
      P.Options := [poWaitOnExit];   { inherit the terminal; block until done }
      P.Execute;
    finally
      parts.Free;
      P.Free;
    end;
  except
    on E: Exception do ;             { editor missing/unlaunchable: carry on }
  end;
  InitIO;
  FLib.ReloadAt(LibIdx);
  Refilter(False);
  if FMode = mDetail then
  begin
    FDetailIdx := LibIdx;
    FLines := BuildDetailLines(FLib.Recipe(LibIdx), ScreenWidth - 2);
    if FDetTop > High(FLines) then FDetTop := 0;
  end;
  FForce := True;
  FDirty := True;
end;

procedure TBrowser.DeleteIndex(LibIdx: Integer);
begin
  if (LibIdx < 0) or (LibIdx >= FLib.Count) then Exit;
  if not ConfirmYN('Delete "' + Disp(FLib.Recipe(LibIdx).Title) + '"?') then Exit;
  FLib.DeleteAt(LibIdx);
  FMode := mList;
  Refilter(False);
  if FSel > High(FFiltered) then FSel := High(FFiltered);
  if FSel < 0 then FSel := 0;
  FForce := True;
  FDirty := True;
end;

{ A one-line text input on the status row. Enter confirms (empty = cancel),
  Backspace edits, Esc cancels (when it arrives). Returns whether confirmed. }
function TBrowser.PromptText(const Prompt: string; out Value: string): Boolean;
var
  K: TKeyEvent;
  kind: Byte;
  ch: Char;
  done: Boolean;
begin
  Value := '';
  Result := False;
  done := False;
  repeat
    FillRow(ScreenHeight - 1, AttrSel);
    PutStr(1, ScreenHeight - 1, Prompt + Value + '_', AttrSel);
    UpdateScreen(True);
    K := TranslateKeyEvent(GetKeyEvent);
    kind := GetKeyEventFlags(K) and $03;
    if (kind = kbFnKey) or (kind = kbPhys) then Continue;   { ignore arrows/F-keys }
    ch := GetKeyEventChar(K);
    case ch of
      #13: begin done := True; Result := Trim(Value) <> ''; end;
      #27: done := True;                                    { Esc: cancel }
      #8:  if Value <> '' then Delete(Value, Length(Value), 1);
      #32..#126: Value := Value + ch;
    end;
  until done;
  FForce := True;
  FDirty := True;
end;

{ Show a message on the status row and wait for a keypress. }
procedure TBrowser.Flash(const Msg: string);
begin
  FillRow(ScreenHeight - 1, AttrSel);
  PutStr(1, ScreenHeight - 1, Msg + '   (press a key)', AttrSel);
  UpdateScreen(True);
  TranslateKeyEvent(GetKeyEvent);
  FForce := True;
  FDirty := True;
end;

{ Prompt for a Meal-Master file/folder, import it into the live library, and
  refresh the list. }
procedure TBrowser.ImportMMInteractive;
var
  path: string;
  Files: TStringList;
  total, updated: Integer;
begin
  if not PromptText('Import Meal-Master file or folder: ', path) then Exit;
  path := Trim(path);
  { expand a leading ~/ to the home directory }
  if (Length(path) >= 2) and (path[1] = '~') and (path[2] = '/') then
    path := IncludeTrailingPathDelimiter(GetUserDir) + Copy(path, 3, Length(path));
  Files := TStringList.Create;
  try
    CollectMMFiles(path, Files);
    if Files.Count = 0 then
    begin
      Flash('No .mmf files found at: ' + path);
      Exit;
    end;
    total := ImportMealMasterFiles(Files, FLib, updated);
    Refilter(False);
    Flash(Format('Imported %d recipe(s) (%d updated)', [total, updated]));
  finally
    Files.Free;
  end;
end;

{ Go back from detail to list, or clear the search when on the list. This is
  the "cancel" action, reachable by Backspace (on an empty query) and by the
  best-effort Esc code. }
procedure TBrowser.CancelOrBack;
begin
  if FMode = mDetail then
  begin
    FMode := mList;
    FDirty := True;
  end
  else if FQuery <> '' then
  begin
    FQuery := '';
    Refilter(True);
  end;
end;

procedure TBrowser.HandleKey(K: TKeyEvent);
var
  kind: Byte;
  code: Word;
  ch: Char;
  img: string;
begin
  kind := GetKeyEventFlags(K) and $03;

  if (kind = kbFnKey) or (kind = kbPhys) then
  begin
    code := GetKeyEventCode(K);
    { F10 quits from anywhere. (Esc is unreliable via FPC's keyboard unit on
      Linux - it is the lead byte of every escape sequence - so it is handled
      only as ASCII #27 below, which is what win64 and some terminals send.) }
    if code = kbdF10 then begin FQuit := True; Exit; end;
    if FMode = mList then
      case code of
        kbdUp:    MoveSel(-1);
        kbdDown:  MoveSel(1);
        kbdPgUp:  MoveSel(-ListRows);
        kbdPgDn:  MoveSel(ListRows);
        kbdHome:  MoveSel(-Length(FFiltered));
        kbdEnd:   MoveSel(Length(FFiltered));
        kbdF4:    if Length(FFiltered) > 0 then EditIndex(FFiltered[FSel]);
        kbdF5:    ImportMMInteractive;
        kbdF8:    if Length(FFiltered) > 0 then DeleteIndex(FFiltered[FSel]);
      end
    else
      case code of
        kbdUp:    DetailScroll(-1);
        kbdDown:  DetailScroll(1);
        kbdPgUp:  DetailScroll(-DetailRows);
        kbdPgDn:  DetailScroll(DetailRows);
        kbdHome:  DetailScroll(-Length(FLines));
        kbdEnd:   DetailScroll(Length(FLines));
        kbdLeft:  CancelOrBack;
      end;
    Exit;
  end;

  ch := GetKeyEventChar(K);
  if FMode = mList then
    case ch of
      #13: OpenDetail;                                   { Enter }
      #27: CancelOrBack;                                 { Esc (when it arrives) }
      #17: FQuit := True;                                { Ctrl-Q }
      #8:  if FQuery <> '' then                          { Backspace: edit... }
           begin
             Delete(FQuery, Length(FQuery), 1);
             Refilter(True);
           end;
      #32..#126:                                         { type into search }
        begin
          FQuery := FQuery + ch;
          Refilter(True);
        end;
    end
  else
    case ch of
      #13, #8, #27: CancelOrBack;                        { Enter / Backspace / Esc: back }
      #17, 'q', 'Q': FQuit := True;                      { letters are free here }
      'e', 'E': EditIndex(FDetailIdx);
      'd', 'D': DeleteIndex(FDetailIdx);
      'o', 'O':
        if FLib.Recipe(FDetailIdx).SourceUrl <> '' then
        begin
          OpenExternal(FLib.Recipe(FDetailIdx).SourceUrl);
          FForce := True; FDirty := True;
        end;
      'i', 'I':
        begin
          img := FLib.ImageBasename(FDetailIdx);
          if img <> '' then
          begin
            OpenExternal(IncludeTrailingPathDelimiter(FLib.Dir) + img);
            FForce := True; FDirty := True;
          end;
        end;
    end;
end;

procedure TBrowser.HandleMouse(const M: TMouseEvent);
var
  idx: Integer;
begin
  if (M.Action and MouseActionDown) = 0 then Exit;

  if (M.Buttons and MouseButton4) <> 0 then          { wheel up }
  begin
    if FMode = mList then MoveSel(-3) else DetailScroll(-3);
    Exit;
  end;
  if (M.Buttons and MouseButton5) <> 0 then          { wheel down }
  begin
    if FMode = mList then MoveSel(3) else DetailScroll(3);
    Exit;
  end;

  if (M.Buttons and MouseLeftButton) <> 0 then
  begin
    if FMode = mList then
    begin
      { list rows start at screen row 3 }
      idx := FTop + (Integer(M.y) - 3);
      if (Integer(M.y) >= 3) and (idx >= 0) and (idx <= High(FFiltered)) then
      begin
        if idx = FSel then OpenDetail
        else begin FSel := idx; FDirty := True; end;
      end;
    end;
  end;
end;

procedure TBrowser.InitIO;
begin
  InitVideo;
  InitKeyboard;
  SetCursorType(crHidden);
  FHasMouse := DetectMouse > 0;
  if FHasMouse then InitMouse;
end;

procedure TBrowser.TeardownIO;
begin
  if FHasMouse then DoneMouse;
  SetCursorType(crUnderLine);
  DoneKeyboard;
  DoneVideo;
  {$ifdef unix}
  Write(#27'[0m'#27'[2J'#27'[H'#27'[?25h');
  {$endif}
end;

procedure TBrowser.Run;
var
  M: TMouseEvent;
begin
  InitIO;
  try
    Refilter(True);
    repeat
      if FDirty then Draw;
      if PollKeyEvent <> 0 then
        HandleKey(TranslateKeyEvent(GetKeyEvent))
      else if FHasMouse and PollMouseEvent(M) then
        HandleMouse(M)
      else
        Sleep(15);
    until FQuit;
  finally
    TeardownIO;
  end;
end;

procedure RunBrowser(Lib: TLibrary; Cfg: TConfig);
var
  B: TBrowser;
begin
  B := TBrowser.Create(Lib, Cfg);
  try
    B.Run;
  finally
    B.Free;
  end;
end;

end.
