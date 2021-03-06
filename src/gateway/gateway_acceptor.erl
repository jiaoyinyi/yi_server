%%%-------------------------------------------------------------------
%%% @author huangzaoyi
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. 三月 2020 01:38
%%%-------------------------------------------------------------------
-module(gateway_acceptor).
-author("huangzaoyi").

-behaviour(gen_server).

-export([start_link/2, start_acceptor/2]).

-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-include("common.hrl").
-include("logs.hrl").
-include("gateway.hrl").

pro_name(Num) ->
    list_to_atom(lists:concat(["gateway_acceptor_", Num])).

start_acceptor(LSock, Num) ->
    Name = pro_name(Num),
    Acceptor = #{
        id => Name,
        start => {?MODULE, start_link, [LSock, Num]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    },
    supervisor:start_child(gateway_acceptor_sup, Acceptor).

start_link(LSock, Num) ->
    Name = pro_name(Num),
    gen_server:start_link({local, Name}, ?MODULE, [LSock], []).

init([LSock]) ->
    {registered_name, Name} = erlang:process_info(self(), registered_name),
    ?info(?start_begin(Name)),
    process_flag(trap_exit, true),
    %% 异步监听客户端的连接
    {ok, Ref} = prim_inet:async_accept(LSock, -1),
    Acceptor = #gateway_acceptor{lsock = LSock, ref = Ref},
    ?info(?start_end(Name)),
    {ok, Acceptor}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    case catch do_handle_info(_Info, State) of
        {noreply, NewState} ->
            {noreply, NewState};
        {stop, normal, NewState} ->
            {stop, normal, NewState};
        _Err ->
            ?error("处理错误, 消息:~w, State:~w, Reason:~w", [_Info, State, _Err]),
            {noreply, State}
    end.

terminate(_Reason, _State) ->
    {registered_name, Name} = erlang:process_info(self(), registered_name),
    ?info(?stop_begin, (Name)),
    ?info(?stop_end, (Name)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% 正常接收到一个socket
do_handle_info({inet_async, LSock, Ref, {ok, CSock}}, Acceptor = #gateway_acceptor{lsock = LSock, ref = Ref}) ->
    {ok, Mod} = inet_db:lookup_socket(LSock),
    inet_db:register_socket(CSock, Mod),
    spawn_worker(CSock),
    case prim_inet:async_accept(LSock, -1) of
        {ok, NewRef} ->
            NewAcceptor = Acceptor#gateway_acceptor{ref = NewRef},
            {noreply, NewAcceptor};
        {error, closed} ->
            {stop, normal, Acceptor};
        {error, Reason} ->
            {stop, Reason, Acceptor}
    end;

%% socket 关闭
do_handle_info({inet_async, LSock, Ref, {error, closed}}, Acceptor = #gateway_acceptor{lsock = LSock, ref = Ref}) ->
    {stop, normal, Acceptor};

%% socket 报错
do_handle_info({inet_async, LSock, Ref, {error, Reason}}, Acceptor = #gateway_acceptor{lsock = LSock, ref = Ref}) ->
    ?error("网络异步处理错误, 原因:~w", [Reason]),
    {noreply, Acceptor};

do_handle_info(_Info, State) ->
    {noreply, State}.

%% 启动网关worker
spawn_worker(CSock) ->
    Opts = srv_config:get(gateway_options),
    Fun =
        fun({reuseaddr, _}, Acc) -> Acc;
            ({backlog, _}, Acc) -> Acc;
            (Opt, Acc) -> [Opt | Acc]
        end,
    NewOpts = lists:foldl(Fun, [], Opts),
    case inet:setopts(CSock, NewOpts) of
        ok ->
            case gateway_worker:start_worker() of
                {ok, Pid} ->
                    case gen_tcp:controlling_process(CSock, Pid) of
                        ok ->
                            Pid ! {start_worker, CSock};
                        _Err ->
                            ?error("交接socket进程失败, 返回:~w", [_Err]),
                            exit(Pid, normal),
                            catch inet:close(CSock)
                    end;
                _Err ->
                    ?error("启动worker进程失败，返回:~w", [_Err]),
                    catch inet:close(CSock)
            end;
        _Err ->
            ?error("设置socket参数失败, 返回:~w, 参数:~w", [_Err, NewOpts]),
            catch inet:close(CSock)
    end.
