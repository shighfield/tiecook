unit uexport_html;

{ Generate a self-contained static recipe website from the library.

  Output (all relative-linked, works from file:// or any static host):
    <out>/index.html      landing page: JS live search, personal section,
                          alphabetical buckets, favorites highlighted
    <out>/<slug>.htm      one page per recipe (photo, ingredients, steps,
                          source link, print button)
    <out>/style.css       shared stylesheet
    <out>/images/...      copied recipe photos + header/background
    <out>/.tiecook2-site  marker proving we own this directory

  Look and structure mirror the user's old ~/html site, but the site title,
  intro, footer, images and the personal/favorite keywords all come from
  config, so anyone can publish their own. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, urecipe, uconfig, ulibrary;

{ Raised when the target exists, is non-empty, and was not made by us. }
type
  EExportUnsafe = class(Exception);

{ Write the site into OutDir. Returns the number of recipe pages written.
  Raises EExportUnsafe rather than overwriting a directory we don't own. }
function ExportHtml(Lib: TLibrary; Cfg: TConfig; const OutDir: string): Integer;

implementation

uses
  Classes;

const
  Marker = '.tiecook2-site';

{ --- helpers --- }

function EscapeHtml(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ Escaped text with paragraph/line breaks turned into HTML. }
function EscapeMultiline(const S: string): string;
begin
  Result := EscapeHtml(S);
  Result := StringReplace(Result, #10#10, '</p><p>', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '<br>', [rfReplaceAll]);
end;

procedure WriteTextFile(const FileName, Content: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.TextLineBreakStyle := tlbsLF;
    SL.Text := Content;
    SL.SaveToFile(FileName);
  finally
    SL.Free;
  end;
end;

procedure CopyBinary(const Src, Dst: string);
var
  ms: TMemoryStream;
begin
  if not FileExists(Src) then Exit;
  ms := TMemoryStream.Create;
  try
    ms.LoadFromFile(Src);
    ForceDirectories(ExtractFileDir(Dst));
    ms.SaveToFile(Dst);
  finally
    ms.Free;
  end;
end;

function DirIsEmpty(const Dir: string): Boolean;
var
  Info: TSearchRec;
  found: Boolean;
begin
  found := False;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Name <> '.') and (Info.Name <> '..') then
      begin
        found := True;
        Break;
      end;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  Result := not found;
end;

{ Which alphabetical bucket a title falls in. }
function Bucket(const Title: string): string;
var
  t: string;
  c: Char;
begin
  t := TrimLeft(Title);
  { skip leading non-alphanumerics }
  while (t <> '') and not (((t[1] >= 'A') and (t[1] <= 'Z')) or
        ((t[1] >= 'a') and (t[1] <= 'z')) or ((t[1] >= '0') and (t[1] <= '9'))) do
    Delete(t, 1, 1);
  if t = '' then Exit('#');
  c := UpCase(t[1]);
  case c of
    'A'..'F': Result := 'A-F';
    'G'..'L': Result := 'G-L';
    'M'..'R': Result := 'M-R';
    'S'..'Z': Result := 'S-Z';
  else
    Result := '#';
  end;
end;

function HasKeyword(const R: TRecipe; const K: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Trim(K) = '' then Exit;
  for i := 0 to High(R.Keywords) do
    if SameText(R.Keywords[i], K) then Exit(True);
end;

{ Render a yield/servings value without redundancy: a Meal-Master yield like
  "4 Servings" is shown as-is; a bare "4" becomes "Serves 4". }
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

{ --- stylesheet (mirrors the old ~/html theme) --- }

function StyleCss(Cfg: TConfig): string;
var
  bg: string;
begin
  if Cfg.BackgroundImage <> '' then
    bg := 'background-image:url(''images/' +
          ExtractFileName(Cfg.BackgroundImage) + ''');' +
          'background-repeat:no-repeat;background-attachment:fixed;background-size:cover;'
  else
    bg := 'background:#eef1f5;';
  Result :=
    'body{' + bg + 'font-family:sans-serif;margin:0;padding:20px;color:#333;}' + #10 +
    '.container{max-width:800px;margin:0 auto;background:rgba(255,255,255,0.94);' +
      'padding:20px;border-radius:15px;box-shadow:0 4px 15px rgba(0,0,0,0.3);}' + #10 +
    'header{text-align:center;margin-bottom:20px;}' + #10 +
    'header img{max-width:100%;height:auto;border-radius:10px;}' + #10 +
    '.nav{display:flex;justify-content:space-around;background:#4A90E2;padding:10px;' +
      'border-radius:8px;margin-bottom:20px;position:sticky;top:10px;flex-wrap:wrap;z-index:10;}' + #10 +
    '.nav a{color:#fff;text-decoration:none;font-weight:bold;text-transform:uppercase;padding:10px 15px;}' + #10 +
    '.controls-row{display:flex;gap:10px;margin-bottom:20px;}' + #10 +
    '#recipeSearch{flex-grow:1;padding:15px;font-size:1.1em;border:2px solid #4A90E2;' +
      'border-radius:8px;outline:none;box-sizing:border-box;}' + #10 +
    '.btn-clear{padding:10px 20px;background:#4A90E2;color:#fff;border:none;border-radius:8px;' +
      'font-weight:bold;cursor:pointer;text-transform:uppercase;}' + #10 +
    'h2{background:#e1e1e1;padding:10px;border-left:5px solid #4A90E2;margin-top:30px;}' + #10 +
    '.recipe-list{display:grid;grid-template-columns:1fr;gap:10px;}' + #10 +
    '.recipe-list a{display:block;padding:15px;background:#fff;border:1px solid #ddd;' +
      'text-decoration:none;color:#333;border-radius:8px;}' + #10 +
    '.recipe-list a.favorite{background:#fff3cd;border-left:10px solid #ffc107;font-weight:bold;}' + #10 +
    '.hidden{display:none;}' + #10 +
    '.recipe h1{margin-top:0;}' + #10 +
    '.recipe .meta{color:#555;font-style:italic;}' + #10 +
    '.recipe-photo{max-width:100%;height:auto;border-radius:10px;margin:10px 0;}' + #10 +
    '.recipe h3{margin:14px 0 4px;}' + #10 +
    '.backlink a{color:#4A90E2;text-decoration:none;font-weight:bold;}' + #10 +
    '.print-nav{margin:20px 0;text-align:center;}' + #10 +
    '.print-nav button{padding:15px 30px;background:#28a745;color:#fff;border:none;' +
      'border-radius:8px;font-size:1.2em;cursor:pointer;font-weight:bold;}' + #10 +
    '@media print{.nav,.controls-row,.print-nav,.backlink,footer{display:none!important;}' +
      'body{background:#fff!important;}.container{box-shadow:none;border:none;max-width:100%;}}' + #10;
end;

{ --- per-recipe page --- }

function RecipePage(const R: TRecipe; Cfg: TConfig; const ImageName: string): string;
var
  sb: TStringList;
  i: Integer;
  ulOpen: Boolean;
begin
  sb := TStringList.Create;
  try
    sb.TextLineBreakStyle := tlbsLF;
    sb.Add('<!DOCTYPE html>');
    sb.Add('<html lang="en"><head>');
    sb.Add('<meta charset="utf-8">');
    sb.Add('<meta name="viewport" content="width=device-width, initial-scale=1">');
    sb.Add('<title>' + EscapeHtml(R.Title) + ' - ' + EscapeHtml(Cfg.SiteTitle) + '</title>');
    sb.Add('<link rel="stylesheet" href="style.css">');
    sb.Add('</head><body>');
    sb.Add('<div class="container recipe">');
    sb.Add('<p class="backlink"><a href="index.html">&larr; Main Page</a></p>');
    sb.Add('<h1>' + EscapeHtml(R.Title) + '</h1>');

    if ImageName <> '' then
      sb.Add('<img class="recipe-photo" src="images/' + EscapeHtml(ImageName) +
             '" alt="' + EscapeHtml(R.Title) + '">');

    if R.Servings <> '' then
      sb.Add('<p class="meta">' + EscapeHtml(ServingsLine(R.Servings)) + '</p>');
    if Length(R.Keywords) > 0 then
      sb.Add('<p class="meta">' + EscapeHtml(KeywordText(R)) + '</p>');

    if R.Description <> '' then
      sb.Add('<p>' + EscapeMultiline(R.Description) + '</p>');

    if Length(R.Ingredients) > 0 then
    begin
      sb.Add('<h2>Ingredients</h2>');
      ulOpen := False;
      for i := 0 to High(R.Ingredients) do
        if R.Ingredients[i].IsSection then
        begin
          if ulOpen then begin sb.Add('</ul>'); ulOpen := False; end;
          sb.Add('<h3>' + EscapeHtml(R.Ingredients[i].Text) + '</h3>');
        end
        else
        begin
          if not ulOpen then begin sb.Add('<ul>'); ulOpen := True; end;
          sb.Add('<li>' + EscapeHtml(R.Ingredients[i].Text) + '</li>');
        end;
      if ulOpen then sb.Add('</ul>');
    end;

    if Length(R.Steps) > 0 then
    begin
      sb.Add('<h2>Steps</h2>');
      sb.Add('<ol>');
      for i := 0 to High(R.Steps) do
        sb.Add('<li><p>' + EscapeMultiline(R.Steps[i]) + '</p></li>');
      sb.Add('</ol>');
    end;

    if R.SourceUrl <> '' then
      sb.Add('<p class="source">Source: <a href="' + EscapeHtml(R.SourceUrl) +
             '">' + EscapeHtml(R.SourceUrl) + '</a></p>');

    sb.Add('<div class="print-nav"><button onclick="window.print()">PRINT THIS RECIPE</button></div>');
    sb.Add('<p class="backlink"><a href="index.html">&larr; Main Page</a></p>');
    sb.Add('</div></body></html>');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

{ --- index page --- }

const
  BucketOrder: array[0..4] of string = ('A-F', 'G-L', 'M-R', 'S-Z', '#');

function IndexPage(Lib: TLibrary; Cfg: TConfig; Order: TIntArray): string;
var
  sb: TStringList;
  bi, i: Integer;
  personalCount: Integer;
  bucketHas: array[0..High(BucketOrder)] of Boolean;

  procedure EmitLink(Index: Integer);
  var
    RR: TRecipe;
    c: string;
  begin
    RR := Lib.Recipe(Index);
    if HasKeyword(RR, Cfg.FavoriteKeyword) then c := ' class="favorite"' else c := '';
    sb.Add('  <a href="' + Lib.Slug(Index) + '.htm"' + c + '>' + EscapeHtml(RR.Title) + '</a>');
  end;

begin
  sb := TStringList.Create;
  try
    sb.TextLineBreakStyle := tlbsLF;

    { count personal recipes and which buckets are populated, for the nav }
    personalCount := 0;
    if Cfg.PersonalKeyword <> '' then
      for i := 0 to High(Order) do
        if HasKeyword(Lib.Recipe(Order[i]), Cfg.PersonalKeyword) then Inc(personalCount);
    for bi := 0 to High(BucketOrder) do
    begin
      bucketHas[bi] := False;
      for i := 0 to High(Order) do
        if Bucket(Lib.Recipe(Order[i]).Title) = BucketOrder[bi] then
        begin
          bucketHas[bi] := True;
          Break;
        end;
    end;

    sb.Add('<!DOCTYPE html>');
    sb.Add('<html lang="en"><head>');
    sb.Add('<meta charset="utf-8">');
    sb.Add('<meta name="viewport" content="width=device-width, initial-scale=1">');
    sb.Add('<title>' + EscapeHtml(Cfg.SiteTitle) + '</title>');
    sb.Add('<link rel="stylesheet" href="style.css">');
    sb.Add('</head><body>');
    sb.Add('<div class="container">');
    sb.Add('<header>');
    if Cfg.HeaderImage <> '' then
      sb.Add('<img src="images/' + EscapeHtml(ExtractFileName(Cfg.HeaderImage)) +
             '" alt="' + EscapeHtml(Cfg.SiteTitle) + '">')
    else
      sb.Add('<h1>' + EscapeHtml(Cfg.SiteTitle) + '</h1>');
    if Cfg.SiteIntro <> '' then
      sb.Add('<p>' + EscapeHtml(Cfg.SiteIntro) + '</p>');
    sb.Add('</header>');

    { nav }
    sb.Add('<div class="nav">');
    if personalCount > 0 then sb.Add('<a href="#personal">MINE</a>');
    for bi := 0 to High(BucketOrder) do
      if bucketHas[bi] then
        sb.Add('<a href="#sec-' + Slugify(BucketOrder[bi]) + '">' + BucketOrder[bi] + '</a>');
    sb.Add('</div>');

    { search }
    sb.Add('<div class="controls-row">');
    sb.Add('<input type="text" id="recipeSearch" onkeyup="searchRecipes()" ' +
           'placeholder="Search recipes...">');
    sb.Add('<button class="btn-clear" onclick="clearSearch()">Clear</button>');
    sb.Add('</div>');

    sb.Add('<div id="recipeSections">');

    { personal section (recipes also still appear in their letter bucket) }
    if personalCount > 0 then
    begin
      sb.Add('<h2 id="personal" style="background:#fff3cd;border-left:5px solid #ffc107;">'
             + EscapeHtml(Cfg.PersonalKeyword) + '</h2>');
      sb.Add('<div class="recipe-list">');
      for i := 0 to High(Order) do
        if HasKeyword(Lib.Recipe(Order[i]), Cfg.PersonalKeyword) then
          EmitLink(Order[i]);
      sb.Add('</div>');
    end;

    { alphabetical buckets }
    for bi := 0 to High(BucketOrder) do
    begin
      if not bucketHas[bi] then Continue;
      sb.Add('<h2 id="sec-' + Slugify(BucketOrder[bi]) + '">' + BucketOrder[bi] + '</h2>');
      sb.Add('<div class="recipe-list">');
      for i := 0 to High(Order) do
        if Bucket(Lib.Recipe(Order[i]).Title) = BucketOrder[bi] then
          EmitLink(Order[i]);
      sb.Add('</div>');
    end;

    sb.Add('</div>'); { #recipeSections }

    if Cfg.SiteFooter <> '' then
      sb.Add('<footer style="text-align:center;margin-top:40px;font-size:0.8em;color:#777;">'
             + EscapeHtml(Cfg.SiteFooter) + '</footer>');
    sb.Add('</div>'); { .container }

    { live search: show/hide links and their section headings }
    sb.Add('<script>');
    sb.Add('function searchRecipes(){');
    sb.Add(' var q=document.getElementById("recipeSearch").value.toLowerCase();');
    sb.Add(' var lists=document.querySelectorAll(".recipe-list");');
    sb.Add(' var heads=document.querySelectorAll("#recipeSections h2");');
    sb.Add(' lists.forEach(function(list,n){');
    sb.Add('  var links=list.getElementsByTagName("a");var any=false;');
    sb.Add('  for(var i=0;i<links.length;i++){');
    sb.Add('   var name=(links[i].textContent||links[i].innerText).toLowerCase();');
    sb.Add('   if(name.indexOf(q)>-1){links[i].style.display="";any=true;}');
    sb.Add('   else{links[i].style.display="none";}}');
    sb.Add('  if(any){heads[n].classList.remove("hidden");list.classList.remove("hidden");}');
    sb.Add('  else{heads[n].classList.add("hidden");list.classList.add("hidden");}});}');
    sb.Add('function clearSearch(){var s=document.getElementById("recipeSearch");');
    sb.Add(' s.value="";searchRecipes();s.focus();}');
    sb.Add('</script>');
    sb.Add('</body></html>');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

{ --- driver --- }

function ExportHtml(Lib: TLibrary; Cfg: TConfig; const OutDir: string): Integer;
var
  order: TIntArray;
  i: Integer;
  outp, imgdir, markerPath, imgSrc, imgName: string;
  R: TRecipe;
begin
  { safety: never overwrite a non-empty directory we did not create }
  markerPath := IncludeTrailingPathDelimiter(OutDir) + Marker;
  if DirectoryExists(OutDir) and not DirIsEmpty(OutDir) and not FileExists(markerPath) then
    raise EExportUnsafe.Create(
      'refusing to write into non-empty directory not created by tiecook2: ' + OutDir);

  ForceDirectories(OutDir);
  WriteTextFile(markerPath, 'tiecook2 static site' + #10);
  outp := IncludeTrailingPathDelimiter(OutDir);
  imgdir := outp + 'images';

  WriteTextFile(outp + 'style.css', StyleCss(Cfg));

  order := Lib.Search('');   { all recipes, title-sorted }

  for i := 0 to High(order) do
  begin
    R := Lib.Recipe(order[i]);
    imgName := Lib.ImageBasename(order[i]);
    WriteTextFile(outp + Lib.Slug(order[i]) + '.htm', RecipePage(R, Cfg, imgName));
    if imgName <> '' then
    begin
      imgSrc := IncludeTrailingPathDelimiter(Lib.Dir) + imgName;
      CopyBinary(imgSrc, IncludeTrailingPathDelimiter(imgdir) + imgName);
    end;
  end;

  if Cfg.HeaderImage <> '' then
    CopyBinary(Cfg.HeaderImage, IncludeTrailingPathDelimiter(imgdir) + ExtractFileName(Cfg.HeaderImage));
  if Cfg.BackgroundImage <> '' then
    CopyBinary(Cfg.BackgroundImage, IncludeTrailingPathDelimiter(imgdir) + ExtractFileName(Cfg.BackgroundImage));

  WriteTextFile(outp + 'index.html', IndexPage(Lib, Cfg, order));
  Result := Length(order);
end;

end.
