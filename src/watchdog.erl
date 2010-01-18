%%%-------------------------------------------------------------------
%%% File    : watchdog.erl
%%% Author  : Mats Cronqvist <etxmacr@mwux005>
%%% Description : 
%%%
%%% Created : 11 Mar 2005 by Mats Cronqvist <etxmacr@mwux005>
%%%-------------------------------------------------------------------
-module(watchdog).

% API
-export(
   [start/0,stop/0
    ,add_send_subscriber/4,add_log_subscriber/0,add_proc_subscriber/1
    ,clear_subscribers/0
    ,message/1]).

% gen_serv callbacks
-export(
   [handle_info/2
    ,init/1
    ,rec_info/1]).

-include("log.hrl").

-record(ld, 
	{jailed=[]			 %jailed pids
	 ,subscribers=[]		 %where to send our reports
	 ,triggers=default_triggers()	 %{atom(Tag), fun/1->no|fun/1}
	 ,prfState			 %prfTarg:subscribe return val
	 ,userData			 %last user data
	 ,prfData			 %last prf data
	 ,monData			 %last system_monitor data
	}).

rec_info(ld) ->
  record_info(fields,ld).

%% constants

default_triggers() -> 
  [ {[sysMon,long_gc],500}	      %gc time [ms]
   ,{[sysMon,large_heap],1024*1024}    %heap size [words]
   ,{user,true}
   ,{ticker,true}
   ,{[prfSys,user],fun(X)->true=(0.95<X) end}
   ,{[prfSys,kernel],fun(X)->true=(0.5<X) end}
   ,{[prfSys,iowait],fun(X)->true=(0.3<X) end}
  ].

timeout(restart) -> 5000;			%  5 sec
timeout(release) -> 1800.			%  1.8 sec
-define(max_jailed, 100).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% api
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() -> 
  case gen_serv:start(?MODULE) of
    {ok,Pid} ->  Pid;
    {error,{already_started,Pid}} -> Pid
  end.

stop() -> 
  gen_serv:stop().

add_proc_subscriber(Pid) when is_pid(Pid) ->
  case is_process_alive(Pid) of
    true -> send_to_wd({add_subscriber,{{pid,Pid},mk_send(Pid)}});
    false-> {error,no_such_pid}
  end;
add_proc_subscriber(Reg) when is_atom(Reg) ->
  send_to_wd({add_subscriber,{{Reg,node()},mk_send(Reg)}});
add_proc_subscriber({Reg,Node}) when is_atom(Reg),is_atom(Node) ->
  send_to_wd({add_subscriber,{{Reg,Node},mk_send({Reg,Node})}}).

%% E.g:  watchdog:add_send_subscriber(tcp,"localhost",56669,"I'm a Cookie").
%% it's possible to add the same subscriber twice. this is a bug.
add_send_subscriber(Proto,Host,Port,PassPhrase) ->
  case inet:gethostbyname(Host) of
    {ok,{hostent,Host,[],inet,4,_}} -> 
      Key = {Proto,{Host,Port}},
      send_to_wd({add_subscriber,{Key,mk_send(Proto,Host,Port,PassPhrase)}});
    {ok,{hostent,G,[W],inet,4,_}} -> {error,{badhost,W,G}};
    {ok,R}                        -> {error,R};
    {error,R}                     -> {error,R}
  end.

add_log_subscriber() ->
  try ?MODULE ! {add_subscriber,{log,mk_log(group_leader())}}, ok
  catch _:R -> {error,R}
  end.

clear_subscribers() ->
  try ?MODULE ! clear_subscribers, ok
  catch _:R -> {error,R}
  end.

message(Term) ->
  try ?MODULE ! {user,Term}, ok
  catch C:R -> {C,R}
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init([]) ->
  LD = #ld{prfState=prfTarg:subscribe(node(),self(),[prfSys,prfPrc])},
  start_monitor(LD#ld.triggers),
  LD.

% admin
handle_info(list_triggers,LD) ->
  print_term(group_leader(),LD#ld.triggers),
  LD;
handle_info({del_trigger,ID},LD) ->
  LD#ld{triggers=del_trigger(LD#ld.triggers,ID)};
handle_info({add_trigger,{ID,Fun}},LD) ->
  LD#ld{triggers=add_trigger(LD#ld.triggers,ID,Fun)};
handle_info(list_subscribers,LD) ->
  print_term(group_leader(),LD#ld.subscribers),
  LD;
handle_info(clear_subscribers,LD) ->
  LD#ld{subscribers=[]};
handle_info({add_subscriber,{Key,Sub}},LD) ->
  case lists:keysearch
  LD#ld{subscribers=[Sub|LD#ld.subscribers]};

% events
handle_info(trigger,LD) -> % fake trigger for debugging
  send_report(LD,test),
  LD;
handle_info({user,Data},LD) -> % data from user
  NLD = LD#ld{userData=Data},
  try do_user(check_jailed(NLD,userData))
  catch _ -> NLD
  end;
handle_info({{data,_},Data},LD) -> % data from prfTarg
  NLD = LD#ld{prfData=Data},
  try do_triggers(check_jailed(NLD,prfData))
  catch _ -> NLD
  end;
handle_info({monitor,Pid,Tag,Data},LD) -> % data from system_monitor
  NLD = LD#ld{monData=[{tag,Tag},{pid,Pid},{data,Data}]},
  try do_mon(check_jailed(NLD,Pid))
  catch _ -> NLD
  end;

% timeouts
handle_info({timeout, _, restart},LD) -> % restarting after timeout
  start_monitor(LD#ld.triggers),
  LD#ld{jailed=[]};
handle_info({timeout, _, {release, Pid}},LD) -> % release a pid from jail
  LD#ld{jailed = LD#ld.jailed--[Pid]};

% "this shouldn't happen"(TM)
handle_info(X,LD) ->
  ?log({unexpected_msg,X}),
  LD.

start_monitor(Triggers) ->
  erlang:system_monitor(self(), sysmons(Triggers)).

sysmons(Triggers) ->
  [{Tag,Val} || {[sysMon,Tag],Val} <- Triggers] ++ [busy_port,busy_dist_port].

stop_monitor() ->
  erlang:system_monitor(undefined).

%% trigger() :: {ID,Val} 
%% Val :: number() | function()
%% ID :: list(Tag) 
%% Tag :: atom() - tags into the data structure. i.e. [prfSys,iowait]
add_trigger(Triggers,ID,Fun) -> 
  maybe_restart(ID,[{ID,Fun}|clean_triggers(Triggers,[ID])]).

del_trigger(Triggers,ID) ->
  maybe_restart(ID,clean_triggers(Triggers,[ID])).

maybe_restart(Trig,Triggers) -> 
  case Trig of 
    [sysMon|_] -> stop_monitor(), start_monitor(Triggers);
    _ -> ok
  end,
  Triggers.

clean_triggers(Triggers,IDs) ->
  lists:filter(fun({ID,_})->not lists:member(ID,IDs) end, Triggers).

check_jailed(LD,_) when ?max_jailed < length(LD#ld.jailed) ->
  % we take a timeout when enough pids are jailed. conservative is good.
  erlang:start_timer(timeout(restart), self(), restart),
  stop_monitor(),
  flush(),
  throw(taking_timeout);
check_jailed(LD,What) ->
  case lists:member(What, LD#ld.jailed) of
    false-> 
      erlang:start_timer(timeout(release), self(), {release, What}),
      LD#ld{jailed=[What|LD#ld.jailed]};
    true -> 
      throw(is_jailed)
    end.

do_mon(LD) ->
  send_report(LD,sysMon),
  LD.

do_user(LD) ->
  send_report(LD,user),
  LD.

do_triggers(LD) ->
  {Triggered, NewTriggers} = check_triggers(LD#ld.triggers,LD#ld.prfData),
  [send_report(LD,Trig) || Trig <- Triggered],
  LD#ld{triggers=NewTriggers}.

check_triggers(Triggers,Data) -> 
  case check_triggers(Triggers,Data,[]) of
    [] -> {[],Triggers};
    Trigd -> IDs = [ID || {ID,_} <- Trigd],
	     {IDs,Trigd++clean_triggers(Triggers,IDs)}
  end.

check_triggers([],_,O) -> O;
check_triggers([T|Ts],Data,O) ->
  check_triggers(Ts,Data,try [check_trigger(T,Data)|O] catch _:_-> O end).

check_trigger({ticker,true},_Data) -> {ticker,true};
check_trigger({ID,T},Data) when is_function(T) -> 
  case T(get_measurement(ID,Data)) of
    true -> {ID,T};
    NewT when is_function(NewT)  -> {ID,NewT}
  end.

send_report(LD,Trigger) ->
  Report = make_report(Trigger,LD),
  [Sub(Report) || Sub <- LD#ld.subscribers].

make_report(user,LD) ->
  reporter(user,LD#ld.userData);
make_report(sysMon,LD) ->
  reporter(sysMon,expand_ps(LD#ld.monData));
make_report(Trigger,LD) ->
  reporter(Trigger,LD#ld.prfData).

reporter(Trigger,TriggerData) ->
  {?MODULE,node(),now(),Trigger,TriggerData}.

expand_ps([]) -> [];
expand_ps([{T,P}|Es]) when is_pid(P)-> pii({T,P})++expand_ps(Es);
expand_ps([{T,P}|Es]) when is_port(P)-> poi({T,P})++expand_ps(Es);
expand_ps([E|Es]) -> [E|expand_ps(Es)].

pi_info() -> [message_queue_len,current_function,initial_call,registered_name].
pii({T,Pid}) -> [{T,Pid} | prfPrc:pid_info(Pid, pi_info())].

poi({T,Port}) -> 
  {Name,Stats} = prfNet:port_info(Port),
  [{T,Port},{name,Name}|Stats].

flush() ->    
  receive {monitor,_,_,_} -> flush()
  after 0 -> ok
  end.

get_measurement([T|Tags],Data) -> get_measurement(Tags,lks(T,Data));
get_measurement([],Data) -> Data.

lks(Tag,List) -> 
  try {value,{Tag,Val}} = lists:keysearch(Tag,1,List), Val
  catch _:_ -> throw({no_such_key,Tag})
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
mk_send(Where) ->
  fun(Chunk) ->
      try Where ! Chunk
      catch _:_ -> ok
      end
  end.

mk_send(tcp,Name,Port,Cookie) ->
  ConnOpts = [{send_timeout,100},{active,false},{packet,4},binary],
  ConnTimeout =  100,
  fun(Chunk)->
      try {ok,Sck} = gen_tcp:connect(Name,Port,ConnOpts,ConnTimeout),
	  try gen_tcp:send(Sck,prf_crypto:encrypt(Cookie,Chunk))
	  after gen_tcp:close(Sck)
	  end
      catch _:_ -> ok
      end
  end;
mk_send(udp,Name,Port,Cookie) ->
  mk_send(0,Name,Port,Cookie);
mk_send(UdpPort,Name,Port,Cookie) when is_integer(UdpPort)->
  fun(Chunk) ->
      try BC = term_to_binary(Chunk,[{compressed,3}]),
          Payload = prf_crypto:encrypt(Cookie,BC),
          PaySize = byte_size(Payload),
          {ok,Sck} = gen_udp:open(UdpPort,[binary]),
          gen_udp:send(Sck,Name,Port,<<PaySize:32,Payload/binary>>),
          gen_udp:close(Sck)
      catch _:_ -> ok
      end
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
mk_log(FD) -> fun(E)-> print_term(FD,expand_recs(E)) end.

print_term(FD,Term) -> 
  case node(FD) == node() of
    true -> ?log(Term);
    false-> io:fwrite(FD," ~p~n",[Term])
  end.

send_to_wd(Term) ->
  try
    ?MODULE ! Term,
    ok
  catch 
    error:badarg   -> {error,watchdog_not_started};
    _:R            -> {error,R}
  end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
expand_recs(List) when is_list(List) -> [expand_recs(L)||L<-List];
expand_recs(Tup) when is_tuple(Tup) -> 
  case tuple_size(Tup) of
    L when L < 1 -> Tup;
    L ->
      Fields = ri(element(1,Tup)),
      case L == length(Fields)+1 of
	false-> list_to_tuple(expand_recs(tuple_to_list(Tup)));
	true -> expand_recs(lists:zip(Fields,tl(tuple_to_list(Tup))))
      end
  end;
expand_recs(Term) -> Term.

ri(ld) -> record_info(fields,ld);
ri(_) -> [].
