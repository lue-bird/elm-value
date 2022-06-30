module Array.Morph exposing
    ( fromList, toList
    , elementEach
    )

{-| [`Morph`](Morph) an `Array`


## `List`

@docs fromList, toList


## each

@docs elementEach

-}

import Array exposing (Array)
import Morph exposing (Morph, Translate, translate)


{-| [`Translate`](Morph#Translate) from `List` to `Array`.

    import Array

    [ 0, 1, 2, 3 ]
        |> (Morph.listToArray |> Morph.map)
    --> Array.fromList [ 0, 1, 2, 3 ]

-}
fromList : Morph (List element) (Array element) error_
fromList =
    translate Array.fromList Array.toList


{-| [`Translate`](Morph#Translate) from `Array` to `List`.

    import Array

    Array.fromList [ 0, 1, 2, 3 ]
        |> (Morph.arrayToList |> Morph.map)
    --> [ 0, 1, 2, 3 ]

-}
toList : Morph (Array element) (List element) error_
toList =
    translate Array.toList Array.fromList



--


{-| [`Translate`](Morph#Translate) each element in an `Array`.
-}
elementEach :
    Translate unmapped mapped
    -> Morph (Array unmapped) (Array mapped) error_
elementEach elementTranslate =
    translate
        (Array.map (Morph.map elementTranslate))
        (Array.map (Morph.unmap elementTranslate))