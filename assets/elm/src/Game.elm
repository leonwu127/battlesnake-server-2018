module Game exposing (..)

import Char
import Debug exposing (..)
import Dict
import Decoder as Decoder
import Game.Types exposing (..)
import Game.View exposing (..)
import GameBoard
import Html exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Keyboard
import Phoenix.Channel as Channel
import Phoenix.Push as Push
import Phoenix.Socket as Socket
import Task exposing (..)
import Tuple exposing (..)
import Types exposing (..)


-- MAIN


main : Program Flags Model Msg
main =
    programWithFlags
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- INIT


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model =
            { socket = socket flags.websocket flags.gameid
            , gameid = flags.gameid
            , phase = InitPhase
            }

        cmds =
            [ emit JoinSpectatorChannel
            , emit JoinAdminChannel
            ]
    in
        model ! cmds



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case (log "msg" msg) of
        KeyDown keyCode ->
            case Char.fromCode keyCode of
                'H' ->
                    model ! [ emit ResumeGame ]

                'J' ->
                    model ! [ emit NextStep ]

                'K' ->
                    model ! [ emit PrevStep ]

                'L' ->
                    model ! [ emit PauseGame ]

                'Q' ->
                    model ! [ emit StopGame ]

                _ ->
                    model ! []

        PhxMsg msg ->
            Socket.update msg model.socket
                |> pushCmd model

        JoinSpectatorChannel ->
            joinChannel ("spectator:" ++ model.gameid) model

        JoinAdminChannel ->
            joinChannel ("admin:" ++ model.gameid) model

        JoinChannelSuccess _ ->
            model ! []

        JoinChannelFailed error ->
            Debug.crash (toString error)

        ResumeGame ->
            adminCmd "resume" model

        PauseGame ->
            adminCmd "pause" model

        StopGame ->
            adminCmd "stop" model

        NextStep ->
            adminCmd "next" model

        PrevStep ->
            adminCmd "prev" model

        ReceiveMoveResponse raw ->
            model ! []

        ReceiveRestartRequestOk raw ->
            case JD.decodeValue (Decoder.lobbySnake) raw of
                Ok { snakeId, data } ->
                    let
                        updateSnake snake =
                            { snake | loadingState = Ready data }

                        model_ =
                            updateLobbyMember updateSnake model snakeId
                    in
                        model_ ! []

                Err err ->
                    Debug.crash err

        ReceiveRestartRequestError raw ->
            case JD.decodeValue Decoder.error raw of
                Ok { snakeId, data } ->
                    let
                        updateSnake snake =
                            { snake | loadingState = Failed data }

                        model_ =
                            updateLobbyMember updateSnake model snakeId
                    in
                        model_ ! []

                Err e ->
                    Debug.crash e

        ReceiveRestartFinished _ ->
            model ! []

        ReceiveRestartInit raw ->
            case JD.decodeValue Decoder.lobby raw of
                Ok lobby ->
                    { model | phase = LobbyPhase lobby } ! []

                Err e ->
                    Debug.crash e

        RecieveTick raw ->
            case JD.decodeValue Decoder.tick raw of
                Ok ( world, rawWorld ) ->
                    { model | phase = GamePhase world }
                        ! [ GameBoard.render rawWorld ]

                Err e ->
                    Debug.crash e



-- SUBS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Socket.listen model.socket PhxMsg
        , Keyboard.downs KeyDown
        ]



-- FUNCTIONS


emit : msg -> Cmd msg
emit msg =
    perform identity (succeed msg)


phxMsg : Cmd PhxSockMsg -> Cmd Msg
phxMsg =
    Cmd.map PhxMsg


pushCmd : Model -> ( PhxSock, Cmd PhxSockMsg ) -> ( Model, Cmd Msg )
pushCmd model ( socket, msg ) =
    ( socket, phxMsg msg )
        |> mapFirst (\x -> { model | socket = x })


joinChannel : String -> Model -> ( Model, Cmd Msg )
joinChannel channel model =
    Channel.init channel
        |> Channel.withPayload (JE.object [ ( "id", JE.string model.gameid ) ])
        |> Channel.onJoin JoinChannelSuccess
        |> Channel.onJoinError JoinChannelFailed
        |> flip Socket.join model.socket
        |> pushCmd model


socket : String -> String -> PhxSock
socket url gameid =
    let
        topic =
            "spectator:" ++ gameid

        model =
            { gameid = gameid }
    in
        Socket.init url
            |> Socket.on "tick" topic RecieveTick
            |> Socket.on "restart:init" topic ReceiveRestartInit
            |> Socket.on "restart:finished" topic ReceiveRestartFinished
            |> Socket.on "restart:request:error" topic ReceiveRestartRequestError
            |> Socket.on "restart:request:ok" topic ReceiveRestartRequestOk
            |> Socket.on "move:response" topic ReceiveMoveResponse


adminCmd : String -> Model -> ( Model, Cmd Msg )
adminCmd cmd model =
    Push.init cmd ("admin:" ++ model.gameid)
        |> flip Socket.push model.socket
        |> pushCmd model


updateLobbyMember : (Permalink -> Permalink) -> Model -> String -> Model
updateLobbyMember update model id =
    let
        updateSnakes snakes =
            Dict.update id (Maybe.map update) snakes

        updateLobby lobby =
            { lobby | snakes = updateSnakes lobby.snakes }

        phase =
            case model.phase of
                LobbyPhase lobby ->
                    LobbyPhase (updateLobby lobby)

                x ->
                    x
    in
        { model | phase = phase }
