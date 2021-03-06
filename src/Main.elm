module Main exposing (main)

import About exposing (viewAboutText)
import Angle exposing (Angle, inDegrees)
import Array exposing (Array)
import BendSmoother exposing (SmoothedBend, bendIncircle)
import BoundingBox3d exposing (BoundingBox3d)
import Browser
import Camera3d
import Color
import Direction2d
import Direction3d exposing (negativeZ, positiveY, positiveZ)
import DisplayOptions exposing (..)
import Element exposing (..)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input exposing (button)
import File exposing (File)
import File.Download as Download
import File.Select as Select
import Flythrough exposing (Flythrough, eyeHeight, flythrough)
import Geometry101 exposing (interpolateScalar)
import Iso8601
import Length
import List exposing (drop, take)
import Msg exposing (..)
import NodesAndRoads exposing (..)
import Pixels exposing (Pixels)
import Plane3d
import Point2d exposing (Point2d)
import Point3d
import Scene3d exposing (Entity)
import Spherical exposing (metresPerDegree)
import Task
import Terrain exposing (makeTerrain)
import Time
import TrackPoint exposing (..)
import Utils exposing (..)
import Vector2d
import Vector3d
import ViewElements exposing (..)
import ViewTypes exposing (..)
import Viewpoint3d
import VisualEntities exposing (..)
import WriteGPX exposing (writeGPX)


main : Program () Model Msg
main =
    Browser.document
        { init = init
        , view = viewGenericNew
        , update = update
        , subscriptions = subscriptions
        }


type alias AbruptChange =
    { node : DrawingNode
    , before : DrawingRoad
    , after : DrawingRoad
    }


type alias UndoEntry =
    { label : String
    , trackPoints : List TrackPoint
    , currentNode : Maybe Int
    , markedNode : Maybe Int
    }


type Loopiness
    = NotALoop
    | IsALoop
    | AlmostLoop Float -- if, say, less than 200m back to start.


type alias Model =
    { gpx : Maybe String
    , filename : Maybe String
    , time : Time.Posix
    , zone : Time.Zone
    , gpxUrl : String
    , trackPoints : List TrackPoint
    , trackPointBox : Maybe (BoundingBox3d Length.Meters GPXCoords)
    , nodeBox : Maybe (BoundingBox3d Length.Meters LocalCoords)
    , nodes : List DrawingNode
    , roads : List DrawingRoad
    , trackName : Maybe String
    , azimuth : Angle -- Orbiting angle of the camera around the focal point
    , elevation : Angle -- Angle of the camera up from the XY plane
    , orbiting : Maybe Point -- Capture mouse down position (when clicking on the 3D control)
    , staticVisualEntities : List (Entity LocalCoords) -- our 3D world
    , staticProfileEntities : List (Entity LocalCoords) -- an unrolled 3D world for the profile view.
    , varyingVisualEntities : List (Entity LocalCoords) -- current position and marker node.
    , varyingProfileEntities : List (Entity LocalCoords)
    , terrainEntities : List (Entity LocalCoords)
    , httpError : Maybe String
    , currentNode : Maybe Int
    , markedNode : Maybe Int
    , viewingMode : ViewingMode
    , summary : Maybe SummaryData
    , nodeArray : Array DrawingNode
    , roadArray : Array DrawingRoad
    , zoomLevelOverview : Float
    , zoomLevelFirstPerson : Float
    , zoomLevelThirdPerson : Float
    , zoomLevelProfile : Float
    , zoomLevelPlan : Float
    , displayOptions : DisplayOptions
    , abruptGradientChanges : List AbruptChange -- change in gradient exceeds user's threshold
    , abruptBearingChanges : List AbruptChange -- change in gradient exceeds user's threshold
    , zeroLengths : List DrawingRoad -- segments that should not be here.
    , gradientChangeThreshold : Float
    , bearingChangeThreshold : Int
    , hasBeenChanged : Bool
    , smoothingEndIndex : Maybe Int
    , undoStack : List UndoEntry
    , thirdPersonSubmode : ViewSubmode
    , planSubmode : ViewSubmode
    , profileSubmode : ViewSubmode
    , smoothedBend : Maybe SmoothedBend -- computed track points
    , smoothedRoads : List DrawingRoad -- derived road from above,
    , numLineSegmentsForBend : Int
    , bumpinessFactor : Float -- 0.0 => average gradient, 1 => original gradients
    , flythroughSpeed : Float
    , flythrough : Maybe Flythrough
    , roadsForProfileView : List DrawingRoad -- yes, cheating somewhat.
    , loopiness : Loopiness
    , nudgeValue : Float
    , nudgedNodeRoads : List DrawingRoad -- actually only two but this is consistent with smoothedRoads.
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { gpx = Nothing
      , filename = Nothing
      , time = Time.millisToPosix 0
      , zone = Time.utc
      , gpxUrl = ""
      , trackPoints = []
      , trackPointBox = Nothing
      , nodeBox = Nothing
      , nodes = []
      , roads = []
      , trackName = Nothing
      , azimuth = Angle.degrees 45
      , elevation = Angle.degrees 30
      , orbiting = Nothing
      , staticVisualEntities = []
      , varyingVisualEntities = []
      , staticProfileEntities = []
      , varyingProfileEntities = []
      , terrainEntities = []
      , httpError = Nothing
      , currentNode = Nothing
      , markedNode = Nothing
      , viewingMode = AboutView
      , summary = Nothing
      , nodeArray = Array.empty
      , roadArray = Array.empty
      , zoomLevelOverview = 1.0
      , zoomLevelFirstPerson = 1.0
      , zoomLevelThirdPerson = 2.0
      , zoomLevelProfile = 1.0
      , zoomLevelPlan = 1.0
      , displayOptions = defaultDisplayOptions
      , abruptGradientChanges = []
      , abruptBearingChanges = []
      , zeroLengths = []
      , gradientChangeThreshold = 10.0 -- Note, this is not an angle, it's a percentage (tangent).
      , bearingChangeThreshold = 90
      , hasBeenChanged = False
      , smoothingEndIndex = Nothing
      , undoStack = []
      , thirdPersonSubmode = ShowData
      , planSubmode = ShowData
      , profileSubmode = ShowData
      , smoothedBend = Nothing
      , smoothedRoads = []
      , numLineSegmentsForBend = 3
      , bumpinessFactor = 0.0
      , flythrough = Nothing
      , flythroughSpeed = 1.0
      , roadsForProfileView = []
      , loopiness = NotALoop
      , nudgeValue = 0.0
      , nudgedNodeRoads = []
      }
    , Task.perform AdjustTimeZone Time.here
    )


metresPerDegreeLatitude =
    78846.81


addToUndoStack : String -> Model -> Model
addToUndoStack label model =
    { model
        | undoStack =
            { label = label
            , trackPoints = model.trackPoints
            , currentNode = model.currentNode
            , markedNode = model.markedNode
            }
                :: model.undoStack
    }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        options =
            model.displayOptions
    in
    case msg of
        Tick newTime ->
            ( { model | time = newTime } |> advanceFlythrough newTime
            , Cmd.none
            )

        AdjustTimeZone newZone ->
            ( { model | zone = newZone }
            , Cmd.none
            )

        GpxRequested ->
            ( model
            , Select.file [ "text/gpx" ] GpxSelected
            )

        GpxSelected file ->
            ( { model | filename = Just (File.name file) }
            , Task.perform GpxLoaded (File.toString file)
            )

        GpxLoaded content ->
            -- TODO: Tidy up the removal of zero length segments,
            -- so as not to repeat ourselves here.
            ( parseGPXintoModel content model
                |> deriveNodesAndRoads
                |> deriveProblems
                |> deleteZeroLengthSegments
                |> deriveNodesAndRoads
                |> deriveProblems
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> resetViewSettings
                |> clearTerrain
            , Cmd.none
            )

        UserMovedNodeSlider node ->
            ( { model | currentNode = Just node }
                |> cancelFlythrough
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        SetSmoothingEnd idx ->
            ( { model | smoothingEndIndex = Just idx }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        PositionForwardOne ->
            ( { model
                | currentNode = incrementMaybeModulo (List.length model.roads) model.currentNode
              }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
                |> cancelFlythrough
            , Cmd.none
            )

        PositionBackOne ->
            ( { model
                | currentNode = decrementMaybeModulo (List.length model.roads) model.currentNode
              }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
                |> cancelFlythrough
            , Cmd.none
            )

        MarkerForwardOne ->
            ( { model
                | markedNode = incrementMaybeModulo (List.length model.roads) model.markedNode
              }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        MarkerBackOne ->
            ( { model
                | markedNode = decrementMaybeModulo (List.length model.roads) model.markedNode
              }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        SetMaxTurnPerSegment turn ->
            ( { model
                | numLineSegmentsForBend = turn
              }
                |> tryBendSmoother
                --|> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        ChooseViewMode mode ->
            ( { model | viewingMode = mode }
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        ZoomLevelOverview level ->
            ( { model | zoomLevelOverview = level }
            , Cmd.none
            )

        ZoomLevelFirstPerson level ->
            ( { model | zoomLevelFirstPerson = level }
            , Cmd.none
            )

        ZoomLevelThirdPerson level ->
            ( { model | zoomLevelThirdPerson = level }
            , Cmd.none
            )

        ZoomLevelProfile level ->
            ( { model | zoomLevelProfile = level }
            , Cmd.none
            )

        ZoomLevelPlan level ->
            ( { model | zoomLevelPlan = level }
            , Cmd.none
            )

        ImageGrab ( dx, dy ) ->
            ( { model | orbiting = Just ( dx, dy ) }
            , Cmd.none
            )

        ImageRotate ( dx, dy ) ->
            case model.orbiting of
                Just ( startX, startY ) ->
                    let
                        newAzimuth =
                            Angle.degrees <|
                                inDegrees model.azimuth
                                    - (dx - startX)

                        newElevation =
                            Angle.degrees <|
                                inDegrees model.elevation
                                    + (dy - startY)
                    in
                    ( { model
                        | azimuth = newAzimuth
                        , elevation = newElevation
                        , orbiting = Just ( dx, dy )
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        ImageRelease _ ->
            ( { model | orbiting = Nothing }
            , Cmd.none
            )

        ToggleCones _ ->
            ( { model
                | displayOptions = { options | roadCones = not options.roadCones }
              }
                |> deriveStaticVisualEntities
            , Cmd.none
            )

        TogglePillars _ ->
            ( { model
                | displayOptions = { options | roadPillars = not options.roadPillars }
              }
                |> deriveStaticVisualEntities
            , Cmd.none
            )

        ToggleRoad _ ->
            ( { model
                | displayOptions = { options | roadTrack = not options.roadTrack }
              }
                |> deriveStaticVisualEntities
            , Cmd.none
            )

        ToggleCentreLine _ ->
            ( { model
                | displayOptions = { options | centreLine = not options.centreLine }
              }
                |> deriveStaticVisualEntities
            , Cmd.none
            )

        SetCurtainStyle style ->
            ( { model
                | displayOptions = { options | curtainStyle = style }
              }
                |> deriveStaticVisualEntities
            , Cmd.none
            )

        SetGradientChangeThreshold threshold ->
            ( { model
                | gradientChangeThreshold = threshold
              }
                |> deriveProblems
            , Cmd.none
            )

        SetBearingChangeThreshold threshold ->
            ( { model
                | bearingChangeThreshold = round threshold
              }
                |> deriveProblems
            , Cmd.none
            )

        SetFlythroughSpeed speed ->
            ( { model
                | flythroughSpeed = speed
              }
            , Cmd.none
            )

        DeleteZeroLengthSegments ->
            ( deleteZeroLengthSegments model
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveProblems
            , Cmd.none
            )

        OutputGPX ->
            ( { model | hasBeenChanged = False }
            , outputGPX model
            )

        SmoothGradient s f g ->
            ( smoothGradient model s f g
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> deriveProblems
                |> clearTerrain
            , Cmd.none
            )

        SmoothBend ->
            ( model
                |> smoothBend
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> deriveProblems
                |> clearTerrain
            , Cmd.none
            )

        SetViewSubmode mode ->
            ( case model.viewingMode of
                PlanView ->
                    { model | planSubmode = mode }

                ThirdPersonView ->
                    { model | thirdPersonSubmode = mode }

                ProfileView ->
                    { model | profileSubmode = mode }

                _ ->
                    model
            , Cmd.none
            )

        Undo ->
            ( case model.undoStack of
                action :: undos ->
                    { model
                        | trackPoints = action.trackPoints
                        , undoStack = undos
                        , currentNode = action.currentNode
                        , markedNode = action.markedNode
                    }
                        |> deriveNodesAndRoads
                        |> deriveStaticVisualEntities
                        |> deriveVaryingVisualEntities
                        |> deriveProblems
                        |> clearTerrain

                _ ->
                    model
            , Cmd.none
            )

        ToggleMarker ->
            ( { model
                | markedNode =
                    case model.markedNode of
                        Just _ ->
                            Nothing

                        Nothing ->
                            model.currentNode
              }
                |> tryBendSmoother
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        SetBumpinessFactor factor ->
            ( { model | bumpinessFactor = factor }
            , Cmd.none
            )

        RunFlythrough isOn ->
            ( if isOn then
                startFlythrough model

              else
                pauseFlythrough model
            , Cmd.none
            )

        ResetFlythrough ->
            ( resetFlythrough model
            , Cmd.none
            )

        VerticalNodeSplit node direction ->
            ( verticalNodeSplit node model
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveProblems
                |> clearTerrain
                |> (\m ->
                        { m
                            | currentNode =
                                case direction of
                                    InsertNodeAfter ->
                                        model.currentNode

                                    InsertNodeBefore ->
                                        Maybe.map (\n -> n + 1) model.currentNode
                        }
                   )
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        MakeTerrain ->
            ( deriveTerrain model
            , Cmd.none
            )

        ClearTerrain ->
            ( clearTerrain model
            , Cmd.none
            )

        CloseTheLoop ->
            ( closeTheLoop model
                |> clearTerrain
                |> deriveNodesAndRoads
                |> deriveProblems
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        StraightenStraight c m ->
            ( straightenStraight c m model
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> deriveProblems
                |> clearTerrain
            , Cmd.none
            )

        SetNudgeFactor current factor ->
            ( simulateNudgeNode model current factor
                |> deriveVaryingVisualEntities
            , Cmd.none
            )

        NudgeNode node factor ->
            ( nudgeNode model node factor
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> deriveProblems
                |> clearTerrain
            , Cmd.none
            )

        SplitRoad node ->
            ( splitRoad model node
                |> deriveNodesAndRoads
                |> deriveStaticVisualEntities
                |> deriveVaryingVisualEntities
                |> deriveProblems
                |> clearTerrain
            , Cmd.none
            )


nudgeTrackPoint : TrackPoint -> Float -> Float -> TrackPoint
nudgeTrackPoint baseTP roadBearing nudgeFactor =
    let
        roadVector =
            -- The negation because, no idea.
            Vector2d.rTheta (Length.meters 1.0)
                (Angle.radians <| -1.0 * roadBearing)
                |> Vector2d.rotateClockwise

        nudgeVector =
            Vector2d.perpendicularTo roadVector
                |> Vector2d.scaleBy (nudgeFactor * 10.0 / metresPerDegree)

        trackPoint2d =
            Point2d.meters baseTP.lon baseTP.lat

        nudgedTrackPoint2d =
            Point2d.translateBy nudgeVector trackPoint2d
    in
    { baseTP
        | lat = Length.inMeters <| Point2d.yCoordinate nudgedTrackPoint2d
        , lon = Length.inMeters <| Point2d.xCoordinate nudgedTrackPoint2d
    }


simulateNudgeNode : Model -> Int -> Float -> Model
simulateNudgeNode model nodeNum nudgeFactor =
    let
        targetRoad =
            Array.get nodeNum model.roadArray

        prevNode =
            Array.get (nodeNum - 1) model.roadArray
    in
    case targetRoad of
        Nothing ->
            model

        Just road ->
            let
                nudgedTrackPoint =
                    nudgeTrackPoint road.startsAt.trackPoint road.bearing model.nudgeValue

                nudgedListForVisuals =
                    (case prevNode of
                        Nothing ->
                            []

                        Just prev ->
                            [ prev.startsAt.trackPoint ]
                    )
                        ++ [ nudgedTrackPoint
                           , road.endsAt.trackPoint
                           ]
            in
            case model.trackPointBox of
                Just box ->
                    { model
                        | nudgeValue = nudgeFactor
                        , nudgedNodeRoads =
                            deriveRoads <|
                                deriveNodes box <|
                                    nudgedListForVisuals
                    }

                _ ->
                    { model | nudgedNodeRoads = [] }


nudgeNode : Model -> Int -> Float -> Model
nudgeNode model node factor =
    -- Apply the nudge factor permanently.
    let
        targetRoad =
            Array.get node model.roadArray

        undoMessage =
            "Nudge at " ++ String.fromInt node
    in
    case targetRoad of
        Nothing ->
            model

        Just road ->
            let
                nudgedTrackPoint =
                    nudgeTrackPoint road.startsAt.trackPoint road.bearing model.nudgeValue
            in
            addToUndoStack undoMessage model
                |> (\m ->
                        { m
                            | trackPoints =
                                List.take node model.trackPoints
                                    ++ [ nudgedTrackPoint ]
                                    ++ List.drop (node + 1) model.trackPoints
                            , nudgedNodeRoads = []
                        }
                   )


splitRoad : Model -> Int -> Model
splitRoad model node =
    let
        targetRoad =
            Array.get node model.roadArray

        undoMessage =
            "Split at " ++ String.fromInt node
    in
    case targetRoad of
        Nothing ->
            model

        Just road ->
            let
                insertTrackPoint =
                    interpolateSegment 0.5 road.startsAt.trackPoint road.endsAt.trackPoint
            in
            addToUndoStack undoMessage model
                |> (\m ->
                        { m
                            | trackPoints =
                                reindexTrackpoints <|
                                    List.take (node + 1) model.trackPoints
                                        ++ [ insertTrackPoint ]
                                        ++ List.drop (node + 1) model.trackPoints
                        }
                   )


closeTheLoop : Model -> Model
closeTheLoop model =
    let
        maybeFirstSegment =
            List.head model.roads

        backOneMeter : DrawingRoad -> TrackPoint
        backOneMeter segment =
            let
                newLatLon : Point2d Length.Meters LocalCoords
                newLatLon =
                    Point2d.interpolateFrom
                        (Point2d.meters segment.startsAt.trackPoint.lon segment.startsAt.trackPoint.lat)
                        (Point2d.meters segment.endsAt.trackPoint.lon segment.endsAt.trackPoint.lat)
                        backAmount

                backAmount =
                    -- Set back new point equivalent to 1 meter, but we're working in lat & lon.
                    -- The fraction should be valid.
                    -1.0 / segment.length
            in
            { lat = Length.inMeters <| Point2d.yCoordinate newLatLon
            , lon = Length.inMeters <| Point2d.xCoordinate newLatLon
            , ele = segment.startsAt.trackPoint.ele
            , idx = 0
            }

        newTrack gap segment1 =
            if gap < 1.0 then
                -- replace last trackpoint with the first
                List.reverse <|
                    List.take 1 model.trackPoints
                        ++ (List.drop 1 <| List.reverse model.trackPoints)

            else
                -- A nicer solution here is to put a new trackpoint slightly "behing"
                -- the existing start, and then join the current last trackpoint to
                -- this new one. Existing tools can then be used to smooth as required.
                model.trackPoints
                    ++ [ backOneMeter segment1 ]
                    ++ List.take 1 model.trackPoints
    in
    case ( model.loopiness, maybeFirstSegment ) of
        ( AlmostLoop gap, Just segment1 ) ->
            addToUndoStack "complete loop" model
                |> (\m ->
                        { m | trackPoints = reindexTrackpoints (newTrack gap segment1) }
                   )

        _ ->
            model


clearTerrain : Model -> Model
clearTerrain model =
    { model | terrainEntities = [] }


verticalNodeSplit : Int -> Model -> Model
verticalNodeSplit n model =
    -- Replace the current node with two close nodes that each have half the gradient change.
    -- 'Close' being perhaps the lesser of one metre and a third segment length.
    -- Lat and Lon to be linear interpolation.
    let
        undoMessage =
            "Chamfer at " ++ String.fromInt n
    in
    case ( Array.get (n - 1) model.roadArray, Array.get n model.roadArray ) of
        ( Just before, Just after ) ->
            let
                amountToStealFromFirstSegment =
                    min 4.0 (before.length / 2.0)

                amountToStealFromSecondSegment =
                    min 4.0 (after.length / 2.0)

                commonAmountToSteal =
                    min amountToStealFromFirstSegment amountToStealFromSecondSegment

                firstTP =
                    interpolateSegment
                        (commonAmountToSteal / before.length)
                        before.endsAt.trackPoint
                        before.startsAt.trackPoint

                secondTP =
                    interpolateSegment
                        (commonAmountToSteal / after.length)
                        after.startsAt.trackPoint
                        after.endsAt.trackPoint

                precedingTPs =
                    model.trackPoints |> List.take n

                remainingTPs =
                    model.trackPoints |> List.drop (n + 1)

                newTPs =
                    precedingTPs
                        ++ [ firstTP, secondTP ]
                        ++ remainingTPs
            in
            addToUndoStack undoMessage model
                |> (\m ->
                        { m | trackPoints = reindexTrackpoints newTPs }
                   )

        _ ->
            model


straightenStraight : Int -> Int -> Model -> Model
straightenStraight c m model =
    let
        ( n1, n2 ) =
            ( min c m, max c m )

        ( firstSeg, lastSeg ) =
            ( Array.get n1 model.roadArray
            , Array.get n2 model.roadArray
            )

        undoMessage =
            "straighten from "
                ++ String.fromInt n1
                ++ " to "
                ++ String.fromInt (n2 + 1)
                ++ "."
    in
    case ( firstSeg, lastSeg ) of
        ( Just firstRoad, Just lastRoad ) ->
            let
                -- Preserve proportionate lengths
                affected =
                    model.roads |> List.take (n2 + 1) |> List.drop (n1 + 1)

                affectedTPs =
                    List.map (.startsAt >> .trackPoint) affected

                affectedLength =
                    List.sum <| List.map .length affected

                ( _, cumulativeLengths ) =
                    List.foldl
                        (\r ( running, acc ) -> ( r.length + running, (r.length + running) :: acc ))
                        ( 0.0, [] )
                        affected

                startTP =
                    firstRoad.startsAt.trackPoint

                endTP =
                    lastRoad.startsAt.trackPoint

                newTPs =
                    List.map2 newTP (List.reverse cumulativeLengths) affectedTPs

                newTP newRange original =
                    { lat = interpolateScalar (newRange / affectedLength) startTP.lat endTP.lat
                    , lon = interpolateScalar (newRange / affectedLength) startTP.lon endTP.lon
                    , ele = original.ele
                    , idx = 0
                    }

                splicedTPs =
                    List.take (n1 + 1) model.trackPoints
                        ++ newTPs
                        ++ List.drop n2 model.trackPoints
            in
            addToUndoStack undoMessage model
                |> (\mdl ->
                        { mdl | trackPoints = reindexTrackpoints splicedTPs }
                   )

        _ ->
            model


startFlythrough : Model -> Model
startFlythrough model =
    case model.flythrough of
        Just flying ->
            { model
                | flythrough =
                    Just
                        { flying
                            | running = True
                            , lastUpdated = model.time
                        }
            }

        Nothing ->
            resetFlythrough model |> startFlythrough


cancelFlythrough : Model -> Model
cancelFlythrough model =
    { model | flythrough = Nothing }


pauseFlythrough : Model -> Model
pauseFlythrough model =
    case model.flythrough of
        Just flying ->
            { model
                | flythrough =
                    Just
                        { flying
                            | running = False
                        }
            }

        Nothing ->
            model


advanceFlythrough : Time.Posix -> Model -> Model
advanceFlythrough newTime model =
    case model.flythrough of
        Just flying ->
            { model
                | flythrough =
                    Just <|
                        flythrough
                            newTime
                            flying
                            model.flythroughSpeed
                            model.roads
            }

        Nothing ->
            model


resetFlythrough : Model -> Model
resetFlythrough model =
    case model.currentNode of
        Just node ->
            case Array.get node model.roadArray of
                Just road ->
                    { model
                        | flythrough =
                            Just
                                { metresFromRouteStart = road.startDistance
                                , running = False
                                , cameraPosition =
                                    Point3d.translateBy
                                        (Vector3d.meters 0.0 0.0 eyeHeight)
                                        road.startsAt.location
                                , focusPoint =
                                    Point3d.translateBy
                                        (Vector3d.meters 0.0 0.0 eyeHeight)
                                        road.endsAt.location
                                , lastUpdated = model.time
                                , segment = road
                                }
                    }

                Nothing ->
                    -- Why no road? Something amiss.
                    { model | flythrough = Nothing }

        _ ->
            model


tryBendSmoother : Model -> Model
tryBendSmoother model =
    -- Note we work here in trackpoint space, not node/road space.
    -- This because we will need to create GPX entries, so better to start there IMHO.
    let
        failed =
            { model
                | smoothedBend = Nothing
                , smoothedRoads = []
                , nudgedNodeRoads = []
                , nudgeValue = 0.0
            }
    in
    case ( model.currentNode, model.markedNode ) of
        ( Nothing, _ ) ->
            failed

        ( _, Nothing ) ->
            failed

        ( Just c, Just m ) ->
            let
                ( n1, n2 ) =
                    ( min c m, max c m )

                entrySegment =
                    Array.get n1 model.roadArray

                exitSegment =
                    Array.get (n2 - 1) model.roadArray
            in
            if n2 >= n1 + 2 then
                case ( entrySegment, exitSegment ) of
                    ( Just road1, Just road2 ) ->
                        let
                            ( pa, pb ) =
                                ( road1.startsAt.trackPoint
                                , road1.endsAt.trackPoint
                                )

                            ( pc, pd ) =
                                ( road2.startsAt.trackPoint
                                , road2.endsAt.trackPoint
                                )

                            newTrack =
                                bendIncircle model.numLineSegmentsForBend pa pb pc pd
                        in
                        case ( newTrack, model.trackPointBox ) of
                            ( Just track, Just box ) ->
                                { model
                                    | smoothedBend = newTrack
                                    , smoothedRoads =
                                        deriveRoads <|
                                            deriveNodes box <|
                                                track.trackPoints
                                    , nudgedNodeRoads = []
                                    , nudgeValue = 0.0
                                }

                            _ ->
                                failed

                    _ ->
                        failed

            else
                failed


smoothGradient : Model -> Int -> Int -> Float -> Model
smoothGradient model start finish gradient =
    -- This feels like a simple foldl, creating a new list of TrackPoints
    -- which we then splice into the model.
    -- It's a fold because we must keep track of the current elevation
    -- which will increase with each segment.
    let
        segments =
            model.roads |> List.take (finish - 1) |> List.drop start

        startNode =
            Array.get start model.nodeArray

        undoMessage =
            "gradient smoothing from "
                ++ String.fromInt start
                ++ " to "
                ++ String.fromInt finish
                ++ ", \nbumpiness "
                ++ showDecimal2 model.bumpinessFactor
                ++ "."
    in
    case startNode of
        Just n ->
            let
                ( _, adjustedTrackPoints ) =
                    List.foldl
                        adjustTrackPoint
                        ( n.trackPoint.ele, [] )
                        segments

                adjustTrackPoint road ( startEle, newTPs ) =
                    -- This would be the elevations along the average, bumpiness == 0.0
                    let
                        increase =
                            road.length * gradient / 100.0

                        oldTP =
                            road.endsAt.trackPoint
                    in
                    ( startEle + increase
                    , { oldTP
                        | ele = startEle + increase
                      }
                        :: newTPs
                    )

                bumpyTrackPoints =
                    -- Intermediate between original and smooth
                    List.map2
                        applyBumpiness
                        (List.reverse adjustedTrackPoints)
                        segments

                applyBumpiness newTP oldSeg =
                    let
                        oldTP =
                            oldSeg.endsAt.trackPoint
                    in
                    { oldTP
                        | ele =
                            model.bumpinessFactor
                                * oldTP.ele
                                + (1.0 - model.bumpinessFactor)
                                * newTP.ele
                    }
            in
            addToUndoStack undoMessage model
                |> (\m ->
                        { m
                            | trackPoints =
                                reindexTrackpoints <|
                                    List.take (start + 1) m.trackPoints
                                        ++ bumpyTrackPoints
                                        ++ List.drop finish m.trackPoints
                        }
                   )

        Nothing ->
            -- shouldn't happen
            model


smoothBend : Model -> Model
smoothBend model =
    -- The replacement bend is a pre-computed list of trackpoints,
    -- so we need only splice them in.
    let
        undoMessage bend =
            "bend smoothing from "
                ++ String.fromInt bend.startIndex
                ++ " to "
                ++ String.fromInt bend.endIndex
                ++ ", \nradius "
                ++ showDecimal2 bend.radius
                ++ " metres."

        ( current, marker ) =
            ( model.currentNode, model.markedNode )
    in
    case ( model.smoothedBend, current, marker ) of
        ( Just bend, Just curr, Just mark ) ->
            let
                numCurrentPoints =
                    abs (curr - mark)

                numNewPoints =
                    List.length bend.trackPoints

                newCurrent =
                    if curr > bend.startIndex then
                        curr - numCurrentPoints + numNewPoints - 2

                    else
                        curr - 1

                newMark =
                    if mark > bend.startIndex then
                        mark - numCurrentPoints + numNewPoints - 2

                    else
                        mark - 1 -- Why?
            in
            addToUndoStack (undoMessage bend) model
                |> (\m ->
                        { m
                            | trackPoints =
                                reindexTrackpoints <|
                                    List.take (bend.startIndex - 1) m.trackPoints
                                        ++ bend.trackPoints
                                        ++ List.drop (bend.endIndex + 1) m.trackPoints
                            , smoothedBend = Nothing
                            , smoothedRoads = []
                            , currentNode = Just newCurrent
                            , markedNode = Just newMark
                        }
                   )

        _ ->
            -- shouldn't happen
            model


outputGPX : Model -> Cmd Msg
outputGPX model =
    let
        gpxString =
            writeGPX model.trackName model.trackPoints

        iso8601 =
            Iso8601.fromTime model.time

        outputFilename =
            case model.filename of
                Just fn ->
                    let
                        dropAfterLastDot s =
                            s
                                |> String.split "."
                                |> List.reverse
                                |> List.drop 1
                                |> List.reverse
                                |> String.join "."

                        prefix =
                            dropAfterLastDot fn

                        timestamp =
                            dropAfterLastDot iso8601

                        suffix =
                            "gpx"
                    in
                    prefix ++ "_" ++ timestamp ++ "." ++ suffix

                Nothing ->
                    iso8601
    in
    Download.string outputFilename "text/gpx" gpxString


deleteZeroLengthSegments : Model -> Model
deleteZeroLengthSegments model =
    -- We have a list of them and their indices.
    -- We remove the troublesome track points and rebuild from there.
    let
        keepNonZero tp =
            not <| List.member tp.idx indexes

        indexes =
            List.map
                (\road -> road.index)
                model.zeroLengths
    in
    { model
        | trackPoints = reindexTrackpoints <| List.filter keepNonZero model.trackPoints
    }


parseGPXintoModel : String -> Model -> Model
parseGPXintoModel content model =
    let
        tps =
            parseTrackPoints content
    in
    { model
        | gpx = Just content
        , trackName = parseTrackName content
        , trackPoints = tps
        , hasBeenChanged = False
        , undoStack = []
        , viewingMode =
            if model.trackPoints == [] then
                InputErrorView

            else
                model.viewingMode
    }


deriveNodesAndRoads : Model -> Model
deriveNodesAndRoads model =
    let
        trackPointAsPoint tp =
            Point3d.meters tp.lon tp.lat tp.ele

        withNodes m =
            case m.trackPointBox of
                Just box ->
                    { m | nodes = deriveNodes box m.trackPoints }

                Nothing ->
                    m

        withTrackPointScaling m =
            { m
                | trackPointBox =
                    BoundingBox3d.hullN <|
                        List.map trackPointAsPoint m.trackPoints
            }

        withNodeScaling m =
            { m
                | nodeBox =
                    BoundingBox3d.hullN <|
                        List.map .location m.nodes
            }

        withRoads m =
            let
                roads =
                    deriveRoads m.nodes
            in
            { m
                | roads = roads
                , roadsForProfileView = roadsForProfileView roads
            }

        withSummary m =
            { m | summary = Just <| deriveSummary m.roads }

        withArrays m =
            { m
                | nodeArray = Array.fromList m.nodes
                , roadArray = Array.fromList m.roads
            }
    in
    model
        |> withTrackPointScaling
        |> withNodes
        |> withNodeScaling
        |> withRoads
        |> withSummary
        |> withArrays


resetViewSettings : Model -> Model
resetViewSettings model =
    let
        routeSize =
            Maybe.map BoundingBox3d.dimensions model.nodeBox

        zoomLevel =
            case routeSize of
                Just ( x, y, _ ) ->
                    -- Empirical!
                    clamp 1.0 4.0 <|
                        5.0
                            - logBase 10 (max (Length.inMeters x) (Length.inMeters y))

                Nothing ->
                    1.0
    in
    { model
        | zoomLevelOverview = zoomLevel
        , zoomLevelFirstPerson = zoomLevel
        , zoomLevelThirdPerson = zoomLevel
        , zoomLevelProfile = zoomLevel
        , zoomLevelPlan = zoomLevel
        , azimuth = Angle.degrees 0.0
        , elevation = Angle.degrees 30.0
        , currentNode = Just 0
        , markedNode = Nothing
        , viewingMode = OverviewView
        , flythrough = Nothing
    }


deriveProblems : Model -> Model
deriveProblems model =
    let
        suddenGradientChanges =
            List.filterMap identity <|
                -- Filters out Nothings (nice)
                List.map2 compareGradients
                    model.roads
                    (List.drop 1 model.roads)

        suddenBearingChanges =
            List.filterMap identity <|
                -- Filters out Nothings (nice)
                List.map2 compareBearings
                    model.roads
                    (List.drop 1 model.roads)

        zeroLengths =
            List.filterMap
                (\road ->
                    if road.length == 0.0 then
                        Just road

                    else
                        Nothing
                )
                model.roads

        compareGradients : DrawingRoad -> DrawingRoad -> Maybe AbruptChange
        compareGradients seg1 seg2 =
            -- This list should not include zero length segments; they are separate.
            if
                seg1.length
                    > 0.0
                    && seg2.length
                    > 0.0
                    && abs (seg1.gradient - seg2.gradient)
                    > model.gradientChangeThreshold
            then
                Just
                    { node = seg1.endsAt
                    , before = seg1
                    , after = seg2
                    }

            else
                Nothing

        compareBearings : DrawingRoad -> DrawingRoad -> Maybe AbruptChange
        compareBearings seg1 seg2 =
            -- This list should not include zero length segments; they are separate.
            let
                diff =
                    abs <| seg1.bearing - seg2.bearing

                includedAngle =
                    if diff > pi then
                        pi + pi - diff

                    else
                        diff
            in
            if
                seg1.length
                    > 0.0
                    && seg2.length
                    > 0.0
                    && toDegrees includedAngle
                    > toFloat model.bearingChangeThreshold
            then
                Just
                    { node = seg1.endsAt
                    , before = seg1
                    , after = seg2
                    }

            else
                Nothing

        loopy =
            let
                maybeGap =
                    trackPointGap
                        (List.head model.trackPoints)
                        (List.head <| List.reverse model.trackPoints)
            in
            case maybeGap of
                Just ( gap, heightDiff ) ->
                    if gap < 0.5 && heightDiff < 0.5 then
                        IsALoop

                    else if gap < 1000.0 then
                        AlmostLoop gap

                    else
                        NotALoop

                _ ->
                    NotALoop
    in
    { model
        | abruptGradientChanges = suddenGradientChanges
        , abruptBearingChanges = suddenBearingChanges
        , zeroLengths = zeroLengths
        , smoothingEndIndex = Nothing
        , loopiness = loopy
    }


trackPointGap : Maybe TrackPoint -> Maybe TrackPoint -> Maybe ( Float, Float )
trackPointGap t1 t2 =
    case ( t1, t2 ) of
        ( Just tp1, Just tp2 ) ->
            Just
                ( Spherical.range ( tp1.lon, tp1.lat ) ( tp2.lon, tp2.lat )
                , abs (tp1.ele - tp2.ele)
                )

        _ ->
            Nothing


deriveStaticVisualEntities : Model -> Model
deriveStaticVisualEntities model =
    -- These need building only when a file is loaded, or a fix is applied.
    case model.nodeBox of
        Just scale ->
            let
                context =
                    { displayOptions = model.displayOptions
                    , currentNode = lookupRoad model model.currentNode
                    , markedNode = lookupRoad model model.markedNode
                    , nodeBox = scale
                    , viewingMode = model.viewingMode
                    , viewingSubMode = model.thirdPersonSubmode
                    , smoothedBend = model.smoothedRoads
                    }
            in
            { model
                | staticVisualEntities = makeStatic3DEntities context model.roads
                , staticProfileEntities = makeStaticProfileEntities context model.roadsForProfileView
            }

        Nothing ->
            model


deriveTerrain : Model -> Model
deriveTerrain model =
    -- Terrain building is O(n^2). Not to be undertaken lightly.
    case model.nodeBox of
        Just scale ->
            let
                context =
                    { displayOptions = model.displayOptions
                    , currentNode = lookupRoad model model.currentNode
                    , markedNode = lookupRoad model model.markedNode
                    , nodeBox = scale
                    , viewingMode = model.viewingMode
                    , viewingSubMode = model.thirdPersonSubmode
                    , smoothedBend = model.smoothedRoads
                    }
            in
            { model
                | terrainEntities = makeTerrain context model.roads
            }

        Nothing ->
            model


deriveVaryingVisualEntities : Model -> Model
deriveVaryingVisualEntities model =
    -- Refers to the current and marked nodes.
    -- These need building each time the user changes current or marked nodes.
    let
        currentRoad =
            lookupRoad model model.currentNode

        markedRoad =
            lookupRoad model model.markedNode

        currentRoadInProfileList =
            findUnrolledRoad currentRoad

        markedRoadInProfileList =
            findUnrolledRoad markedRoad

        findUnrolledRoad r =
            case r of
                Just road ->
                    model.roadsForProfileView |> List.drop road.index |> List.head

                Nothing ->
                    Nothing
    in
    case model.nodeBox of
        Just scale ->
            let
                context =
                    { displayOptions = model.displayOptions
                    , currentNode = currentRoad
                    , markedNode = markedRoad
                    , nodeBox = scale
                    , viewingMode = model.viewingMode
                    , viewingSubMode =
                        --TODO: Hack that should not be needed with proper view management.
                        if
                            (model.viewingMode
                                == ThirdPersonView
                                && model.thirdPersonSubmode
                                == ShowBendFixes
                            )
                                || (model.viewingMode
                                        == PlanView
                                        && model.planSubmode
                                        == ShowBendFixes
                                   )
                                || (model.viewingMode
                                        == PlanView
                                        && model.planSubmode
                                        == ShowNodeTools
                                   )
                        then
                            ShowBendFixes

                        else
                            ShowData
                    , smoothedBend = model.smoothedRoads ++ model.nudgedNodeRoads --TODO: Cheeky. Not clever.
                    }

                profileContext =
                    { context
                        | currentNode = currentRoadInProfileList
                        , markedNode = markedRoadInProfileList
                    }
            in
            { model
                | varyingVisualEntities =
                    makeVaryingVisualEntities
                        context
                        model.roadArray
                , varyingProfileEntities =
                    makeVaryingProfileEntities
                        profileContext
                        model.roadsForProfileView
            }

        Nothing ->
            model


viewGenericNew : Model -> Browser.Document Msg
viewGenericNew model =
    { title = "GPX viewer"
    , body =
        [ layout
            [ width fill
            , padding 20
            , spacing 20
            ]
          <|
            column
                [ spacing 10 ]
                [ row [ centerX, spaceEvenly, spacing 20 ]
                    [ loadButton
                    , case model.filename of
                        Just name ->
                            column []
                                [ displayName model.trackName
                                , text <| "Filename: " ++ name
                                ]

                        Nothing ->
                            none
                    , saveButtonIfChanged model
                    ]
                , row []
                    [ viewModeChoices model
                    ]
                , case model.nodeBox of
                    Just scale ->
                        row []
                            [ view3D scale model ]

                    Nothing ->
                        viewAboutText
                ]
        ]
    }


saveButtonIfChanged : Model -> Element Msg
saveButtonIfChanged model =
    case model.undoStack of
        _ :: _ ->
            button
                prettyButtonStyles
                { onPress = Just OutputGPX
                , label = text "Save as GPX file to your computer"
                }

        _ ->
            none


viewModeChoices : Model -> Element Msg
viewModeChoices model =
    Input.radioRow
        [ Border.rounded 6
        , Border.shadow { offset = ( 0, 0 ), size = 3, blur = 10, color = rgb255 0xE0 0xE0 0xE0 }
        ]
        { onChange = ChooseViewMode
        , selected = Just model.viewingMode
        , label =
            Input.labelHidden "Choose view"
        , options =
            [ Input.optionWith OverviewView <| radioButton First "Overview"
            , Input.optionWith FirstPersonView <| radioButton Mid "First person"
            , Input.optionWith ThirdPersonView <| radioButton Mid "Third person"
            , Input.optionWith ProfileView <| radioButton Mid "Elevation"
            , Input.optionWith PlanView <| radioButton Mid "Plan"
            , Input.optionWith AboutView <| radioButton Last "About"
            ]
        }



-- Each of these view is really just a left pane and a right pane.


view3D : BoundingBox3d Length.Meters LocalCoords -> Model -> Element Msg
view3D scale model =
    case model.viewingMode of
        OverviewView ->
            viewPointCloud scale model

        FirstPersonView ->
            viewFirstPerson scale model

        ThirdPersonView ->
            viewThirdPerson scale model

        ProfileView ->
            viewProfileView model

        AboutView ->
            viewAboutText

        InputErrorView ->
            viewInputError model

        PlanView ->
            viewPlanView scale model


viewInputError : Model -> Element Msg
viewInputError model =
    if model.trackPoints == [] then
        column [ spacing 20 ]
            [ text "I was looking for things like 'lat', 'lon' and 'ele' but didn't find them."
            , case model.gpx of
                Just content ->
                    column []
                        [ text "This is what I found instead."
                        , text <| content
                        ]

                Nothing ->
                    text "<Nothing to see here>"
            ]

    else
        text "That was lovely."


averageGradient : Model -> Int -> Int -> Maybe Float
averageGradient model s f =
    let
        segments =
            model.roads |> List.take f |> List.drop s
    in
    if s < f then
        case ( Array.get s model.nodeArray, Array.get f model.nodeArray ) of
            ( Just startNode, Just endNode ) ->
                let
                    startElevation =
                        startNode.trackPoint.ele

                    endElevation =
                        endNode.trackPoint.ele

                    overallLength =
                        List.sum <| List.map .length segments
                in
                Just <| (endElevation - startElevation) / overallLength * 100.0

            _ ->
                Nothing

    else
        Nothing


viewGradientChanges : Model -> Element Msg
viewGradientChanges model =
    let
        idx change =
            change.node.trackPoint.idx

        linkButton change =
            button prettyButtonStyles
                { onPress = Just (UserMovedNodeSlider (idx change))
                , label = text <| String.fromInt (idx change)
                }
    in
    column [ spacing 10, padding 20 ]
        [ gradientChangeThresholdSlider model
        , wrappedRow [ width <| px 300 ] <|
            List.map linkButton model.abruptGradientChanges
        ]


viewBearingChanges : Model -> Element Msg
viewBearingChanges model =
    let
        idx change =
            change.node.trackPoint.idx

        linkButton change =
            button prettyButtonStyles
                { onPress = Just (UserMovedNodeSlider (idx change))
                , label = text <| String.fromInt (idx change)
                }
    in
    column [ spacing 10, padding 20 ]
        [ bearingChangeThresholdSlider model
        , wrappedRow [ width <| px 300 ] <|
            List.map linkButton model.abruptBearingChanges
        ]


buttonHighlightCurrent : Int -> Model -> List (Attribute msg)
buttonHighlightCurrent index model =
    if Just index == model.currentNode then
        [ Background.color <| rgb255 114 159 207, alignRight ]

    else
        [ Background.color <| rgb255 0xFF 0xFF 0xFF, alignRight ]


buttonSmoothingEnd : Int -> Model -> List (Attribute msg)
buttonSmoothingEnd index model =
    if Just index == model.smoothingEndIndex then
        [ Background.color <| rgb255 114 159 207, alignRight ]

    else
        [ Background.color <| rgb255 0xFF 0xFF 0xFF, alignRight ]


viewZeroLengthSegments : Model -> Element Msg
viewZeroLengthSegments model =
    el [ spacing 10, padding 20 ] <|
        if List.length model.zeroLengths > 0 then
            column [ spacing 10 ]
                [ table [ width fill, centerX, spacing 10 ]
                    { data = model.zeroLengths
                    , columns =
                        [ { header = text "Track point\n(Click to pick)"
                          , width = fill
                          , view =
                                \z ->
                                    button (buttonHighlightCurrent z.index model)
                                        { onPress = Just (UserMovedNodeSlider z.index)
                                        , label = text <| String.fromInt z.index
                                        }
                          }
                        ]
                    }
                , button
                    prettyButtonStyles
                    { onPress = Just DeleteZeroLengthSegments
                    , label = text "Delete these segments"
                    }
                ]

        else
            text "There are no zero-length segments to see here."


viewOptions : Model -> Element Msg
viewOptions model =
    column [ padding 20, alignTop, spacing 10 ]
        [ if model.terrainEntities == [] then
            button prettyButtonStyles
                { onPress = Just MakeTerrain
                , label = text """Build terrain
(I understand this may take several
minutes and will be lost if I make changes)"""
                }

          else
            button prettyButtonStyles
                { onPress = Just ClearTerrain
                , label = text "Remove the terrain."
                }
        , paragraph
            [ padding 10
            , Font.size 24
            ]
          <|
            [ text "Select view elements" ]
        , Input.checkbox [ Font.size 18 ]
            { onChange = ToggleRoad
            , icon = checkboxIcon
            , checked = model.displayOptions.roadTrack
            , label = Input.labelRight [] (text "Road surface")
            }
        , Input.checkbox [ Font.size 18 ]
            { onChange = TogglePillars
            , icon = checkboxIcon
            , checked = model.displayOptions.roadPillars
            , label = Input.labelRight [] (text "Road support pillars")
            }
        , Input.checkbox [ Font.size 18 ]
            { onChange = ToggleCones
            , icon = checkboxIcon
            , checked = model.displayOptions.roadCones
            , label = Input.labelRight [] (text "Trackpoint cones")
            }
        , Input.checkbox [ Font.size 18 ]
            { onChange = ToggleCentreLine
            , icon = checkboxIcon
            , checked = model.displayOptions.centreLine
            , label = Input.labelRight [] (text "Centre line")
            }
        , Input.radioRow
            [ Border.rounded 6
            , Border.shadow { offset = ( 0, 0 ), size = 3, blur = 10, color = rgb255 0xE0 0xE0 0xE0 }
            ]
            { onChange = SetCurtainStyle
            , selected = Just model.displayOptions.curtainStyle
            , label =
                Input.labelBelow [ centerX ] <| text "Curtain style"
            , options =
                [ Input.optionWith NoCurtain <| radioButton First "None"
                , Input.optionWith PlainCurtain <| radioButton Mid "Plain"
                , Input.optionWith PastelCurtain <| radioButton Mid "Pastel"
                , Input.optionWith RainbowCurtain <| radioButton Last "Rainbow"
                ]
            }
        ]


gradientChangeThresholdSlider : Model -> Element Msg
gradientChangeThresholdSlider model =
    Input.slider
        commonShortHorizontalSliderStyles
        { onChange = SetGradientChangeThreshold
        , label =
            Input.labelBelow [] <|
                text <|
                    "Gradient change threshold = "
                        ++ showDecimal2 model.gradientChangeThreshold
        , min = 5.0
        , max = 20.0
        , step = Nothing
        , value = model.gradientChangeThreshold
        , thumb = Input.defaultThumb
        }


bearingChangeThresholdSlider : Model -> Element Msg
bearingChangeThresholdSlider model =
    Input.slider
        commonShortHorizontalSliderStyles
        { onChange = SetBearingChangeThreshold
        , label =
            Input.labelBelow [] <|
                text <|
                    "Direction change threshold = "
                        ++ String.fromInt model.bearingChangeThreshold
        , min = 30.0
        , max = 120.0
        , step = Just 1.0
        , value = toFloat model.bearingChangeThreshold
        , thumb = Input.defaultThumb
        }


bendSmoothnessSlider : Model -> Element Msg
bendSmoothnessSlider model =
    Input.slider
        commonShortHorizontalSliderStyles
        { onChange = round >> SetMaxTurnPerSegment
        , label =
            Input.labelBelow [] <|
                text <|
                    "Road segments = "
                        ++ String.fromInt model.numLineSegmentsForBend
        , min = 2.0
        , max = 10.0
        , step = Just 1.0
        , value = toFloat model.numLineSegmentsForBend
        , thumb = Input.defaultThumb
        }


viewPointCloud : BoundingBox3d Length.Meters LocalCoords -> Model -> Element Msg
viewPointCloud scale model =
    let
        camera =
            Camera3d.perspective
                { viewpoint =
                    Viewpoint3d.orbitZ
                        { focalPoint = Point3d.meters 0.0 0.0 0.0
                        , azimuth = model.azimuth
                        , elevation = model.elevation
                        , distance = Length.meters <| distanceFromZoom model.zoomLevelOverview
                        }
                , verticalFieldOfView = Angle.degrees 30
                }
    in
    row []
        [ zoomSlider model.zoomLevelOverview ZoomLevelOverview
        , el
            withMouseCapture
          <|
            html <|
                Scene3d.sunny
                    { camera = camera
                    , dimensions = ( Pixels.int 800, Pixels.int 500 )
                    , background = Scene3d.backgroundColor Color.lightBlue
                    , clipDepth = Length.meters 1.0 -- * scale.metresToClipSpace)
                    , entities =
                        model.varyingVisualEntities
                            ++ model.staticVisualEntities
                            ++ model.terrainEntities
                    , upDirection = positiveZ
                    , sunlightDirection = negativeZ
                    , shadows = True
                    }
        , column []
            [ overviewSummary model
            , viewLoopiness model
            , viewOptions model
            ]
        ]


overviewSummary model =
    case model.summary of
        Just summary ->
            row [ padding 20 ]
                [ column [ spacing 10 ]
                    [ text "Highest point "
                    , text "Lowest point "
                    , text "Track length "
                    , text "Climbing distance "
                    , text "Elevation gain "
                    , text "Descending distance "
                    , text "Elevation loss "
                    ]
                , column [ spacing 10 ]
                    [ text <| showDecimal2 summary.highestMetres
                    , text <| showDecimal2 summary.lowestMetres
                    , text <| showDecimal2 summary.trackLength
                    , text <| showDecimal2 summary.climbingDistance
                    , text <| showDecimal2 summary.totalClimbing
                    , text <| showDecimal2 summary.descendingDistance
                    , text <| showDecimal2 summary.totalDescending
                    ]
                ]

        _ ->
            none


viewLoopiness : Model -> Element Msg
viewLoopiness model =
    el [ spacing 10, padding 20 ] <|
        case model.loopiness of
            AlmostLoop gap ->
                button
                    prettyButtonStyles
                    { onPress = Just CloseTheLoop
                    , label =
                        text <|
                            "Make the track into a loop"
                    }

            _ ->
                none


positionControls model =
    row
        [ spacing 5
        , padding 5
        , Border.width 1
        , centerX
        , centerY
        ]
        [ positionSlider model
        , button
            prettyButtonStyles
            { onPress = Just PositionBackOne
            , label = text "◀︎"
            }
        , button
            prettyButtonStyles
            { onPress = Just PositionForwardOne
            , label = text "►︎"
            }
        ]


positionSlider model =
    Input.slider
        [ height <| px 80
        , width <| px 500
        , centerY
        , behindContent <|
            -- Slider track
            el
                [ width <| px 500
                , height <| px 30
                , centerY
                , centerX
                , Background.color <| rgb255 114 159 207
                , Border.rounded 6
                ]
                Element.none
        ]
        { onChange = UserMovedNodeSlider << round
        , label =
            Input.labelHidden "Drag slider or use arrow buttons"
        , min = 1.0
        , max = toFloat <| List.length model.roads - 1
        , step = Just 1
        , value = toFloat <| Maybe.withDefault 0 model.currentNode
        , thumb = Input.defaultThumb
        }


viewFirstPerson scale model =
    let
        getRoad : Maybe DrawingRoad
        getRoad =
            -- N.B. will fail on last node.
            case model.currentNode of
                Just n ->
                    Array.get n model.roadArray

                _ ->
                    Nothing

        summaryData road =
            row [ padding 20 ]
                [ column [ spacing 10 ]
                    [ text "Start point index "
                    , text "Start latitude "
                    , text "Start longitude "
                    , text "Start elevation "
                    , text "Start distance "
                    , text "End latitude "
                    , text "End longitude "
                    , text "End elevation "
                    , text "End distance "
                    , text "Length "
                    , text "Gradient "
                    , text "Bearing "
                    ]
                , column [ spacing 10 ]
                    [ text <| String.fromInt <| Maybe.withDefault 1 model.currentNode
                    , text <| showDecimal6 road.startsAt.trackPoint.lat
                    , text <| showDecimal6 road.startsAt.trackPoint.lon
                    , text <| showDecimal2 road.startsAt.trackPoint.ele
                    , text <| showDecimal2 road.startDistance
                    , text <| showDecimal6 road.endsAt.trackPoint.lat
                    , text <| showDecimal6 road.endsAt.trackPoint.lon
                    , text <| showDecimal2 road.endsAt.trackPoint.ele
                    , text <| showDecimal2 road.endDistance
                    , text <| showDecimal2 road.length
                    , text <| showDecimal2 road.gradient
                    , text <| bearingToDisplayDegrees road.bearing
                    ]
                ]
    in
    case getRoad of
        Nothing ->
            none

        Just road ->
            row []
                [ zoomSlider model.zoomLevelFirstPerson ZoomLevelFirstPerson
                , column [ alignTop, padding 20, spacing 10 ]
                    [ viewRoadSegment scale model road
                    , positionControls model
                    ]
                , column [ alignTop, padding 20, spacing 10 ]
                    [ summaryData road
                    , flythroughControls model
                    ]
                ]


flythroughControls : Model -> Element Msg
flythroughControls model =
    let
        flythroughSpeedSlider =
            Input.slider
                commonShortHorizontalSliderStyles
                { onChange = SetFlythroughSpeed
                , label =
                    Input.labelBelow [] <|
                        text <|
                            "Fly-through speed = "
                                ++ (showDecimal2 <|
                                        10.0
                                            ^ model.flythroughSpeed
                                   )
                                ++ " m/sec"
                , min = 1.0 -- i.e. 1
                , max = 3.0 -- i.e. 1000
                , step = Nothing
                , value = model.flythroughSpeed
                , thumb = Input.defaultThumb
                }

        resetButton =
            button
                prettyButtonStyles
                { onPress = Just ResetFlythrough
                , label = el [ Font.size 24 ] <| text "⏮️"
                }

        playButton =
            button
                prettyButtonStyles
                { onPress = Just (RunFlythrough True)
                , label = el [ Font.size 24 ] <| text "▶️"
                }

        pauseButton =
            button
                prettyButtonStyles
                { onPress = Just (RunFlythrough False)
                , label = el [ Font.size 24 ] <| text "⏸"
                }

        playPauseButton =
            case model.flythrough of
                Nothing ->
                    playButton

                Just flying ->
                    if flying.running then
                        pauseButton

                    else
                        playButton

        flythroughPosition =
            case model.flythrough of
                Just fly ->
                    text <| showDecimal2 fly.metresFromRouteStart

                Nothing ->
                    none
    in
    row [ padding 10, spacing 10 ]
        [ resetButton
        , playPauseButton
        , flythroughSpeedSlider

        --, flythroughPosition
        ]


viewRoadSegment : BoundingBox3d Length.Meters LocalCoords -> Model -> DrawingRoad -> Element Msg
viewRoadSegment _ model road =
    let
        eyePoint =
            case model.flythrough of
                Nothing ->
                    Point3d.translateBy
                        (Vector3d.meters 0.0 0.0 eyeHeight)
                        road.startsAt.location

                Just flying ->
                    flying.cameraPosition

        cameraViewpoint =
            case model.flythrough of
                Nothing ->
                    Viewpoint3d.lookAt
                        { eyePoint = eyePoint
                        , focalPoint =
                            Point3d.translateBy
                                (Vector3d.meters 0.0 0.0 eyeHeight)
                                road.endsAt.location
                        , upDirection = Direction3d.positiveZ
                        }

                Just flying ->
                    Viewpoint3d.lookAt
                        { eyePoint = eyePoint
                        , focalPoint = flying.focusPoint
                        , upDirection = Direction3d.positiveZ
                        }

        camera =
            Camera3d.perspective
                { viewpoint = cameraViewpoint
                , verticalFieldOfView = Angle.degrees <| 120.0 / model.zoomLevelFirstPerson
                }
    in
    el [] <|
        html <|
            Scene3d.sunny
                { camera = camera
                , dimensions = ( Pixels.int 800, Pixels.int 500 )
                , background = Scene3d.backgroundColor Color.lightBlue
                , clipDepth = Length.meters 1.0
                , entities =
                    model.varyingVisualEntities
                        ++ model.staticVisualEntities
                        ++ model.terrainEntities
                , upDirection = positiveZ
                , sunlightDirection = negativeZ
                , shadows = True
                }


viewThirdPerson : BoundingBox3d Length.Meters LocalCoords -> Model -> Element Msg
viewThirdPerson scale model =
    -- Let's the user spin around and zoom in on selected road point.
    case lookupRoad model model.currentNode of
        Nothing ->
            none

        Just node ->
            row [ alignTop ]
                [ column
                    [ alignTop
                    ]
                    [ viewCurrentNode scale model node.startsAt
                    , positionControls model
                    ]
                , column [ alignTop ]
                    [ viewThirdPersonSubpane model
                    ]
                ]


viewPlanView : BoundingBox3d Length.Meters LocalCoords -> Model -> Element Msg
viewPlanView scale model =
    case lookupRoad model model.currentNode of
        Nothing ->
            none

        Just node ->
            row [ alignTop ]
                [ column
                    [ alignTop
                    ]
                    [ viewCurrentNodePlanView scale model node.startsAt
                    , positionControls model
                    ]
                , column [ spacing 10, padding 10, alignTop ]
                    [ viewPlanViewSubpane model
                    ]
                ]


viewPlanViewSubpane : Model -> Element Msg
viewPlanViewSubpane model =
    column [ alignTop, padding 20, spacing 10 ]
        [ Input.radioRow
            [ Border.rounded 6
            , Border.shadow { offset = ( 0, 0 ), size = 3, blur = 10, color = rgb255 0xE0 0xE0 0xE0 }
            ]
            { onChange = SetViewSubmode
            , selected = Just model.planSubmode
            , label =
                Input.labelHidden "Choose mode"
            , options =
                [ Input.optionWith ShowData <| radioButton First "Location\ndata"
                , Input.optionWith ShowBendFixes <| radioButton Mid "Bend\nsmoother"
                , Input.optionWith ShowNodeTools <| radioButton Last "On the\nstraight"
                ]
            }
        , case model.planSubmode of
            ShowData ->
                viewSummaryStats model

            ShowGradientFixes ->
                viewGradientFixerPane model

            ShowBendFixes ->
                viewBendFixerPane model

            ShowNodeTools ->
                viewNodeTools model
        ]


viewProfileView : Model -> Element Msg
viewProfileView model =
    -- Let's the user spin around and zoom in on selected road point.
    let
        getNodeNum =
            case model.currentNode of
                Just n ->
                    n

                Nothing ->
                    0

        getRoad =
            case model.currentNode of
                Just n ->
                    model.roadsForProfileView |> List.drop n |> List.head

                Nothing ->
                    Nothing
    in
    case getRoad of
        Nothing ->
            none

        Just road ->
            row [ alignTop ]
                [ column
                    [ alignTop
                    ]
                    [ viewRouteProfile model road.startsAt
                    , positionControls model
                    ]
                , viewProfileSubpane model
                ]


viewThirdPersonSubpane : Model -> Element Msg
viewThirdPersonSubpane model =
    column [ alignTop, padding 20, spacing 10 ]
        [ Input.radioRow
            [ Border.rounded 6
            , Border.shadow { offset = ( 0, 0 ), size = 3, blur = 10, color = rgb255 0xE0 0xE0 0xE0 }
            ]
            { onChange = SetViewSubmode
            , selected = Just model.thirdPersonSubmode
            , label =
                Input.labelHidden "Choose mode"
            , options =
                [ Input.optionWith ShowData <| radioButton First "Location\ndata"
                , Input.optionWith ShowGradientFixes <| radioButton Mid "Gradient\nsmoother"
                , Input.optionWith ShowBendFixes <| radioButton Last "Bend\nsmoother"
                ]
            }
        , case model.thirdPersonSubmode of
            ShowData ->
                column [ alignTop, spacing 10, padding 10 ]
                    [ viewSummaryStats model
                    , flythroughControls model
                    ]

            ShowGradientFixes ->
                viewGradientFixerPane model

            ShowBendFixes ->
                viewBendFixerPane model

            ShowNodeTools ->
                none
        ]


viewProfileSubpane : Model -> Element Msg
viewProfileSubpane model =
    column [ alignTop, padding 20, spacing 10 ]
        [ Input.radioRow
            [ Border.rounded 6
            , Border.shadow { offset = ( 0, 0 ), size = 3, blur = 10, color = rgb255 0xE0 0xE0 0xE0 }
            ]
            { onChange = SetViewSubmode
            , selected = Just model.profileSubmode
            , label =
                Input.labelHidden "Choose mode"
            , options =
                [ Input.optionWith ShowData <| radioButton First "Location\ndata"
                , Input.optionWith ShowGradientFixes <| radioButton Last "Gradient\nsmoother"
                ]
            }
        , case model.profileSubmode of
            ShowData ->
                viewSummaryStats model

            ShowGradientFixes ->
                viewGradientFixerPane model

            ShowBendFixes ->
                viewBendFixerPane model

            ShowNodeTools ->
                viewSummaryStats model
        ]


viewBendFixerPane : Model -> Element Msg
viewBendFixerPane model =
    let
        fixBendButton smooth =
            button
                prettyButtonStyles
                { onPress = Just SmoothBend
                , label =
                    text <|
                        "Smooth between markers\nRadius "
                            ++ showDecimal2 smooth.radius
                }
    in
    column [ spacing 10, padding 10, alignTop ]
        [ markerButton model
        , case ( model.currentNode, model.smoothedBend ) of
            ( Just _, Just smooth ) ->
                column [ spacing 10, padding 10, alignTop ]
                    [ fixBendButton smooth
                    , bendSmoothnessSlider model
                    ]

            ( Just c, _ ) ->
                insertNodeOptionsBox c

            _ ->
                none
        , undoButton model
        , viewBearingChanges model
        ]


viewNodeTools : Model -> Element Msg
viewNodeTools model =
    --2020-12-08 Adding tools to Nudge node, split straight, straighten straight.
    let
        straightenButton c m =
            button
                prettyButtonStyles
                { onPress = Just (StraightenStraight c m)
                , label =
                    text <|
                        "Straighten between markers"
                }

        nudgeButton c value =
            button
                prettyButtonStyles
                { onPress = Just (NudgeNode c value)
                , label =
                    text <|
                        "Apply nudge"
                }

        splitButton c =
            button
                prettyButtonStyles
                { onPress = Just (SplitRoad c)
                , label =
                    text <|
                        "Divide this segment\ninto two"
                }

        nudgeSlider c value =
            Input.slider
                commonShortHorizontalSliderStyles
                { onChange = SetNudgeFactor c
                , label =
                    Input.labelBelow [] <|
                        text <|
                            "Nudge value = "
                                ++ showDecimal2 value
                , min = -1.0
                , max = 1.0
                , step = Nothing
                , value = value
                , thumb = Input.defaultThumb
                }
    in
    column [ spacing 10, padding 10, alignTop ]
        [ markerButton model
        , case ( model.currentNode, model.markedNode ) of
            ( Just c, Just m ) ->
                straightenButton c m

            ( Just c, Nothing ) ->
                column [ padding 5, spacing 10 ]
                    [ nudgeSlider c model.nudgeValue
                    , nudgeButton c model.nudgeValue
                    , splitButton c
                    ]

            _ ->
                none
        , undoButton model
        ]


showCircle : Maybe SmoothedBend -> Element Msg
showCircle hello =
    case hello of
        Just sb ->
            let
                ( x, y ) =
                    sb.centre
            in
            column [ Border.width 1 ]
                [ text "Debugging information"

                --, text <| showDecimal6 x
                --, text <| showDecimal6 y
                , text <| "Radius " ++ (showDecimal6 <| metresPerDegreeLatitude * sb.radius)
                ]

        Nothing ->
            none


markerButton model =
    let
        makeButton label =
            button
                prettyButtonStyles
                { onPress = Just ToggleMarker
                , label =
                    text <| label
                }
    in
    row [ spacing 5, padding 5, Border.width 1 ] <|
        case model.markedNode of
            Just _ ->
                [ button
                    prettyButtonStyles
                    { onPress = Just MarkerBackOne
                    , label = text "◀︎"
                    }
                , makeButton "Clear marker"
                , button
                    prettyButtonStyles
                    { onPress = Just MarkerForwardOne
                    , label = text "►︎"
                    }
                ]

            Nothing ->
                [ makeButton "Drop marker to select a range" ]


undoButton model =
    button
        prettyButtonStyles
        { onPress =
            case model.undoStack of
                [] ->
                    Nothing

                _ ->
                    Just Undo
        , label =
            case model.undoStack of
                u :: _ ->
                    text <| "Undo " ++ u.label

                _ ->
                    text "Nothing to undo"
        }


viewGradientFixerPane : Model -> Element Msg
viewGradientFixerPane model =
    let
        gradientSmoothControls =
            case ( model.currentNode, model.markedNode ) of
                ( Just c, Just m ) ->
                    let
                        start =
                            min c m

                        finish =
                            max c m

                        avg =
                            averageGradient model start finish
                    in
                    case avg of
                        Just gradient ->
                            column [ Border.width 1, spacing 5, padding 5 ]
                                [ button
                                    prettyButtonStyles
                                    { onPress = Just <| SmoothGradient start finish gradient
                                    , label =
                                        text <|
                                            "Smooth between markers\nAverage gradient "
                                                ++ showDecimal2 gradient
                                    }
                                , smoothnessSlider model
                                ]

                        _ ->
                            none

                ( Just c, Nothing ) ->
                    insertNodeOptionsBox c

                _ ->
                    none
    in
    column [ spacing 10 ] <|
        []
            ++ [ markerButton model ]
            ++ [ gradientSmoothControls ]
            ++ [ undoButton model
               , viewGradientChanges model
               ]


insertNodeOptionsBox c =
    column
        [ Border.width 1
        , Border.color <| rgb255 114 159 207
        , spacing 10
        , padding 5
        ]
        [ paragraph [] [ text "Replace current node with two nodes\nto smooth this transition." ]
        , row [ padding 5, spacing 5 ]
            [ button
                prettyButtonStyles
                { onPress = Just (VerticalNodeSplit c InsertNodeAfter)
                , label = text "Insert a node\nafter this one"
                }
            , button
                prettyButtonStyles
                { onPress = Just (VerticalNodeSplit c InsertNodeBefore)
                , label = text "Insert a node\nbefore this one"
                }
            ]
        ]


smoothnessSlider : Model -> Element Msg
smoothnessSlider model =
    Input.slider
        commonShortHorizontalSliderStyles
        { onChange = SetBumpinessFactor
        , label =
            Input.labelBelow [] <|
                text <|
                    "Bumpiness factor = "
                        ++ showDecimal2 model.bumpinessFactor
        , min = 0.0
        , max = 1.0
        , step = Nothing
        , value = model.bumpinessFactor
        , thumb = Input.defaultThumb
        }


lookupRoad : Model -> Maybe Int -> Maybe DrawingRoad
lookupRoad model idx =
    -- Have I not written this already?
    case idx of
        Just i ->
            Array.get i model.roadArray

        _ ->
            Nothing


viewSummaryStats : Model -> Element Msg
viewSummaryStats model =
    let
        getNodeNum =
            case model.currentNode of
                Just n ->
                    n

                Nothing ->
                    0
    in
    case Array.get getNodeNum model.nodeArray of
        Just node ->
            column [ padding 20, spacing 20 ]
                [ row [ padding 20 ]
                    [ column [ spacing 10 ]
                        [ text "Index "
                        , text "Latitude "
                        , text "Longitude "
                        , text "Elevation "
                        ]
                    , column [ spacing 10 ]
                        [ text <| String.fromInt <| getNodeNum
                        , text <| showDecimal6 node.trackPoint.lat
                        , text <| showDecimal6 node.trackPoint.lon
                        , text <| showDecimal2 node.trackPoint.ele
                        ]
                    ]
                ]

        Nothing ->
            none


viewCurrentNode : BoundingBox3d Length.Meters LocalCoords -> Model -> DrawingNode -> Element Msg
viewCurrentNode scale model node =
    let
        focus =
            case model.flythrough of
                Just fly ->
                    fly.cameraPosition

                Nothing ->
                    node.location

        camera =
            Camera3d.perspective
                { viewpoint =
                    Viewpoint3d.orbitZ
                        { focalPoint = focus
                        , azimuth = model.azimuth
                        , elevation = model.elevation
                        , distance =
                            Length.meters <|
                                distanceFromZoom model.zoomLevelThirdPerson
                        }
                , verticalFieldOfView = Angle.degrees <| 20 * model.zoomLevelThirdPerson
                }
    in
    row []
        [ zoomSlider model.zoomLevelThirdPerson ZoomLevelThirdPerson
        , el
            withMouseCapture
          <|
            html <|
                Scene3d.sunny
                    { camera = camera
                    , dimensions = ( Pixels.int 800, Pixels.int 500 )
                    , background = Scene3d.backgroundColor Color.lightBlue
                    , clipDepth = Length.meters 1.0
                    , entities =
                        model.varyingVisualEntities
                            ++ model.staticVisualEntities
                            ++ model.terrainEntities
                    , upDirection = positiveZ
                    , sunlightDirection = negativeZ
                    , shadows = True
                    }
        ]


viewCurrentNodePlanView : BoundingBox3d Length.Meters LocalCoords -> Model -> DrawingNode -> Element Msg
viewCurrentNodePlanView scale model node =
    let
        focus =
            Point3d.projectOnto Plane3d.xy
                node.location

        eyePoint =
            Point3d.translateBy
                (Vector3d.meters 0.0 0.0 5000.0)
                node.location

        camera =
            Camera3d.orthographic
                { viewpoint =
                    Viewpoint3d.lookAt
                        { focalPoint = focus
                        , eyePoint = eyePoint
                        , upDirection = positiveY
                        }
                , viewportHeight = Length.meters <| 2.0 * 10.0 ^ (5.0 - model.zoomLevelPlan)
                }
    in
    row []
        [ zoomSlider model.zoomLevelPlan ZoomLevelPlan
        , el
            []
          <|
            html <|
                Scene3d.sunny
                    { camera = camera
                    , dimensions = ( Pixels.int 800, Pixels.int 500 )
                    , background = Scene3d.backgroundColor Color.darkGreen
                    , clipDepth = Length.meters 1.0
                    , entities = model.varyingVisualEntities ++ model.staticVisualEntities
                    , upDirection = positiveZ
                    , sunlightDirection = negativeZ
                    , shadows = True
                    }
        ]


viewRouteProfile : Model -> DrawingNode -> Element Msg
viewRouteProfile model node =
    let
        focus =
            Point3d.projectOnto
                Plane3d.yz
                node.location

        eyePoint =
            Point3d.translateBy
                (Vector3d.meters 100.0 0.0 0.0)
                node.location

        camera =
            Camera3d.orthographic
                { viewpoint =
                    Viewpoint3d.lookAt
                        { focalPoint = focus
                        , eyePoint = eyePoint
                        , upDirection = positiveZ
                        }
                , viewportHeight = Length.meters <| 1.0 * 10.0 ^ (4.0 - model.zoomLevelProfile)
                }
    in
    row []
        [ zoomSlider model.zoomLevelProfile ZoomLevelProfile
        , el
            []
          <|
            html <|
                Scene3d.sunny
                    { camera = camera
                    , dimensions = ( Pixels.int 800, Pixels.int 500 )
                    , background = Scene3d.backgroundColor Color.lightCharcoal
                    , clipDepth = Length.meters 1.0
                    , entities = model.varyingProfileEntities ++ model.staticProfileEntities
                    , upDirection = positiveZ
                    , sunlightDirection = negativeZ
                    , shadows = True
                    }
        ]


subscriptions : Model -> Sub Msg
subscriptions model =
    Time.every 10 Tick
