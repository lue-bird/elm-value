module Morph.Test exposing (tests)

import AToZ exposing (AToZ)
import ArraySized exposing (ArraySized)
import ArraySized.Morph exposing (atLeast)
import Char.Morph
import Decimal exposing (Decimal)
import Expect
import Linear exposing (Direction(..))
import Morph exposing (Morph, MorphRow, MorphRowIndependently, broad, broadenFrom, grab, narrowTo, one, match, translate)
import N exposing (In, Min, N, N0, N1, N2, N9, On, n0, n1, n9)
import N.Morph
import RecordWithoutConstructorFunction exposing (RecordWithoutConstructorFunction)
import Stack
import Stack.Morph
import String.Morph
import Test exposing (Test, test)


tests : Test
tests =
    Test.describe
        "Morph to row"
        [ pointTest
        , emailTest
        ]



-- point


pointTest : Test
pointTest =
    Test.describe "point"
        [ test "fail"
            (\() ->
                Expect.fail """
What could have gone wrong in case of an overflow?

Maybe the lossy conversion
hasn't been set up properly (see DecimalOrException.float).

Another option is a potentially missed chance to do TCO.
This could have happened in many places, maybe because `|>` is used.
"""
            )
        , test "narrowTo |> broadenFrom"
            (\() ->
                let
                    narrowResult =
                        "(3.00,  -9999.1240)"
                            |> narrowTo
                                (point
                                    |> Morph.rowFinish
                                    |> Morph.over Stack.Morph.string
                                )
                in
                case narrowResult of
                    Err error ->
                        error
                            |> Morph.errorToLines
                            |> Stack.foldFrom "" Up (\line soFar -> soFar ++ "\n" ++ line)
                            |> Expect.fail

                    Ok narrow ->
                        narrow
                            |> broadenFrom
                                (point
                                    |> Morph.rowFinish
                                    |> Morph.over Stack.Morph.string
                                )
                            |> Expect.equal "( 3., -9999.124 )"
            )
        ]


point : MorphRow Point Char
point =
    Morph.succeed (\x y -> { x = x, y = y })
        |> match (String.Morph.only "(")
        |> match
            (broad (ArraySized.one () |> ArraySized.minTo n0)
                |> Morph.overRow (atLeast (String.Morph.only " ") n0)
            )
        |> grab .x Decimal.chars
        |> match
            (broad ArraySized.empty
                |> Morph.overRow (atLeast (String.Morph.only " ") n0)
            )
        |> match (String.Morph.only ",")
        |> match
            (broad (ArraySized.one () |> ArraySized.minTo n0)
                |> Morph.overRow (atLeast (String.Morph.only " ") n0)
            )
        |> grab .y Decimal.chars
        |> match
            (broad (ArraySized.one () |> ArraySized.minTo n0)
                |> Morph.overRow (atLeast (String.Morph.only " ") n0)
            )
        |> match (String.Morph.only ")")


emailTest : Test
emailTest =
    let
        emailToText =
            email |> Morph.rowFinish |> Morph.over Stack.Morph.string
    in
    Test.describe
        "email"
        [ Test.describe
            "valid"
            ([ """simple@example.com"""
             , """very.common@example.com"""
             , """other.email-with-hyphen@example.com"""
             , """fully-qualified-domain@example.com"""
             , -- one-letter local-part
               """x@example.com"""
             , """example-indeed@strange-example.com"""
             , -- slashes are an allowed printable character
               """test/test@test.com"""
             , -- local domain name with no TLD, although ICANN highly discourages dotless email addresses
               """admin@mailserver1"""
             , """example@s.example"""
             , """user-@example.org"""
             ]
                |> List.map
                    (\exampleEmail ->
                        test
                            exampleEmail
                            (\() ->
                                case exampleEmail |> narrowTo emailToText of
                                    Ok emailParsed ->
                                        emailParsed
                                            |> broadenFrom emailToText
                                            |> Expect.equal exampleEmail

                                    Err _ ->
                                        Expect.pass
                            )
                    )
            )
        , Test.describe
            "invalid"
            ([ -- no @ character
               """Abc.example.com"""
             , -- only one @ is allowed
               """A@b@c@example.com"""
             , -- Underscore is not allowed in domain part
               """i_like_underscore@but_its_not_allowed_in_this_part.example.com"""
             , """QA[icon]CHOCOLATE[icon]@test.com"""
             ]
                |> List.map
                    (\exampleEmail ->
                        test
                            exampleEmail
                            (\() ->
                                case exampleEmail |> narrowTo emailToText of
                                    Ok _ ->
                                        Expect.fail exampleEmail

                                    Err _ ->
                                        Expect.pass
                            )
                    )
            )
        ]



-- email
-- format as described in https://en.wikipedia.org/wiki/Email_address


email : MorphRow Email Char
email =
    Morph.succeed
        (\local_ domain_ ->
            { local = local_
            , domain = domain_
            }
        )
        |> grab .local local
        |> match (String.Morph.only "@")
        |> grab .domain domain


local : MorphRow Local Char
local =
    Morph.succeed
        (\first afterFirst ->
            ArraySized.one first
                |> ArraySized.attachMin Up
                    (afterFirst |> ArraySized.minTo n1)
        )
        |> grab (ArraySized.element ( Up, n0 )) localPart
        |> grab (ArraySized.removeMin ( Up, n0 ))
            (atLeast
                (Morph.succeed (\part -> part)
                    |> match (String.Morph.only ".")
                    |> grab (\part -> part) localPart
                )
                n1
            )


localPart :
    MorphRowIndependently
        (ArraySized LocalSymbol (In (On N1) max_))
        LocalPart
        Char
localPart =
    atLeast (localSymbol |> one) n1


localSymbol : Morph LocalSymbol Char
localSymbol =
    Morph.choice
        (\printableVariant aToZVariant n0To9Variant localSymbolUnion ->
            case localSymbolUnion of
                LocalSymbolPrintable printableValue ->
                    printableVariant printableValue

                LocalSymbolAToZ aToZValue ->
                    aToZVariant aToZValue

                LocalSymbol0To9 n0To9Value ->
                    n0To9Variant n0To9Value
        )
        |> Morph.try LocalSymbolPrintable
            localSymbolPrintable
        |> Morph.try LocalSymbolAToZ
            (translate .letter
                (\letter -> { letter = letter, case_ = AToZ.CaseLower })
                |> Morph.over AToZ.char
            )
        |> Morph.try LocalSymbol0To9
            (N.Morph.in_ ( n0, n9 )
                |> Morph.over N.Morph.char
            )
        |> Morph.choiceFinish



-- local


localSymbolPrintable : Morph LocalSymbolPrintable Char
localSymbolPrintable =
    Morph.choice
        (\exclamationMark numberSign dollarSign percentSign ampersand asterisk lowLine hyphenMinus tilde verticalLine plusSign equalsSign graveAccent leftCurlyBracket rightCurlyBracket localSymbolPrintableNarrow ->
            case localSymbolPrintableNarrow of
                ExclamationMark ->
                    exclamationMark ()

                NumberSign ->
                    numberSign ()

                DollarSign ->
                    dollarSign ()

                PercentSign ->
                    percentSign ()

                Ampersand ->
                    ampersand ()

                Asterisk ->
                    asterisk ()

                LowLine ->
                    lowLine ()

                HyphenMinus ->
                    hyphenMinus ()

                Tilde ->
                    tilde ()

                VerticalLine ->
                    verticalLine ()

                PlusSign ->
                    plusSign ()

                EqualsSign ->
                    equalsSign ()

                GraveAccent ->
                    graveAccent ()

                LeftCurlyBracket ->
                    leftCurlyBracket ()

                RightCurlyBracket ->
                    rightCurlyBracket ()
        )
        |> Morph.try (\() -> ExclamationMark) (Char.Morph.only '!')
        |> Morph.try (\() -> NumberSign) (Char.Morph.only '#')
        |> Morph.try (\() -> DollarSign) (Char.Morph.only '$')
        |> Morph.try (\() -> PercentSign) (Char.Morph.only '%')
        |> Morph.try (\() -> Ampersand) (Char.Morph.only '&')
        |> Morph.try (\() -> Asterisk) (Char.Morph.only '*')
        |> Morph.try (\() -> LowLine) (Char.Morph.only '_')
        |> Morph.try (\() -> HyphenMinus) (Char.Morph.only '-')
        |> Morph.try (\() -> Tilde) (Char.Morph.only '~')
        |> Morph.try (\() -> VerticalLine) (Char.Morph.only '|')
        |> Morph.try (\() -> PlusSign) (Char.Morph.only '+')
        |> Morph.try (\() -> EqualsSign) (Char.Morph.only '=')
        |> Morph.try (\() -> GraveAccent) (Char.Morph.only '`')
        |> Morph.try (\() -> LeftCurlyBracket) (Char.Morph.only '{')
        |> Morph.try (\() -> RightCurlyBracket) (Char.Morph.only '}')
        |> Morph.choiceFinish


domain : MorphRow Domain Char
domain =
    Morph.succeed
        (\first hostLabels topLevel ->
            { first = first, hostLabels = hostLabels, topLevel = topLevel }
        )
        |> Morph.grab .first hostLabel
        |> Morph.match (String.Morph.only ".")
        |> Morph.grab .hostLabels
            (atLeast
                (Morph.succeed (\label -> label)
                    |> Morph.grab (\label -> label) hostLabel
                    |> Morph.match (String.Morph.only ".")
                )
                n0
            )
        |> Morph.grab .topLevel domainTopLevel


hostLabel : MorphRow HostLabel Char
hostLabel =
    Morph.succeed
        (\firstSymbol betweenFirstAndLastSymbols lastSymbol ->
            { firstSymbol = firstSymbol
            , betweenFirstAndLastSymbols = betweenFirstAndLastSymbols
            , lastSymbol = lastSymbol
            }
        )
        |> grab .firstSymbol
            (hostLabelSideSymbol |> one)
        |> grab .betweenFirstAndLastSymbols
            (atLeast (hostLabelSymbol |> one) n0)
        |> grab .lastSymbol
            (hostLabelSideSymbol |> one)


hostLabelSideSymbol : Morph HostLabelSideSymbol Char
hostLabelSideSymbol =
    Morph.choice
        (\aToZVariant n0To9Variant sideSymbol ->
            case sideSymbol of
                HostLabelSideSymbolAToZ aToZValue ->
                    aToZVariant aToZValue

                HostLabelSideSymbol0To9 n0To9Value ->
                    n0To9Variant n0To9Value
        )
        |> Morph.try HostLabelSideSymbolAToZ
            AToZ.char
        |> Morph.try HostLabelSideSymbol0To9
            (N.Morph.in_ ( n0, n9 )
                |> Morph.over N.Morph.char
            )
        |> Morph.choiceFinish


hostLabelSymbol : Morph HostLabelSymbol Char
hostLabelSymbol =
    Morph.choice
        (\hyphenMinus aToZVariant n0To9Variant symbol ->
            case symbol of
                HostLabelHyphenMinus ->
                    hyphenMinus ()

                HostLabelSymbolAToZ aToZValue ->
                    aToZVariant aToZValue

                HostLabelSymbol0To9 n0To9Value ->
                    n0To9Variant n0To9Value
        )
        |> Morph.try (\() -> HostLabelHyphenMinus)
            (Char.Morph.only '-')
        |> Morph.try HostLabelSymbolAToZ
            AToZ.char
        |> Morph.try HostLabelSymbol0To9
            (N.Morph.in_ ( n0, n9 )
                |> Morph.over N.Morph.char
            )
        |> Morph.choiceFinish


domainTopLevel : MorphRow DomainTopLevel Char
domainTopLevel =
    Morph.succeed
        (\startDigits firstAToZ afterFirstAToZ ->
            { startDigits = startDigits
            , firstAToZ = firstAToZ
            , afterFirstAToZ = afterFirstAToZ
            }
        )
        |> grab .startDigits
            (atLeast
                (N.Morph.in_ ( n0, n9 )
                    |> Morph.over N.Morph.char
                    |> one
                )
                n0
            )
        |> -- guarantees it can't be numeric only
           grab .firstAToZ
            (AToZ.char |> one)
        |> grab .afterFirstAToZ
            (atLeast (domainTopLevelAfterFirstAToZSymbol |> one) n0)



-- domain


domainTopLevelAfterFirstAToZSymbol : Morph DomainTopLevelAfterFirstAToZSymbol Char
domainTopLevelAfterFirstAToZSymbol =
    Morph.choice
        (\aToZVariant n0To9Variant domainTopLevelSymbolUnion ->
            case domainTopLevelSymbolUnion of
                DomainTopLevelSymbolAToZ aToZValue ->
                    aToZVariant aToZValue

                DomainTopLevelSymbol0To9 n0To9Value ->
                    n0To9Variant n0To9Value
        )
        |> Morph.try DomainTopLevelSymbolAToZ
            AToZ.char
        |> Morph.try DomainTopLevelSymbol0To9
            (N.Morph.in_ ( n0, n9 )
                |> Morph.over N.Morph.char
            )
        |> Morph.choiceFinish


type alias Point =
    RecordWithoutConstructorFunction
        { x : Decimal, y : Decimal }


type alias Email =
    RecordWithoutConstructorFunction
        { local : Local
        , domain : Domain
        }


type alias Local =
    ArraySized LocalPart (Min (On N2))


type alias LocalPart =
    ArraySized LocalSymbol (Min (On N1))


type LocalSymbol
    = LocalSymbolPrintable LocalSymbolPrintable
    | LocalSymbolAToZ AToZ
    | LocalSymbol0To9 (N (In (On N0) (On N9)))


type LocalSymbolPrintable
    = ExclamationMark
    | NumberSign
    | DollarSign
    | PercentSign
    | Ampersand
    | Asterisk
    | LowLine
    | HyphenMinus
    | Tilde
    | VerticalLine
    | PlusSign
    | EqualsSign
    | GraveAccent
    | LeftCurlyBracket
    | RightCurlyBracket


type alias Domain =
    RecordWithoutConstructorFunction
        { first : HostLabel
        , hostLabels : ArraySized HostLabel (Min (On N0))
        , topLevel : DomainTopLevel
        }


type alias HostLabel =
    RecordWithoutConstructorFunction
        { firstSymbol : HostLabelSideSymbol
        , betweenFirstAndLastSymbols :
            ArraySized HostLabelSymbol (Min (On N0))
        , lastSymbol : HostLabelSideSymbol
        }


type HostLabelSideSymbol
    = HostLabelSideSymbolAToZ { case_ : AToZ.Case, letter : AToZ }
    | HostLabelSideSymbol0To9 (N (In (On N0) (On N9)))


type HostLabelSymbol
    = HostLabelHyphenMinus
    | HostLabelSymbolAToZ { case_ : AToZ.Case, letter : AToZ }
    | HostLabelSymbol0To9 (N (In (On N0) (On N9)))


{-| <https://data.iana.org/TLD/tlds-alpha-by-domain.txt>
-}
type alias DomainTopLevel =
    RecordWithoutConstructorFunction
        { startDigits :
            ArraySized (N (In (On N0) (On N9))) (Min (On N0))
        , firstAToZ : { case_ : AToZ.Case, letter : AToZ }
        , afterFirstAToZ :
            ArraySized DomainTopLevelAfterFirstAToZSymbol (Min (On N0))
        }


type DomainTopLevelAfterFirstAToZSymbol
    = DomainTopLevelSymbolAToZ { case_ : AToZ.Case, letter : AToZ }
    | DomainTopLevelSymbol0To9 (N (In (On N0) (On N9)))
