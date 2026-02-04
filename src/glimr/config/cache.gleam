//// Cache Configuration
////
//// Centralizes cache store setup so application code doesn't
//// need to know about config file locations or parsing. Uses
//// ${VAR} syntax for secrets like Redis URLs to keep credentials
//// out of version control.
////

import dot_env/env
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import glimr/cache/driver.{type CacheStore, DatabaseStore, FileStore, RedisStore}
import simplifile
import tom

// ------------------------------------------------------------- Public Functions

/// Safe to call repeatedly from hot paths since results are
/// cached after first load. Returns empty list on missing/invalid
/// config to let apps start without cache configuration.
///
pub fn load() -> List(CacheStore) {
  case get_cached() {
    Ok(stores) -> stores
    Error(_) -> {
      let stores = load_from_file()
      cache(stores)
      stores
    }
  }
}

// ------------------------------------------------------------- Private Functions

/// Separated from load() to keep caching logic distinct from
/// file I/O. Makes the caching behavior easier to test and
/// reason about independently.
///
fn load_from_file() -> List(CacheStore) {
  case simplifile.read("config/cache.toml") {
    Ok(content) -> parse(content)
    Error(_) -> []
  }
}

/// Expects [stores.*] tables so users can define multiple named
/// stores (e.g., main, sessions, redis) with different backends
/// and switch between them at runtime.
///
fn parse(content: String) -> List(CacheStore) {
  case tom.parse(content) {
    Ok(toml) -> {
      case dict.get(toml, "stores") {
        Ok(tom.Table(stores)) -> {
          stores
          |> dict.to_list
          |> list.map(fn(entry) {
            let #(name, store_toml) = entry
            parse_store(name, store_toml)
          })
        }
        _ -> []
      }
    }
    Error(_) -> []
  }
}

/// Maps driver field to the appropriate CacheStore variant.
/// Defaults to file for unknown drivers since it requires no
/// external dependencies and works out of the box.
///
fn parse_store(name: String, toml: tom.Toml) -> CacheStore {
  let driver = get_string(toml, "driver", "file")

  case driver {
    "reis" ->
      RedisStore(
        name: name,
        url: get_env_string(toml, "url"),
        pool_size: get_env_int(toml, "pool_size"),
      )
    "database" ->
      DatabaseStore(
        name: name,
        database: get_string(toml, "database", "main"),
        table: get_string(toml, "table", "cache"),
      )
    _ -> FileStore(name: name, path: get_string(toml, "path", "priv/cache"))
  }
}

/// No env interpolation here since paths and table names are
/// typically static and safe to commit. Keeps config simple
/// for non-sensitive values.
///
fn get_string(toml: tom.Toml, key: String, default: String) -> String {
  case toml {
    tom.Table(table) -> {
      case dict.get(table, key) {
        Ok(tom.String(s)) -> s
        _ -> default
      }
    }
    _ -> default
  }
}

/// Returns Result to surface missing env vars early. Secrets
/// like Redis URLs should fail loudly at startup rather than
/// silently falling back to defaults.
///
fn get_env_string(toml: tom.Toml, key: String) -> Result(String, String) {
  case toml {
    tom.Table(table) -> {
      case dict.get(table, key) {
        Ok(tom.String(s)) -> interpolate_env(s)
        _ -> Error("Missing key: " <> key)
      }
    }
    _ -> Error("Invalid TOML structure")
  }
}

/// Accepts both TOML integers and strings for flexibility.
/// Strings allow env var references like "${REDIS_POOL_SIZE}"
/// for values that vary between environments.
///
fn get_env_int(toml: tom.Toml, key: String) -> Result(Int, String) {
  case toml {
    tom.Table(table) -> {
      case dict.get(table, key) {
        Ok(tom.String(s)) -> {
          case interpolate_env(s) {
            Ok(value) ->
              case int.parse(value) {
                Ok(i) -> Ok(i)
                Error(_) -> Error("Invalid int: " <> value)
              }
            Error(e) -> Error(e)
          }
        }
        Ok(tom.Int(i)) -> Ok(i)
        _ -> Error("Missing key: " <> key)
      }
    }
    _ -> Error("Invalid TOML structure")
  }
}

/// Only supports full-value substitution (${VAR}, not mixed
/// strings) to keep parsing simple. Partial interpolation
/// adds escaping complexity not worth it for config values.
///
fn interpolate_env(value: String) -> Result(String, String) {
  case string.starts_with(value, "${") && string.ends_with(value, "}") {
    True -> {
      let var_name =
        value
        |> string.drop_start(2)
        |> string.drop_end(1)

      case env.get_string(var_name) {
        Ok(s) -> Ok(s)
        Error(_) -> Error("Env var not set: " <> var_name)
      }
    }
    False -> Ok(value)
  }
}

// ------------------------------------------------------------- FFI Bindings

/// Stores parsed config in persistent_term for fast access
/// across all processes. Avoids re-parsing TOML on every
/// cache operation which would add unnecessary latency.
///
@external(erlang, "glimr_kernel_ffi", "cache_cache_config")
fn cache(stores: List(CacheStore)) -> Nil

/// Retrieves cached config from persistent_term. Returns Error
/// if not yet cached, signaling that load_from_file() should
/// be called to populate the cache.
///
@external(erlang, "glimr_kernel_ffi", "get_cached_cache_config")
fn get_cached() -> Result(List(CacheStore), Nil)
