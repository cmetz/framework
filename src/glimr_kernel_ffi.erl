-module(glimr_kernel_ffi).
-export([cache_config/2, get_cached_config/1, clear_cached_config/1]).
-export([cache_session_store/1, get_cached_session_store/0]).

cache_config(Key, Value) ->
    persistent_term:put({glimr_config, Key}, Value),
    nil.

get_cached_config(Key) ->
    try persistent_term:get({glimr_config, Key}) of
        Value -> {ok, Value}
    catch
        error:badarg -> {error, nil}
    end.

clear_cached_config(Key) ->
    try persistent_term:erase({glimr_config, Key}) of
        _ -> nil
    catch
        error:badarg -> nil
    end.

cache_session_store(Store) ->
    persistent_term:put(glimr_session_store, Store),
    nil.

get_cached_session_store() ->
    try persistent_term:get(glimr_session_store) of
        Store -> {ok, Store}
    catch
        error:badarg -> {error, nil}
    end.
