module TrackPoint exposing (..)

type alias TrackPoint =
    -- This is the basic info we extract from a GPX file.
    { lat : Float
    , lon : Float
    , ele : Float
    , idx : Int
    }