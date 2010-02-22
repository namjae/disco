
-module(ddfs_put).

-include_lib("kernel/include/file.hrl").

-export([start/1]).

% maximum file size: 1T
-define(MAX_RECV_BODY, (1024*1024*1024*1024)).
% blob mode u=r
-define(FILE_MODE, 8#00400).

start(MochiConfig) ->
    error_logger:info_report({"START PID", self()}),
    mochiweb_http:start([{name, ddfs_put},
        {loop, fun(Req) -> loop(Req:get(path), Req) end}
            | MochiConfig]).

loop("/proxy/" ++ Path, Req) ->
    {_Node, Rest} = mochiweb_util:path_split(Path),
    {_Method, RealPath} = mochiweb_util:path_split(Rest),
    loop([$/|RealPath], Req);

loop("/ddfs/" ++ BlobName, Req) ->
    % Disable keep-alive
    erlang:put(mochiweb_request_force_close, true),
    
    case {Req:get(method),
            valid_blob(catch ddfs_util:unpack_objname(BlobName))} of
        {'PUT', true} ->
            case catch gen_server:call(ddfs_node, {put_blob, BlobName}) of
                {ok, Path, Url} ->
                    receive_blob(Req, {Path, BlobName}, Url);
                {error, Path, Error} ->
                    error_reply(Req, "Could not create path for blob",
                        Path, Error);
                _ ->
                    Req:respond({503, [],
                        ["Maximum number of uploaders reached. ",
                         "Try again later"]})
                    
            end;
        {'PUT', _} ->
            Req:respond({403, [], ["Invalid blob name"]});
        _ ->
            Req:respond({501, [], ["Method not supported"]})
    end;

loop(_, Req) ->
    Req:not_found().

valid_blob({'EXIT', _}) -> false;
valid_blob({Name, _}) -> 
    ddfs_util:is_valid_name(binary_to_list(Name)).

receive_blob(Req, {Path, Fname}, Url) ->
    Dir = filename:join(Path, Fname),
    case prim_file:read_file_info(Dir) of
        {error, enoent} ->
            Tstamp = ddfs_util:timestamp(),
            Dst = filename:join(Path, ["!partial-", Tstamp, ".", Fname]),
            case file:open(Dst, [write, raw, binary]) of
                {ok, IO} -> receive_blob(Req, IO, Dst, Url);
                Error -> error_reply(Req, "Opening file failed", Dst, Error)
            end;
        _ ->
            error_reply(Req, "File exists", Dir, Dir)
    end.

receive_blob(Req, IO, Dst, Url) ->
    case receive_body(Req, IO) of
        ok ->
            [_, Fname] = string:tokens(Dst, "."),
            Dir = filename:join(filename:dirname(Dst), Fname),
            % NB: Renaming is not atomic below, thus there's a small
            % race condition if two clients are PUTting the same blob
            % concurrently and finish at the same time. In any case the
            % file should not be corrupted.
            case ddfs_util:safe_rename(Dst, Dir) of
                ok ->
                    Req:respond({201,
                        [{"content-type", "application/json"}],
                            ["\"", Url, "\""]});
                {error, {rename_failed, E}} ->
                    error_reply(Req, "Rename failed", Dst, E);
                {error, {chmod_failed, E}} ->
                    error_reply(Req, "Mode change failed", Dst, E);
                {error, file_exists} ->
                    error_reply(Req, "File exists", Dst, Dir)
            end;
        Error ->
            error_reply(Req, "Write failed", Dst, Error)
    end.

receive_body(Req, IO) ->
    R0 = Req:stream_body(?MAX_RECV_BODY, fun
            ({_, Buf}, ok) -> file:write(IO, Buf);
            (_, S) -> S
        end, ok),
    R1 = file:sync(IO),
    R2 = file:close(IO),
    % R0 == <<>> if the blob is zero bytes
    case lists:filter(fun(ok) -> false; (<<>>) -> false; (_) -> true end,
            [R0, R1, R2]) of
        [] -> ok;
        [Error|_] -> Error
    end.

error_reply(Req, Msg, Dst, Err) ->
    M = io_lib:format("~s (path: ~s): ~p", [Msg, Dst, Err]),
    error_logger:warning_report(M),
    Req:respond({500, [], M}).
   


