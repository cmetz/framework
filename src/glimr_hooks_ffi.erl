-module(glimr_hooks_ffi).
-export([call_module_main/1]).

call_module_main(ModuleString) ->
    Module = binary_to_atom(ModuleString, utf8),
    Module:main(),
    nil.
