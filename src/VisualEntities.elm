module VisualEntities exposing (ThingsWeNeedForRendering, makeVisualEntities)

import Array exposing (Array)
import BendSmoother exposing (SmoothedBend)
import Color
import Cone3d
import Cylinder3d
import Direction3d exposing (negativeZ, positiveZ)
import DisplayOptions exposing (CurtainStyle(..), DisplayOptions)
import Length exposing (meters)
import NodesAndRoads exposing (DrawingNode, DrawingRoad, MyCoord)
import Point3d
import Scene3d exposing (Entity, cone, cylinder)
import Scene3d.Material as Material
import TrackPoint exposing (ScalingInfo)
import Utils exposing (gradientColour)
import ViewTypes exposing (ThirdPersonSubmode(..), ViewingMode(..))


type alias ThingsWeNeedForRendering =
    { displayOptions : DisplayOptions
    , currentNode : Maybe DrawingRoad
    , markedNode : Maybe DrawingRoad
    , scaling : ScalingInfo
    , viewingMode : ViewingMode
    , viewingSubMode : ThirdPersonSubmode
    , smoothedBend : List DrawingRoad
    }


makeVisualEntities : ThingsWeNeedForRendering -> Array DrawingRoad -> List (Entity MyCoord)
makeVisualEntities context roads =
    let
        roadList =
            Array.toList roads

        beginnings =
            List.map .startsAt roadList

        endings =
            List.map .endsAt roadList

        nodes =
            -- No, it's not efficient. Let's make it work first.
            List.take 1 beginnings ++ endings

        seaLevelInClipSpace =
            context.scaling.seaLevelInClipSpace

        seaLevel =
            Scene3d.quad (Material.color Color.darkGreen)
                (Point3d.meters -1.2 -1.2 seaLevelInClipSpace)
                (Point3d.meters 1.2 -1.2 seaLevelInClipSpace)
                (Point3d.meters 1.2 1.2 seaLevelInClipSpace)
                (Point3d.meters -1.2 1.2 seaLevelInClipSpace)

        metresToClipSpace =
            context.scaling.metresToClipSpace

        -- Convert the points to a list of entities by providing a radius and
        -- color for each point
        pointEntities =
            (if context.displayOptions.roadPillars then
                List.map
                    (\node ->
                        cylinder (Material.color Color.brown) <|
                            Cylinder3d.startingAt
                                (Point3d.meters node.x node.y (node.z - 1.0 * metresToClipSpace))
                                negativeZ
                                { radius = meters <| 1.0 * metresToClipSpace
                                , length = meters <| (node.trackPoint.ele - 1.0) * metresToClipSpace
                                }
                    )
                    nodes

             else
                []
            )
                ++ (if context.displayOptions.roadCones then
                        List.map
                            (\node ->
                                cone (Material.color Color.black) <|
                                    Cone3d.startingAt
                                        (Point3d.meters node.x node.y (node.z - 1.0 * metresToClipSpace))
                                        positiveZ
                                        { radius = meters <| 1.0 * metresToClipSpace
                                        , length = meters <| 1.0 * metresToClipSpace
                                        }
                            )
                            nodes

                    else
                        []
                   )

        roadEntities =
            List.concat <|
                List.map roadEntity <|
                    Array.toList roads

        currentPositionDisc =
            case ( context.currentNode, context.viewingMode ) of
                ( Just node, ThirdPersonView ) ->
                    [ cylinder (Material.color Color.lightOrange) <|
                        Cylinder3d.startingAt
                            (Point3d.meters
                                node.startsAt.x
                                node.startsAt.y
                                node.startsAt.z
                            )
                            (segmentDirection node)
                            { radius = meters <| 10.0 * metresToClipSpace
                            , length = meters <| 1.0 * metresToClipSpace
                            }
                    ]

                _ ->
                    []

        markedNode =
            case ( context.markedNode, context.viewingMode ) of
                ( Just road, ThirdPersonView ) ->
                    [ cone (Material.color Color.purple) <|
                        Cone3d.startingAt
                            (Point3d.meters
                                road.startsAt.x
                                road.startsAt.y
                                road.startsAt.z
                            )
                            (segmentDirection road)
                            { radius = meters <| 6.0 * metresToClipSpace
                            , length = meters <| 3.0 * metresToClipSpace
                            }
                    ]

                _ ->
                    []

        roadEntity segment =
            let
                kerbX =
                    -- Road is assumed to be 6 m wide.
                    3.0 * cos segment.bearing * metresToClipSpace

                kerbY =
                    3.0 * sin segment.bearing * metresToClipSpace

                edgeHeight =
                    -- Let's try a low wall at the road's edges.
                    0.3 * metresToClipSpace
            in
            (if context.displayOptions.roadTrack then
                [ --surface
                  Scene3d.quad (Material.color Color.grey)
                    (Point3d.meters (segment.startsAt.x + kerbX)
                        (segment.startsAt.y - kerbY)
                        segment.startsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x + kerbX)
                        (segment.endsAt.y - kerbY)
                        segment.endsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x - kerbX)
                        (segment.endsAt.y + kerbY)
                        segment.endsAt.z
                    )
                    (Point3d.meters (segment.startsAt.x - kerbX)
                        (segment.startsAt.y + kerbY)
                        segment.startsAt.z
                    )

                -- kerb walls
                , Scene3d.quad (Material.color Color.darkGrey)
                    (Point3d.meters (segment.startsAt.x + kerbX)
                        (segment.startsAt.y - kerbY)
                        segment.startsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x + kerbX)
                        (segment.endsAt.y - kerbY)
                        segment.endsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x + kerbX)
                        (segment.endsAt.y - kerbY)
                        (segment.endsAt.z + edgeHeight)
                    )
                    (Point3d.meters (segment.startsAt.x + kerbX)
                        (segment.startsAt.y - kerbY)
                        (segment.startsAt.z + edgeHeight)
                    )
                , Scene3d.quad (Material.color Color.darkGrey)
                    (Point3d.meters (segment.startsAt.x - kerbX)
                        (segment.startsAt.y + kerbY)
                        segment.startsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x - kerbX)
                        (segment.endsAt.y + kerbY)
                        segment.endsAt.z
                    )
                    (Point3d.meters (segment.endsAt.x - kerbX)
                        (segment.endsAt.y + kerbY)
                        (segment.endsAt.z + edgeHeight)
                    )
                    (Point3d.meters (segment.startsAt.x - kerbX)
                        (segment.startsAt.y + kerbY)
                        (segment.startsAt.z + edgeHeight)
                    )
                ]

             else
                []
            )
                ++ (case context.displayOptions.curtainStyle of
                        RainbowCurtain ->
                            [ Scene3d.quad (Material.color <| gradientColour segment.gradient)
                                (Point3d.meters segment.startsAt.x segment.startsAt.y segment.startsAt.z)
                                (Point3d.meters segment.endsAt.x segment.endsAt.y segment.endsAt.z)
                                (Point3d.meters segment.endsAt.x segment.endsAt.y seaLevelInClipSpace)
                                (Point3d.meters segment.startsAt.x segment.startsAt.y seaLevelInClipSpace)
                            ]

                        PlainCurtain ->
                            [ Scene3d.quad (Material.color <| Color.rgb255 0 100 0)
                                (Point3d.meters segment.startsAt.x segment.startsAt.y segment.startsAt.z)
                                (Point3d.meters segment.endsAt.x segment.endsAt.y segment.endsAt.z)
                                (Point3d.meters segment.endsAt.x segment.endsAt.y seaLevelInClipSpace)
                                (Point3d.meters segment.startsAt.x segment.startsAt.y seaLevelInClipSpace)
                            ]

                        NoCurtain ->
                            []
                   )

        segmentDirection segment =
            let
                maybe =
                    Direction3d.from
                        (Point3d.meters
                            segment.startsAt.x
                            segment.startsAt.y
                            segment.startsAt.z
                        )
                        (Point3d.meters
                            segment.endsAt.x
                            segment.endsAt.y
                            segment.endsAt.z
                        )
            in
            case maybe of
                Just dir ->
                    dir

                Nothing ->
                    positiveZ

        suggestedBend =
            if context.viewingSubMode == ShowBendFixes then
                List.map bendElement context.smoothedBend

            else
                []

        bendElement segment =
            let
                kerbX =
                    2.0 * cos segment.bearing * metresToClipSpace

                kerbY =
                    2.0 * sin segment.bearing * metresToClipSpace

                floatHeight =
                    0.1 * metresToClipSpace
            in
            Scene3d.quad (Material.color Color.white)
                (Point3d.meters (segment.startsAt.x + kerbX)
                    (segment.startsAt.y - kerbY)
                    (segment.startsAt.z + floatHeight)
                )
                (Point3d.meters (segment.endsAt.x + kerbX)
                    (segment.endsAt.y - kerbY)
                    (segment.endsAt.z + floatHeight)
                )
                (Point3d.meters (segment.endsAt.x - kerbX)
                    (segment.endsAt.y + kerbY)
                    (segment.endsAt.z + floatHeight)
                )
                (Point3d.meters (segment.startsAt.x - kerbX)
                    (segment.startsAt.y + kerbY)
                    (segment.startsAt.z + floatHeight)
                )
    in
    seaLevel
        :: pointEntities
        ++ roadEntities
        ++ currentPositionDisc
        ++ markedNode
        ++ suggestedBend
