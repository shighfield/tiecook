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
  TMode = (mList, mDetail, mEdit);

  { rows of the structured editor; headers are not selectable }
  TEditRowKind = (erTitle, erKeywords, erServings, erTime, erSource, erImage,
                  erDesc, erIngHdr, erIng, erIngAdd, erStepHdr, erStep, erStepAdd);
  TEditRow = record
    Kind: TEditRowKind;
    Idx: Integer;           { item index for erIng / erStep }
  end;

  { a clickable segment of the bottom status bar }
  THotZone = record
    x1, x2: Integer;        { inclusive column range on the status row }
    Tag: string;            { action id dispatched on click }
  end;

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
    FEdit: TRecipe;        { working copy in the structured editor }
    FEditIdx: Integer;     { library index being edited }
    FEditRow: Integer;     { current row in FEditRows }
    FEditTop: Integer;     { first visible editor row }
    FEditRows: array of TEditRow;
    FEditReturn: TMode;    { mode to return to on save/cancel }
    FEditImageSrc: string; { pending photo to copy in on save ('' = none) }
    FEditImageClear: Boolean; { pending photo removal on save }
    FZones: array of THotZone;  { clickable status-bar segments from last draw }
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
    procedure ShowTitle;
    function ConfirmYN(const Msg: string): Boolean;
    function PromptText(const Prompt: string; out Value: string;
      const Initial: string = ''): Boolean;
    procedure Flash(const Msg: string);
    procedure TeardownIO;
    procedure InitIO;
    procedure RunEditorFile(const FileName: string);
    procedure EditProseText(var S: string);
    procedure EnterEdit(LibIdx: Integer);
    procedure BuildEditRows;
    function EditRows: Integer;
    procedure EditMove(Delta: Integer);
    procedure DrawEdit;
    procedure HandleEditKey(K: TKeyEvent);
    procedure SaveEdit;
    procedure DeleteIndex(LibIdx: Integer);
    procedure ImportMMInteractive;
    procedure HandleKey(K: TKeyEvent);
    procedure HandleMouse(const M: TMouseEvent);
    procedure ClearZones;
    procedure StatusSeg(var x: Integer; const Txt, Tag: string);
    function ZoneAt(x: Integer): string;
    procedure ClickAction(const Tag: string);
    procedure ActivateEditRow;
    procedure AddEditItem;
    procedure DeleteEditItem;
    procedure ReplaceStepWithProse(Idx: Integer; const S: string);
    procedure InsertStepsAfter(Idx: Integer; const S: string);
    procedure SetEditImage;
    procedure SetDetailImage;
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

procedure PutCentered(y: Integer; const S: string; Attr: Byte);
var
  x: Integer;
begin
  x := (ScreenWidth - Length(S)) div 2;
  if x < 0 then x := 0;
  PutStr(x, y, S, Attr);
end;

{ Expand a leading ~ to the user's home directory. }
function ExpandTilde(const P: string): string;
begin
  Result := P;
  if (Length(P) >= 1) and (P[1] = '~') then
  begin
    if Length(P) = 1 then
      Result := ExcludeTrailingPathDelimiter(GetUserDir)
    else if (P[2] = '/') or (P[2] = PathDelim) then
      Result := IncludeTrailingPathDelimiter(GetUserDir) + Copy(P, 3, Length(P));
  end;
end;

{ True for an image extension the library serves (leading dot, any case). }
function ImgExtOk(const Ext: string): Boolean;
var
  e: string;
begin
  e := LowerCase(Ext);
  Result := (e = '.jpg') or (e = '.jpeg') or (e = '.png') or (e = '.webp');
end;

{ Copy a file's bytes to Dest (overwriting). Returns False on any error. }
function CopyFileTo(const Src, Dest: string): Boolean;
var
  fs, fd: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      fd := TFileStream.Create(Dest, fmCreate);
      try
        if fs.Size > 0 then fd.CopyFrom(fs, fs.Size);
      finally
        fd.Free;
      end;
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do Result := False;
  end;
end;

{ Split edited prose into paragraphs: a blank line starts a new paragraph, and
  the wrapped lines within a paragraph are rejoined with spaces. Used so that a
  blank line in the step editor makes a new, separate step. }
procedure SplitProseParagraphs(const S: string; Dest: TStrings);
var
  lines: TStringList;
  i: Integer;
  para: string;
begin
  Dest.Clear;
  lines := TStringList.Create;
  try
    lines.TextLineBreakStyle := tlbsLF;
    lines.Text := StringReplace(StringReplace(S, #13#10, #10, [rfReplaceAll]),
                                #13, #10, [rfReplaceAll]);
    para := '';
    for i := 0 to lines.Count - 1 do
      if Trim(lines[i]) = '' then
      begin
        if para <> '' then begin Dest.Add(para); para := ''; end;
      end
      else if para = '' then para := Trim(lines[i])
      else para := para + ' ' + Trim(lines[i]);
    if para <> '' then Dest.Add(para);
  finally
    lines.Free;
  end;
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

procedure TBrowser.ClearZones;
begin
  SetLength(FZones, 0);
end;

{ Write one status-bar segment at column x (advancing x past it) and, when Tag
  is set, record its column range so a click there triggers that action. }
procedure TBrowser.StatusSeg(var x: Integer; const Txt, Tag: string);
begin
  PutStr(x, ScreenHeight - 1, Txt, AttrStatus);
  if Tag <> '' then
  begin
    SetLength(FZones, Length(FZones) + 1);
    FZones[High(FZones)].x1 := x;
    FZones[High(FZones)].x2 := x + Length(Txt) - 1;
    FZones[High(FZones)].Tag := Tag;
  end;
  Inc(x, Length(Txt));
end;

{ The action tag for a status-bar column, or '' if none. }
function TBrowser.ZoneAt(x: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FZones) do
    if (x >= FZones[i].x1) and (x <= FZones[i].x2) then Exit(FZones[i].Tag);
end;

procedure TBrowser.DrawList;
var
  i, y, idx, vis, sx: Integer;
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

  { status bar (clickable segments) }
  FillRow(ScreenHeight - 1, AttrStatus);
  sx := 0;
  StatusSeg(sx, Format(' %d/%d ', [Length(FFiltered), FLib.Count]), '');
  StatusSeg(sx, ' Enter open ', 'open');
  StatusSeg(sx, ' F4 edit ', 'edit');
  StatusSeg(sx, ' F5 import ', 'import');
  StatusSeg(sx, ' F8 del ', 'del');
  StatusSeg(sx, ' type=search ', '');
  StatusSeg(sx, ' F10 quit', 'quit');
end;

procedure TBrowser.DrawDetail;
var
  i, y, li, sx: Integer;
  attr: Byte;
  line: string;
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
  sx := 0;
  StatusSeg(sx, ' scroll ', '');
  StatusSeg(sx, ' e edit ', 'edit');
  StatusSeg(sx, ' d delete ', 'del');
  if FLib.Recipe(FDetailIdx).SourceUrl <> '' then StatusSeg(sx, ' o source ', 'source');
  if FLib.ImageBasename(FDetailIdx) <> '' then StatusSeg(sx, ' i image ', 'image');
  StatusSeg(sx, ' p photo ', 'photo');
  StatusSeg(sx, ' q back ', 'back');
  StatusSeg(sx, ' F10 quit', 'quit');
end;

procedure TBrowser.Draw;
begin
  ClearZones;                 { rebuilt by whichever status bar we draw }
  case FMode of
    mList:   DrawList;
    mDetail: DrawDetail;
    mEdit:   DrawEdit;
  end;
  UpdateScreen(FForce);
  FForce := False;
  FDirty := False;
end;

{ The startup splash: an ASCII-art banner (figlet "standard" font), the site
  title, a tagline, the recipe count and a prompt. Any key or mouse click
  dismisses it. }
procedure TBrowser.ShowTitle;
const
  AttrBanner = 11;   { light cyan on black }
  BannerW = 39;
  Banner: array[0..4] of string = (
    ' _   _                      _    ____',
    '| |_(_) ___  ___ ___   ___ | | _|___ \',
    '| __| |/ _ \/ __/ _ \ / _ \| |/ / __) |',
    '| |_| |  __/ (_| (_) | (_) |   < / __/',
    ' \__|_|\___|\___\___/ \___/|_|\_\_____|');
var
  top, x, i, cy: Integer;
  sub: string;
  M: TMouseEvent;
begin
  ClearAll(AttrNormal);
  top := (ScreenHeight - 12) div 2;
  if top < 0 then top := 0;
  x := (ScreenWidth - BannerW) div 2;
  if x < 0 then x := 0;
  for i := 0 to High(Banner) do
    PutStr(x, top + i, Banner[i], AttrBanner);

  cy := top + 6;
  sub := Trim(FCfg.SiteTitle);
  if sub = '' then sub := 'Recipe Library';
  PutCentered(cy, Disp(sub), 15);                          { site title, bright white }
  PutCentered(cy + 1, 'your recipe library', AttrNormal);
  PutCentered(cy + 3, IntToStr(FLib.Count) + ' recipes', AttrNormal);
  PutCentered(cy + 5, 'press any key or click to begin', AttrHeading);

  UpdateScreen(True);
  { A terminal often emits escape sequences on startup (focus/query replies),
    and the keypress that launched us can be buffered; either would be read
    immediately and skip the splash. Let them arrive, discard everything
    pending, then wait for a genuine keypress or mouse click. }
  Sleep(120);
  while PollKeyEvent <> 0 do GetKeyEvent;
  if FHasMouse then
    while PollMouseEvent(M) do GetMouseEvent(M);
  repeat
    if PollKeyEvent <> 0 then begin GetKeyEvent; Break; end;
    if FHasMouse and PollMouseEvent(M) then
    begin
      GetMouseEvent(M);
      if (M.Action and MouseActionDown) <> 0 then Break;   { click or wheel }
    end;
    Sleep(20);
  until False;
  FForce := True;
  FDirty := True;
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
{ Join keywords for display. }
function KwJoin(const R: TRecipe): string;
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

{ First line of a possibly multi-paragraph value, with an ellipsis if more. }
function FirstLine(const S: string): string;
var
  p: Integer;
begin
  Result := S;
  p := Pos(#10, Result);
  if p > 0 then Result := Copy(Result, 1, p - 1) + ' ...';
end;

{ Run the configured editor on a file, tearing down the console first. }
procedure TBrowser.RunEditorFile(const FileName: string);
var
  P: TProcess;
  parts: TStringList;
  i: Integer;
begin
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
      P.Parameters.Add(FileName);
      P.Options := [poWaitOnExit];
      P.Execute;
    finally
      parts.Free;
      P.Free;
    end;
  except
    on E: Exception do ;             { editor missing/unlaunchable: carry on }
  end;
  InitIO;
  FForce := True;
  FDirty := True;
end;

{ Edit a piece of prose (a step, the description) in the external editor. }
procedure TBrowser.EditProseText(var S: string);
var
  fn: string;
  SL: TStringList;
begin
  fn := GetTempFileName('', 'tc2ed');
  SL := TStringList.Create;
  try
    SL.TextLineBreakStyle := tlbsLF;
    SL.Text := S;
    SL.SaveToFile(fn);
    RunEditorFile(fn);
    SL.LoadFromFile(fn);
    S := SL.Text;
    while (S <> '') and ((S[Length(S)] = #10) or (S[Length(S)] = #13)) do
      Delete(S, Length(S), 1);
  finally
    SL.Free;
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

procedure TBrowser.BuildEditRows;
var
  i: Integer;

  procedure Row(K: TEditRowKind; Ix: Integer);
  begin
    SetLength(FEditRows, Length(FEditRows) + 1);
    FEditRows[High(FEditRows)].Kind := K;
    FEditRows[High(FEditRows)].Idx := Ix;
  end;

begin
  SetLength(FEditRows, 0);
  Row(erTitle, 0); Row(erKeywords, 0); Row(erServings, 0);
  Row(erTime, 0); Row(erSource, 0); Row(erImage, 0); Row(erDesc, 0);
  Row(erIngHdr, 0);
  for i := 0 to High(FEdit.Ingredients) do Row(erIng, i);
  Row(erIngAdd, 0);
  Row(erStepHdr, 0);
  for i := 0 to High(FEdit.Steps) do Row(erStep, i);
  Row(erStepAdd, 0);
  if FEditRow > High(FEditRows) then FEditRow := High(FEditRows);
end;

function TBrowser.EditRows: Integer;
begin
  Result := ScreenHeight - 2;     { rows 1 .. H-2 }
  if Result < 1 then Result := 1;
end;

procedure TBrowser.EnterEdit(LibIdx: Integer);
begin
  if (LibIdx < 0) or (LibIdx >= FLib.Count) then Exit;
  FEditReturn := FMode;
  FEditIdx := LibIdx;
  FEdit := CopyRecipe(FLib.Recipe(LibIdx));
  FEditImageSrc := '';
  FEditImageClear := False;
  FEditRow := 0;
  FEditTop := 0;
  BuildEditRows;
  FMode := mEdit;
  FForce := True;
  FDirty := True;
end;

{ Move the cursor to the next/prev selectable row (skipping section headers). }
procedure TBrowser.EditMove(Delta: Integer);
var
  r, vis: Integer;
begin
  if Length(FEditRows) = 0 then Exit;
  r := FEditRow;
  repeat
    r := r + Delta;
    if r < 0 then r := 0;
    if r > High(FEditRows) then r := High(FEditRows);
    if (r = FEditRow) then Break;                { hit an end }
    if not (FEditRows[r].Kind in [erIngHdr, erStepHdr]) then Break;
  until False;
  FEditRow := r;
  vis := EditRows;
  if FEditRow < FEditTop then FEditTop := FEditRow;
  if FEditRow >= FEditTop + vis then FEditTop := FEditRow - vis + 1;
  if FEditTop < 0 then FEditTop := 0;
  FDirty := True;
end;

procedure TBrowser.DrawEdit;
var
  i, y, ri, sx: Integer;
  attr: Byte;
  s, val: string;
  row: TEditRow;
begin
  ClearAll(AttrNormal);
  FillRow(0, AttrTitle);
  PutStr(1, 0, 'Edit:  ' + Disp(FEdit.Title), AttrTitle);

  for i := 0 to EditRows - 1 do
  begin
    ri := FEditTop + i;
    if ri > High(FEditRows) then Break;
    y := 1 + i;
    row := FEditRows[ri];
    case row.Kind of
      erTitle:     s := 'Title       ' + Disp(FEdit.Title);
      erKeywords:  s := 'Keywords    ' + Disp(KwJoin(FEdit));
      erServings:  s := 'Servings    ' + Disp(FEdit.Servings);
      erTime:      s := 'Time        ' + Disp(FEdit.Time);
      erSource:    s := 'Source      ' + Disp(FEdit.SourceUrl);
      erImage:     begin
                     val := FEdit.Image;
                     if Trim(val) = '' then val := '(none)';
                     s := 'Image       ' + Disp(val);
                   end;
      erDesc:      begin
                     val := FirstLine(FEdit.Description);
                     if Trim(val) = '' then val := '(none)';
                     s := 'Description  ' + Disp(val);
                   end;
      erIngHdr:    s := '-- Ingredients --';
      erIng:       if FEdit.Ingredients[row.Idx].IsSection then
                     s := '  ## ' + Disp(FEdit.Ingredients[row.Idx].Text)
                   else
                     s := '  ' + Disp(FEdit.Ingredients[row.Idx].Text);
      erIngAdd:    s := '  + add ingredient';
      erStepHdr:   s := '-- Steps --';
      erStep:      s := '  ' + IntToStr(row.Idx + 1) + '. ' +
                        Disp(FirstLine(FEdit.Steps[row.Idx]));
      erStepAdd:   s := '  + add step';
    else
      s := '';
    end;

    if ri = FEditRow then
    begin
      attr := AttrSel;
      FillRow(y, attr);
    end
    else if row.Kind in [erIngHdr, erStepHdr] then
      attr := AttrHeading
    else
      attr := AttrNormal;
    PutStr(0, y, s, attr);
  end;

  FillRow(ScreenHeight - 1, AttrStatus);
  sx := 0;
  StatusSeg(sx, ' Enter edit ', 'activate');
  StatusSeg(sx, ' a add ', 'eadd');
  StatusSeg(sx, ' d del ', 'edel');
  StatusSeg(sx, ' [ ] move ', '');
  StatusSeg(sx, ' F2 save ', 'save');
  StatusSeg(sx, ' F10 cancel', 'cancel');
end;

procedure TBrowser.SaveEdit;
var
  libd, oldImg: string;
begin
  if Trim(FEdit.Title) = '' then
  begin
    Flash('Title cannot be empty - not saved');
    Exit;
  end;
  libd := IncludeTrailingPathDelimiter(FLib.Dir);
  oldImg := FLib.ImageBasename(FEditIdx);   { current photo, before we overwrite }

  { apply a pending photo change to disk (editor works on a copy, so this is
    deferred to save; cancel never reaches here) }
  if FEditImageSrc <> '' then
  begin
    if CopyFileTo(FEditImageSrc, libd + FEdit.Image) then
    begin
      if (oldImg <> '') and (oldImg <> FEdit.Image) and FileExists(libd + oldImg) then
        DeleteFile(libd + oldImg);          { drop a differently-named old photo }
    end
    else
    begin
      Flash('Could not copy image - saving recipe without it');
      FEdit.Image := oldImg;                { keep the previous photo reference }
    end;
  end
  else if FEditImageClear then
  begin
    if (oldImg <> '') and FileExists(libd + oldImg) then DeleteFile(libd + oldImg);
  end;

  SaveRecipe(FEdit, FLib.FilePath(FEditIdx));
  FLib.ReloadAt(FEditIdx);          { canonical, reflowed copy back into the lib }
  Refilter(False);
  FMode := FEditReturn;
  if FMode = mDetail then
  begin
    FDetailIdx := FEditIdx;
    FLines := BuildDetailLines(FLib.Recipe(FEditIdx), ScreenWidth - 2);
    FDetTop := 0;
  end;
  FForce := True;
  FDirty := True;
end;

{ Edit/open the current editor row (the Enter action), shared by keyboard and
  mouse. }
procedure TBrowser.ActivateEditRow;
var
  row: TEditRow;
  v, s: string;
begin
  if Length(FEditRows) = 0 then Exit;
  row := FEditRows[FEditRow];
  case row.Kind of
    erTitle:     if PromptText('Title: ', v, FEdit.Title) then FEdit.Title := v;
    erKeywords:  if PromptText('Keywords (comma separated): ', v, KwJoin(FEdit)) then SetKeywords(FEdit, v);
    erServings:  if PromptText('Servings: ', v, FEdit.Servings) then FEdit.Servings := v;
    erTime:      if PromptText('Time: ', v, FEdit.Time) then FEdit.Time := v;
    erSource:    if PromptText('Source URL: ', v, FEdit.SourceUrl) then FEdit.SourceUrl := v;
    erImage:     SetEditImage;
    erDesc:      begin s := FEdit.Description; EditProseText(s); FEdit.Description := s; end;
    erIng:       if PromptText('Ingredient: ', v, FEdit.Ingredients[row.Idx].Text) then
                   FEdit.Ingredients[row.Idx].Text := v;
    erIngAdd:    if PromptText('New ingredient: ', v) and (Trim(v) <> '') then
                 begin InsertIngredient(FEdit, Length(FEdit.Ingredients), v); BuildEditRows; end;
    erStep:      begin s := FEdit.Steps[row.Idx]; EditProseText(s);
                   if Trim(s) <> '' then ReplaceStepWithProse(row.Idx, s); end;
    erStepAdd:   begin s := ''; EditProseText(s);
                   if Trim(s) <> '' then InsertStepsAfter(High(FEdit.Steps), s); end;
  end;
end;

{ Insert a new item after the current ingredient/step (the 'a' action). }
procedure TBrowser.AddEditItem;
var
  row: TEditRow;
  v, s: string;
begin
  if Length(FEditRows) = 0 then Exit;
  row := FEditRows[FEditRow];
  if row.Kind = erIng then
  begin
    if PromptText('New ingredient: ', v) and (Trim(v) <> '') then
    begin InsertIngredient(FEdit, row.Idx + 1, v); BuildEditRows; EditMove(1); end;
  end
  else if row.Kind = erStep then
  begin
    s := ''; EditProseText(s);
    if Trim(s) <> '' then begin InsertStepsAfter(row.Idx, s); EditMove(1); end;
  end;
end;

{ Delete the current ingredient/step (the 'd' action). }
procedure TBrowser.DeleteEditItem;
var
  row: TEditRow;
begin
  if Length(FEditRows) = 0 then Exit;
  row := FEditRows[FEditRow];
  if row.Kind = erIng then begin DeleteIngredient(FEdit, row.Idx); BuildEditRows; end
  else if row.Kind = erStep then begin DeleteStep(FEdit, row.Idx); BuildEditRows; end;
end;

{ Replace the step at Idx with the edited prose, splitting it into one step per
  blank-line-separated paragraph (so a blank line makes a new numbered step). }
procedure TBrowser.ReplaceStepWithProse(Idx: Integer; const S: string);
var
  parts: TStringList;
  i: Integer;
begin
  parts := TStringList.Create;
  try
    SplitProseParagraphs(S, parts);
    if parts.Count = 0 then Exit;
    FEdit.Steps[Idx] := parts[0];
    for i := 1 to parts.Count - 1 do
      InsertStep(FEdit, Idx + i, parts[i]);
    BuildEditRows;
  finally
    parts.Free;
  end;
end;

{ Insert the edited prose as one or more steps after Idx (one per paragraph). }
procedure TBrowser.InsertStepsAfter(Idx: Integer; const S: string);
var
  parts: TStringList;
  i: Integer;
begin
  parts := TStringList.Create;
  try
    SplitProseParagraphs(S, parts);
    for i := 0 to parts.Count - 1 do
      InsertStep(FEdit, Idx + 1 + i, parts[i]);
    BuildEditRows;
  finally
    parts.Free;
  end;
end;

{ Editor "Image" row: prompt for a photo to attach (blank removes the current
  one). The file is only copied/removed on save, so a cancel is undoable. The
  destination name is the recipe's slug plus the source extension. }
procedure TBrowser.SetEditImage;
var
  p, ext, destName: string;
begin
  if not PromptText('Image file path (blank to remove): ', p, '') then Exit;  { cancelled }
  p := Trim(p);
  if p = '' then
  begin
    FEdit.Image := '';
    FEditImageSrc := '';
    FEditImageClear := True;
    Exit;
  end;
  p := ExpandTilde(p);
  if not FileExists(p) then begin Flash('No such file: ' + p); Exit; end;
  ext := ExtractFileExt(p);
  if not ImgExtOk(ext) then begin Flash('Image must be .jpg, .jpeg, .png or .webp'); Exit; end;
  destName := ChangeFileExt(ExtractFileName(FLib.FilePath(FEditIdx)), LowerCase(ext));
  FEditImageSrc := p;
  FEditImageClear := False;
  FEdit.Image := destName;     { tentative; copied in on save }
end;

{ Recipe-view 'p' action: attach or replace a photo immediately (blank removes
  it). Unlike the editor this writes straight through, since there is no
  save/cancel step in the detail view. }
procedure TBrowser.SetDetailImage;
var
  R: TRecipe;
  p, ext, libd, destName, oldImg: string;
begin
  if not PromptText('Image file path (blank to remove): ', p, '') then Exit;
  p := Trim(p);
  libd := IncludeTrailingPathDelimiter(FLib.Dir);
  oldImg := FLib.ImageBasename(FDetailIdx);
  R := CopyRecipe(FLib.Recipe(FDetailIdx));
  if p = '' then
  begin
    if oldImg = '' then begin Flash('No photo to remove'); Exit; end;
    if FileExists(libd + oldImg) then DeleteFile(libd + oldImg);
    R.Image := '';
    SaveRecipe(R, FLib.FilePath(FDetailIdx));
    FLib.ReloadAt(FDetailIdx);
    Flash('Photo removed');
  end
  else
  begin
    p := ExpandTilde(p);
    if not FileExists(p) then begin Flash('No such file: ' + p); Exit; end;
    ext := ExtractFileExt(p);
    if not ImgExtOk(ext) then begin Flash('Image must be .jpg, .jpeg, .png or .webp'); Exit; end;
    destName := ChangeFileExt(ExtractFileName(FLib.FilePath(FDetailIdx)), LowerCase(ext));
    if not CopyFileTo(p, libd + destName) then begin Flash('Could not copy image'); Exit; end;
    if (oldImg <> '') and (oldImg <> destName) and FileExists(libd + oldImg) then
      DeleteFile(libd + oldImg);
    R.Image := destName;
    SaveRecipe(R, FLib.FilePath(FDetailIdx));
    FLib.ReloadAt(FDetailIdx);
    Flash('Photo set: ' + destName);
  end;
  FLines := BuildDetailLines(FLib.Recipe(FDetailIdx), ScreenWidth - 2);
  FForce := True;
  FDirty := True;
end;

procedure TBrowser.HandleEditKey(K: TKeyEvent);
var
  kind: Byte;
  code: Word;
  ch: Char;
  row: TEditRow;
begin
  kind := GetKeyEventFlags(K) and $03;
  if (kind = kbFnKey) or (kind = kbPhys) then
  begin
    code := GetKeyEventCode(K);
    case code of
      kbdUp:   EditMove(-1);
      kbdDown: EditMove(1);
      kbdPgUp: EditMove(-EditRows);
      kbdPgDn: EditMove(EditRows);
      kbdHome: EditMove(-Length(FEditRows));
      kbdEnd:  EditMove(Length(FEditRows));
      kbdF2:   SaveEdit;
      kbdF10:  begin FMode := FEditReturn; FForce := True; FDirty := True; end;
    end;
    Exit;
  end;

  ch := GetKeyEventChar(K);
  if ch = #27 then                    { Esc: cancel (best-effort) }
  begin
    FMode := FEditReturn; FForce := True; FDirty := True; Exit;
  end;
  if Length(FEditRows) = 0 then Exit;
  row := FEditRows[FEditRow];

  case ch of
    #13:      ActivateEditRow;        { Enter: edit/add current row }
    'a', 'A': AddEditItem;            { insert a new item after the current one }
    'd', 'D': DeleteEditItem;         { delete the current item }
    '[':                              { move item up }
      if (row.Kind = erIng) and (row.Idx > 0) then
      begin MoveIngredient(FEdit, row.Idx, -1); BuildEditRows; EditMove(-1); end
      else if (row.Kind = erStep) and (row.Idx > 0) then
      begin MoveStep(FEdit, row.Idx, -1); BuildEditRows; EditMove(-1); end;
    ']':                              { move item down }
      if (row.Kind = erIng) and (row.Idx < High(FEdit.Ingredients)) then
      begin MoveIngredient(FEdit, row.Idx, 1); BuildEditRows; EditMove(1); end
      else if (row.Kind = erStep) and (row.Idx < High(FEdit.Steps)) then
      begin MoveStep(FEdit, row.Idx, 1); BuildEditRows; EditMove(1); end;
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
function TBrowser.PromptText(const Prompt: string; out Value: string;
  const Initial: string): Boolean;
var
  K: TKeyEvent;
  kind: Byte;
  ch: Char;
  done: Boolean;
begin
  Value := Initial;
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

{ Go back from detail to list, or clear the search when on the list. From the
  detail view this is reached by q, Enter, or the best-effort Esc; on the list
  (where typing edits the search) it is reached by Esc. }
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
  if FMode = mEdit then
  begin
    HandleEditKey(K);
    Exit;
  end;

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
        kbdF4:    if Length(FFiltered) > 0 then EnterEdit(FFiltered[FSel]);
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
      #13, #27, 'q', 'Q': CancelOrBack;                  { Enter / Esc / q: back to list }
      #17: FQuit := True;                                { Ctrl-Q quits (F10 quits anywhere) }
      'e', 'E': EnterEdit(FDetailIdx);
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
      'p', 'P': SetDetailImage;
    end;
end;

{ Run the action for a clicked status-bar label. Tags are drawn per mode, so
  the shared ones (edit/del/quit) act on whatever the current mode shows. }
procedure TBrowser.ClickAction(const Tag: string);
var
  img: string;
begin
  if Tag = 'open' then OpenDetail
  else if Tag = 'edit' then
  begin
    if FMode = mList then
    begin if Length(FFiltered) > 0 then EnterEdit(FFiltered[FSel]); end
    else EnterEdit(FDetailIdx);
  end
  else if Tag = 'del' then
  begin
    if FMode = mList then
    begin if Length(FFiltered) > 0 then DeleteIndex(FFiltered[FSel]); end
    else DeleteIndex(FDetailIdx);
  end
  else if Tag = 'import' then ImportMMInteractive
  else if Tag = 'source' then
  begin
    if FLib.Recipe(FDetailIdx).SourceUrl <> '' then
    begin OpenExternal(FLib.Recipe(FDetailIdx).SourceUrl); FForce := True; FDirty := True; end;
  end
  else if Tag = 'image' then
  begin
    img := FLib.ImageBasename(FDetailIdx);
    if img <> '' then
    begin OpenExternal(IncludeTrailingPathDelimiter(FLib.Dir) + img); FForce := True; FDirty := True; end;
  end
  else if Tag = 'back' then CancelOrBack
  else if Tag = 'photo' then SetDetailImage
  else if Tag = 'quit' then FQuit := True
  else if Tag = 'activate' then begin ActivateEditRow; FForce := True; FDirty := True; end
  else if Tag = 'eadd' then begin AddEditItem; FForce := True; FDirty := True; end
  else if Tag = 'edel' then begin DeleteEditItem; FForce := True; FDirty := True; end
  else if Tag = 'save' then SaveEdit
  else if Tag = 'cancel' then begin FMode := FEditReturn; FForce := True; FDirty := True; end;
end;

procedure TBrowser.HandleMouse(const M: TMouseEvent);
var
  idx, y, ri: Integer;
  tag: string;
begin
  if (M.Action and MouseActionDown) = 0 then Exit;

  { wheel: scroll the list / detail text / editor rows }
  if (M.Buttons and MouseButton4) <> 0 then          { wheel up }
  begin
    case FMode of
      mList:   MoveSel(-3);
      mDetail: DetailScroll(-3);
      mEdit:   EditMove(-3);
    end;
    Exit;
  end;
  if (M.Buttons and MouseButton5) <> 0 then          { wheel down }
  begin
    case FMode of
      mList:   MoveSel(3);
      mDetail: DetailScroll(3);
      mEdit:   EditMove(3);
    end;
    Exit;
  end;

  if (M.Buttons and MouseLeftButton) = 0 then Exit;
  y := Integer(M.y);

  { a click on the bottom status bar triggers that label's action }
  if y = ScreenHeight - 1 then
  begin
    tag := ZoneAt(Integer(M.x));
    if tag <> '' then ClickAction(tag);
    Exit;
  end;

  case FMode of
    mList:
      begin
        { list rows start at screen row 3 }
        idx := FTop + (y - 3);
        if (y >= 3) and (idx >= 0) and (idx <= High(FFiltered)) then
        begin
          if idx = FSel then OpenDetail
          else begin FSel := idx; FDirty := True; end;
        end;
      end;
    mEdit:
      begin
        { editor rows start at screen row 1 }
        if (y >= 1) and (y <= EditRows) then
        begin
          ri := FEditTop + (y - 1);
          if (ri >= 0) and (ri <= High(FEditRows)) then
          begin
            if ri = FEditRow then begin ActivateEditRow; FForce := True; FDirty := True; end
            else begin FEditRow := ri; FDirty := True; end;
          end;
        end;
      end;
    mDetail: ;   { clicks in the body do nothing; status bar handled above }
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
    if FCfg.Splash then ShowTitle;
    repeat
      if FDirty then Draw;
      if PollKeyEvent <> 0 then
        HandleKey(TranslateKeyEvent(GetKeyEvent))
      else if FHasMouse and PollMouseEvent(M) then
      begin
        GetMouseEvent(M);   { PollMouseEvent only peeks; dequeue it or the }
        HandleMouse(M);     { queue head (a move event) blocks all clicks }
      end
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
