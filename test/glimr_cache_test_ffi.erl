-module(glimr_cache_test_ffi).
-export([clear_config_cache/0]).

clear_config_cache() ->
    try persistent_term:erase({glimr_config, <<"toml">>}) of
        _ -> nil
    catch
        error:badarg -> nil
    end,
    try persistent_term:erase({glimr_config, <<"cache_stores">>}) of
        _ -> nil
    catch
        error:badarg -> nil
    end.
