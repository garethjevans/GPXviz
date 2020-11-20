module Geometry101 exposing (..)

import List
import Arc2d


type alias Point =
    { x : Float
    , y : Float
    }


type alias Road =
    { startAt : Point
    , endsAt : Point
    }


type alias Circle =
    { centre : Point
    , radius : Float
    }


type alias LineEquation =
    { a : Float
    , b : Float
    , c : Float
    }


type alias Matrix =
    { tl : Float
    , tr : Float
    , bl : Float
    , br : Float
    }


type alias Column =
    { t : Float
    , b : Float
    }


type alias Row =
    { l : Float
    , r : Float
    }



{-
   This is about helping to smooth a bend.
   In one case, maybe are looking at only one vertex.
   That is to say, we have one road segment B-P and the next P-C.
   Then we have the three points we need to find the incenter and incircle.
   Note that we are implicitly.

   More generally, suppose we have segments
   AB, BC, CD, DE, EF, FG
   We select at least two contiguous segments.
   Suppose we select (BC, CD).
   This means that points B and D remain, point C will be replaced with
   new segments derived from the incircle of BCD.
   We don't need to find the intersection of BC and CD, we know it.

   Suppose we select (BC, CD, DE).
   This means that B and E remain, C and D will be replaced with
   new segments derived from the incircle of BCP,
   where P is the intersect of (the extensions of) BC and DE.
-}


findIncircleFromRoads : List Road -> Maybe Circle
findIncircleFromRoads roads =
    case roads of
        [] ->
            Nothing

        [ _ ] ->
            Nothing

        [ r1, r2 ] ->
            findIncircleFromTwoRoads r1 r2

        r1 :: rs ->
            findIncircleFromRoads <| r1 :: List.take 1 (List.reverse rs)


findIncircleFromTwoRoads : Road -> Road -> Maybe Circle
findIncircleFromTwoRoads r1 r2 =
    let
        intersection =
            if r1.endsAt == r2.startAt then
                Just r1.endsAt

            else
                findIntercept r1 r2
    in
    case intersection of
        Just p ->
            Just <| findIncircle r1.startAt r2.endsAt p

        --Just  { centre = { x = p.x, y = p.y }, radius = 0.05 }
        Nothing ->
            Nothing


findTangentPoint : Road -> Circle -> Maybe Point
findTangentPoint road incircle =
    {-
       Given the road's line is Ax + By + C = 0,
       the radius is perpendicular hence has line Bx - Ay + D = 0
       and it passes through the circle centre (X, Y) so BX - AY + D = 0
       or D = AY - BX.
       Then we can find the intercept point using existing code.
    -}
    let
        roadLine =
            lineEquationFromTwoPoints road.startAt road.endsAt

        radiusLine =
            { a = roadLine.b, b = -1.0 * roadLine.a, c = aybx }

        aybx =
            roadLine.a * incircle.centre.y - roadLine.b * incircle.centre.x
    in
    lineIntersection roadLine radiusLine


findIncircle : Point -> Point -> Point -> Circle
findIncircle pA pB pC =
    {-
       The centre of the inscribed triangle (incentre) requires the lengths of the sides.
       (The naming convention is that side b is opposite angle B, etc.)
       |b| = |CP| = 2.0
       |c| = |BP| = 1.0
       |p| = |BC| = sqrt 5 = 2.236

       X = (|b|.Bx + |c|.Cx + |p|.Px) / (|b| + |c| + |p|)
         = (2.0 * 3 + 1.0 * 4 + 2.236 * 4) / 5.236
         = 3.618

       Y = (|b|.By + |c|.Cy + |p|.Py) / (|b| + |c| + |p|)
         = (2.0 * 5 + 1.0 * 3 + 2.236 * 5) / 5.236
         = 4.618

       We also derive the radius of the incircle:

       r = sqrt <| (s - b)(s - c)(s - p)/s, where s = (b + c + p)/2

       That should give us enough information to determine the tangent points.
       (The triangle formed by these touchpoints is the Gergonne triangle.)

       In our case, s = 2.618
       r = sqrt <| (2.618 - 2)(2.618 - 1)(2.618 - 2.236)/2.618
         = sqrt 0.1459
         = 0.382
    -}
    let
        a =
            distance pB pC

        b =
            distance pA pC

        c =
            distance pA pB

        perimeter =
            a + b + c

        s =
            perimeter / 2.0

        r =
            sqrt <| (s - a) * (s - b) * (s - c) / s

        x =
            (a * pA.x + b * pB.x + c * pC.x) / perimeter

        y =
            (a * pA.y + b * pB.y + c * pC.y) / perimeter

        distance p1 p2 =
            sqrt <|
                ((p1.x - p2.x)
                    * (p1.x - p2.x)
                )
                    + ((p1.y - p2.y)
                        * (p1.y - p2.y)
                      )
    in
    { centre = { x = x, y = y }
    , radius = r
    }


findIntercept : Road -> Road -> Maybe Point
findIntercept r1 r2 =
    {-
       The intercept P of AB and CD, if it exists, satisfies both equations.

           0 x + 2 y -10 == 0
       &&  2 x - 2 y -2  == 0

       In matrix form  | 0 2  | | x |    | -10 |
                       | 2 -2 | | y | == |  +2 |

       By inverting and multiplying through, the intersect P is
       | x | = | 4 |
       | y |   | 5 |

       We now have three points:
       B = (3,5)    C = (4,3)   P = (4,5)


       Now let us try to draw this circle on the third person view!
    -}
    let
        r1Line =
            lineEquationFromTwoPoints r1.startAt r1.endsAt

        r2Line =
            lineEquationFromTwoPoints r2.startAt r2.endsAt
    in
    lineIntersection r1Line r2Line


lineIntersection : LineEquation -> LineEquation -> Maybe Point
lineIntersection l1 l2 =
    let
        matrix =
            { tl = l1.a
            , tr = l1.b
            , bl = l2.a
            , br = l2.b
            }

        column =
            { t = -1.0 * l1.c, b = -1.0 * l2.c }

        inv =
            matrixInverse matrix
    in
    case inv of
        Just inverse ->
            let
                col =
                    matrixMultiplyColumn inverse column
            in
            Just { x = col.t, y = col.b }

        Nothing ->
            Nothing


matrixInverse : Matrix -> Maybe Matrix
matrixInverse m =
    let
        det =
            m.tl * m.br - m.tr * m.bl
    in
    if abs det < 10 ^ -20 then
        Nothing

    else
        Just
            { tl = m.br / det
            , tr = -1.0 * m.tr / det
            , bl = -1.0 * m.bl / det
            , br = m.tl / det
            }


matrixMultiplyColumn : Matrix -> Column -> Column
matrixMultiplyColumn m c =
    { t = m.tl * c.t + m.tr * c.b
    , b = m.bl * c.t + m.br * c.b
    }


lineEquationFromTwoPoints : Point -> Point -> LineEquation
lineEquationFromTwoPoints p1 p2 =
    {-
       An arrangement of the two point line equation is:
       (y1 - y2) X + (x2 - x1) Y + (x1.y2 - x2.y1) = 0

       For AB this is
       (5.0 - 5.0) X + (3.0 - 1.0) Y + (5.0 - 15.0) = 0
       Thus A = 0, B = 2, C = -10

       To check, for (1,5) : 0 x 1 + 2 x 5 + (-10) == 0
                 for (3,5) : 0 x 3 + 2 x 5 + (-10) == 0

       For CD:
       (3.0 - 1.0) X + (2.0 - 4.0) Y + (4.0 - 6.0) = 0
       Thus A = 2, B = -2, C = -2

       To check, for (4,3) : 2 x 4 + (-2) x 3 + (-2) == 0
                 for (2,1) : 2 x 2 + (-2) x 1 + (-2) == 0
    -}
    let
        a =
            p1.y - p2.y

        b =
            p2.x - p1.x

        c =
            p1.x * p2.y - p2.x * p1.y
    in
    { a = a, b = b, c = c }

