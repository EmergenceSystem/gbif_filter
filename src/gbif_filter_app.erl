-module(gbif_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(UA, "agent/1.0 (EmergenceSystem; +https://github.com/EmergenceSystem)").

base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"image">>, <<"images">>, <<"species">>, <<"animals">>, <<"plants">>, <<"wildlife">>, <<"nature">>, <<"biodiversity">>, <<"gbif">>, <<"media">>].

start(_Type, _Args) ->
    case gbif_filter_sup:start_link() of
        {ok, Pid} -> ok = start_pop_and_http(), {ok, Pid};
        Error -> Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(gbif_filter_query_listener),
    catch em_pop_sup:stop_node(gbif_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(gbif_filter, pop_port,   9562),
    QueryPort = application:get_env(gbif_filter, query_port, 9563),
    Seeds     = application:get_env(gbif_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(gbif_filter),
    catch cowboy:stop_listener(gbif_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(gbif_filter, #{
        port => PopPort, query_port => QueryPort, vector => Vec,
        max_peers => 100, gossip_interval => 5_000
    }),
    lists:foreach(fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end, Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http, #{server => gbif_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(gbif_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[gbif_filter] gossip port ~w  query port ~w", [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) -> {[], Memory}.

extract_query(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map, maps:get(<<"query">>, Map, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

put_opt(M, _K, null)      -> M;
put_opt(M, _K, <<>>)      -> M;
put_opt(M, K, V) when is_binary(V) -> M#{K => V};
put_opt(M, _K, _)         -> M.

-define(SEARCH_URL, "https://api.gbif.org/v1/occurrence/search?mediaType=StillImage&limit=12&q=").

generate_embryo_list(Body) ->
    case extract_query(Body) of
        "" -> [];
        Query -> fetch(?SEARCH_URL ++ uri_string:quote(Query))
    end.

fetch(Url) ->
    Headers = [{"User-Agent", ?UA}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, 8000}, {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case catch json:decode(Body) of
                #{<<"results">> := List} when is_list(List) ->
                    lists:filtermap(fun occ_embryo/1, List);
                _ -> []
            end;
        _ -> []
    end.

occ_embryo(#{<<"media">> := [M | _]} = R) when is_map(M) ->
    case maps:get(<<"identifier">>, M, null) of
        Img when is_binary(Img), byte_size(Img) > 0 ->
            Title = maps:get(<<"scientificName">>, R, <<"Unknown species">>),
            Url = case maps:get(<<"key">>, R, null) of
                      K when is_integer(K) ->
                          <<"https://www.gbif.org/occurrence/", (integer_to_binary(K))/binary>>;
                      _ -> Img
                  end,
            {true, #{<<"properties">> => #{
                <<"media_type">> => <<"image">>,
                <<"media_url">>  => Img,
                <<"thumbnail">>  => Img,
                <<"title">>      => Title,
                <<"url">>        => Url,
                <<"source">>     => <<"gbif">>
            }}};
        _ -> false
    end;
occ_embryo(_) -> false.
