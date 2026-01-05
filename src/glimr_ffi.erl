-module(glimr_ffi).
-export([get_version/0]).

get_version() ->
    case application:get_key(glimr, vsn) of
        {ok, Version} -> {ok, list_to_binary(Version)};
        undefined -> {error, nil}
    end.
