module NaturalAtLeast1 exposing
    ( n1
    , add
    , chars
    )

{-| Helpers for [`Natural.AtLeast1`](Natural#AtLeast1)

@docs n1


## alter

@docs add


## morph

@docs chars

-}

import ArraySized exposing (ArraySized)
import Bit exposing (Bit)
import Emptiable
import Linear exposing (Direction(..))
import Morph exposing (MorphRow)
import N exposing (Min, N, N0, N1, On, n0)
import Natural
import NaturalAtLeast1.Internal


{-| The [positive natural number](#Natural.AtLeast1) 1
-}
n1 : Natural.AtLeast1
n1 =
    NaturalAtLeast1.Internal.n1


add :
    Natural.AtLeast1
    -> (Natural.AtLeast1 -> Natural.AtLeast1)
add toAdd =
    \naturalPositive ->
        let
            bitsSum : { inRange : ArraySized Bit (Min (On N1)), overflow : Bit }
            bitsSum =
                naturalPositive |> addBits toAdd

            sumBitsAfterI : ArraySized Bit (Min (On N0))
            sumBitsAfterI =
                case bitsSum.overflow of
                    Bit.I ->
                        bitsSum.inRange
                            |> ArraySized.minTo n0

                    Bit.O ->
                        bitsSum.inRange
                            |> ArraySized.removeMin ( Up, n0 )
        in
        { bitsAfterI =
            sumBitsAfterI |> ArraySized.minToNumber
        }


addBits :
    Natural.AtLeast1
    ->
        (Natural.AtLeast1
         ->
            { inRange : ArraySized Bit (Min (On N1))
            , overflow : Bit
            }
        )
addBits toAdd =
    \naturalAtLeast1 ->
        let
            bits : ArraySized Bit (Min (On N1))
            bits =
                naturalAtLeast1 |> toBits

            bitsToAdd : ArraySized Bit (Min (On N1))
            bitsToAdd =
                toAdd |> toBits

            lengthMaximum : N (Min (On N1))
            lengthMaximum =
                N.greater
                    (bits |> ArraySized.length)
                    (bitsToAdd |> ArraySized.length)

            addResult =
                ArraySized.upTo (lengthMaximum |> N.subtractMin N.n1 |> N.maxToOn)
                    |> ArraySized.maxToInfinity
                    |> ArraySized.mapFoldFrom Bit.O
                        Down
                        (\step ->
                            let
                                bit =
                                    \bitArray ->
                                        bitArray
                                            |> ArraySized.elementTry ( Up, step.element )
                                            |> Emptiable.fillElseOnEmpty (\_ -> Bit.O)
                            in
                            case ( bits |> bit, bitsToAdd |> bit, step.folded ) of
                                ( Bit.O, Bit.O, overflowSoFar ) ->
                                    { element = overflowSoFar, folded = Bit.O }

                                ( Bit.I, Bit.I, overflowSoFar ) ->
                                    { element = overflowSoFar, folded = Bit.I }

                                ( Bit.I, Bit.O, Bit.O ) ->
                                    { element = Bit.I, folded = Bit.O }

                                ( Bit.O, Bit.I, Bit.O ) ->
                                    { element = Bit.I, folded = Bit.O }

                                ( Bit.I, Bit.O, Bit.I ) ->
                                    { element = Bit.O, folded = Bit.I }

                                ( Bit.O, Bit.I, Bit.I ) ->
                                    { element = Bit.O, folded = Bit.I }
                        )
        in
        { inRange = addResult.mapped, overflow = addResult.folded }


toBits :
    Natural.AtLeast1
    -> ArraySized Bit (Min (On N1))
toBits =
    \naturalAtLeast1 ->
        naturalAtLeast1.bitsAfterI
            |> ArraySized.minToOn
            |> ArraySized.insertMin ( Up, n0 ) Bit.I


chars : MorphRow Natural.AtLeast1 Char
chars =
    NaturalAtLeast1.Internal.chars
