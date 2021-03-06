module NodesAndRoads exposing (..)

--import ScalingInfo exposing (ScalingInfo)

import BoundingBox3d exposing (BoundingBox3d)
import Length
import Point3d exposing (Point3d)
import Spherical exposing (metresPerDegree)
import TrackPoint exposing (TrackPoint)


type LocalCoords
    = LocalCoords


type GPXCoords
    = GPXCoords


type alias ScalingInfo =
    { nodeBox : BoundingBox3d Length.Meters LocalCoords
    , trackPointBox : BoundingBox3d Length.Meters GPXCoords
    }


type alias DrawingNode =
    -- We draw in a rectangular space using metre units.
    { trackPoint : TrackPoint
    , location : Point3d Length.Meters LocalCoords
    }


type alias DrawingRoad =
    { startsAt : DrawingNode
    , endsAt : DrawingNode
    , length : Float
    , bearing : Float
    , gradient : Float -- percent
    , startDistance : Float
    , endDistance : Float
    , index : Int
    }


type alias SummaryData =
    { highestMetres : Float
    , lowestMetres : Float
    , trackLength : Float
    , climbingDistance : Float
    , descendingDistance : Float
    , totalClimbing : Float
    , totalDescending : Float
    }


deriveTrackPointBox : List TrackPoint -> BoundingBox3d Length.Meters LocalCoords
deriveTrackPointBox tps =
    Maybe.withDefault
        (BoundingBox3d.singleton <| Point3d.meters 0.0 0.0 0.0)
    <|
        BoundingBox3d.hullN <|
            List.map (\tp -> Point3d.meters tp.lon tp.lat tp.ele)
                tps


deriveNodes : BoundingBox3d Length.Meters GPXCoords -> List TrackPoint -> List DrawingNode
deriveNodes box tps =
    let
        ( midX, midY, _ ) =
            Point3d.toTuple Length.inMeters <|
                BoundingBox3d.centerPoint box

        prepareDrawingNode tp =
            { trackPoint = tp
            , location =
                Point3d.meters
                    ((tp.lon - midX) * metresPerDegree)
                    -- * cos tp.lat)
                    ((tp.lat - midY) * metresPerDegree)
                    tp.ele
            }
    in
    List.map prepareDrawingNode tps


deriveRoads : List DrawingNode -> List DrawingRoad
deriveRoads drawingNodes =
    let
        roadSegment node1 node2 =
            let
                zDifference =
                    node2.trackPoint.ele - node1.trackPoint.ele

                earthDistance =
                    -- Great circle distance (!) ignoring elevation difference
                    Spherical.range
                        ( degrees node2.trackPoint.lat, degrees node2.trackPoint.lon )
                        ( degrees node1.trackPoint.lat, degrees node1.trackPoint.lon )
            in
            { startsAt = node1
            , endsAt = node2
            , length = earthDistance
            , bearing =
                Spherical.findBearingToTarget
                    ( degrees node1.trackPoint.lat, degrees node1.trackPoint.lon )
                    ( degrees node2.trackPoint.lat, degrees node2.trackPoint.lon )
            , gradient =
                if earthDistance > 0 then
                    100.0 * (zDifference / earthDistance)

                else
                    0.0
            , startDistance = 0.0
            , endDistance = 0.0
            , index = 0
            }

        roadSegments =
            List.map2 roadSegment
                drawingNodes
                (List.drop 1 drawingNodes)

        ( _, _, withAccumulations ) =
            List.foldl
                (\road ( idx, dist, done ) ->
                    ( idx + 1
                    , dist + road.length
                    , { road
                        | startDistance = dist
                        , endDistance = dist + road.length
                        , index = idx
                      }
                        :: done
                    )
                )
                ( 0, 0.0, [] )
                roadSegments
    in
    List.reverse withAccumulations


deriveSummary : List DrawingRoad -> SummaryData
deriveSummary roadSegments =
    let
        accumulateInfo segment summary =
            { trackLength = summary.trackLength + segment.length
            , highestMetres =
                max summary.highestMetres <|
                    max segment.startsAt.trackPoint.ele segment.endsAt.trackPoint.ele
            , lowestMetres =
                min summary.lowestMetres <|
                    min segment.startsAt.trackPoint.ele segment.endsAt.trackPoint.ele
            , climbingDistance =
                if segment.gradient > 0 then
                    summary.climbingDistance + segment.length

                else
                    summary.climbingDistance
            , descendingDistance =
                if segment.gradient < 0 then
                    summary.climbingDistance + segment.length

                else
                    summary.climbingDistance
            , totalClimbing =
                if segment.gradient > 0 then
                    summary.totalClimbing + segment.endsAt.trackPoint.ele - segment.startsAt.trackPoint.ele

                else
                    summary.totalClimbing
            , totalDescending =
                if segment.gradient < 0 then
                    summary.totalClimbing - segment.endsAt.trackPoint.ele + segment.startsAt.trackPoint.ele

                else
                    summary.totalClimbing
            }
    in
    List.foldl accumulateInfo
        { trackLength = 0.0
        , highestMetres = -9999.9
        , lowestMetres = 9999.9
        , climbingDistance = 0.0
        , descendingDistance = 0.0
        , totalClimbing = 0.0
        , totalDescending = 0.0
        }
        roadSegments


roadsForProfileView : List DrawingRoad -> List DrawingRoad
roadsForProfileView roads =
    -- Don't try to be clever. Be pragmatic.
    let
        unrolledRoads : List DrawingRoad
        unrolledRoads =
            List.map unrollRoad roads

        unrollRoad : DrawingRoad -> DrawingRoad
        unrollRoad road =
            let
                startNode =
                    road.startsAt

                endNode =
                    road.endsAt

                newStartNode =
                    { startNode
                        | location =
                            Point3d.xyz
                                (Length.meters 0.0)
                                (Length.meters <| road.startDistance / 5.0)
                                (Point3d.zCoordinate startNode.location)
                    }

                newEndNode =
                    { endNode
                        | location =
                            Point3d.xyz
                                (Length.meters 0.0)
                                (Length.meters <| road.endDistance / 5.0)
                                (Point3d.zCoordinate endNode.location)
                    }
            in
            { road | startsAt = newStartNode, endsAt = newEndNode, bearing = 0.0 }
    in
    unrolledRoads
