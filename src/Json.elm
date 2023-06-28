module Json exposing
    ( Json, Atom(..), Composed(..), Tagged
    , value
    , string, stringBroadWith
    , tagMap, eachTag
    , JsValueMagic, jsValueMagic
    )

{-| JSON

@docs Json, Atom, Composed, Tagged


## morph

@docs value
@docs string, stringBroadWith


## tag

@docs tagMap, eachTag


## js value magic

@docs JsValueMagic, jsValueMagic

-}

import Array
import Decimal exposing (Decimal)
import Decimal.Morph
import DecimalOrException
import Emptiable
import Json.Decode
import Json.Encode
import Morph exposing (Morph, MorphIndependently, oneToOne)
import Possibly exposing (Possibly(..))
import RecordWithoutConstructorFunction exposing (RecordWithoutConstructorFunction)
import Stack
import Tree
import Value exposing (AtomOrComposed(..))


{-| A value from the javascript side:
from a [`port`](https://guide.elm-lang.org/interop/ports.html),
on `init`,
from [`elm/http`](https://package.elm-lang.org/packages/elm/http/latest), ...

Compiler magic. Not `case`able. Elm crashes on `==`.
Can include functions, proxies, getters, bigInts, anything

and.. of course this can be abused to break elm's promises 🙈, see for example

  - [randomness without `Cmd` ellie](https://ellie-app.com/hpXzJxh4HRda1)
  - web-audio examples
      - [`WebAudio.Context.currentTime`](https://package.elm-lang.org/packages/pd-andy/elm-web-audio/latest/WebAudio-Context#currentTime)
      - [`WebAudio.Context.AudioContext`](https://package.elm-lang.org/packages/pd-andy/elm-web-audio/latest/WebAudio-Context#AudioContext)
  - [`getBoundingClientRect`](https://github.com/funk-team/funkLang/blob/master/src/domMonkeyPatches.js#L44)
  - [listening to events outside a given element](https://github.com/funk-team/funkLang/blob/master/src/domMonkeyPatches/eventsOutside.js#L21)

-}
type alias JsValueMagic =
    Json.Encode.Value


{-| A valid JSON value. `case`able. Elm doesn't crash on `==`.
Can't contain any [spooky impure stuff](#JsValueMagic)
-}
type alias Json tag =
    AtomOrComposed Atom (Composed tag)


{-| json atom. null, bool, number, string
-}
type Atom
    = Null ()
    | Bool Bool
    | Number Decimal
    | String String


{-| json structure. record/object/dict or array
-}
type Composed tag
    = Array (Array.Array (Json tag))
    | Object (List (Tagged tag))


{-| tag-[value](#Json) pair used to represent a field
-}
type alias Tagged tag =
    RecordWithoutConstructorFunction
        { tag : tag, value : Json tag }


{-| Should be redundant if `anyDecoder` catches all cases
-}
decodeErrorToMorph : Json.Decode.Error -> Morph.Error
decodeErrorToMorph =
    \decodeError ->
        case decodeError of
            Json.Decode.Field fieldName error ->
                Morph.ElementsError ({ location = fieldName, error = error |> decodeErrorToMorph } |> Stack.one)

            Json.Decode.Index arrayIndex error ->
                { index = arrayIndex
                , error = error |> decodeErrorToMorph
                }
                    |> Stack.one
                    |> Morph.PartsError

            Json.Decode.OneOf possibilities ->
                case possibilities |> Stack.fromList of
                    Emptiable.Empty Possible ->
                        "missing expected possibilities in Json.Decode.oneOf"
                            |> Morph.DeadEnd

                    Emptiable.Filled stacked ->
                        stacked
                            |> Emptiable.filled
                            |> Stack.map (\_ -> decodeErrorToMorph)
                            |> Morph.ChoiceError

            Json.Decode.Failure custom jsValue ->
                [ custom
                , "\n\n"
                , "    "
                , jsValue
                    |> Json.Encode.encode 4
                    |> String.lines
                    |> String.join "    "
                ]
                    |> String.concat
                    |> Morph.DeadEnd


jsValueMagicEncode : () -> (Json String -> JsValueMagic)
jsValueMagicEncode () =
    \jsonAny ->
        case jsonAny of
            Atom atom ->
                atom |> atomJsValueMagicEncode

            Composed composed ->
                composed |> composedJsValueMagicEncode ()


atomJsValueMagicEncode : Atom -> JsValueMagic
atomJsValueMagicEncode =
    \atom ->
        case atom of
            Null () ->
                Json.Encode.null

            Bool boolAtom ->
                boolAtom |> Json.Encode.bool

            Number floatAtom ->
                floatAtom
                    |> Morph.toBroad
                        (Decimal.Morph.orException |> Morph.over DecimalOrException.float)
                    |> Json.Encode.float

            String stringAtom ->
                stringAtom |> Json.Encode.string


{-| Some elm functions,
[for example html events](https://dark.elm.dmy.fr/packages/elm/html/latest/Html-Events#on)
require a `Json.Decode.Decoder`,
which is an opaque type and can't be constructed (for example by from `Json.Decode.Value -> Result Json.Error elm`)

In general, try to use [`Json.jsValueMagic`](#jsValueMagic) instead wherever possible

-}
jsValueMagicDecoder : Json.Decode.Decoder (Json String)
jsValueMagicDecoder =
    Json.Decode.oneOf
        [ Json.Decode.map Atom jsonAtomDecoder
        , Json.Decode.map Composed jsonComposedDecoder
        ]


jsonAtomDecoder : Json.Decode.Decoder Atom
jsonAtomDecoder =
    Json.Decode.oneOf
        [ Null () |> Json.Decode.null
        , Json.Decode.map Bool Json.Decode.bool
        , Json.Decode.andThen
            (\float ->
                case float |> Morph.toNarrow decimalFloatMorph of
                    Ok decimal ->
                        Number decimal |> Json.Decode.succeed

                    Err exception ->
                        Morph.descriptionAndErrorToTree (decimalFloatMorph |> Morph.description) exception
                            |> Tree.map .text
                            |> Morph.treeToLines
                            |> String.join "\n"
                            |> Json.Decode.fail
            )
            Json.Decode.float
        , Json.Decode.map String Json.Decode.string
        ]


decimalFloatMorph : Morph Decimal Float
decimalFloatMorph =
    Decimal.Morph.orException
        |> Morph.over DecimalOrException.float


{-| [Morph](Morph#Morph) to valid [`Json` value](#Json) format from [`JsValueMagic`](#JsValueMagic)

About json numbers...

  - json numbers don't strictly adhere to a `Float`
    as defined in the [IEEE 754 standard][ieee]
    which is hardcoded into almost all CPUs.
    This standard allows `Infinity` and `NaN` which the [json.org spec][json] does not include.
  - [`elm/json` silently encodes both as `null`](https://github.com/elm/json/blob/0206c00884af953f2cba8823fee111ee71a0330e/src/Json/Encode.elm#L106).
    This behavior matches `JSON.stringify` behavior in plain JS
  - our json representation doesn't have this footgun since it uses [`Decimal`](Decimal#Decimal)
  - elm `Decoder`s/`Encoder`s can only handle `Float` range which dictates the range we can use for [`Decimal`](Decimal#Decimal)s

[ieee]: https://en.wikipedia.org/wiki/IEEE_754
[json]: https://www.json.org/

-}
jsValueMagic : Morph (Json String) JsValueMagic
jsValueMagic =
    Morph.named "JSON"
        { description = Morph.CustomDescription
        , toNarrow =
            \jsValueMagicBeforeNarrow ->
                jsValueMagicBeforeNarrow
                    |> Json.Decode.decodeValue jsValueMagicDecoder
                    |> Result.mapError decodeErrorToMorph
        , toBroad = jsValueMagicEncode ()
        }


{-| [Morph](Morph#Morph) to valid [`Json` value](#Json) format from a `String`

[Broadens](Morph#toBroad) to a compact `String`.
To adjust format readability → [`stringBroadWith`](#stringBroadWith)

-}
string : Morph (Json String) String
string =
    stringBroadWith { indentation = 0 }


{-| [`Json.string`](#string) [Morph](Morph#Morph) with adjustable readability configuration
-}
stringBroadWith : { indentation : Int } -> Morph (Json String) String
stringBroadWith { indentation } =
    Morph.named "JSON"
        { description = Morph.CustomDescription
        , toNarrow =
            \jsValueMagicBroad ->
                jsValueMagicBroad
                    |> Json.Decode.decodeString jsValueMagicDecoder
                    |> Result.mapError decodeErrorToMorph
        , toBroad =
            \json ->
                json
                    |> jsValueMagicEncode ()
                    |> Json.Encode.encode indentation
        }


composedJsValueMagicEncode : () -> (Composed String -> JsValueMagic)
composedJsValueMagicEncode () =
    \composedAny ->
        case composedAny of
            Array arrayAny ->
                arrayAny
                    |> Json.Encode.array (jsValueMagicEncode ())

            Object objectAny ->
                objectAny
                    |> List.map
                        (\field ->
                            ( field.tag
                            , field.value |> jsValueMagicEncode ()
                            )
                        )
                    |> Json.Encode.object


jsonComposedDecoder : Json.Decode.Decoder (Composed String)
jsonComposedDecoder =
    Json.Decode.lazy
        (\() ->
            Json.Decode.oneOf
                [ Json.Decode.map Array
                    (Json.Decode.array jsValueMagicDecoder)
                , Json.Decode.map Object
                    (Json.Decode.keyValuePairs jsValueMagicDecoder
                        |> Json.Decode.map
                            (\keyValuePairs ->
                                keyValuePairs
                                    |> List.map
                                        (\( tag, v ) -> { tag = tag, value = v })
                            )
                    )
                ]
        )


toValue : Json Value.IndexAndName -> Value.Value Value.IndexAndName
toValue =
    \json ->
        case json of
            Atom atom ->
                atom |> atomToValue

            Composed composed ->
                composed |> composedToValue |> Composed


atomToValue : Atom -> Value.Value Value.IndexAndName
atomToValue =
    \atom ->
        case atom of
            Null unit ->
                unit |> Value.Unit |> Atom

            Number decimal ->
                decimal |> Value.Number |> Atom

            String string_ ->
                string_ |> Value.String |> Atom

            Bool bool ->
                { value = () |> Value.Unit |> Atom
                , tag =
                    if bool then
                        { index = 0, name = "False" }

                    else
                        { index = 1, name = "True" }
                }
                    |> Value.Variant
                    |> Composed


fromValueImplementation : Value.Value tag -> Json tag
fromValueImplementation =
    \json ->
        case json of
            Atom atom ->
                atom |> atomFromValue |> Atom

            Composed composed ->
                composed |> composedFromValue |> Composed



-- tag


atomFromValue : Value.Atom -> Atom
atomFromValue =
    \atom ->
        case atom of
            Value.Unit () ->
                Null ()

            Value.String stringAtom ->
                stringAtom |> String

            Value.Number decimal ->
                decimal |> Number


{-| Convert a [representation of an elm value](Value#Value) to a [valid `Json` value](#Json)
-}
value :
    MorphIndependently
        (Value.Value narrowTag
         -> Result error_ (Json narrowTag)
        )
        (Json Value.IndexAndName
         -> Value.Value Value.IndexAndName
        )
value =
    oneToOne fromValueImplementation toValue


composedToValue :
    Composed Value.IndexAndName
    -> Value.Composed Value.IndexAndName
composedToValue =
    \composed ->
        case composed of
            Array array ->
                array |> Array.map toValue |> Value.Array

            Object object ->
                object
                    |> List.map
                        (\tagged ->
                            { tag = tagged.tag
                            , value = tagged.value |> toValue
                            }
                        )
                    |> Value.Record


composedFromValue : Value.Composed tag -> Composed tag
composedFromValue =
    \composed ->
        case composed of
            Value.List list ->
                list |> List.map fromValueImplementation |> Array.fromList |> Array

            Value.Array array ->
                array |> Array.map fromValueImplementation |> Array

            Value.Record record ->
                record
                    |> List.map
                        (\field ->
                            { tag = field.tag
                            , value = field.value |> fromValueImplementation
                            }
                        )
                    |> Object

            Value.Variant variant ->
                { tag = variant.tag, value = variant.value |> fromValueImplementation }
                    |> List.singleton
                    |> Object



-- Decimal


{-| [`OneToOne`](Morph#OneToOne) [`Json`](#Json) by calling [`tagMap`](#tagMap) in both directions

    ...
        |> Morph.over (Json.eachTag Value.compact)

    -- or
    ...
        |> Morph.over (Json.eachTag Value.descriptive)

Links: [`Value.compact`](Value#compact), [`Value.descriptive`](Value#descriptive)

-}
eachTag :
    MorphIndependently
        (tagBeforeMap -> Result (Morph.ErrorWithDeadEnd Never) tagMapped)
        (tagBeforeUnmap -> tagUnmapped)
    ->
        MorphIndependently
            (Json tagBeforeMap
             -> Result (Morph.ErrorWithDeadEnd never_) (Json tagMapped)
            )
            (Json tagBeforeUnmap -> Json tagUnmapped)
eachTag tagTranslate_ =
    Morph.oneToOneOn ( tagMap, tagMap ) tagTranslate_


{-| Reduce the amount of tag information.
Used to make its representation [`compact`](Value#compact) or [`descriptive`](Value#descriptive)
-}
tagMap : (tag -> tagMapped) -> (Json tag -> Json tagMapped)
tagMap tagChange =
    \json ->
        json |> Value.composedMap (composedTagMap tagChange)


composedTagMap :
    (tag -> tagMapped)
    -> (Composed tag -> Composed tagMapped)
composedTagMap tagChange =
    \composed ->
        case composed of
            Array array ->
                array |> Array.map (tagMap tagChange) |> Array

            Object object ->
                object |> List.map (taggedTagMap tagChange) |> Object


taggedTagMap : (tag -> tagMapped) -> (Tagged tag -> Tagged tagMapped)
taggedTagMap tagChange =
    \tagged ->
        { tag = tagged.tag |> tagChange
        , value = tagged.value |> tagMap tagChange
        }
