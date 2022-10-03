module Morph exposing
    ( Morph, Translate, MorphOrError, MorphIndependently
    , Description, DescriptionInner(..)
    , Error, ErrorWithDeadEnd(..), GroupError
    , broaden
    , value, only, validate
    , translate, broad, toggle, keep, translateOn
    , lazy
    , succeed, end, one
    , to
    , reverse
    , deadEndMap
    , deadEndNever, narrowErrorMap
    , description
    , broadenWith, narrowWith, mapWith
    , over, overRow
    , group, part, GroupMorph(..), NoPart(..), groupFinish
    , choice, try, ChoiceMorph(..), NoTry(..), choiceFinish
    , MorphRow, MorphRowIndependently, rowFinish
    , skip, grab
    , rowTry, ChoiceMorphRow, rowChoiceFinish
    , atLeast, in_, exactly, emptiable
    , before
    )

{-| Call it Codec, Conversion, Transformation, Shape, PrismReversible, ParseBuild

@docs Morph, Translate, MorphOrError, MorphIndependently
@docs Description, DescriptionInner
@docs Error, ErrorWithDeadEnd, GroupError


## create

@docs broaden
@docs value, only, validate
@docs translate, broad, toggle, keep, translateOn

@docs lazy


### create row

@docs succeed, end, one


## alter

@docs to
@docs reverse
@docs deadEndMap
@docs deadEndNever, narrowErrorMap


## scan

@docs description
@docs broadenWith, narrowWith, mapWith


# combine

@docs over, overRow


## groups

@docs group, part, GroupMorph, NoPart, groupFinish


## choices

@docs choice, try, ChoiceMorph, NoTry, choiceFinish


## row

@docs MorphRow, MorphRowIndependently, rowFinish


## group row

@docs skip, grab


## choice row

@docs rowTry, ChoiceMorphRow, rowChoiceFinish


## sequence row

@docs atLeast, in_, exactly, emptiable
@docs before

`whileAccumulate`, `until` aren't exposed for simplicity.
Have a need for them? → issue

---

Up for a challenge? implement & PR

  - `date`, `time`, `datetime`
  - `pathUnix`, `pathWindows`
  - `uri`
  - `ipV4`, `ipV6`

-}

import ArraySized exposing (ArraySized)
import Emptiable exposing (Emptiable, filled)
import Linear exposing (Direction(..))
import N exposing (Add1, Exactly, Fixed, In, InFixed, Min, N, N0, N2, To, Up, n0, n1, n2)
import Possibly exposing (Possibly(..))
import RecordWithoutConstructorFunction exposing (RecordWithoutConstructorFunction)
import Stack exposing (Stacked)
import Util exposing (restoreTry)



{- dev notes and zombie comments

   ### loop

   Powerful ways to recurse over [`MorphRow`](#MorphRow)s:

   situation: One [`possibility`](#try) matches, next the new argument is taken to call the whole [`MorphRow`](#MorphRow) recursively.

   This grows the stack, so you cannot do it indefinitely.
   ↓ enable tail-call elimination so you can have as many repeats you want.

   @docs whileAccumulate, until


   ## performance optimizations

   - `commit` to set a path as non-backtracking add
   - use `StackedWithLength` as input so that `Error.Row` paths don't re-evaluate `List.length` (O(n))

-}


{-| Conversion functions from a more general to
a more specific format and back.

There's no use-case implied.
You can always chain, [group](#groups), [choose](#choices), ...

👀 Each type `Morph narrow broad`,
for example `Morph Email String`, can


### `broaden : narrow -> broad`

  - example: `Email -> String`
  - going from a specific type to a general one
  - any specific value can be turned back successfully
  - can loose information on its way


### `narrow : broad -> Result error narrow`

  - example: `String -> Result Morph.Error Email`
      - ↑ is exactly how running your typical parser looks
  - going from a general type to a specific one
  - the result can always be turned back successfully
  - 📰 [blog post "A Broader Take on Parsing" by Joël Quenneville](https://thoughtbot.com/blog/a-broader-take-on-parsing?utm_campaign=Elm%20Weekly&utm_medium=email&utm_source=Revue%20newsletter)
    captures the essence of narrowing and gives more examples
  - 📰 [blog post "Shaping Values with Types" by Josh Clayton](https://thoughtbot.com/blog/shaping-values-with-types?utm_campaign=Elm%20Weekly&utm_medium=email&utm_source=Revue%20newsletter)
    following the example of an employee id,
    shows how simply wrapping broad data into an opaque type
      - doesn't bring safety and peace of mind
          - for example,
            you won't have to fix a bug from months ago
            that interrupts the work when you're swamped with today
      - opaque types don't save complexity in validation, tests, documentation anyway
          - doesn't communicate business rules (requirements, TODO)
              - including for other developers,
                "allowing for improved reasoning across the codebase"
  - 🎙️ [podcast "Parse, don't validate"](https://elm-radio.com/episode/parse-dont-validate/)


#### Why `Morph.Error` in `Morph` this when I could [use custom errors](#MorphOrError) everywhere?

Errors with more narrow structural information are mostly useful for recovery based on what went wrong.

You _can_ use [`MorphOrError`](#MorphOrError) in these cases (TODO recovering).

Without needing to recover, benefits of having narrow error types for every interaction
aren't worth

  - making new structure-specific types for
  - the extra type variable which decreases simplicity

-}
type alias Morph narrow broad =
    MorphIndependently
        (broad -> Result Error narrow)
        (narrow -> broad)


{-| Sometimes, you'll see the most general version of [`Morph`](#Morph):

    : MorphIndependently narrow broaden

where

  - [`narrow`](#narrow)ed value types can't necessarily be [`broaden`](#broaden)ed
  - [`broaden`](#broaden)ed value types can't necessarily be [`narrow`](#narrow)ed

This general form is helpful to describe a step in building an incomplete [`Morph`](#Morph).

TODO: add error as type parameter to allow translate

TODO: dream:
Choice by group/choice/... associating errors and description

-}
type alias MorphIndependently narrow broaden =
    RecordWithoutConstructorFunction
        { description : Description
        , narrow : narrow
        , broaden : broaden
        }


{-| [`Morph`](#Morph) that can [narrow](#narrowWith)
to an error that can be different from the default [`Error`](#Error)

    type alias Translate mapped unmapped =
        MorphOrError mapped unmapped (ErrorWithDeadEnd Never)

-}
type alias MorphOrError narrow broad error =
    MorphIndependently
        (broad -> Result error narrow)
        (narrow -> broad)


{-| Describing what the Morph [narrows to](#narrowWith) and [broadens from](#broadenWith)

  - custom description of the context
  - maybe [a description depending on structure](#DescriptionInner)

-}
type alias Description =
    RecordWithoutConstructorFunction
        { custom : Emptiable (Stacked String) Possibly
        , inner : Emptiable DescriptionInner Possibly
        }


{-| Description of a structure

  - chained morphs
  - narrow group of multiple
  - narrow choice between multiple

-}
type DescriptionInner
    = Over { narrow : Description, broad : Description }
    | Group (ArraySized (Min (Fixed N2)) Description)
    | Choice (ArraySized (Min (Fixed N2)) Description)
    | Elements Description
      -- row
    | While Description
    | Until { end : Description, element : Description }


{-| Where [narrowing](#narrowWith) has failed.

`String` is not enough for display?
→ use [`MorphOrError`](#MorphOrError) [`ErrorWithDeadEnd`](#ErrorWithDeadEnd) doing [`mapDeadEnd`](#mapDeadEnd)
on [`Morph`](#Morph) that are returned

Have trouble doing so because some API is too strict on errors? → issue

-}
type alias Error =
    ErrorWithDeadEnd String


{-| [`Error`](#Error) with a custom value on `DeadEnd`

    type alias Translate mapped unmapped =
        MorphOrError mapped unmapped (ErrorWithDeadEnd Never)

`deadEnd` could also be formatted text for display.
For that, use [`MorphOrError`](#MorphOrError) [`ErrorWithDeadEnd`](#ErrorWithDeadEnd) doing [`mapDeadEnd`](#mapDeadEnd)
on [`Morph`](#Morph) that are returned.

Have trouble doing so because some API is too strict on errors? → issue


### Why use text instead of a more narrow type for dead ends?

Different cases shouldn't invoke different responses.
Types give the benefit that all error conditions are explicit and transparent and that users are only able to produce those kinds of errors.
Then again: They don't have to be.
**Structured** text is enough while being so much easier to work with (mostly on the developer side)

-}
type ErrorWithDeadEnd deadEnd
    = DeadEnd deadEnd
    | Row { startDown : Int, error : ErrorWithDeadEnd deadEnd }
    | Parts (GroupError (ErrorWithDeadEnd deadEnd))
    | -- TODO: Stack → ArraySized (Min (Fixed N2))
      -- TODO: error → { index : Int, error : error }
      Possibilities (Emptiable (Stacked (ErrorWithDeadEnd deadEnd)) Never)


{-| A group's part [`Error`](#Error)s with their locations
-}
type alias GroupError partError =
    Emptiable
        (Stacked
            { index : Int
            , error : partError
            }
        )
        Never


{-| Describe the context to improve error messages.

    import Morph.Error
    import Char.Morph as Char
    import String.Morph as Text

    -- we can redefine an error message if something goes wrong
    "123"
        |> Text.narrowWith
            (Morph.to "variable name"
                (atLeast n1 Char.letter)
            )
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:1: I was expecting a name consisting of letters. I got stuck when I got '1'."


    import Morph exposing (take, drop, succeed, expect, one)
    import String.Morph as Text

    type alias Point =
        -- makes `Point` function unavailable:
        -- https://dark.elm.dmy.fr/packages/lue-bird/elm-no-record-type-alias-constructor-function/latest/
        RecordWithoutConstructorFunction
            { x : Float
            , y : Float
            }

    -- we can use `expect` to have more context when an error happens
    point : MorphRow Point
    point =
        Morph.to "point"
            (succeed (\x y -> { x = x, y = y })
                |> skip (Char.Morph.only '(' |> one)
                |> grab .x Text.number
                |> skip (Char.Morph.only ',' |> one)
                |> grab .y Text.number
                |> skip (Char.Morph.only ')' |> one)
            )

    "(12,34)" |> narrow (map Text.fromList point)
    --> Ok { x = 12, y = 34 }

    -- we can get the error context stack as well as where they started matching
    "(a,b)" |> narrow (map Text.fromList point)
        |> Result.mapError .expected
    --> Err [ ExpectedCustom "point" ]

-}
to :
    String
    ->
        (MorphIndependently narrow broaden
         -> MorphIndependently narrow broaden
        )
to expectationCustomDescription morphToDescribe =
    { morphToDescribe
        | description =
            morphToDescribe.description
                |> (\description_ ->
                        { description_
                            | custom =
                                description_.custom
                                    |> Stack.onTopLay
                                        expectationCustomDescription
                        }
                   )
    }



--


{-| The morph's [`Description`](#Description).

Add custom ones via [`Morph.to`](#to)

-}
description : MorphIndependently narrow_ broaden_ -> Description
description =
    .description


{-| Its transformation that turns `narrow` into `broad`.
Some call it "build"
-}
broadenWith : MorphIndependently narrow_ broaden -> broaden
broadenWith =
    .broaden


{-| Its transformation that turns `broad` into `narrow` or an `error`.
Some call it "parse"
-}
narrowWith : MorphIndependently narrow broaden_ -> narrow
narrowWith =
    .narrow


{-| Convert values of the arbitrarily chosen types `unmapped -> mapped`.

    "3456" |> |> Morph.mapWith String.Morph.toList
    --> [ '3', '4', '5', '6' ]

-}
mapWith :
    MorphIndependently
        (unmapped -> Result (ErrorWithDeadEnd Never) mapped)
        broaden_
    -> (unmapped -> mapped)
mapWith translate_ =
    \unmapped ->
        case unmapped |> narrowWith translate_ of
            Ok mappedNarrow ->
                mappedNarrow

            Err error ->
                error |> deadEndNever



--


{-| Filter specific values.

In general, try to narrow down the type when limiting values:
["Parse, don't validate"](https://elm-radio.com/episode/parse-dont-validate/).
That's a core idea in elm. You'll find lots of legendary resources on this topic.

Narrowing gives you

  - a better error description out of the box
  - a more descriptive and correct type
  - building invalid values becomes impossible

```
printable : Morph LocalSymbolPrintable Char (Morph.Error Char)
printable =
    choice
        (\exclamationMark numberSign dollarSign percentSign ampersand asterisk lowLine hyphenMinus backSlash printable ->
            case printable of
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
        )
        |> Morph.try (\() -> ExclamationMark) (Char.Morph.only '!')
        |> Morph.try (\() -> NumberSign) (Char.Morph.only '#')
        |> Morph.try (\() -> DollarSign) (Char.Morph.only '$')
        |> Morph.try (\() -> PercentSign) (Char.Morph.only '%')
        |> Morph.try (\() -> Ampersand) (Char.Morph.only '&')
        |> Morph.try (\() -> Asterisk) (Char.Morph.only '*')
        |> Morph.try (\() -> LowLine) (Char.Morph.only '_')
        |> Morph.try (\() -> HyphenMinus) (Char.Morph.only '-')
        |> Morph.choiceFinish
```

-}
validate :
    String
    -> (narrow -> Result deadEnd narrow)
    ->
        MorphIndependently
            (narrow -> Result (ErrorWithDeadEnd deadEnd) narrow)
            (broad -> broad)
validate descriptionCustom narrowConvert =
    value descriptionCustom
        { narrow = narrowConvert
        , broaden = identity
        }


{-| Mutual [`Morph`](#Morph) between representations
that have the same structural information
and can be mapped 1:1 into each other.
[narrowing](#mapWith) can `Never` fail

Examples:

  - some [`Morph`](#Morph) needs a different type

        translate Set.toList Set.fromList
            |> Morph.over
                (Value.list elementMorph)

      - [`Array.Morph.toList`](Array-#toList), [`Array.Morph.fromList`](Array-#fromList)
      - [`Stack.Morph.toString`](Stack-#toString), [`Stack.Morph.fromString`](Stack-#fromString)

  - strip unnecessary information
    ~`{ end : (), before :`~`List element`~`}`~

        translate .before
            (\before_ -> { before = before_, end = () })

Only use [`Translate`](#Translate) to annotate consumed inputs, for results,

    MorphOrError (List Char) String error_

allows it to be used in more general [`Morph`](#Morph) chains where the target value can be a concrete error.

Both type arguments are really equal in "narrowness",
so choosing one as the `mapped` and one as the `unmapped` is rather arbitrary.

That's the reason it's a good idea to always expose 2 versions: `aToB` & `bToA`.

**!** Information can get lost on the way:

    dictFromListMorph =
        Morph.translate Dict.fromList Dict.toList

Still, there's no narrowing necessary to translate one state to the other

-}
type alias Translate narrow broad =
    MorphOrError narrow broad (ErrorWithDeadEnd Never)


{-| Switch between 2 opposite representations. Examples:

    toggle List.reverse

    toggle not

    toggle negate

    toggle (\n -> n ^ -1)

    toggle Linear.opposite

If you want to allow both directions to [`MorphIndependently`](#MorphIndependently),
opt for `translate v v` instead of `toggle v`!

-}
toggle :
    (value -> value)
    ->
        MorphIndependently
            (value -> Result error_ value)
            (value -> value)
toggle changeToOpposite =
    translate changeToOpposite changeToOpposite


{-| A [`Morph`](#Morph) that doesn't transform anything.
Any possible input stays, remains the same. A no-op.

Same as writing:

  - [`map`](#map)`identity`
  - [`unmap`](#unmap)`identity`
  - [`validate`](#validate)`Ok`
  - [`translate`](#translate)`identity identity`
  - `{ broaden = identity, narrow = Ok }`
  - [`toggle`](#toggle)`identity` when broad and narrow types match

-}
keep :
    MorphIndependently
        (narrow -> Result error_ narrow)
        (broad -> broad)
keep =
    translate identity identity


{-| Create a [`Translate`](#Translate)

    stringToListMorph : Morph (List Char) String error_
    stringToListMorph =
        Morph.translate String.toList String.fromList

See the type's documentation for more detail

-}
translate :
    (beforeMap -> mapped)
    -> (beforeUnmap -> unmapped)
    ->
        MorphIndependently
            (beforeMap -> Result error_ mapped)
            (beforeUnmap -> unmapped)
translate mapTo unmapFrom =
    { description =
        { custom = Emptiable.empty, inner = Emptiable.empty }
    , narrow = mapTo >> Ok
    , broaden = unmapFrom
    }


{-| Only broadens (unmaps), doesn't narrow.
What comes out as the broad thing will be transformed but input doesn't.

What is great is using this to make inputs more "user-usable":

    ArraySized.Morph.maxToInfinity :
        MorphIndependently
            (narrow -> Result error_ narrow)
            (ArraySized (In (Fixed min) max_)
             -> ArraySized (In (Fixed min) max_)
            )
    ArraySized.Morph.maxToInfinity =
        Morph.broaden ArraySized.maxToInfinity

However! This can also often be an anti-pattern. See [`validate`](#validate).

    "WOW"
        |> Morph.broadenWith
            (Morph.broaden String.toLower
                |> Morph.over stringValidation
            )
    --→ "wow"

-}
broaden :
    (beforeBroaden -> broad)
    ->
        MorphIndependently
            (narrow -> Result error_ narrow)
            (beforeBroaden -> broad)
broaden broadenFrom =
    translate identity broadenFrom


{-| [`Morph`](#Morph) that always [`broaden`](#broaden)s to a given constant.

For any more complex [`broaden`](#broaden)ing process, use [`translate`](#translate)

-}
broad :
    broadConstant
    ->
        MorphIndependently
            (beforeNarrow_ -> Result error_ ())
            (() -> broadConstant)
broad broadConstantSeed =
    translate (\_ -> ()) (\() -> broadConstantSeed)


{-| Match only the specific given broad input.

Make helpers for each type of constant for convenience!

    Char.Morph.only broadCharConstant =
        Morph.only
            (\char ->
                [ "'", char |> String.fromChar, "'" ]
                    |> String.concat
            )
            broadCharConstant

-}
only :
    (broadConstant -> String)
    -> broadConstant
    -> Morph () broadConstant
only broadConstantToString broadConstant =
    value
        (broadConstant |> broadConstantToString)
        { narrow =
            \broadValue ->
                if broadValue == broadConstant then
                    () |> Ok

                else
                    broadConstant
                        |> broadConstantToString
                        |> Err
        , broaden =
            \() -> broadConstant
        }


{-| Create a custom morph for a value by explicitly specifying

  - a `String` description
  - `narrow`: a transformation that can fail with a `String` error
  - `broaden`: a transformation that can build the parsed value back to what a value that can be parsed

-}
value :
    String
    ->
        { narrow : beforeNarrow -> Result deadEnd narrowed
        , broaden : beforeBroaden -> broadened
        }
    ->
        MorphIndependently
            (beforeNarrow -> Result (ErrorWithDeadEnd deadEnd) narrowed)
            (beforeBroaden -> broadened)
value descriptionCustom morphTransformations =
    { description =
        { custom = Stack.only descriptionCustom
        , inner = Emptiable.empty
        }
    , narrow =
        morphTransformations.narrow
            >> Result.mapError DeadEnd
    , broaden = morphTransformations.broaden
    }



-- group


{-| [`Morph`](#Morph) on groups in progress.
Start with [`group`](#group), complete with [`part`](#part), finally [`groupFinish`](#groupFinish)
-}
type GroupMorph narrow broaden noPartTag_ noPartPossiblyOrNever
    = GroupMorphInProgress
        { description :
            -- parts
            Emptiable (Stacked Description) noPartPossiblyOrNever
        , narrow : narrow
        , broaden : broaden
        }


{-| Word in a [`GroupMorph`](#GroupMorph) in progress. For example

    choiceFinish :
        Value.GroupMorph (N (InFixed N0 N9)) Char (N (InFixed N0 N9) -> Char) NoPart Never
        -> Morph (N (InFixed N0 N9)) Char

-}
type NoPart
    = NoPartTag Never


{-| Assemble a from its morphed [`part`](#part)s

    ( "4", "5" )
        |> narrowWith
            (Morph.group
                ( \x y -> { x = x, y = y }
                , \x y -> ( x, y )
                )
                |> Morph.part ( .x, Tuple.first )
                    (Integer.Morph.toInt
                        |> Morph.overRow Integer.Morph.fromText
                        |> Morph.rowFinish
                    )
                |> Morph.part ( .y, Tuple.second )
                    (Integer.Morph.toInt
                        |> Morph.overRow Integer.Morph.fromText
                        |> Morph.rowFinish
                    )
            )
    --> Ok { x = 4, y = 5 }

-}
group :
    ( narrowAssemble
    , broadAssemble
    )
    ->
        GroupMorph
            (broad_
             -> Result error_ narrowAssemble
            )
            (groupNarrow_ -> broadAssemble)
            NoPart
            Possibly
group ( narrowAssemble, broadAssemble ) =
    { description = Emptiable.empty
    , narrow = \_ -> narrowAssemble |> Ok
    , broaden = \_ -> broadAssemble
    }
        |> GroupMorphInProgress


{-| The [`Morph`](#Morph) of the next part in a [`group`](#group).

    Morph.group
        ( \nameFirst nameLast email ->
            { nameFirst = nameFirst, nameLast = nameLast, email = email }
        , \nameFirst nameLast email ->
            { nameFirst = nameFirst, nameLast = nameLast, email = email }
        )
        |> Morph.part ( .nameFirst, .nameFirst ) remain
        |> Morph.part ( .nameLast, .nameLast ) remain
        |> Morph.part ( .email, .email ) emailMorph

-}
part :
    ( groupNarrow -> partNarrow
    , groupBroad -> partBroad
    )
    -> MorphOrError partNarrow partBroad partError
    ->
        (GroupMorph
            (groupBroad
             ->
                Result
                    (GroupError partError)
                    (partNarrow -> groupNarrowFurther)
            )
            (groupNarrow -> (partBroad -> groupBroadenFurther))
            NoPart
            noPartPossiblyOrNever_
         ->
            GroupMorph
                (groupBroad
                 ->
                    Result
                        (GroupError partError)
                        groupNarrowFurther
                )
                (groupNarrow -> groupBroadenFurther)
                NoPart
                noPartNever_
        )
part ( narrowPartAccess, broadPartAccess ) partMorph =
    \(GroupMorphInProgress groupMorphSoFar) ->
        { description =
            groupMorphSoFar.description
                |> Stack.onTopLay partMorph.description
        , narrow =
            groupMorphSoFar.narrow
                |> narrowPart
                    (groupMorphSoFar.description |> Stack.length)
                    broadPartAccess
                    (narrowWith partMorph)
        , broaden =
            groupMorphSoFar.broaden
                |> broadenPart narrowPartAccess (broadenWith partMorph)
        }
            |> GroupMorphInProgress


broadenPart :
    (groupNarrow -> partNarrow)
    -> (partNarrow -> partBroad)
    ->
        ((groupNarrow -> (partBroad -> groupBroadenFurther))
         -> (groupNarrow -> groupBroadenFurther)
        )
broadenPart narrowPartAccess broadenPartMorph =
    \groupMorphSoFarBroaden ->
        \groupNarrow ->
            (groupNarrow |> groupMorphSoFarBroaden)
                (groupNarrow
                    |> narrowPartAccess
                    |> broadenPartMorph
                )


narrowPart :
    Int
    -> (groupBroad -> partBroad)
    -> (partBroad -> Result partError partNarrow)
    ->
        ((groupBroad
          ->
            Result
                (GroupError partError)
                (partNarrow -> groupNarrowFurther)
         )
         ->
            (groupBroad
             ->
                Result
                    (GroupError partError)
                    groupNarrowFurther
            )
        )
narrowPart index broadPartAccess narrowPartMorph =
    \groupMorphSoFarNarrow ->
        \groupBroad ->
            let
                narrowPartOrError : Result partError partNarrow
                narrowPartOrError =
                    groupBroad
                        |> broadPartAccess
                        |> narrowPartMorph
            in
            case ( groupBroad |> groupMorphSoFarNarrow, narrowPartOrError ) of
                ( Ok groupMorphSoFarEat, Ok partNarrow ) ->
                    groupMorphSoFarEat partNarrow |> Ok

                ( Ok _, Err partError ) ->
                    { index = index, error = partError }
                        |> Stack.only
                        |> Err

                ( Err partsSoFarErrors, Ok _ ) ->
                    partsSoFarErrors |> Err

                ( Err partsSoFarErrors, Err partError ) ->
                    partsSoFarErrors
                        |> Stack.onTopLay { index = index, error = partError }
                        |> Err


{-| Conclude a [`Morph.group`](#group) |> [`Morph.part`](#part) chain
-}
groupFinish :
    GroupMorph
        (beforeNarrow
         ->
            Result
                (GroupError (ErrorWithDeadEnd deadEnd))
                narrowed
        )
        (beforeBroaden -> broadened)
        NoPart
        Never
    ->
        MorphIndependently
            (beforeNarrow -> Result (ErrorWithDeadEnd deadEnd) narrowed)
            (beforeBroaden -> broadened)
groupFinish =
    \(GroupMorphInProgress groupMorphInProgress) ->
        { description =
            case groupMorphInProgress.description |> Emptiable.fill of
                Stack.TopDown part0 (part1 :: parts2Up) ->
                    { inner =
                        ArraySized.l2 part0 part1
                            |> ArraySized.glueMin Up
                                (parts2Up |> ArraySized.fromList)
                            |> Group
                            |> Emptiable.filled
                    , custom = Emptiable.empty
                    }

                Stack.TopDown partOnly [] ->
                    partOnly
        , narrow =
            groupMorphInProgress.narrow
                >> Result.mapError Parts
        , broaden = groupMorphInProgress.broaden
        }



-- choice


{-| Possibly incomplete [`Morph`](#Morph) to and from a choice.
See [`choice`](#choice), [`possibility`](#try), [`choiceFinish`](#choiceFinish)
-}
type ChoiceMorph choiceNarrow choiceBroad choiceBroaden error noTryTag_ noTryPossiblyOrNever
    = ChoiceMorphInProgress
        { description :
            -- possibilities
            Emptiable (Stacked Description) noTryPossiblyOrNever
        , narrow :
            choiceBroad
            ->
                Result
                    (-- possibilities
                     Emptiable (Stacked error) noTryPossiblyOrNever
                    )
                    choiceNarrow
        , broaden : choiceBroaden
        }


{-| Word in an incomplete morph in progress. For example

    choiceFinish :
        Morph.Choice (N (InFixed N0 N9)) Char (N (InFixed N0 N9) -> Char) NoTry Never
        -> Morph (N (InFixed N0 N9)) Char

-}
type NoTry
    = NoTryTag Never


{-| If the previous [`possibility`](#try) fails
try this [`Morph`](#Morph).

> ℹ️ Equivalent regular expression: `|`

    import Char.Morph as Char
    import Morph.Error
    import AToZ exposing (AToZ)

    type UnderscoreOrLetter
        = Underscore
        | Letter Char

    underscoreOrLetter : Morph UnderscoreOrLetter Char
    underscoreOrLetter =
        choice
            (\underscore letter underscoreOrLetter ->
                case underscoreOrLetter of
                    Underscore ->
                        underscore ()

                    Letter aToZ ->
                        letter aToZ
            )
            |> try Underscore (Char.Morph.only '_')
            |> try Letter AToZ.char

    -- try the first possibility
    "_" |> Text.narrowWith (underscoreOrLetter |> one)
    --> Ok Underscore

    -- if it fails, try the next
    "a" |> Text.narrowWith (underscoreOrLetter |> one)
    --> Ok 'a'

    -- if none work, we get the error from all possible steps
    "1"
        |> Text.narrowWith (underscoreOrLetter |> one)
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:1: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '1'."

-}
try :
    (possibilityNarrow -> narrowChoice)
    ->
        MorphIndependently
            (possibilityBeforeNarrow
             -> Result error possibilityNarrow
            )
            (possibilityBeforeBroaden -> possibilityBroad)
    ->
        (ChoiceMorph
            narrowChoice
            possibilityBeforeNarrow
            ((possibilityBeforeBroaden -> possibilityBroad)
             -> choiceBroadenFurther
            )
            error
            NoTry
            noTryPossiblyOrNever_
         ->
            ChoiceMorph
                narrowChoice
                possibilityBeforeNarrow
                choiceBroadenFurther
                error
                NoTry
                noTryNever_
        )
try possibilityToChoice possibilityMorph =
    \(ChoiceMorphInProgress choiceMorphSoFar) ->
        { description =
            choiceMorphSoFar.description
                |> Stack.onTopLay possibilityMorph.description
        , narrow =
            \broadValue ->
                broadValue
                    |> choiceMorphSoFar.narrow
                    |> restoreTry
                        (\soFarExpectationPossibilities ->
                            case broadValue |> narrowWith possibilityMorph of
                                Ok possibilityNarrow ->
                                    possibilityNarrow
                                        |> possibilityToChoice
                                        |> Ok

                                Err possibilityExpectation ->
                                    soFarExpectationPossibilities
                                        |> Stack.onTopLay possibilityExpectation
                                        |> Err
                        )
        , broaden =
            choiceMorphSoFar.broaden
                (broadenWith possibilityMorph)
        }
            |> ChoiceMorphInProgress


{-| Discriminate into [possibilities](#try).

    {-| Invisible spacing character.
    -}
    type Blank
        = Space
        | Tab
        | Return Line.Return
        | FormFeed

    blankChar : Morph Blank Char (Morph.Error Char)
    blankChar =
        Morph.to "blank"
            (choice
                (\spaceVariant tabVariant returnVariant formFeedVariant blankNarrow ->
                    case blankNarrow of
                        Space ->
                            spaceVariant ()

                        Tab ->
                            tabVariant ()

                        Return return_ ->
                            returnVariant return_

                        FormFeed ->
                            formFeedVariant ()
                )
                |> Morph.try (\() -> Space) (Char.Morph.only ' ')
                |> Morph.try (\() -> Tab) (Char.Morph.only '\t')
                |> Morph.try Return Line.returnChar
                |> Morph.try (\() -> FormFeed)
                    -- \f
                    (Char.Morph.only '\u{000C}')
                |> Morph.choiceFinish
            )

    {-| Line break character
    -}
    type Return
        = NewLine
        | CarriageReturn

    {-| Match a line break character: Either

      - new line `'\n'`
      - carriage return `'\r'`

    > ℹ️ Equivalent regular expression: `[\n\r]`

        import Morph.Error
        import String.Morph as Text

        -- match a blank
        "\n\t abc" |> Text.narrowWith blank --> Ok '\n'

        -- anything else makes it fail
        "abc"
            |> Text.narrowWith blank
            |> Result.mapError Morph.Error.textMessage
        --> Err "1:1: I was expecting a blank space or new line. I got stuck when I got 'a'."

    -}
    returnChar : Morph Return Char (Morph.Error Char)
    returnChar =
        choice
            (\newLineVariant carriageReturnVariant returnNarrow ->
                case returnNarrow of
                    NewLine ->
                        newLineVariant ()

                    CarriageReturn ->
                        carriageReturnVariant ()
            )
            |> Morph.try (\() -> NewLine)
                (Char.Morph.only '\n')
            |> Morph.try (\() -> CarriageReturn)
                -- \r
                (Char.Morph.only '\u{000D}')
            |> Morph.choiceFinish

    {-| The end of a text line:
    either a [return character](Return#Return) or the end of the whole text.
    -}
    type LineEnd
        = InputEnd
        | Return Return

    {-| Consume the end of the current line or succeed if there are
    no more remaining characters in the input text.

    > ℹ️ Equivalent regular expression: `$`

    -}
    endText : MorphRow Char LineEnd
    endText =
        Morph.choice
            (\returnVariant inputEndVariant maybeChoice ->
                case maybeChoice of
                    Return returnValue ->
                        returnVariant returnValue

                    InputEnd ->
                        inputEndVariant ()
            )
            |> Morph.rowTry Return
                (returnChar |> Morph.one)
            |> Morph.rowTry (\() -> InputEnd)
                Morph.end
            |> Morph.rowChoiceFinish

-}
choice :
    choiceBroadenByPossibility
    ->
        ChoiceMorph
            choiceNarrow_
            choiceBroad_
            choiceBroadenByPossibility
            error_
            NoTry
            Possibly
choice choiceBroadenDiscriminatedByPossibility =
    { description = Emptiable.empty
    , narrow =
        \_ ->
            Emptiable.empty |> Err
    , broaden = choiceBroadenDiscriminatedByPossibility
    }
        |> ChoiceMorphInProgress


{-| Conclude a [`Morph.choice`](#choice) |> [`Morph.try`](#try) chain
-}
choiceFinish :
    ChoiceMorph
        narrow
        beforeNarrow
        broaden
        (ErrorWithDeadEnd deadEnd)
        NoTry
        Never
    ->
        MorphIndependently
            (beforeNarrow
             -> Result (ErrorWithDeadEnd deadEnd) narrow
            )
            broaden
choiceFinish =
    \(ChoiceMorphInProgress choiceMorphComplete) ->
        { description =
            case choiceMorphComplete.description |> Emptiable.fill of
                Stack.TopDown variantOnly [] ->
                    variantOnly

                Stack.TopDown variant0 (variant1 :: variants2Up) ->
                    { custom = Emptiable.empty
                    , inner =
                        ArraySized.l2 variant0 variant1
                            |> ArraySized.glueMin Up
                                (variants2Up |> ArraySized.fromList)
                            |> Choice
                            |> Emptiable.filled
                    }
        , narrow =
            choiceMorphComplete.narrow
                >> Result.mapError Possibilities
        , broaden =
            choiceMorphComplete.broaden
        }



--


{-| To reference a [`Morph`](#Morph) in recursive definitions

    import Morph exposing (grab, skip, one)
    import Integer.Morph
    import String.Morph

    type LazyList
        = End
        | Next ( Int, LazyList )

    lazyList : MorphRow LazyList
    lazyList =
        choice
            (\endVariant nextVariant lazyListNarrow ->
                case lazyListNarrow of
                    End ->
                        endVariant ()
                    Next next ->
                        nextVariant next
            )
            |> Morph.try (\() -> End)
                (String.Morph.only "[]")
            |> Morph.try Next
                (succeed Tuple.pair
                    |> grab
                        (Integer.Morph.toInt
                            |> Morph.overRow Integer.Morph.text
                        )
                    |> skip
                        (broad [ () ]
                            |> Morph.overRow
                                (atLeast n1 (String.Morph.only " "))
                        )
                    |> skip (String.Morph.only "::")
                    |> skip
                        (broad [ () ]
                            |> Morph.overRow
                                (atLeast n1 (String.Morph.only " "))
                        )
                    |> grab (Morph.lazy (\() -> lazyList))
                )

    "[]" |> Text.narrowWith lazyList
    --> Ok End

    "a :: []" |> Text.narrowWith lazyList
    --> Ok (Next 'a' End)

    "a :: b :: []" |> Text.narrowWith lazyList
    --> Ok (Next 'a' (Next 'b' End))

Without `lazy`, you would get an error like:

>     The `lazyList` definition is causing a very tricky infinite loop.
>
>     The `lazyList` value depends on itself through the following chain of
>     definitions:
>
>           ┌─────┐
>           │    lazyList
>           │     ↓
>           │    lazyListNext
>           └─────┘

-}
lazy :
    (()
     ->
        MorphIndependently
            (beforeNarrow -> Result error narrow)
            (beforeBroaden -> broad)
    )
    ->
        MorphIndependently
            (beforeNarrow -> Result error narrow)
            (beforeBroaden -> broad)
lazy morphLazy =
    { description = morphLazy () |> description
    , narrow =
        \broadValue ->
            broadValue |> narrowWith (morphLazy ())
    , broaden =
        \narrowValue ->
            narrowValue |> broadenWith (morphLazy ())
    }


{-| Go over an additional step of [`Morph`](#Morph) on its broad type

Chaining

  - `<<` on the broad side
  - `<< Result.andThen` on the narrow side

This can be used to, for example

  - [`Translate`](#Translate) what was [narrowed](#narrowWith)
  - narrow only one variant,
    then of that variant's value type one of their variants

-}
over :
    MorphIndependently
        (beforeBeforeNarrow -> Result error beforeNarrow)
        (beforeBroaden -> broad)
    ->
        (MorphIndependently
            (beforeNarrow -> Result error narrow)
            (beforeBeforeBroaden -> beforeBroaden)
         ->
            MorphIndependently
                (beforeBeforeNarrow -> Result error narrow)
                (beforeBeforeBroaden -> broad)
        )
over morphNarrowBroad =
    \morph ->
        { description =
            { custom = Emptiable.empty
            , inner =
                Over
                    { narrow = morph |> description
                    , broad = morphNarrowBroad |> description
                    }
                    |> Emptiable.filled
            }
        , broaden =
            broadenWith morph
                >> broadenWith morphNarrowBroad
        , narrow =
            narrowWith morphNarrowBroad
                >> Result.andThen (narrowWith morph)
        }


{-| `Translate a <-> b`
by swapping the functions [`map`](#map) <-> [`unmap`](#unmap).

    [ 'O', 'h', 'a', 'y', 'o' ]
        |> Morph.map
           (Text.toList |> Morph.reverse)
    --> "Ohayo"

This can be used to easily create a `fromX`/`toX` pair

    module Stack.Morph exposing (fromListNonEmpty)

    import Emptiable exposing (Emptiable)
    import List.NonEmpty
    import Stack exposing (Stacked)

    fromListNonEmpty :
        MorphIndependently
            (List.NonEmpty.NonEmpty element
             -> Result error_ (Emptiable (Stacked element) never_)
            )
            (Emptiable (Stacked element) Never
             -> List.NonEmpty.NonEmpty element
            )
    fromListNonEmpty =
        toListNonEmpty |> Morph.reverse

    toListNonEmpty :
        MorphIndependently
            (Emptiable (Stacked element) Never
             -> Result error_ (List.NonEmpty.NonEmpty element)
            )
            (List.NonEmpty.NonEmpty element
             -> Emptiable (Stacked element) never_
            )
    toListNonEmpty =
        translate Stack.toListNonEmpty Stack.fromListNonEmpty

[`unmap`](#unmap) `...` is equivalent to `map (... |> reverse)`.

-}
reverse :
    MorphIndependently
        (beforeMap -> Result (ErrorWithDeadEnd Never) mapped)
        (beforeUnmap -> unmapped)
    ->
        MorphIndependently
            (beforeUnmap -> Result error_ unmapped)
            (beforeMap -> mapped)
reverse =
    \translate_ ->
        { description = translate_ |> description
        , narrow =
            \unmapped ->
                unmapped |> broadenWith translate_ |> Ok
        , broaden = mapWith translate_
        }


{-| Change all [`DeadEnd`](#ErrorWithDeadEnd)s based on their current values.

`deadEnd` can for example be changed to formatted text for display.
For that, use [`MorphOrError`](#MorphOrError) [`ErrorWithDeadEnd`](#ErrorWithDeadEnd) doing [`mapDeadEnd`](#mapDeadEnd)
on [`Morph`](#Morph) that are returned.

Have trouble doing so because some API is too strict on errors? → issue

See also: [`deadEndNever`](#deadEndNever)

-}
deadEndMap :
    (deadEnd -> deadEndMapped)
    -> ErrorWithDeadEnd deadEnd
    -> ErrorWithDeadEnd deadEndMapped
deadEndMap deadEndChange =
    \error ->
        case error of
            DeadEnd deadEnd ->
                deadEnd |> deadEndChange |> DeadEnd

            Row row ->
                { startDown = row.startDown
                , error = row.error |> deadEndMap deadEndChange
                }
                    |> Row

            Parts parts ->
                parts
                    |> Stack.map
                        (\_ partError ->
                            { index = partError.index
                            , error = partError.error |> deadEndMap deadEndChange
                            }
                        )
                    |> Parts

            Possibilities possibilities ->
                possibilities
                    |> Stack.map
                        (\_ -> deadEndMap deadEndChange)
                    |> Possibilities


{-| An [`Error`](#ErrorWithDeadEnd) where running into a dead end is impossible can't be created.
Therefore, you can treat it as _any_ value.

Under the hood, only [`Basics.never`] is used so it's completely safe to use.

-}
deadEndNever : ErrorWithDeadEnd Never -> any_
deadEndNever =
    \error ->
        case error of
            DeadEnd deadEnd ->
                deadEnd |> never

            Row row ->
                row.error |> deadEndNever

            Parts parts ->
                parts
                    |> Stack.top
                    |> .error
                    |> deadEndNever

            Possibilities possibilities ->
                possibilities
                    |> Stack.top
                    |> deadEndNever


{-| Change the potential [`Error`](#Error) TODO This is usually used with either

  - [`deadEndNever : ErrorWithDeadEnd Never -> any_`](#deadEndNever)
  - [`deadEndMap`](#deadEndMap)

-}
narrowErrorMap :
    (error -> errorMapped)
    ->
        MorphIndependently
            (beforeNarrow -> Result error narrowed)
            (beforeBroaden -> broadened)
    ->
        MorphIndependently
            (beforeNarrow -> Result errorMapped narrowed)
            (beforeBroaden -> broadened)
narrowErrorMap errorChange =
    \morph ->
        { description = morph |> description
        , broaden = broadenWith morph
        , narrow =
            narrowWith morph
                >> Result.mapError errorChange
        }



--


{-| Morph the structure's elements

    List.Morph.elementTranslate elementTranslate =
        translateOn ( List.map, List.map ) elementTranslate

-}
translateOn :
    ( (elementBeforeMap -> elementMapped)
      -> (structureBeforeMap -> structureMapped)
    , (elementBeforeUnmap -> elementUnmapped)
      -> (structureBeforeUnmap -> structureUnmapped)
    )
    ->
        (MorphIndependently
            (elementBeforeMap -> Result (ErrorWithDeadEnd Never) elementMapped)
            (elementBeforeUnmap -> elementUnmapped)
         ->
            MorphIndependently
                (structureBeforeMap -> Result error_ structureMapped)
                (structureBeforeUnmap -> structureUnmapped)
        )
translateOn ( structureMap, structureUnmap ) elementTranslate =
    { description =
        { custom = Emptiable.empty
        , inner = Emptiable.empty
        }
    , narrow =
        structureMap (mapWith elementTranslate)
            >> Ok
    , broaden =
        structureUnmap (broadenWith elementTranslate)
    }



-- row


{-| Parser-builder:

  - grab some elements from an input stack,
    and return either a value or else an [`Error`](#Error)

  - take the value and turn it back into an input stack

```
{-| [`MorphRow`](#MorphRow) on input characters
-}
type alias MorphText narrow =
    MorphRow Char narrow
```

[`MorphRow`](#MorphRow) is inspired by [`lambda-phi/parser`](https://dark.elm.dmy.fr/packages/lambda-phi/parser/latest/)


## example: 2D point

    import Morph exposing (MorphRow, atLeast, skip, into, succeed, grab, one)
    import Char.Morph as Char
    import String.Morph as Text exposing (number)
    import Morph.Error

    type alias Point =
        -- makes `Point` function unavailable:
        -- https://dark.elm.dmy.fr/packages/lue-bird/elm-no-record-type-alias-constructor-function/latest/
        RecordWithoutConstructorFunction
            { x : Float
            , y : Float
            }

    -- successful parsing looks like
    "(2.71, 3.14)" |> narrow (listToString |> over point)
    --> Ok { x = 2.71, y = 3.14 }

    -- building always works
    { x = 2.71, y = 3.14 } |> broad (listToString |> over point)
    --> "( 2.71, 3.14 )"

    point : MorphRow Point
    point =
        Morph.to "point"
            (succeed (\x y -> { x = x, y = y })
                |> skip (String.Morph.only "(")
                |> skip
                    (broad [ () ]
                        |> Morph.overRow (atLeast n0 (String.Morph.only " "))
                    )
                |> grab number
                |> skip
                    (broad []
                        |> Morph.overRow (atLeast n0 (String.Morph.only " "))
                    )
                |> skip (String.Morph.only ",")
                |> skip
                    (broad [ () ]
                        |> Morph.overRow (atLeast n0 (String.Morph.only " "))
                    )
                |> grab .x Number.Morph.text
                |> skip
                    (broad [ () ]
                        |> Morph.overRow (atLeast n0 (String.Morph.only " "))
                    )
                |> skip (String.Morph.only ")")
            )

    -- we can get a nice error message if it fails
    "(2.71, x)"
        |> Text.narrowWith point
        |> Result.mapError (Morph.Error.dump "filename.txt")
    --> Err
    -->     [ "[ERROR] filename.txt: line 1:8: I was expecting a digit [0-9]. I got stuck when I got 'x'."
    -->     , "  in Point at line 1:1"
    -->     , ""
    -->     , "1|(2.71, x)"
    -->     , "  ~~~~~~~^"
    -->     ]

Note before we start:
`MorphRow` _always backtracks_ and never commits to a specific path!

  - 👍 improves readability

    crucial so we don't experience reports like

    > "If it compiles it runs"
    >
    > Unless you are writing a parser.
    >
    > The parser doesn't care.
    >
    > The parser will compile and then murder you for breakfast.

    – xarvh (Francesco Orsenigo) on slack

  - 👍 error messages will always show all options and why they failed,
    showing those that came the furthest first

  - 👎 performs worse as there are more [possibilities](#try) to parse to know it failed

-}
type alias MorphRow broadElement narrow =
    MorphIndependently
        (Emptiable (Stacked broadElement) Possibly
         ->
            Result
                Error
                { narrow : narrow
                , broad : Emptiable (Stacked broadElement) Possibly
                }
        )
        (narrow -> Emptiable (Stacked broadElement) Possibly)


{-| Incomplete [`MorphRow`](#MorphRow) for a thing composed of multiple parts = group.
It's what you supply during a [`succeed`](#succeed)`|>`[`grab`](#grab)/[`skip`](#skip) build
-}
type alias MorphRowIndependently broadElement beforeBroaden narrowed =
    MorphIndependently
        (Emptiable (Stacked broadElement) Possibly
         ->
            Result
                Error
                { narrow : narrowed
                , broad : Emptiable (Stacked broadElement) Possibly
                }
        )
        (beforeBroaden
         -> Emptiable (Stacked broadElement) Possibly
        )



--


{-| Take what we get from [converting](#MorphRow) the next section
and channel it back up to the [`succeed`](#succeed) grouping
-}
grab :
    (groupNarrow -> partNextNarrow)
    -> MorphRow broadElement partNextNarrow
    ->
        (MorphRowIndependently
            broadElement
            groupNarrow
            (partNextNarrow -> groupNarrowFurther)
         ->
            MorphRowIndependently
                broadElement
                groupNarrow
                groupNarrowFurther
        )
grab partAccess grabbedNextMorphRow =
    \groupMorphRowSoFar ->
        { description = groupMorphRowSoFar |> description
        , narrow =
            \broad_ ->
                broad_
                    |> narrowWith groupMorphRowSoFar
                    |> Result.andThen
                        (\result ->
                            result.broad
                                |> narrowWith grabbedNextMorphRow
                                |> Result.map
                                    (\nextParsed ->
                                        { narrow = result.narrow nextParsed.narrow
                                        , broad = nextParsed.broad
                                        }
                                    )
                        )
        , broaden =
            \groupNarrow ->
                groupNarrow
                    |> partAccess
                    |> grabbedNextMorphRow.broaden
                    |> Stack.onTopStack
                        (groupNarrow
                            |> groupMorphRowSoFar.broaden
                        )
        }



-- basic


{-| Require values to be matched next to continue but ignore the result.

    import String.Morph exposing (text)
    import Morph exposing (succeed, atLeast, take, drop)

    -- parse a simple email, but we're only interested in the username
    "user@example.com"
        |> Text.narrowWith
            (succeed (\userName -> { username = userName })
                |> grab .username (atLeast n1 aToZ)
                |> skip (one '@')
                |> skip
                    (Text.fromList
                        |> Morph.overRow (atLeast n1 aToZ)
                        |> broad "example"
                    )
                |> skip (text ".com")
            )
    --> Ok { username = "user" }

[`broad`](#broad) `... |>` [`Morph.overRow`](MorphRow#over) is cool:
when multiple kinds of input can be dropped,
it allows choosing a default possibility for building.

-}
skip :
    MorphRow broadElement ()
    ->
        (MorphRowIndependently broadElement groupNarrow narrow
         -> MorphRowIndependently broadElement groupNarrow narrow
        )
skip ignoredNext =
    \groupMorphRowSoFar ->
        { description = groupMorphRowSoFar |> description
        , narrow =
            \broad_ ->
                broad_
                    |> narrowWith groupMorphRowSoFar
                    |> Result.andThen
                        (\result ->
                            result.broad
                                |> narrowWith ignoredNext
                                |> Result.map
                                    (\nextParsed ->
                                        { narrow = result.narrow
                                        , broad = nextParsed.broad
                                        }
                                    )
                        )
        , broaden =
            \groupNarrow ->
                (() |> ignoredNext.broaden)
                    |> Stack.onTopStack
                        (groupNarrow |> groupMorphRowSoFar.broaden)
        }


{-| [`MorphRow`](#MorphRow) from and to a single broad input.


## `Morph.keep |> Morph.one`

> ℹ️ Equivalent regular expression: `.`

    import Morph
    import Morph.Error
    import String.Morph as Text

    -- can match any character
    "a" |> Text.narrowWith (Morph.keep |> one)
    --> Ok 'a'

    "#" |> Text.narrowWith (Morph.keep |> one)
    --> Ok '#'

    -- only fails if we run out of inputs
    ""
        |> Text.narrowWith (Morph.keep |> one)
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:0: I was expecting a character. I reached the end of the input."

-}
one :
    Morph narrow element
    -> MorphRow element narrow
one =
    \morph ->
        { description =
            morph |> description
        , narrow =
            \broad_ ->
                case broad_ of
                    Emptiable.Empty _ ->
                        { error = "end of input" |> DeadEnd
                        , startDown = 0
                        }
                            |> Row
                            |> Err

                    Emptiable.Filled (Stack.TopDown nextBroadElement afterNextBroadElement) ->
                        case
                            nextBroadElement
                                |> narrowWith morph
                        of
                            Ok narrowNarrow ->
                                { narrow = narrowNarrow
                                , broad =
                                    afterNextBroadElement
                                        |> Stack.fromList
                                }
                                    |> Ok

                            Err error ->
                                { error = error
                                , startDown = broad_ |> Stack.length
                                }
                                    |> Row
                                    |> Err
        , broaden =
            broadenWith morph
                >> Stack.only
        }


{-| Always [`narrow`](#narrow) to a given constant.

    import Morph exposing (succeed)

    "no matter the input text"
        |> Text.narrowWith (succeed "abc")
    --> Ok "abc"

For anything composed of multiple parts,

> `succeed` is the key to success
> – folks from [elm radio](https://elm-radio.com/)

first declaratively describing what you expect to get in the end,
then [taking](#grab) and [dropping](#skip) what you need to parse.

    import Morph exposing (succeed, one)
    import String.Morph exposing (integer)

    type alias Point =
        -- makes `Point` function unavailable:
        -- https://dark.elm.dmy.fr/packages/lue-bird/elm-no-record-type-alias-constructor-function/latest/
        RecordWithoutConstructorFunction
            { x : Int
            , y : Int
            }

    point : MorphRow Char Point
    point =
        succeed (\x y -> { x = x, y = y })
            |> grab .x integer
            |> skip (MorphRow.only [ ',' ])
            |> grab .y integer

    "12,34" |> Text.narrowWith point
    --> Ok { x = 12, y = 34 }


### `succeed` anti-patterns

One example you'll run into when using other parsers is using

    succeed identity
        |> skip ...
        |> skip ...
        |> grab ...
        |> skip ...

it get's pretty hard to read as you have to jump around the code to know what you're actually producing.

    succeed (\sum -> sum) |> ...

is already nicer.

-}
succeed :
    constant
    -> MorphRowIndependently broadElement_ narrow_ constant
succeed narrowConstant =
    { description =
        { custom = Emptiable.empty -- "any"
        , inner = Emptiable.empty
        }
    , narrow =
        \broad_ ->
            { narrow = narrowConstant
            , broad = broad_
            }
                |> Ok
    , broaden =
        \_ -> Emptiable.empty
    }



-- chain


{-| Possibly incomplete [`MorphRow`](#MorphRow) to and from a choice.
See [`Morph.choice`](#choice), [`Morph.rowTry`](#try), [`MorphRow.choiceFinish`](#choiceFinish)
-}
type alias ChoiceMorphRow broadElement choiceNarrow choiceBroaden noTryTag noTryPossiblyOrNever =
    ChoiceMorph
        { narrow : choiceNarrow
        , broad : Emptiable (Stacked broadElement) Possibly
        }
        (Emptiable (Stacked broadElement) Possibly)
        choiceBroaden
        Error
        noTryTag
        noTryPossiblyOrNever


{-| If the previous [`possibility`](#try) fails
try this [`MorphRow`](#MorphRow).

> ℹ️ Equivalent regular expression: `|`

    import Morph
    import Char.Morph as Char
    import Morph.Error

    type UnderscoreOrLetter
        = Underscore
        | Letter Char

    underscoreOrLetter : MorphRow Char UnderscoreOrLetter
    underscoreOrLetter =
        choice
            (\underscoreVariant letterVariant underscoreOrLetterNarrow ->
                case underscoreOrLetterNarrow of
                    Underscore ->
                        underscoreVariant ()

                    Letter letter ->
                        letterVariant letter
            )
            |> try (\() -> Underscore) (Char.Morph.only '_')
            |> try Letter AToZ.caseAny
            |> choiceFinish

    -- try the first possibility
    "_"
        |> Text.narrowWith underscoreOrLetter
    --> Ok Underscore

    -- if it fails, try the next
    "a"
        |> Text.narrowWith underscoreOrLetter
    --> Ok 'a'

    -- if none work, we get the error from all possible steps
    "1"
        |> Text.narrowWith (onFailDown [ one '_', Char.letter ])
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:1: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '1'."


### example: fallback step if the previous step fails

    import Morph
    import Char.Morph as Char
    import Morph.Error

    type AlphaNum
        = Digits (List (N (InFixed N0 N9)))
        | Letters String

    alphaNum : MorphRow Char AlphaNum
    alphaNum =
        Morph.choice
            (\digit letter alphaNum ->
                case alphaNum of
                    Digits int ->
                        digit int

                    Letters char ->
                        letter char
            )
            |> Morph.try Letter
                (map String.Morph.fromList
                    (atLeast n1 Char.letter)
                )
            |> Morph.try Digit
                (atLeast n1 Digit.n0To9)
            |> MorphRow.choiceFinish

    -- try letters, or else give me some digits
    "abc"
        |> Text.narrowWith alphaNum
    --> Ok "abc"

    -- we didn't get letters, but we still got digits
    "123"
        |> Text.narrowWith alphaNum
    --> Ok "123"

    -- but if we still fail, give the expectations of all steps
    "_"
        |> Text.narrowWith alphaNum
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:1: I was expecting at least 1 digit [0-9]. I got stuck when I got the character '_'."

-}
rowTry :
    (possibilityNarrow -> choiceNarrow)
    -> MorphRow broadElement possibilityNarrow
    ->
        (ChoiceMorphRow
            broadElement
            choiceNarrow
            ((possibilityNarrow -> Emptiable (Stacked broadElement) Possibly)
             -> choiceBroadenFurther
            )
            NoTry
            noTryPossiblyOrNever_
         ->
            ChoiceMorphRow
                broadElement
                choiceNarrow
                choiceBroadenFurther
                NoTry
                never_
        )
rowTry possibilityToChoice possibilityMorph (ChoiceMorphInProgress choiceMorphSoFar) =
    { description =
        choiceMorphSoFar.description
            |> Stack.onTopLay (possibilityMorph |> description)
    , narrow =
        \choiceBroad ->
            choiceBroad
                |> choiceMorphSoFar.narrow
                |> restoreTry
                    (\soFarErrorPossibilities ->
                        case choiceBroad |> narrowWith possibilityMorph of
                            Ok possibilityParsed ->
                                { broad = possibilityParsed.broad
                                , narrow =
                                    possibilityParsed.narrow
                                        |> possibilityToChoice
                                }
                                    |> Ok

                            Err possibilityExpectation ->
                                soFarErrorPossibilities
                                    |> Stack.onTopLay possibilityExpectation
                                    |> Err
                    )
    , broaden =
        choiceMorphSoFar.broaden
            (broadenWith possibilityMorph)
    }
        |> ChoiceMorphInProgress


{-| Always the last step in a [`Morph.choice`](#choice) `|>` [`Morph.rowTry`](#try) build process
-}
rowChoiceFinish :
    ChoiceMorphRow
        broadElement
        choiceNarrow
        (choiceNarrow -> Emptiable (Stacked broadElement) Possibly)
        NoTry
        Never
    -> MorphRow broadElement choiceNarrow
rowChoiceFinish =
    \(ChoiceMorphInProgress choiceMorphRowComplete) ->
        { description =
            case choiceMorphRowComplete.description |> Emptiable.fill of
                Stack.TopDown descriptionOnly [] ->
                    descriptionOnly

                Stack.TopDown description0 (description1 :: description2Up) ->
                    { custom = Emptiable.empty
                    , inner =
                        ArraySized.l2 description0 description1
                            |> ArraySized.glueMin Up
                                (description2Up |> ArraySized.fromList)
                            |> Group
                            |> Emptiable.filled
                    }
        , narrow =
            \broad_ ->
                broad_
                    |> choiceMorphRowComplete.narrow
                    |> Result.mapError
                        (\errorPossibilities ->
                            { startDown = broad_ |> Stack.length
                            , error = errorPossibilities |> Possibilities
                            }
                                |> Row
                        )
        , broaden = choiceMorphRowComplete.broaden
        }



{-

   `next` existed once:

       next :
           (narrow -> broad)
           -> (broad -> MorphRow broadElement narrow)
           ->
               (Row broadElement broad
               -> MorphRow broadElement narrow
               )

   After [converting](#MorphRow) the previous section,
   it formed another [morph](#MorphRow) with the value we got.

   It allowed using the last value for the next [`MorphRow`](#MorphRow) like a backreference.

   But!

     - one should [`Morph.overRow`](#over) to narrow parsed values
     - one should [loop](#loop) instead of recursively recursively [`next`](#next)
     - one should try to know what to morph by tracking context,
       independent of what narrow result the last morph gave
         - for example, don't use [`next`](#next) for versioning etc.
           Use [`choice`](#choice) where each [`possibility`](#try) expects a specific number


-}
-- transform


{-| Describe how to reach an even broader type.

  - try to keep [`Morph.overRow`](#over) filters/validations to a minimum to get
      - a better error description out of the box
      - a more descriptive and correct type
      - building invalid values becomes impossible

↓

    import Morph exposing (toggle)
    import Morph exposing (map, atLeast)
    import Char.Morph as Char
    import Text

    -- get some letters, make them lowercase
    "ABC"
        |> Text.narrowWith
            (atLeast n1 Char.letter
                |> map Text.fromList
                |> map (toggle String.toLower)
            )
    --> Ok "abc"

-}
overRow :
    MorphRowIndependently
        broadElement
        beforeBroaden
        beforeNarrow
    ->
        (MorphIndependently
            (beforeNarrow -> Result Error narrow)
            (beforeBeforeBroaden -> beforeBroaden)
         ->
            MorphRowIndependently
                broadElement
                beforeBeforeBroaden
                narrow
        )
overRow morphRowBeforeMorph =
    \narrowMorph ->
        { description =
            { custom = Emptiable.empty
            , inner =
                Over
                    { narrow = narrowMorph |> description
                    , broad = morphRowBeforeMorph |> description
                    }
                    |> Emptiable.filled
            }
        , narrow =
            \broad_ ->
                broad_
                    |> narrowWith morphRowBeforeMorph
                    |> Result.andThen
                        (\narrowed ->
                            narrowed.narrow
                                |> narrowWith narrowMorph
                                |> Result.map
                                    (\narrowNarrow ->
                                        { narrow = narrowNarrow
                                        , broad = narrowed.broad
                                        }
                                    )
                                |> Result.mapError
                                    (\error ->
                                        { error = error
                                        , startDown = broad_ |> Stack.length
                                        }
                                            |> Row
                                    )
                        )
        , broaden =
            broadenWith narrowMorph
                >> broadenWith morphRowBeforeMorph
        }



-- sequence


{-| Match an optional value and returns it as a `Maybe`.

> ℹ️ Equivalent regular expression: `?`

    import Char.Morph exposing (letter)
    import String.Morph as Text

    -- maybe we get `Just` a letter
    "abc" |> Text.narrowWith (emptiable Char.letter)
    --> Ok (Just 'a')

    -- maybe we get `Nothing`
    "123abc" |> Text.narrowWith (emptiable Char.letter)
    --> Ok Nothing

-}
emptiable :
    MorphRow broadElement contentNarrow
    -> MorphRow broadElement (Emptiable contentNarrow Possibly)
emptiable contentMorphRow =
    choice
        (\justVariant nothingVariant maybeNarrow ->
            case maybeNarrow of
                Emptiable.Filled justValue ->
                    justVariant justValue

                Emptiable.Empty _ ->
                    nothingVariant ()
        )
        |> rowTry filled contentMorphRow
        |> rowTry (\() -> Emptiable.empty) (succeed ())
        |> rowChoiceFinish


{-| Match a value `exactly` a number of times
and return them as a [`ArraySized`](https://package.elm-lang.org/packages/lue-bird/elm-typesafe-array/latest/ArraySized)

> ℹ️ Equivalent regular expression: `{n}`

    import Morph.Error
    import Char.Morph as Char
    import String.Morph as Text
    import N exposing (n3)

    -- we want `exactly 3` letters
    "abcdef" |> narrow (map Text.fromList (exactly n3 Char.letter))
    --> Ok [ 'a', 'b', 'c' ]

    -- not 2 or 4, we want 3
    "ab_def"
        |> narrow (map Text.fromList (exactly n3 Char.letter))
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:3: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '_'."

-}
exactly :
    N (Exactly howMany)
    -> MorphRow broadElement element
    ->
        MorphRow
            broadElement
            (ArraySized (Exactly howMany) element)
exactly repeatCount repeatedMorphRow =
    { description =
        case repeatCount |> N.is n1 of
            Err (N.Below _) ->
                { custom = Emptiable.empty
                , inner = Emptiable.empty
                }

            Ok _ ->
                repeatedMorphRow |> description

            Err (N.Above repeatCountAtLeast2) ->
                { custom =
                    Stack.only
                        ([ "exactly "
                         , repeatCountAtLeast2 |> N.toInt |> String.fromInt
                         ]
                            |> String.concat
                        )
                , inner =
                    ArraySized.repeat
                        (repeatedMorphRow |> description)
                        repeatCountAtLeast2
                        |> ArraySized.maxToInfinity
                        |> ArraySized.minTo n2
                        |> Group
                        |> Emptiable.filled
                }
    , narrow =
        let
            narrowRepeatStep :
                { soFar : ArraySized (Min (Fixed N0)) element }
                ->
                    (Emptiable (Stacked broadElement) Possibly
                     ->
                        Result
                            Error
                            { narrow : ArraySized (Exactly howMany) element
                            , broad : Emptiable (Stacked broadElement) Possibly
                            }
                    )
            narrowRepeatStep { soFar } =
                \broad_ ->
                    case soFar |> ArraySized.hasAtLeast (repeatCount |> N.maxUp n1) of
                        Ok arraySizedAtLeastHowOften ->
                            { narrow =
                                arraySizedAtLeastHowOften
                                    |> ArraySized.take ( Up, repeatCount )
                            , broad = broad_
                            }
                                |> Ok

                        Err _ ->
                            case broad_ |> narrowWith repeatedMorphRow of
                                Err error ->
                                    error |> Err

                                Ok parsed ->
                                    -- does this blow the stack?
                                    narrowRepeatStep
                                        { soFar =
                                            ArraySized.minDown n1
                                                (ArraySized.pushMin parsed.narrow soFar)
                                        }
                                        parsed.broad
        in
        narrowRepeatStep { soFar = ArraySized.empty |> ArraySized.maxToInfinity }
    , broaden =
        \repeated ->
            repeated
                |> ArraySized.toList
                |> Stack.fromList
                |> Stack.map (\_ -> broadenWith repeatedMorphRow)
                |> Stack.flatten
    }


{-| Match a value at least a number of times and returns them as a `List`.

> ℹ️ Equivalent regular expression: `{min,}`

    import Morph.Error
    import Char.Morph as Char
    import String.Morph as Text

    -- we want at least three letters, we are okay with more than three
    "abcdef"
        |> Text.narrowWith (atLeast n3 Char.letter)
    --> Ok [ 'a', 'b', 'c', 'd', 'e', 'f' ]

    -- but not two, that's sacrilegious
    "ab_def"
        |> Text.narrowWith (atLeast n3 Char.letter)
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:3: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '_'."


## `atLeast n0`

> ℹ️ Equivalent regular expression: `*`

    import Char.Morph as Char
    import String.Morph as Text

    -- We want as many letters as there are.
    "abc" |> Text.narrowWith (atLeast n0 Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    "abc123" |> Text.narrowWith (atLeast n0 Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    -- even zero letters is okay
    "123abc" |> Text.narrowWith (atLeast n0 Char.letter)
    --> Ok []


### `atLeast n1`

> ℹ️ Equivalent regular expression: `+`

    import N exposing (n1)
    import Morph.Error
    import Char.Morph as Char
    import String.Morph as Text

    -- we want as many letters as there are
    "abc" |> Text.narrowWith (atLeast n1 Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    "abc123" |> Text.narrowWith (atLeast n1 Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    -- but we want at least one
    "123abc"
        |> Text.narrowWith (atLeast n1 Char.letter)
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:1: I was expecting a letter a|..|z or A|...|Z. I got stuck when I got the character '1'."


### example: interspersed separators

    import Stack
    import Morph exposing (separatedBy, atLeast, one)
    import String.Morph as Text exposing (text)
    import Char.Morph as Char


    tag =
        atLeast n0 (Morph.AToZ.caseAnyLower |> one)

    tags =
        succeed (\first afterFirst -> Stack.topDown first afterFirst)
            |> grab .first tag
            |> grab .afterFirst
                (ArraySized.Morph.toList
                    |> Morph.overRow
                        (atLeast n0
                            (succeed (\part -> part)
                                |> skip separator
                                |> grab .tag tag
                            )
                        )
                )

    -- note that both values and separators must be of the same type
    "a,bc,def"
        |> Text.narrowWith tags
    --> Ok
    -->     { first = [ 'a' ]
    -->     , afterFirst =
    -->         [ { separator = (), part = [ 'b', 'c' ] }
    -->         , { separator = (), part = [ 'd', 'e', 'f' ] }
    -->         ]
    -->     }

    ",a,,"
        |> Text.narrowWith tags
    --> Ok
    -->     (Stack.topDown
    -->         []
    -->         [ { separator = (), part = [ 'a' ] }
    -->         , { separator = (), part = [] }
    -->         , { separator = (), part = [] }
    -->         ]
    -->     )

    -- an empty input text gives a single element from an empty string
    ""
        |> Text.narrowWith tags
    --> Ok (topDown [] [])


### anti-example: parsing infinitely

    succeed ...
        |> grab (atLeast n0 (Morph.keep |> Morph.one))
        |> grab ...

would only parse the first part until the end
because it always [`succeed`](#succeed)s.
Nothing after would ever be parsed, making the whole thing fail.

-}
atLeast :
    N (In (Fixed lowerLimitMin) (Up minNewMaxToMin_ To min))
    -> MorphRow broadElement narrow
    ->
        MorphRowIndependently
            broadElement
            (ArraySized (In (Fixed min) max_) narrow)
            (ArraySized (Min (Fixed lowerLimitMin)) narrow)
atLeast minimum =
    \elementStepMorphRow ->
        broaden (ArraySized.minTo minimum >> ArraySized.maxToInfinity)
            |> overRow
                (let
                    minimumExactly =
                        minimum |> N.min |> N.exactly
                 in
                 succeed
                    (\minimumArraySized overMinimum ->
                        minimumArraySized
                            |> ArraySized.glueMin Up
                                (overMinimum |> ArraySized.minTo n0)
                    )
                    |> grab
                        (ArraySized.take ( Up, minimumExactly ))
                        (exactly minimumExactly elementStepMorphRow)
                    |> grab
                        (ArraySized.dropMin ( Up, minimumExactly ))
                        (translate ArraySized.fromList ArraySized.toList
                            |> overRow (untilFail elementStepMorphRow)
                        )
                )


untilFail :
    MorphRow broadElement element
    -> MorphRow broadElement (List element)
untilFail elementStepMorphRow =
    whileAccumulate
        { initial = ()
        , step = \_ () -> () |> Ok
        , element = elementStepMorphRow
        }


{-| [Morph](#MorphRow) multiple elements from now to when `end` matches.

    decoderNameSubject : MorphRow String Char expectationCustom
    decoderNameSubject =
        Text.fromList
            |> Morph.overRow
                (MorphRow.before
                    { end =
                        MorphRow.succeed ()
                            |> skip (String.Morph.only "Decoder")
                            |> skip Morph.end
                    , goOn = Morph.keep |> Morph.one
                    }
                )

You might think: Why not use

    decoderNameSubject : MorphRow String Char expectationCustom
    decoderNameSubject =
        MorphRow.succeed (\subject -> subject)
            |> grab (\subject -> subject)
                (atLeast n0 (Morph.keep |> Morph.one))
            |> skip (String.Morph.only "Decoder")
            |> skip Morph.end

Problem is: This will never succeed.
`atLeast n0 (Morph.keep |> Morph.one)` always goes on.
We never reach the necessary [`skip`](#skip)ped things.

-}
before :
    { end : MorphRow broadElement ()
    , goOn : MorphRow broadElement goOnElement
    }
    -> MorphRow broadElement (List goOnElement)
before untilStep =
    until
        { commit =
            translate .before
                (\before_ -> { before = before_, end = () })
        , end = untilStep.end
        , goOn = untilStep.goOn
        }


{-| How are [`in_`](#in_), ... defined?

    decoderNameSubject : MorphRow String Char expectationCustom
    decoderNameSubject =
        Text.fromList
            |> Morph.overRow
                (MorphRow.until
                    { commit =
                        translate .before
                            (\before -> { before = before, end = () })
                    , end =
                        MorphRow.succeed ()
                            |> skip (String.Morph.only "Decoder")
                            |> skip Morph.end
                    , goOn = Morph.keep |> Morph.one
                    }
                )

↑ can be simplified with [`before`](#before)

Any kind of structure validation that if it fails should proceed to `goOn`
must be in `commit`

-}
until :
    { commit :
        Morph
            commitResult
            { end : endElement
            , before : List goOnElement
            }
    , end : MorphRow broadElement endElement
    , goOn : MorphRow broadElement goOnElement
    }
    -> MorphRow broadElement commitResult
until untilStep =
    let
        loopStep =
            choice
                (\commit goOn loopStepNarrow ->
                    case loopStepNarrow of
                        Commit commitElement ->
                            commit commitElement

                        GoOn goOnELement ->
                            goOn goOnELement
                )
                |> rowTry Commit untilStep.end
                |> rowTry GoOn untilStep.goOn
                |> rowChoiceFinish
    in
    { description =
        { custom = Emptiable.empty
        , inner =
            Over
                { narrow = untilStep.commit |> description
                , broad =
                    { custom = Emptiable.empty
                    , inner =
                        Until
                            { end = untilStep.end |> description
                            , element = untilStep.goOn |> description
                            }
                            |> Emptiable.filled
                    }
                }
                |> Emptiable.filled
        }
    , broaden =
        let
            broadenStepBack :
                ()
                ->
                    (List goOnElement
                     -> Emptiable (Stacked broadElement) Possibly
                    )
            broadenStepBack () =
                \toStep ->
                    case toStep of
                        [] ->
                            Emptiable.empty

                        top :: tail ->
                            (top |> GoOn)
                                |> broadenWith loopStep
                                |> Stack.onTopStack
                                    (tail |> broadenStepBack ())
        in
        \commitResultNarrow ->
            let
                committedBack =
                    commitResultNarrow
                        |> broadenWith untilStep.commit
            in
            (committedBack.before
                |> List.reverse
                |> broadenStepBack ()
            )
                |> Stack.onTopStack
                    ((committedBack.end |> Commit)
                        |> broadenWith loopStep
                    )
    , narrow =
        let
            loopNarrowStep :
                ()
                ->
                    (List goOnElement
                     ->
                        (Emptiable (Stacked broadElement) Possibly
                         ->
                            Result
                                Error
                                { narrow : commitResult
                                , broad : Emptiable (Stacked broadElement) Possibly
                                }
                        )
                    )
            loopNarrowStep () =
                \before_ ->
                    narrowWith loopStep
                        >> Result.andThen
                            (\stepped ->
                                case stepped.narrow of
                                    Commit committed ->
                                        case
                                            { before = before_, end = committed }
                                                |> narrowWith untilStep.commit
                                        of
                                            Err error ->
                                                { error = error
                                                , startDown = stepped.broad |> Stack.length
                                                }
                                                    |> Row
                                                    |> Err

                                            Ok commitResult ->
                                                { broad = stepped.broad
                                                , narrow = commitResult
                                                }
                                                    |> Ok

                                    GoOn goOnElement ->
                                        stepped.broad
                                            |> (before_ |> (::) goOnElement |> loopNarrowStep ())
                            )
        in
        [] |> loopNarrowStep ()
    }


{-| Match a value between a range of times and returns them as a `List`.

> ℹ️ Equivalent regular expression: `{min,max}`

    import Morph.Error
    import Char.Morph as Char
    import String.Morph as Text

    -- we want between two and four letters
    "abcdef" |> Text.narrowWith (in_ 2 4 Char.letter)
    --> Ok [ 'a', 'b', 'c', 'd' ]

    "abc_ef" |> Text.narrowWith (in_ ( n2, n4 ) Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    "ab_def" |> Text.narrowWith (in_ ( n2, n4 ) Char.letter)
    --> Ok [ 'a', 'b' ]


    -- but less than that is not cool
    "i_am_here"
        |> Text.narrowWith (in_ ( n2, n3 ) letter)
        |> Result.mapError Morph.Error.textMessage
    --> Err "1:2: I was expecting a letter [a-zA-Z]. I got stuck when I got the character '_'."


### example: `in_ ( n0, n1 )`

Alternative to [`maybe`](#maybe) which instead returns a `List`.

> ℹ️ Equivalent regular expression: `?`

    import Char.Morph as Char
    import String.Morph as Text

    -- we want one letter, optionally
    "abc" |> Text.narrowWith (in_ ( n0, n1 ) Char.letter)
    --> Ok [ 'a' ]

    -- if we don't get any, that's still okay
    "123abc" |> Text.narrowWith (in_ ( n0, n1 ) Char.letter)
    --> Ok []


### example: at most

> ℹ️ Equivalent regular expression: `{0,max}`

    import Morph
    import Char.Morph as Char
    import String.Morph as Text

    -- we want a maximum of three letters
    "abcdef" |> Text.narrowWith (in_ ( n0, n3 ) Char.letter)
    --> Ok [ 'a', 'b', 'c' ]

    -- less than that is also okay
    "ab_def" |> Text.narrowWith (in_ ( n0, n3 ) Char.letter)
    --> Ok [ 'a', 'b' ]

    -- even zero letters are fine
    "_underscore" |> Text.narrowWith (in_ ( n0, n3 ) Char.letter)
    --> Ok []

    -- make sure we don't consume more than three letters
    "abcdef"
        |> Text.narrowWith
            (succeed (\letters -> letters)
                |> grab (in_ ( n0, n3 ) Char.letter)
                |> skip (one 'd')
            )
    --> Ok [ 'a', 'b', 'c' ]

-}
in_ :
    ( N (In (Fixed lowerLimitMin) (Up minToLowerLimitMin_ To min))
    , N (In (Fixed lowerLimitMin) (Fixed upperLimitMax))
    )
    -> MorphRow broadElement element
    ->
        MorphRowIndependently
            broadElement
            (ArraySized
                (In (Fixed min) (Up maxToUpperLimitMax_ To upperLimitMax))
                element
            )
            (ArraySized
                (InFixed lowerLimitMin upperLimitMax)
                element
            )
in_ ( lowerLimit, upperLimit ) repeatedElementMorphRow =
    translate identity
        (ArraySized.minTo lowerLimit)
        |> overRow
            (let
                lowerLimitExactly =
                    lowerLimit |> N.min |> N.exactly
             in
             succeed
                (\minimumList overMinimum ->
                    minimumList
                        |> ArraySized.glueMin Up (overMinimum |> ArraySized.minTo n0)
                        |> ArraySized.minTo lowerLimitExactly
                        |> ArraySized.take ( Up, upperLimit )
                )
                |> grab
                    (ArraySized.take
                        ( Up
                        , lowerLimitExactly
                        )
                    )
                    (exactly lowerLimitExactly repeatedElementMorphRow)
                |> grab
                    (ArraySized.dropMin ( Up, lowerLimitExactly )
                        >> ArraySized.maxToInfinity
                    )
                    (atMostLoop
                        ((upperLimit |> N.toInt)
                            - (lowerLimit |> N.toInt)
                            |> N.intAtLeast n0
                        )
                        repeatedElementMorphRow
                    )
            )


{-| Match a value at less or equal a number of times.

**Shouldn't be exposed**

-}
atMostLoop :
    N
        (In
            upperLimitMin_
            (Up upperLimitMaxX_ To upperLimitMaxPlusX_)
        )
    -> MorphRow broadElement narrow
    ->
        MorphRowIndependently
            broadElement
            (ArraySized (In min_ max_) narrow)
            (ArraySized (Min (Up narrowX To narrowX)) narrow)
atMostLoop upperLimit elementStepMorphRow =
    to
        ([ "<= ", upperLimit |> N.toInt |> String.fromInt ]
            |> String.concat
        )
        (translate ArraySized.fromList ArraySized.toList
            |> overRow
                (whileAccumulate
                    { initial = { length = n0 |> N.maxToInfinity }
                    , step =
                        \_ soFar ->
                            case soFar.length |> N.isAtLeast (upperLimit |> N.maxUp n1) of
                                Ok _ ->
                                    Err ()

                                Err _ ->
                                    { length = soFar.length |> N.addMin n1 } |> Ok
                    , element = elementStepMorphRow
                    }
                )
        )


{-| How are [`atLeast`](#atLeast), ... defined?

    import Morph exposing (choice, validate)
    import Morph exposing (MorphRow, one, succeed, atLeast, take, drop, whileAccumulate)
    import Char.Morph
    import String.Morph
    import Number.Morph

    sumWhileLessThan : Float -> MorphRow Char (List Number)
    sumWhileLessThan max =
        whileAccumulate
            { initial = 0
            , step =
                \element stepped ->
                    let
                        floats =
                            stepped + (element |> Morph.map Number.Morph.toFloat)
                    in
                    if floats >= max then
                        Err ()
                    else
                        floats |> Ok
            , element =
                succeed (\n -> n)
                    |> grab (\n -> n) Number.Morph.text
                    |> skip (atLeast n0 (String.Morph.only " "))
            }

    -- stops before we reach a maximum of 6 in the sum
    "2 3 4"
        |> narrow
            (String.Morph.fromList
                |> Morph.overRow
                    (succeed (\numbers -> numbers)
                        |> grab (\numbers -> numbers) (sumWhileLessThan 6)
                        |> skip (String.Morph.only "4")
                    )
            )
    --> Ok 5

-}
whileAccumulate :
    { initial : accumulationValue
    , step :
        goOnElement
        -> accumulationValue
        -> Result () accumulationValue
    , element : MorphRow broadElement goOnElement
    }
    -> MorphRow broadElement (List goOnElement)
whileAccumulate { initial, step, element } =
    { description =
        { custom = Emptiable.empty
        , inner =
            While (element |> description)
                |> Emptiable.filled
        }
    , broaden =
        List.map (broadenWith element)
            >> Stack.fromList
            >> Stack.flatten
    , narrow =
        let
            loopNarrowStep :
                { accumulationValue : accumulationValue }
                ->
                    (Emptiable (Stacked broadElement) Possibly
                     ->
                        Result
                            Error
                            { narrow : List goOnElement
                            , broad : Emptiable (Stacked broadElement) Possibly
                            }
                    )
            loopNarrowStep { accumulationValue } =
                \broad_ ->
                    broad_
                        |> narrowWith element
                        |> Result.andThen
                            (\stepped ->
                                case accumulationValue |> step stepped.narrow of
                                    Err () ->
                                        { broad = broad_
                                        , narrow = []
                                        }
                                            |> Ok

                                    Ok accumulationValueAltered ->
                                        stepped.broad
                                            |> loopNarrowStep
                                                { accumulationValue = accumulationValueAltered }
                                            |> Result.map
                                                (\tail ->
                                                    { broad = tail.broad
                                                    , narrow =
                                                        tail.narrow
                                                            |> (::) stepped.narrow
                                                    }
                                                )
                            )
        in
        loopNarrowStep { accumulationValue = initial }
    }


{-| How to continue this `loop`.
Either continue with a partial result or return with a complete value
-}
type LoopStep partial complete
    = GoOn partial
    | Commit complete


{-| Only matches when there's no further broad input afterwards.

This is not required for [`narrow`](#narrow)ing to succeed.

It can, however simplify checking for specific endings:

    decoderNameSubject : MorphRow String Char expectationCustom
    decoderNameSubject =
        Text.fromList
            |> Morph.overRow
                (MorphRow.until
                    { commit =
                        translate .before
                            (\before -> { before = before, end = () })
                    , end =
                        MorphRow.succeed ()
                            |> skip (String.Morph.only "Decoder")
                            |> skip Morph.end
                    , goOn = Morph.keep |> Morph.one
                    }
                )

-}
end : MorphRow broadElement_ ()
end =
    { description =
        { custom = Stack.only "end"
        , inner = Emptiable.empty
        }
    , narrow =
        \broad_ ->
            case broad_ of
                Emptiable.Empty _ ->
                    Emptiable.empty |> narrowWith (succeed ())

                Emptiable.Filled stacked ->
                    { startDown = stacked |> filled |> Stack.length
                    , error = "remaining input" |> DeadEnd
                    }
                        |> Row
                        |> Err
    , broaden =
        \() -> Emptiable.empty
    }


{-| Final step before running a [`MorphRow`](#MorphRow),
transforming it into a [`Morph`](#Morph) on the full stack of input elements.

    fromString =
        narrowWith
            (Point.morphRowChar
                |> Morph.rowFinish
                |> Morph.over Stack.Morph.toString
            )

-}
rowFinish :
    MorphRow broadElement narrow
    -> Morph narrow (Emptiable (Stacked broadElement) Possibly)
rowFinish =
    \morphRow ->
        { description = morphRow.description
        , narrow =
            narrowWith (morphRow |> skip end)
                >> Result.map .narrow
        , broaden =
            broadenWith morphRow
        }
