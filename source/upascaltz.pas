unit uPascalTZ;

{$mode objfpc}{$H+}

{
  File: upascaltz.pas

  This unit is designed to convert local times across different time zones
  at any given time in the past and probably in the future, this can not be
  ensured as time change rules could change in the future. For this purpose
  it uses the time rules database available at
  http://www.twinsun.com/tz/tz-link.htm

  License: The same as freepascal packages (basically LGPL)

  The database is presented in different files so you can use one of them
  using "ParseDatabaseFromFile" or concatenate the interested ones in a single
  file or stream. Once the database is loaded calling "ParseDatabaseFromXXXX"
  deletes the in memory parsed data.

  ProcessedLines
    Amount of read lines in database.

  DetectInvalidLocalTimes [True|False] (default true)
    When converting it will check if the given time is impossible (does not
    exists). This happends, in example, when a local time changes from 2:00
    to 3:00, if the time to be converted is 2:01 at the change date, that
    time does not exists as it is not linear.

  GetTimeZoneNames(const AZones: TStringList; const AOnlyGeoZones: Boolean=true);
    Returns a TStringList with the time zones available in the database. This
    names must be used for local times to perform conversions. It is not a
    country list, as many countries have several time zones. AOnlyGeoZones
    removes from the list the usual "GMT, BST, PST" from the list.

  GMTToLocalTime
    Converts a GMT/UTC/Zulu time to a time zone (AToZone). ATimeZoneSubFix
    returns the subfix for that zone like "GMT, BST, ...".

  LocalTimeToGMT
    Converts a local time at time zone "AFromZone" to GMT/UTC/Zulu time.

  TimeZoneToTimeZone
    Converts time across zones. Basically this performs a local time to
    GMT and GTM to the new local time.

  ParseDatabaseFromFile(const AFileName: String): Boolean;
    Reads the database from a file.

  ParseDatabaseFromStream(const AStream: TStream): Boolean;
    Reads the database from a stream.

  2009 - José Mejuto
}

interface

uses
  Classes,SysUtils,uPascalTZ_Types,uPascalTZ_Sorters;

type
  { TPascalTZ }

  TPascalTZ = class(TObject)
  private
    FDatabaseLoaded: Boolean;
    ParseStatusTAG: AsciiString;
    ParseStatusPreviousZone: AsciiString;
    function FindZoneForDate(const ZoneIndexStart: integer;const ADateTime: TTZDateTime): integer;
    function FindZoneName(const AZone: String): integer;
    function fSortCompareRule(const AIndex,BIndex: SizeInt): TSortCompareResult;
    procedure fSortSwapRule(const AIndex,BIndex: SizeInt);
    procedure SortRules();
    function GetCountZones: Integer;
    function GetCountRules: Integer;
    procedure CheckCanLoadDatabase;
  protected
    FDetectInvalidLocalTimes: Boolean;
    FLineCounter: integer;
    FCurrentLine: AsciiString;
    FRules: array of TTZRules;
    FZones: array of TTzZone;
    Function LookupRuleNonIndexed(const AName: AsciiString): Integer;
    procedure ParseLine(const ALine: AsciiString;const AParseSequence: TParseSequence);
    procedure ParseZone(const AIterator: TTZLineIterate; const AZone: AsciiString);
    procedure ParseRule(const AIterator: TTZLineIterate);
    function LocalTimeToGMT(const ADateTime: TTZDateTime; const AFromZone: String): TTZDateTime;
    function GMTToLocalTime(const ADateTime: TTZDateTime; const AToZone: String;out ATimeZoneName: String): TTZDateTime;
  public
    property CountZones: Integer read GetCountZones;
    property CountRules: Integer read GetCountRules;
    property ProcessedLines: integer read FLineCounter;
    property DetectInvalidLocalTimes: Boolean read FDetectInvalidLocalTimes write FDetectInvalidLocalTimes;
    procedure GetTimeZoneNames(const AZones: TStringList; const AOnlyGeoZones: Boolean=true);
    function TimeZoneExists(const AZone: String): Boolean;
    function GMTToLocalTime(const ADateTime: TDateTime; const AToZone: String): TDateTime; overload;
    function GMTToLocalTime(const ADateTime: TDateTime; const AToZone: String; out ATimeZoneSubFix: String): TDateTime; overload;
    function LocalTimeToGMT(const ADateTime: TDateTime; const AFromZone: String): TDateTime;
    function TimeZoneToTimeZone(const ADateTime: TDateTime; const AFromZone, AToZone: String): TDateTime; overload;
    function TimeZoneToTimeZone(const ADateTime: TDateTime; const AFromZone, AToZone: String; out ATimeZoneSubFix: String): TDateTime; overload;
    function ParseDatabaseFromFile(const AFileName: String): Boolean;
    function ParseDatabaseFromFiles(const AFileNames: array of String): Boolean;
    function ParseDatabaseFromStream(const AStream: TStream): Boolean;
    constructor Create;
  end;

implementation

uses
  RtlConsts, DateUtils, uPascalTZ_Tools;

{ TPascalTZ }

function TPascalTZ.FindZoneName(const AZone: String): integer;
var
  ZoneIndex: integer;
  j: integer;
begin
  ZoneIndex:=-1;
  for j := 0 to High(FZones) do begin
    if FZones[j].Name=AZone then begin
      ZoneIndex:=j;
      Break;
    end;
  end;
  if ZoneIndex<0 then begin
    raise TTZException.CreateFmt('Zone not found [%s]', [AZone]);
  end;
  Result:=ZoneIndex;
end;

function TPascalTZ.FindZoneForDate(const ZoneIndexStart: integer;const ADateTime: TTZDateTime): integer;
var
  Found: Boolean;
  AZone: AsciiString;
  j: integer;
begin
  AZone:=FZones[ZoneIndexStart].Name;
  j:=ZoneIndexStart;
  Found:=false;
  while (j<=High(FZones)) and (FZones[j].Name=AZone) do begin
    if CompareDates(FZones[j].RuleValidUntil, ADateTime)=1 then begin
      Found:=true;
      break;
    end;
    inc(j);
  end;
  if not Found then begin
    raise TTZException.CreateFmt('No valid conversion rule for Zone [%s]', [AZone]);
  end;
  Result:=j;
end;

function TPascalTZ.fSortCompareRule(const AIndex, BIndex: SizeInt
  ): TSortCompareResult;
begin
  if FRules[AIndex].Name>FRules[BIndex].Name Then begin
    Exit(eSortCompareBigger);
  end else if FRules[AIndex].Name<FRules[BIndex].Name Then begin
    Exit(eSortCompareLesser);
  end;
  if FRules[AIndex].FromYear>FRules[BIndex].FromYear then begin
    Exit(eSortCompareBigger);
  end else if FRules[AIndex].FromYear<FRules[BIndex].FromYear Then begin
    Exit(eSortCompareLesser);
  end;
  if FRules[AIndex].ToYear>FRules[BIndex].ToYear then begin
    Exit(eSortCompareBigger);
  end else if FRules[AIndex].ToYear<FRules[BIndex].ToYear Then begin
    Exit(eSortCompareLesser);
  end;
  if FRules[AIndex].InMonth>FRules[BIndex].InMonth then begin
    Exit(eSortCompareBigger);
  end else if FRules[AIndex].InMonth<FRules[BIndex].InMonth Then begin
    Exit(eSortCompareLesser);
  end;
  //This should not happend
//  Raise TTZException.CreateFmt('Invalid rule sorting',[]);
  Result:=eSortCompareEqual;
end;

procedure TPascalTZ.fSortSwapRule(const AIndex, BIndex: SizeInt);
var
  Temporal: TTZRules;
begin
  Temporal:=FRules[AIndex];
  FRules[AIndex]:=FRules[BIndex];
  FRules[BIndex]:=Temporal;
end;

procedure TPascalTZ.SortRules();
var
  Sorter: THeapSort;
begin
  //Sort the rules by name
  Sorter:=THeapSort.Create(Length(FRules));
  Sorter.OnCompareOfClass:=@fSortCompareRule;
  Sorter.OnSwapOfClass:=@fSortSwapRule;
  Sorter.Sort();
  Sorter.Free;
end;

function TPascalTZ.LookupRuleNonIndexed(const AName: AsciiString): Integer;
var
  j: integer;
begin
  Result:=-1;
  for j := 0 to High(FRules) do begin
    if FRules[j].Name=AName then begin
      Result:=j;
      break;
    end;
  end;
end;

procedure TPascalTZ.ParseLine(const ALine: AsciiString;const AParseSequence: TParseSequence);
var
  j: integer;
  Parser: TTZLineIterate;
  PreParseLine: AsciiString;
  ZoneContinue: Boolean;
  spCount: integer;
begin
  PreParseLine:=ALine;
  j:=Pos('#',PreParseLine);
  if j>0 then PreParseLine:=Copy(PreParseLine,1,j-1);
  spCount:=0;
  for j := 1 to Length(PreParseLine) do begin
    if PreParseLine[j]=#9 then PreParseLine[j]:=#32;
    if PreParseLine[j]=#32 then begin
      inc(spCount);
    end;
  end;
  if spCount=Length(PreParseLine) Then PreParseLine:=''; //all spaces in line
  if Length(PreParseLine)>0 then begin
    FCurrentLine:=ALine;
    Parser:=TTZLineIterate.Create(PreParseLine);
    try
      ZoneContinue:=false;
      if (PreParseLine[1]=#32) or (PreParseLine[1]=#9) then begin
        //Its a continuation
        if ParseStatusTAG<>'Zone' then begin
          Raise TTZException.CreateFmt('Continue error at line: "%s" (No Zone)',[ALine]);
        end;
        ZoneContinue:=true;
      end else begin
        ParseStatusTAG:=Parser.GetNextWord;
      end;
      if (ParseStatusTAG='Zone') then begin
        if (AParseSequence=TTzParseZone) Then begin
          if not ZoneContinue then begin
            ParseStatusPreviousZone:=Parser.GetNextWord;
          end;
          ParseZone(Parser,ParseStatusPreviousZone);
        end;
      end else if (ParseStatusTAG='Rule') then begin
        if (AParseSequence=TTzParseRule) then begin
          ParseRule(Parser);
        end;
      end else if ParseStatusTAG='Link' then begin

      end else begin
        Raise TTZException.CreateFmt('Parsing error at line: "%s"',[ALine]);
      end;
    finally
      Parser.Free;
    end;
  end;
end;

procedure TPascalTZ.ParseZone(const AIterator: TTZLineIterate;
  const AZone: AsciiString);
var
  Index: integer;
  RuleName: AsciiString;
  RuleTmpIndex: integer;
  TmpWord: AsciiString;
begin
  Index:=Length(FZones);
  SetLength(FZones,Index+1);
  with FZones[Index] do begin
    //First is the zone name
    if Length(AZone)>TZ_ZONENAME_SIZE then begin
      SetLength(FZones,Index); //Remove put information
      Raise TTZException.CreateFmt('Name on Zone line "%s" too long. (Increase source code TZ_ZONENAME_SIZE)',[AIterator.CurrentLine]);
    end;
    Name:=AZone;

    //Now check the offset
    TmpWord:=AIterator.GetNextWord; //Offset
    Offset:=TimeToSeconds(TmpWord);

    //Now check the rules...
    RuleName:=AIterator.GetNextWord;
    if RuleName='' Then begin
      SetLength(FZones,Index); //Remove put information
      Raise TTZException.CreateFmt('Rule on Zone line "%s" empty.',[AIterator.CurrentLine]);
    end;
    if RuleName='-' then begin
      //Standard time (Local time)
      RuleFixedOffset:=0;
      RuleIndex:=-1;
    end else if RuleName[1] in ['0'..'9'] then begin
      //Fixed offset time to get standard time (Local time)
      RuleFixedOffset:=TimeToSeconds(RuleName);
      RuleIndex:=-1;
    end else begin
      RuleTmpIndex:=LookupRuleNonIndexed(RuleName);
      if RuleTmpIndex<0 then begin
        SetLength(FZones,Index); //Remove put information
        Raise TTZException.CreateFmt('Rule on Zone line "%s" not found.',[AIterator.CurrentLine]);
      end else begin
        RuleIndex:=RuleTmpIndex;
        RuleFixedOffset:=0; //Nonsense value.
      end;
    end;

    //Now its time for the format (GMT, BST, ...)
    TmpWord:=AIterator.GetNextWord;
    if Length(TmpWord)>TZ_TIMEZONELETTERS_SIZE Then begin
      SetLength(FZones,Index); //Remove put information
      Raise TTZException.CreateFmt('Format on Zone line "%s" too long. (Increase source code TZ_TIMEZONELETTERS_SIZE)',[AIterator.CurrentLine]);
    end;
    TimeZoneLetters:=TmpWord;

    //And finally the UNTIL field which format is optional fields from
    //left to right: year month day hour[s]
    //defaults:      YEAR Jan   1   0:00:00
    RuleValidUntil:=ParseUntilFields(AIterator,RuleValidUntilGMT);
  end;
end;

procedure TPascalTZ.ParseRule(const AIterator: TTZLineIterate);
var
  Index: integer;
  TmpWord: AsciiString;
  StandardTimeFlag: char;
begin
  Index:=Length(FRules);
  SetLength(FRules,Index+1);
  with FRules[Index] do begin
    TmpWord:=AIterator.GetNextWord;
    if Length(TmpWord)>TZ_RULENAME_SIZE then begin
      SetLength(FRules,Index); //Remove put information
      Raise TTZException.CreateFmt('Name on Rule line "%s" too long. (Increase source code TZ_RULENAME_SIZE)',[AIterator.CurrentLine]);
    end;
    Name:=TmpWord;
    //Begin year...
    TmpWord:=AIterator.GetNextWord;
    FromYear:=StrToInt(TmpWord);
    //End year...
    TmpWord:=AIterator.GetNextWord;
    if TmpWord='only' then begin
      ToYear:=FromYear;
    end else if TmpWord='max' then begin
      //max year, so in this case 9999
      ToYear:=9999;
    end else begin
      ToYear:=StrToInt(TmpWord);
    end;
    //Year type (macro)
    TmpWord:=AIterator.GetNextWord;
    if TmpWord='-' then begin
      //No year type, so all years.
    end else begin
      //Special year... check macro...
      //No one defined by now, so raise an exception if found.
      Raise TTZException.CreateFmt('Year type not supported in line "%s"',[AIterator.CurrentLine]);
    end;
    //In month...
    TmpWord:=AIterator.GetNextWord;
    InMonth:=MonthNumberFromShortName(TmpWord);
    //On Rule...
    TmpWord:=AIterator.GetNextWord;
    if sizeOf(Onrule)<Length(TmpWord) then begin
      Raise TTZException.CreateFmt('ON Rule condition at "%s" too long. (Increase source code TZ_ONRULE_SIZE)',[AIterator.CurrentLine]);
    end;
    OnRule:=TmpWord;
    //AT field
    TmpWord:=AIterator.GetNextWord;
    StandardTimeFlag:=TmpWord[Length(TmpWord)];
    if StandardTimeFlag in ['s','u','g'] Then begin
      if StandardTimeFlag='s' then begin
        AtHourGMT:=false;
      end else begin
        AtHourGMT:=true;
      end;
      TmpWord:=Copy(TmpWord,1,Length(TmpWord)-1); //remove the standard time flag
    end;
    AtHourTime:=TimeToSeconds(TmpWord);
    //SAVE field
    TmpWord:=AIterator.GetNextWord;
    SaveTime:=TimeToSeconds(TmpWord);
    //LETTERS field
    TimeZoneLetters:=AIterator.GetNextWord;
    if TimeZoneLetters='-' Then TimeZoneLetters:='';
  end;
end;

function TPascalTZ.GetCountZones: Integer;
begin
  Result := Length(FZones);
end;

function TPascalTZ.GetCountRules: Integer;
begin
  Result := Length(FRules);
end;

procedure TPascalTZ.GetTimeZoneNames(const AZones: TStringList;
  const AOnlyGeoZones: Boolean);
var
  j: integer;
  LT: AsciiString;
begin
  AZones.Clear;
  LT:='';
  for j := 0 to High(FZones) do begin
    if FZones[j].Name<>LT Then begin
      LT:=FZones[j].Name;
      if AOnlyGeoZones then begin
        if Pos('/',LT)>0 then begin
          AZones.Add(LT);
        end;
      end else begin
        AZones.Add(LT);
      end;
    end;
  end;
end;

function TPascalTZ.TimeZoneExists(const AZone: String): Boolean;
var
  AZoneList: TStringList;
begin
  AZoneList := TStringList.Create;
  try
    GetTimeZoneNames(AZoneList, False);
    Result := (AZoneList.IndexOf(AZone) >= 0);
  finally
    AZoneList.Free;
  end;
end;

function TPascalTZ.GMTToLocalTime(const ADateTime: TDateTime; const AToZone: String): TDateTime;
var
  ATimeZoneSubFix: String; // dummy
begin
  Result := GMTToLocalTime(ADateTime, AToZone, ATimeZoneSubFix);
end;

function TPascalTZ.GMTToLocalTime(const ADateTime: TDateTime;
  const AToZone: String; out ATimeZoneSubFix: String): TDateTime;
var
  MilliSeconds: integer;
begin
  MilliSeconds:=MilliSecondOfTheSecond(ADateTime);
  Result:=TZDateToPascalDate(GMTToLocalTime(PascalDateToTZDate(ADateTime),AToZone,ATimeZoneSubFix));
  Result:=IncMilliSecond(Result,MilliSeconds);
end;

function TPascalTZ.GMTToLocalTime(const ADateTime: TTZDateTime;
  const AToZone: String; out ATimeZoneName: String): TTZDateTime;
var
  j: integer;
  ZoneIndex: integer;
  RuleIndex: integer;
  ApplyRuleName: AsciiString;
  RuleBeginDate,RuleEndDate: TTZDateTime;
  SaveTime: integer;
  RuleLetters: AsciiString;
  ZoneNameCut: integer;
begin
  //Find zone matching target...
  ZoneIndex:=FindZoneName(AToZone);
  // Now check which zone configuration line matches the given date.
  ZoneIndex:=FindZoneForDate(ZoneIndex,ADateTime);
  RuleIndex:=FZones[ZoneIndex].RuleIndex;
  if RuleIndex=-1 then begin
    //No rule is applied, so use the zone fixed offset
    Result:=ADateTime;
    inc(Result.SecsInDay,FZones[ZoneIndex].RuleFixedOffset+FZones[ZoneIndex].Offset);
    ATimeZoneName:=FZones[ZoneIndex].TimeZoneLetters;
    FixUpTime(Result);
    exit;
  end;
  //Now we have the valid rule index...
  ApplyRuleName:=FRules[RuleIndex].Name;
  j:=RuleIndex;
  SaveTime:=0;
  while (j<=High(FRules)) and (FRules[j].Name=ApplyRuleName) do begin
    if (ADateTime.Year>=FRules[j].FromYear) and (ADateTime.Year<=FRules[j].ToYear) then begin
      //The year is in the rule range, so discard year information...
      RuleBeginDate.Year:=ADateTime.Year;
      RuleBeginDate.Month:=FRules[j].InMonth;
      MacroSolver(RuleBeginDate,FRules[j].OnRule);
      RuleBeginDate.SecsInDay:=FRules[j].AtHourTime;

      RuleEndDate.Year:=ADateTime.Year;
      RuleEndDate.Month:=12;
      RuleEndDate.Day:=31;
      RuleEndDate.SecsInDay:=86400;

      if (CompareDates(ADateTime,RuleBeginDate)>-1) and
         (CompareDates(ADateTime,RuleEndDate)<1) then begin
        SaveTime:=FRules[j].SaveTime;
        RuleLetters:=FRules[j].TimeZoneLetters;
      end;
    end;
    inc(j);
  end;
  Result:=ADateTime;
  inc(Result.SecsInDay,SaveTime+FZones[ZoneIndex].Offset);
  ATimeZoneName:=format(FZones[ZoneIndex].TimeZoneLetters,[RuleLetters]);
  //When timezonename is XXX/YYY XXX is no daylight and YYY is daylight saving.
  ZoneNameCut:=Pos('/',ATimeZoneName);
  if ZoneNameCut>0 then begin
    if SaveTime=0 then begin
      //Use the XXX
      ATimeZoneName:=Copy(ATimeZoneName,1,ZoneNameCut-1);
    end else begin
      //Use the YYY
      ATimeZoneName:=Copy(ATimeZoneName,ZoneNameCut+1,Length(ATimeZoneName)-ZoneNameCut);
    end;
  end;
  FixUpTime(Result);
end;

function TPascalTZ.LocalTimeToGMT(const ADateTime: TDateTime;
  const AFromZone: String): TDateTime;
var
  MilliSeconds: integer;
begin
  MilliSeconds:=MilliSecondOfTheSecond(ADateTime);
  Result:=TZDateToPascalDate(LocalTimeToGMT(PascalDateToTZDate(ADateTime),AFromZone));
  Result:=IncMilliSecond(Result,MilliSeconds);
end;

function TPascalTZ.TimeZoneToTimeZone(const ADateTime: TDateTime; const AFromZone, AToZone: String): TDateTime;
var
  ATimeZoneSubFix: String; // dummy
begin
  Result := TimeZoneToTimeZone(ADateTime, AFromZone, AToZone, ATimeZoneSubFix);
end;

function TPascalTZ.TimeZoneToTimeZone(const ADateTime: TDateTime;
  const AFromZone, AToZone: String; out ATimeZoneSubFix: String
  ): TDateTime;
var
  Tmp: TTZDateTime;
begin
  Tmp:=PascalDateToTZDate(ADateTime);
  Tmp:=LocalTimeToGMT(Tmp,AFromZone);
  Tmp:=GMTToLocalTime(Tmp,AToZone,ATimeZoneSubFix);
  Result:=TZDateToPascalDate(Tmp);
end;

function TPascalTZ.LocalTimeToGMT(const ADateTime: TTZDateTime;
  const AFromZone: String): TTZDateTime;
var
  ZoneIndex,RuleIndex: integer;
  ApplyRuleName: AsciiString;
  RuleBeginDate,RuleEndDate: TTZDateTime;
  SaveTime: integer;
  j: integer;
begin
  //Find zone matching target...
  ZoneIndex:=FindZoneName(AFromZone);
  // Now check which zone configuration line matches the given date.
  ZoneIndex:=FindZoneForDate(ZoneIndex,ADateTime);
  RuleIndex:=FZones[ZoneIndex].RuleIndex;
  if RuleIndex=-1 then begin
    //No rule is applied, so use the zone fixed offset
    Result:=ADateTime;
    Dec(Result.SecsInDay,FZones[ZoneIndex].RuleFixedOffset+FZones[ZoneIndex].Offset);
    FixUpTime(Result);
    exit;
  end;
  //Now we have the valid rule index...
  ApplyRuleName:=FRules[RuleIndex].Name;
  j:=RuleIndex;
  SaveTime:=0;
  while (j<=High(FRules)) and (FRules[j].Name=ApplyRuleName) do begin
    if (ADateTime.Year>=FRules[j].FromYear) and (ADateTime.Year<=FRules[j].ToYear) then begin
      //The year is in the rule range, so discard year information...
      RuleBeginDate.Year:=ADateTime.Year;
      RuleBeginDate.Month:=FRules[j].InMonth;
      MacroSolver(RuleBeginDate,FRules[j].OnRule);
      RuleBeginDate.SecsInDay:=FRules[j].AtHourTime+FZones[ZoneIndex].Offset;

      RuleEndDate.Year:=ADateTime.Year;
      RuleEndDate.Month:=12;
      RuleEndDate.Day:=31;
      RuleEndDate.SecsInDay:=SecsPerDay;

      if (CompareDates(ADateTime,RuleBeginDate)>-1) and
         (CompareDates(ADateTime,RuleEndDate)<1) then begin
        SaveTime:=FRules[j].SaveTime;
      end;
    end;
    inc(j);
  end;
  Result:=ADateTime;
  Dec(Result.SecsInDay,SaveTime+FZones[ZoneIndex].Offset);
  FixUpTime(Result);
  if FDetectInvalidLocalTimes then begin
    //Applyrulename here is a dummy variable
    if CompareDates(ADateTime,GMTToLocalTime(Result,AFromZone,ApplyRuleName))<>0 then begin
      Raise TTZException.CreateFmt('The time %s does not exists in %s',[DateTimeToStr(ADateTime),AFromZone]);
    end;
  end;
end;

function TPascalTZ.ParseDatabaseFromFile(const AFileName: String): Boolean;
var
  FileStream: TFileStream;
begin
  CheckCanLoadDatabase;
  FileStream:=TFileStream.Create(AFileName,fmOpenRead or fmShareDenyWrite);
  try
    Result:=ParseDatabaseFromStream(FileStream);
  finally
    FileStream.Free;
  end;
end;

function TPascalTZ.ParseDatabaseFromFiles(const AFileNames: array of String): Boolean;
var
  ADatabaseStream: TStringStream;
  AFileStream: TFileStream;
  AFileName: String;
begin
  CheckCanLoadDatabase;
  ADatabaseStream := TStringStream.Create('');
  try
    for AFileName in AFileNames do
    begin
      AFileStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
      try
        ADatabaseStream.CopyFrom(AFileStream, AFileStream.Size);
        ADatabaseStream.WriteString(LineEnding + LineEnding);
      finally
        AFileStream.Free;
      end;
    end;
    ADatabaseStream.Position := 0;
    Result := ParseDatabaseFromStream(ADatabaseStream);
  finally
    ADatabaseStream.Free;
  end;
end;

procedure TPascalTZ.CheckCanLoadDatabase;
begin
  // TPascalTZ class was not designed to load more than one database file.
  // Loading more than once messes up evaluation/application of timezones,
  // so forbid it until this problem is fixed.
  if FDatabaseLoaded then
    raise TTZException.Create('Cannot load timezone database, it is already loaded');
end;

function TPascalTZ.ParseDatabaseFromStream(const AStream: TStream): Boolean;
var
  Buffer: PChar;
  FileSize: integer;
  LineBegin: integer;
  LineSize: integer;
  ThisLine: AsciiString;
  ParseSequence: TParseSequence;
begin
  CheckCanLoadDatabase;
  FDatabaseLoaded := True;

  FileSize:=AStream.Size;
  Buffer:=nil;
  GetMem(Buffer,FileSize);
  if not Assigned(Buffer) Then begin
    raise EOutOfMemory.Create(SErrOutOfMemory);
  end;
  try
    if AStream.Read(Buffer^,FileSize)<>FileSize then begin
      Raise EStreamError.Create('Stream read error');
    end;
    ParseSequence:=TTzParseRule;
    while ParseSequence<TTzParseFinish do begin
      FLineCounter:=1;
      LineBegin:=0;
      LineSize:=0;
      while LineBegin<FileSize do begin
        if (Buffer[LineBegin+LineSize]=#13) or (Buffer[LineBegin+LineSize]=#10) then begin
          SetLength(ThisLine,LineSize);
          Move(Buffer[LineBegin],ThisLine[1],LineSize);
          ParseLine(ThisLine,ParseSequence);
          inc(LineBegin,LineSize);
          LineSize:=0;
          while (LineBegin<FileSize) and ((Buffer[LineBegin]=#13) or (Buffer[LineBegin]=#10)) do begin
            if Buffer[LineBegin]=#10 then begin
              inc(FLineCounter);
            end;
            inc(LineBegin);
          end;
        end else begin
          inc(LineSize);
        end;
      end;
      if LineSize>0 then begin
        inc(FLineCounter);
        SetLength(ThisLine,LineSize);
        Move(Buffer[LineBegin],ThisLine[1],LineSize);
        ParseLine(ThisLine,ParseSequence);
      end;
      if ParseSequence=TTzParseRule then begin
        //Sort the rules...
        SortRules();
      end;
      ParseSequence:=Succ(ParseSequence);
    end;
    Result:=true;
  finally
    FreeMem(Buffer);
  end;
end;

constructor TPascalTZ.Create;
begin
  FDetectInvalidLocalTimes := True;
  FDatabaseLoaded := False;
end;

end.

