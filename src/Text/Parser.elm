module Text.Parser exposing
    ( narrowWith, parse
    , text, caseAny
    , int, number
    , line, lineEnd, lineBeginning
    , split, splitIncluding
    )

{-| Parsing text

@docs narrowWith, parse


## match

@docs text, caseAny


## numbers

@docs int, number


## lines

@docs line, lineEnd, lineBeginning


## splitting

@docs split, splitIncluding

Feeling motivated? implement & PR

  - date, time, datetime
  - email
  - unixPath, windowsPath
  - uri
  - IPv4, IPv6
  - int2 (bin), int8 (oct), int6 (hex)

-}

import Char.Parser as Char exposing (digit, letter)
import Parser exposing (Parser, andThen, atLeast, atom, atomAny, beginning, between, end, exactly, except, expected, expecting, followedBy, map, notFollowedBy, oneOf, sequence, succeed, take, until)


{-| Parse an input text, and get either an [`Error`](#Error)
or the parsed value as a result.

    import Char.Parser as Char
    import Text.Parser exposing (number)
    import Parser.Error

    -- Consumes a single letter, then "bc" are still remaining.
    parse "abc" Char.letter --> Ok 'a'

    -- We can also parse text into other data types like numbers.
    parse "3.14" number --> Ok 3.14

    -- We get an error message if the parser doesn't match.
    Char.letter
        |> parse "123"
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:1: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '1'."

[`narrowWith`](#narrowWith) is the more general version.

-}
parse :
    String
    -> Parser Char narrow
    -> Result (Parser.Error Char) narrow
parse input =
    \parser ->
        input |> narrowWith parser


{-| Parse an input, and get either an [`Error`](#Error)
or a narrow value as a `Result`.

[`parse`](#parse) is a version that specifically parses `String`s.

-}
narrowWith :
    Parser Char narrow
    -> String
    -> Result (Parser.Error Char) narrow
narrowWith parser =
    \input ->
        input |> String.toList |> Parser.narrowWith parser


{-| Matches a specific text string.
This is case sensitive.

    import Parser exposing (parse)

    -- Match an exact text, case sensitive.
    parse "abcdef" (text "abc") --> Ok "abc"

    -- But anything else makes it fail.
    import Parser.Error

    text "abc"
        |> parse "abCDEF"
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:3: I was expecting the text 'abc'. I got stuck when I got the character 'C'."

-}
text : String -> Parser Char String
text expectedText =
    sequence (List.map atom (expectedText |> String.toList))
        |> map String.fromList
        |> expecting
            ([ "the text \"", expectedText, "\"" ]
                |> String.concat
            )


{-| Matches a specific text string.
This is case insensitive.

    import Parser exposing (parse)
    import Parser.Error

    parse "aBcdef" (Text.caseAny "abC") --> Ok "aBc"

    Text.caseAny "abc"
        |> parse "ab@"
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:3: I was expecting the text \"abc\" (case insensitive). I got stuck when I got the character '@'."

-}
caseAny : String -> Parser Char String
caseAny expectedText =
    sequence (List.map Char.caseAny (expectedText |> String.toList))
        |> map String.fromList
        |> expecting
            ([ "the text \"", expectedText, "\" (case insensitive)" ]
                |> String.concat
            )


{-| Matches a line from the input text, delimited by `'\\n'`.

    import Parser exposing (parse, atLeast)
    import Parser.Error

    -- A line could be delimited by the newline character '\n'.
    parse "abc\ndef" line --> Ok "abc"

    -- Or this could also be the last line.
    parse "abc" line --> Ok "abc"

    -- An empty line still counts.
    parse "\n" line --> Ok ""

    -- But not an empty file.
    line
        |> parse ""
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:0: I was expecting a line. I reached the end of the input."

    -- So we can parse multiple lines.
    atLeast 0 line
        |> parse "abc\ndef\nghi"
    --> Ok [ "abc", "def", "ghi"]

-}
line : Parser Char String
line =
    oneOf
        [ until lineEnd atomAny
            |> map .before
            |> map String.fromList
        , map (\_ -> "") (expected "a line")
        ]


{-| Matches an integer value as an `Int`.

    import Parser exposing (parse)
    import Parser.Error

    -- You can parse integers as `Int` instead of `String`.
    parse "123" int --> Ok 123

    -- It also works with negative numbers.
    parse "-123" int --> Ok -123

    -- A decimal number is _not_ an integer :)
    parse "3.14" int
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:2: I was expecting an integer value. I got stuck when I got the character '.'."

    -- But not with invalid numbers.
    parse "abc" int
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:1: I was expecting an integer value. I got stuck when I got the character 'a'."

-}
int : Parser Char Int
int =
    sequence
        [ between 0 1 (atom '-')
        , atLeast 1 digit
        ]
        |> map List.concat
        |> notFollowedBy (atom '.')
        |> map String.fromList
        |> andThen
            (\intString ->
                case intString |> String.toInt of
                    Just intNarrow ->
                        intNarrow |> succeed

                    Nothing ->
                        expected ("an integer" ++ intString)
            )
        |> expecting "an integer value"


{-| Matches a decimal value as a `Float`.

    import Parser exposing (parse)
    import Parser.Error

    number |> parse "12" --> Ok 12.0
    number |> parse "12.34" --> Ok 12.34
    number |> parse "12." --> Ok 12.0
    number |> parse ".12" --> Ok 0.12
    number |> parse "-12.34" --> Ok -12.34
    number |> parse "-.12" --> Ok -0.12

    parse "." number
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:1: I was expecting a digit [0-9]. I got stuck when I got the character '.'."

    parse "abc" number
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:1: I was expecting a digit [0-9]. I got stuck when I got the character 'a'."

-}
number : Parser Char Float
number =
    sequence
        [ between 0 1 (oneOf [ atom '-', atom '+' ])
        , oneOf
            [ sequence
                [ exactly 1 (atom '.')
                , atLeast 1 digit
                ]
                |> map List.concat
            , sequence
                [ atLeast 1 digit
                , between 0 1 (atom '.')
                , atLeast 0 digit
                ]
                |> map List.concat
            ]
        ]
        |> map List.concat
        |> map String.fromList
        |> andThen
            (\floatString ->
                case floatString |> String.toFloat of
                    Just float ->
                        succeed float

                    -- not expected
                    Nothing ->
                        expected ("Failed to parse number from \"" ++ floatString ++ "\"")
            )


{-| Succeeds only the parser is at the end of the current line or there are
no more remaining characters in the input text.
This does not consume any inputs.

> ℹ️ Equivalent regular expression: `$`

    import Parser exposing (parse, map, followedBy, atLeast)
    import Char.Parser as Char
    import Text.Parser exposing (line)
    import Parser.Error

    atLeast 1 Char.letter
        |> map String.fromList
        |> followedBy lineEnd
        |> parse "abc\n123"
    --> Ok "abc"

    -- carriage return also counts
    atLeast 1 Char.letter
        |> map String.fromList
        |> followedBy lineEnd
        |> parse "abc\r123"
    --> Ok "abc"

    -- end of file also counts
    atLeast 1 Char.letter
        |> map String.fromList
        |> followedBy lineEnd
        |> parse "abc"
    --> Ok "abc"

    -- fail otherwise
    atLeast 1 Char.letter
        |> map String.fromList
        |> followedBy lineEnd
        |> parse "abc123"
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:4: I was expecting the end of the current line. I got stuck when I got the character '1'."

-}
lineEnd : Parser Char ()
lineEnd =
    { parse =
        \state ->
            case atomAny.parse state of
                Err _ ->
                    (succeed ()).parse state

                Ok parsed ->
                    case parsed.narrow of
                        '\n' ->
                            (succeed ()).parse parsed.state

                        -- Carriage return '\r'
                        '\u{000D}' ->
                            (succeed ()).parse parsed.state

                        _ ->
                            (expected "the end of the current line").parse parsed.state
    }


{-| Succeeds only the parser is at the beginning of a new line or
at the beginning of the input text.
This does not consume any inputs.

> ℹ️ Equivalent regular expression: `^`

    import Parser exposing (parse, andThen, followedBy, atomAny)
    import Char.Parser as Char
    import Text.Parser exposing (line)
    import Parser.Error

    -- Succeed at the beginning of the file.
    lineBeginning
        |> andThen (\_ -> line)
        |> parse "abc\n123"
    --> Ok "abc"

    -- The end of file also counts.
    line
        |> followedBy lineBeginning
        |> andThen (\_ -> line)
        |> parse "abc\n123"
    --> Ok "123"

    -- But fail otherwise
    singleAny
        |> followedBy lineBeginning
        |> parse "abc"
        |> Result.mapError Parser.Error.textMessage
    --> Err "1:2: I was expecting the beginning of a line. I got stuck when I got the character 'b'."

TODO: not make lookbehind

-}
lineBeginning : Parser Char ()
lineBeginning =
    { parse =
        \state ->
            case state.lastInput of
                Nothing ->
                    (succeed ()).parse state

                Just '\n' ->
                    (succeed ()).parse state

                -- Carriage return '\r'
                Just '\u{000D}' ->
                    (succeed ()).parse state

                Just _ ->
                    (atomAny
                        |> map (\_ -> ())
                        |> (\_ -> expected "the beginning of a line")
                    ).parse
                        state
    }



-- split


{-| Splits the input text by a _separator_ parser into a `List` of `String`s.
The separators cannot overlap, and are discarded after being matched.

    import Parser exposing (parse, atom)

    -- Split Comma-Separated-Values (CSV) into a `List` of `String`s.
    split (atom ',')
        |> parse "a,bc,def"
    --> Ok [ "a", "bc", "def" ]

    -- Leading/trailing separators are valid and give empty values.
    split (atom ',')
        |> parse ",a,,"
    --> Ok [ "", "a", "", "" ]

    -- An empty input text gives a single empty string element.
    split (atom ',')
        |> parse ""
    --> Ok [ "" ]

TODO: check if API can be rewritten

-}
split : Parser Char separator_ -> Parser Char (List String)
split separator =
    succeed (\beforeLast last -> beforeLast ++ [ last ])
        |> take
            -- 0 or more values pairs delimited by the separator.
            (atLeast 0
                (until separator atomAny
                    |> map .before
                    |> map String.fromList
                )
            )
        |> take
            -- last value with whatever is left
            (atLeast 0 atomAny |> map String.fromList)


{-| Splits the input text by a _separator_ parser into a `List` of `String`s.
The separators cannot overlap,
and are interleaved alongside the values in the order found.

    import Parser exposing (map, parse)
    import Text.Parser exposing (text)

    type Token
        = Separator
        | Value String

    -- Note that both values and separators must be of the same type.
    splitIncluding (text "," |> map (\_ -> Separator)) Value
        |> parse "a,bc,def"
    --> Ok [ Value "a", Separator, Value "bc", Separator, Value "def" ]

    -- Leading/trailing separators are valid and give empty values.
    splitIncluding (text "," |> map (\_ -> Separator)) Value
        |> parse ",a,,"
    --> Ok [ Value "", Separator, Value "a", Separator, Value "", Separator, Value "" ]

    -- An empty input text gives a single element from an empty string.
    splitIncluding (text "," |> map (\_ -> Separator)) Value
        |> parse ""
    --> Ok [ Value "" ]

TODO: check if API can be rewritten

-}
splitIncluding :
    Parser Char separator
    -> (String -> separator)
    -> Parser Char (List separator)
splitIncluding separator f =
    succeed (\before last -> before ++ [ last ])
        |> take
            -- Zero or more value-separator pairs
            (atLeast 0
                (until separator atomAny
                    |> map
                        (\narrow ->
                            [ f (narrow.before |> String.fromList), narrow.delimiter ]
                        )
                )
                |> map List.concat
            )
        |> take
            -- Last value with whatever is left
            (atLeast 0 atomAny
                |> map (\last -> last |> String.fromList |> f)
            )