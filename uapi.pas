unit uapi;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fphttpclient, opensslsockets, fpjson, jsonparser, umodels;

type
  ETandoorError = class(Exception)
  public
    HttpStatus: Integer; // 0 = network/TLS-level failure, no HTTP status
    constructor CreateHttp(AStatus: Integer; const AMsg: string);
  end;

  TTandoorClient = class
  private
    FBaseUrl: string;
    FToken: string;
    FHttp: TFPHTTPClient;
    function DoGet(const APath: string): TJSONData;
    function ParseKeywords(Arr: TJSONArray): TKeywordArray;
    function ParseOverview(Obj: TJSONObject): TRecipeOverview;
    function ParseIngredient(Obj: TJSONObject): TIngredient;
    function ParseStep(Obj: TJSONObject): TStep;
  public
    constructor Create(const ABaseUrl, AToken: string);
    destructor Destroy; override;
    function SearchRecipes(const P: TSearchParams): TSearchResult;
    function GetRecipeDetail(AId: Integer): TRecipeDetail;
    function GetRandomRecipe: TRecipeOverview;
    function ListKeywords: TKeywordArray;
    property BaseUrl: string read FBaseUrl;
  end;

implementation

{ ETandoorError }

constructor ETandoorError.CreateHttp(AStatus: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  HttpStatus := AStatus;
end;

{ TTandoorClient }

constructor TTandoorClient.Create(const ABaseUrl, AToken: string);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  FToken := AToken;
  FHttp := TFPHTTPClient.Create(nil);
  FHttp.AddHeader('Authorization', 'Bearer ' + FToken);
  FHttp.AddHeader('Accept', 'application/json');
  FHttp.AllowRedirect := True;
  FHttp.IOTimeout := 10000;
end;

destructor TTandoorClient.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TTandoorClient.DoGet(const APath: string): TJSONData;
var
  ResponseBody: TStringStream;
  Status: Integer;
begin
  ResponseBody := TStringStream.Create('');
  try
    try
      FHttp.Get(FBaseUrl + APath, ResponseBody);
      Status := FHttp.ResponseStatusCode;
    except
      on E: EHTTPClient do
      begin
        Status := FHttp.ResponseStatusCode;
        case Status of
          401, 403:
            raise ETandoorError.CreateHttp(Status,
              'Authentication failed (check token in config) - HTTP ' + IntToStr(Status));
          404:
            raise ETandoorError.CreateHttp(Status, 'Not found (HTTP 404)');
          500..599:
            raise ETandoorError.CreateHttp(Status, 'Server error (HTTP ' + IntToStr(Status) + ')');
        else
          raise ETandoorError.CreateHttp(Status, 'Unexpected HTTP status ' + IntToStr(Status));
        end;
      end;
      on E: Exception do
        raise ETandoorError.CreateHttp(0, 'Network/TLS error: ' + E.Message);
    end;

    try
      Result := GetJSON(ResponseBody.DataString);
    except
      on E: Exception do
        raise ETandoorError.CreateHttp(Status, 'Invalid JSON response: ' + E.Message);
    end;
  finally
    ResponseBody.Free;
  end;
end;

function TTandoorClient.ParseKeywords(Arr: TJSONArray): TKeywordArray;
var
  I: Integer;
  KwObj: TJSONObject;
begin
  Result := nil;
  if not Assigned(Arr) then
    Exit;
  SetLength(Result, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    KwObj := TJSONObject(Arr.Items[I]);
    Result[I].Id := KwObj.Get('id', 0);
    { The recipe-list serializer returns keywords with id + label and no
      name field; the detail serializer returns both. label is present in
      both, so fall back to it. }
    Result[I].Name := KwObj.Get('name', '');
    if Result[I].Name = '' then
      Result[I].Name := KwObj.Get('label', '');
  end;
end;

function TTandoorClient.ParseOverview(Obj: TJSONObject): TRecipeOverview;
begin
  Result.Id := Obj.Get('id', 0);
  Result.Name := Obj.Get('name', '');
  Result.Description := Obj.Get('description', '');
  Result.ImageUrl := Obj.Get('image', '');
  Result.WorkingTime := Obj.Get('working_time', 0);
  Result.WaitingTime := Obj.Get('waiting_time', 0);
  Result.Servings := Obj.Get('servings', 0);
  Result.ServingsText := Obj.Get('servings_text', '');
  Result.Rating := Obj.Get('rating', Double(0));
  Result.Keywords := ParseKeywords(Obj.Get('keywords', TJSONArray(nil)));
end;

function TTandoorClient.ParseIngredient(Obj: TJSONObject): TIngredient;
var
  FoodObj, UnitObj: TJSONObject;
begin
  FoodObj := Obj.Get('food', TJSONObject(nil));
  if Assigned(FoodObj) then
    Result.FoodName := FoodObj.Get('name', '')
  else
    Result.FoodName := '';

  UnitObj := Obj.Get('unit', TJSONObject(nil));
  if Assigned(UnitObj) then
    Result.UnitName := UnitObj.Get('name', '')
  else
    Result.UnitName := '';

  Result.Amount := Obj.Get('amount', Double(0));
  Result.Note := Obj.Get('note', '');
  Result.OriginalText := Obj.Get('original_text', '');
  Result.IsHeader := Obj.Get('is_header', False);
end;

function TTandoorClient.ParseStep(Obj: TJSONObject): TStep;
var
  IngArr: TJSONArray;
  I: Integer;
begin
  Result.Name := Obj.Get('name', '');
  Result.Instruction := Obj.Get('instruction', '');
  Result.TimeMinutes := Obj.Get('time', 0);
  Result.Order := Obj.Get('order', 0);

  SetLength(Result.Ingredients, 0);
  IngArr := Obj.Get('ingredients', TJSONArray(nil));
  if Assigned(IngArr) then
  begin
    SetLength(Result.Ingredients, IngArr.Count);
    for I := 0 to IngArr.Count - 1 do
      Result.Ingredients[I] := ParseIngredient(TJSONObject(IngArr.Items[I]));
  end;
end;

function TTandoorClient.SearchRecipes(const P: TSearchParams): TSearchResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  ResultsArr: TJSONArray;
  I: Integer;
  Path: string;
begin
  Path := '/api/recipe/?query=' + EncodeURLElement(P.Query) + '&page=' + IntToStr(P.Page);
  { sort_order and random both control ordering; a filtered search never sets
    random, so they can't collide here. keywords is a repeat parameter, so a
    second keyword would be another &keywords=<id> rather than a comma list. }
  if P.SortOrder <> '' then
    Path := Path + '&sort_order=' + EncodeURLElement(P.SortOrder);
  if P.RatingGte > 0 then
    Path := Path + '&rating_gte=' + IntToStr(P.RatingGte);
  if P.KeywordId > 0 then
    Path := Path + '&keywords=' + IntToStr(P.KeywordId);
  Data := DoGet(Path);
  try
    Obj := TJSONObject(Data);
    Result.Count := Obj.Get('count', 0);
    Result.HasNext := Obj.Get('next', '') <> '';
    Result.HasPrevious := Obj.Get('previous', '') <> '';

    SetLength(Result.Recipes, 0);
    ResultsArr := Obj.Get('results', TJSONArray(nil));
    if Assigned(ResultsArr) then
    begin
      SetLength(Result.Recipes, ResultsArr.Count);
      for I := 0 to ResultsArr.Count - 1 do
        Result.Recipes[I] := ParseOverview(TJSONObject(ResultsArr.Items[I]));
    end;
  finally
    Data.Free;
  end;
end;

function TTandoorClient.GetRecipeDetail(AId: Integer): TRecipeDetail;
var
  Data: TJSONData;
  Obj: TJSONObject;
  StepsArr: TJSONArray;
  I: Integer;
begin
  Data := DoGet('/api/recipe/' + IntToStr(AId) + '/');
  try
    Obj := TJSONObject(Data);
    Result.Id := Obj.Get('id', 0);
    Result.Name := Obj.Get('name', '');
    Result.Description := Obj.Get('description', '');
    Result.WorkingTime := Obj.Get('working_time', 0);
    Result.WaitingTime := Obj.Get('waiting_time', 0);
    Result.Servings := Obj.Get('servings', 0);
    Result.ServingsText := Obj.Get('servings_text', '');
    Result.SourceUrl := Obj.Get('source_url', '');
    Result.Rating := Obj.Get('rating', Double(0));
    Result.Keywords := ParseKeywords(Obj.Get('keywords', TJSONArray(nil)));

    SetLength(Result.Steps, 0);
    StepsArr := Obj.Get('steps', TJSONArray(nil));
    if Assigned(StepsArr) then
    begin
      SetLength(Result.Steps, StepsArr.Count);
      for I := 0 to StepsArr.Count - 1 do
        Result.Steps[I] := ParseStep(TJSONObject(StepsArr.Items[I]));
    end;
  finally
    Data.Free;
  end;
end;

function TTandoorClient.GetRandomRecipe: TRecipeOverview;
var
  Data: TJSONData;
  Obj: TJSONObject;
  ResultsArr: TJSONArray;
begin
  Data := DoGet('/api/recipe/?random=true&page=1');
  try
    Obj := TJSONObject(Data);
    ResultsArr := Obj.Get('results', TJSONArray(nil));
    if (not Assigned(ResultsArr)) or (ResultsArr.Count = 0) then
      raise ETandoorError.CreateHttp(0, 'No recipes available.');
    Result := ParseOverview(TJSONObject(ResultsArr.Items[0]));
  finally
    Data.Free;
  end;
end;

function TTandoorClient.ListKeywords: TKeywordArray;
var
  Data: TJSONData;
  Obj: TJSONObject;
  I, J: Integer;
  Tmp: TKeyword;
begin
  Result := nil;
  { page_size well above the current keyword count so the whole set arrives in
    one page. }
  Data := DoGet('/api/keyword/?page_size=1000');
  try
    Obj := TJSONObject(Data);
    Result := ParseKeywords(Obj.Get('results', TJSONArray(nil)));
  finally
    Data.Free;
  end;

  { Insertion sort by name (case-insensitive) for a predictable picker. }
  for I := 1 to High(Result) do
  begin
    Tmp := Result[I];
    J := I - 1;
    while (J >= 0) and (CompareText(Result[J].Name, Tmp.Name) > 0) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := Tmp;
  end;
end;

end.
