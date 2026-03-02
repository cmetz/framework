-module(glimr_command_test_ffi).
-export([cache_db_connections/1, cache_cache_stores/1, clear_db_connections/0, clear_cache_stores/0]).

cache_db_connections(Connections) ->
    persistent_term:put({glimr_config, <<"db_connections">>}, Connections),
    nil.

cache_cache_stores(Stores) ->
    persistent_term:put({glimr_config, <<"cache_stores">>}, Stores),
    nil.

clear_db_connections() ->
    try persistent_term:erase({glimr_config, <<"db_connections">>}) of
        _ -> nil
    catch
        error:badarg -> nil
    end.

clear_cache_stores() ->
    try persistent_term:erase({glimr_config, <<"cache_stores">>}) of
        _ -> nil
    catch
        error:badarg -> nil
    end.
