module MorphRow.Error exposing
    ( describe
    , LinesLocation, downToUpIn, downToUpInLine, downToUpInLines
    )

{-| Error reporting

@docs describe


## offset

@docs LinesLocation, downToUpIn, downToUpInLine, downToUpInLines

-}

import Hand exposing (Empty, Hand)
import Morph
import MorphRow
import Possibly exposing (Possibly)
import RecordWithoutConstructorFunction exposing (RecordWithoutConstructorFunction)
import Stack exposing (Stacked)


{-| Position withing multiple lines.
-}
type alias LinesLocation =
    RecordWithoutConstructorFunction
        { line : Int
        , column : Int
        }


{-| How far parsing got from the beginning of an input source.

  - 0 for before the first input atom
  - 1 for the first input atom
  - input-length for the last input atom

Use [`downToUpInLine`](#downToUpInLine) for `String` inputs.

-}
downToUpIn : Hand (Stacked atom_) Possibly Empty -> Int -> Int
downToUpIn inputSource =
    \fromLast ->
        1
            + ((inputSource |> Stack.length) - 1)
            - fromLast


{-| How far parsing got from the beginning of input source lines.
-}
downToUpInLines : String -> Int -> LinesLocation
downToUpInLines source =
    \offset ->
        source
            |> String.lines
            |> List.foldl
                (\line locationOrSoFar ->
                    case locationOrSoFar of
                        Ok location ->
                            location |> Ok

                        Err soFar ->
                            let
                                nextOffset =
                                    soFar.offset + (line |> String.length)
                            in
                            if nextOffset > offset then
                                { column = soFar.column, line = offset - nextOffset } |> Ok

                            else
                                Err { column = soFar.column + 1, offset = nextOffset }
                )
                (Err { column = 1, offset = 1 })
            |> -- meh
               Result.withDefault { line = 0, column = 0 }


{-| How far parsing got from the beginning of an input source `String`.

Use [`downToUpIn`](#downToUpIn) for any `List` inputs.

-}
downToUpInLine : String -> Int -> Int
downToUpInLine inputSource =
    downToUpIn (inputSource |> Stack.fromString)


{-| Present the `TextLocation` as `"line:column"`, for example

    { line = 3, column = 10 } |> locationToString
    --> "line 3)10"

-}
locationToString : LinesLocation -> String
locationToString =
    \location ->
        [ "line "
        , location.line |> String.fromInt
        , ")"
        , location.column |> String.fromInt
        ]
            |> String.concat


expectationMissDescribe :
    { source : String }
    -> MorphRow.SuccessExpectation Char String
    -> List String
expectationMissDescribe { source } =
    \expectationMiss ->
        [ case expectationMiss.startingAtDown of
            0 ->
                [ expectationMiss.expected |> expectedDescribe { source = source }
                , [ "but nothing's left to parse" ]
                ]
                    |> List.concat

            stuckAtDown ->
                let
                    stuckAt =
                        stuckAtDown |> downToUpInLine source
                in
                [ [ (stuckAt |> downToUpInLines source |> locationToString) ++ ":" ]
                , expectationMiss.expected |> expectedDescribe { source = source }
                ]
                    |> List.concat
        , [ expectationMiss.expected |> expectedDescribe { source = source }
          , [ [ "starting at "
              , (source |> String.length)
                    - expectationMiss.startingAtDown
                    |> downToUpInLines source
                    |> locationToString
              ]
                |> String.concat
            ]
          ]
            |> List.concat
        , let
            errorOffset =
                expectationMiss.startingAtDown |> downToUpInLine source

            errorLocation =
                errorOffset |> downToUpInLines source

            rangeStart =
                (errorOffset - expectationMiss.startingAtDown)
                    |> downToUpInLines source

            lineNumberWidth =
                max
                    (rangeStart.line |> String.fromInt |> String.length)
                    (errorLocation.line |> String.fromInt |> String.length)

            sourceSnippet =
                source
                    |> String.lines
                    |> List.drop (rangeStart.line - 1)
                    |> List.take (errorLocation.line - rangeStart.line + 1)
                    |> List.indexedMap
                        (\i ln ->
                            [ String.padLeft lineNumberWidth
                                ' '
                                (String.fromInt (rangeStart.line + i))
                            , "|"
                            , ln
                            ]
                                |> String.concat
                        )

            underline =
                [ String.repeat lineNumberWidth " "
                , if rangeStart.line == errorLocation.line then
                    [ String.repeat rangeStart.column " "
                    , String.repeat (errorLocation.column - rangeStart.column) "~"
                    ]
                        |> String.concat

                  else
                    [ "+"
                    , String.repeat (errorLocation.column - 1) "~"
                    ]
                        |> String.concat
                , "^"
                ]
                    |> String.concat
          in
          sourceSnippet ++ [ underline ]
        ]
            |> List.concat


{-| Dumps the error into a human-readable format.

    import MorphRow exposing (MorphRow, take, drop, into, succeed, atLeast, atom, take)
    import Morph.CharRow as Char
    import Morph.TextRow as Text

    "  abc  "
        |> Text.narrowWith
            (succeed (\number -> number)
                |> grab (atLeast 0 Char.blank)
                |> skip Text.number
            )
        |> Result.mapError (dump "filename.txt")
    --> Err
    -->     [ "[ERROR] filename.txt:1:3: I was expecting a digit [0-9]. I got stuck when I got the character 'a'."
    -->     , ""
    -->     , "1|  abc  "
    -->     , "    ^"
    -->     ]


    type alias Point =
        { x : Float
        , y : Float
        }

    point : MorphRow Point
    point =
        into "Point"
            (succeed Point
                |> skip (atom '(')
                |> grab Text.number
                |> skip (atom ',')
                |> grab Text.number
                |> skip (atom ')')
            )

    "  (12,)  "
        |> Text.narrowWith
            (succeed (\point -> point)
                |> skip (atLeast 0 Char.blank)
                |> grab point
            )
        |> Result.mapError (dump "filename.txt")
    --> Err
    -->     [ "[ERROR] filename.txt:1:7: I was expecting a digit [0-9]. I got stuck when I got the character ')'."
    -->     , "  in Point at line 1:3"
    -->     , ""
    -->     , "1|  (12,)  "
    -->     , "    ~~~~^"
    -->     ]

    type alias Line =
        { p1 : Point
        , p2 : Point
        }

    line : MorphRow Line
    line =
        into "Line"
            (succeed (\p1 p2 -> { p1 = p1, p2 = p2 })
                |> skip (atom '[')
                |> grab point
                |> skip (atom ',')
                |> grab point
                |> skip (atom ']')
            )

    "  [(12,34),(56,)]  "
        |> Text.narrowWith
            (succeed (\line -> line)
                |> skip (atLeast 0 Char.blank)
                |> grab line
            )
        |> Result.mapError (dump { source = "  [(12,34),(56,)]  " })
    --> Err
    -->     [ "I was expecting a digit [0-9]. I got stuck when I got the character ')'."
    -->     , "  in Point at line 1:12"
    -->     , "  in Line at line 1:3"
    -->     , ""
    -->     , "1|  [(12,34),(56,)]  "
    -->     , "             ~~~~^"
    -->     ]

    import MorphRow exposing (MorphRow, drop, into, succeed, atLeast, take, atom)
    import Morph.CharRow exposing (blank)
    import Morph.TextRow exposing (number)

    type alias Point =
        { x : Float
        , y : Float
        }

    point : MorphRow Point
    point =
        into "Point"
            (succeed (\x y -> { x = x, y = y })
                |> skip (atom '(')
                |> skip (atLeast 0 blank)
                |> grab number
                |> skip (atLeast 0 blank)
                |> skip (atom ',')
                |> skip (atLeast 0 blank)
                |> grab number
                |> skip (atLeast 0 blank)
                |> skip (atom ')')
            )

    "  (12,)  "
        |> Text.narrowWith
            (succeed (\point -> point)
                |> skip (atLeast 0 Char.blank)
                |> grab point
            )
        |> Result.mapError dumpCodeSnippet
    --> Err
    -->     [ "1|  (12,)  "
    -->     , "    ~~~~^"
    -->     ]

    String.join "\n"
        [ "  "
        , "  (  "
        , "  12  "
        , "  ,  "
        , "  )  "
        , "  "
        ]
        |> Text.narrowWith
            (succeed (\point -> point)
                |> skip (atLeast 0 Char.blank)
                |> grab point
            )
        |> Result.mapError dumpCodeSnippet
    --> Err
    -->     [ "2|  (  "
    -->     , "3|  12  "
    -->     , "4|  ,  "
    -->     , "5|  )  "
    -->     , " +~~^"
    -->     ]

-}
describe :
    { source : String }
    -> MorphRow.Error Char narrow_ String
    -> List String
describe { source } =
    \error ->
        case error of
            Morph.Expected (MorphRow.NoMoreInputRemaining remaining) ->
                [ [ [ remaining.remainingAtomCount
                        |> Stack.length
                        |> downToUpInLines source
                        |> locationToString
                    , ": I was done parsing but something's still left:\n"
                    ]
                        |> String.concat
                  ]
                , ((remaining.remainingAtomCount
                        |> Stack.toList
                        |> String.fromList
                        |> String.left 100
                   )
                    ++ "...\""
                  )
                    |> String.lines
                    |> List.map (\line -> "    " ++ line)
                , [ "Correct or remove that part, then try again" ]
                ]
                    |> List.concat

            Morph.Expected (MorphRow.Success expectationMiss) ->
                [ [ "I was expecting" ]
                , expectationMiss |> expectationMissDescribe { source = source }
                ]
                    |> List.concat


{-| Create an [`Error`](MorphRow#Error) message.

TODO: update examples

    import MorphRow
    import Morph.TextRow as Text
    import Morph.CharRow exposing (letter)

    -- Getting a digit instead of a letter.
    "123"
        |> Text.narrowWith letter
        |> Result.mapError
            (expectationMissMessage { source = "123" })
    --> Err "1:1: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '1'."

    -- Running out of input characters.
    ""
        |> Text.narrowWith letter
        |> Result.mapError
            (expectationMissMessage { source = "" })
    --> Err "1:0: I was expecting a letter [a-zA-Z]. I reached the end of the input."

-}
expectedDescribe :
    { source : String }
    -> Morph.ExpectationWith { startingAtDown : Int } Char String
    -> List String
expectedDescribe source =
    \expected ->
        case expected of
            Morph.NoFail ->
                []

            Morph.MoreInput ->
                [ "more input" ]

            Morph.NoMoreInput ->
                [ "no more input" ]

            Morph.Specific atomSpecific ->
                [ atomSpecific |> String.fromChar ]

            Morph.OneIn possibilities ->
                [ [ "either" ]
                , possibilities
                    |> Stack.map
                        (\_ possibilityExpectation ->
                            case possibilityExpectation |> expectationMissDescribe source of
                                [] ->
                                    Hand.empty

                                possibilityLine0 :: possibilityLines1Up ->
                                    Stack.topDown
                                        ("\n  - " ++ possibilityLine0)
                                        (possibilityLines1Up
                                            |> List.map (\possibilityLine -> "    " ++ possibilityLine)
                                        )
                        )
                    |> Stack.flatten
                    |> Stack.toList
                ]
                    |> List.concat
