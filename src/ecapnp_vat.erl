%%
%%  Copyright 2014, Andreas Stenius <kaos@astekk.se>
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%

%% @copyright 2014, Andreas Stenius
%% @author Andreas Stenius <kaos@astekk.se>
%% @doc VAT server module.
%%
%% One VAT server per connection.

-module(ecapnp_vat).
-author("Andreas Stenius <kaos@astekk.se>").
-behaviour(gen_server).

%% API

-export([start/0, start_link/0, start_link/1, start_link/2, stop/1,
         send/2, wait/2, import_capability/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ecapnp.hrl").

-type request_list() :: list({non_neg_integer(), reference(), {list(), ecapnp:schema_node()} | ecapnp:object()}).
-type cap_list() :: list({non_neg_integer(), non_neg_integer(), #capability{}}).

-record(questions, {
          next_id = 0 :: non_neg_integer(),
          promises = [] :: request_list()
         }).

-record(answers, {
          results = [] :: request_list()
         }).

-record(exports, {
          next_id = 0 :: non_neg_integer(),
          caps = [] :: cap_list()
         }).

-record(imports, {
          caps = [] :: cap_list()
         }).

-record(state, {
          owner,
          transport,
          restorer,
          questions = #questions{} :: #questions{},
          answers = #answers{} :: #answers{},
          imports = #imports{} :: #imports{},
          exports = #exports{} :: #exports{},
          cont_data = <<>>
         }).


%% ===================================================================
%% API functions
%% ===================================================================

start() ->
    gen_server:start(?MODULE, setup_state(), []).

start_link() ->
    gen_server:start_link(?MODULE, setup_state(), []).

start_link(Transport) ->
    gen_server:start_link(?MODULE, setup_state(Transport), []).

start_link(Transport, Restorer) ->
    gen_server:start_link(?MODULE, setup_state(Transport, Restorer), []).

stop(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, stop).

send(Req, #capability{ id = {_, {_Id, Vat}} }) ->
    gen_server:call(Vat, {send_req, Req});
send(Req, #promise{ id = {_, {_Id, Vat}} }) ->
    gen_server:call(Vat, {send_req, Req}).

wait({Kind, {Id, Vat}}, Timeout) ->
    gen_server:call(Vat, {wait, {Kind, Id}}, Timeout).

import_capability(ObjectId, Schema, Vat) ->
    gen_server:call(Vat, {import, ObjectId, Schema}).


%% ===================================================================
%% gen server callbacks
%% ===================================================================

init(State) ->
    {ok, State}.

handle_call({send_req, Req}, _From, State) ->
    send_req(Req, State);
handle_call({send_message, Message}, _From, State) ->
    {reply, ok, send_message(Message, process_message(Message, State))};
handle_call({answer, Id, Content}, _From, State) ->
    {reply, ok, set_promise_result(Id, Content, State)};
handle_call({wait, Id}, From, State) ->
    wait(Id, From, State);
handle_call({import, ObjectId, Schema}, {Pid, _Ref}=_From, State) ->
    import_req(Pid, ObjectId, Schema, State);
handle_call({restore, ObjectId}, From, State) ->
    %% todo: better error handling...
    Vat = self(),
    spawn_link(
      fun () ->
              gen_server:reply(From, (State#state.restorer)(ObjectId, Vat))
      end),
    {noreply, State};
handle_call({finish, Id, ReleaseResultCaps}, _From, State) ->
    {reply, ok, purge_answer(Id, ReleaseResultCaps, State)};
handle_call({release, Id, Count}, _From, State) ->
    {reply, ok, release_export(Id, Count, State)};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({stop, Reason}, State) ->
    {stop, Reason, State};
handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({receive_message, Data}, State) ->
    handle_message(Data, State);
handle_info({'DOWN', MonRef, process, _Pid, _Info}, State) ->
    purge_ref(MonRef, State);
handle_info(_Info, State) ->
    io:format(
      standard_error, "~p:ecapnp_vat(~p): unhandled info: ~n   ~p~n",
      [self(), State#state.transport, _Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ===================================================================
%% internal server functions
%% ===================================================================

%% ===================================================================
send_req(#rpc_call{ target = Target }=Req, State) ->
    Ref = Target#object.ref#ref.kind,
    Cap = Ref#interface_ref.cap,
    case Cap of
        #promise{ id = {answer, _} } -> send_local_req(Req, State);
        #promise{ id = {remote, _} } -> send_remote_req(Req, Cap, State);
        #capability{ id = {remote, _} } -> send_remote_req(Req, Cap, State);
        #capability{ id = {exported, {Id, _Vat}} } ->
            case find(Id, State#state.exports) of
                false ->
                    {reply, {error, unknown_capability}, State};
                {local, Exported} ->
                    Kind = #interface_ref{ cap=Exported },
                    Target1 = Target#object{ ref = #ref{ kind=Kind } },
                    {reply, ecapnp:send(Req#rpc_call{ target = Target1 }),
                     State}
            end
    end.

send_remote_req(#rpc_call{ owner = Pid, interface = I, method = M,
                           params = P, resultSchema = Schema },
                Cap, State) ->
    %% hackish approach. getting at the root element has not been implemented yet..
    Msg = ecapnp_obj:from_ref(
            ecapnp_ref:get(0, 0, P#object.ref#ref.data),
            'Message', rpc_capnp),
    {call, Call} = ecapnp:get(Msg),

    {Id, Promise, State1} = new_question(Pid, Schema, State),
    ok = ecapnp:set(questionId, Id, Call),
    ok = set_target(Cap, ecapnp:init(target, Call)),
    ok = ecapnp:set(interfaceId, I, Call),
    ok = ecapnp:set(methodId, M, Call),

    {reply, {ok, Promise}, send_message(Msg, process_message(Msg, State1))}.

send_local_req(#rpc_call{ target = TargetPromise,
                          resultSchema = ResultSchema }=Req, State) ->
    ResultPromise = ecapnp_rpc:promise(
                      fun () ->
                              case ecapnp:wait(TargetPromise) of
                                  {ok, ObjCap} ->
                                      {ok, SendPromise} = ecapnp:send(
                                                            Req#rpc_call{ target = ObjCap }),
                                      ecapnp:wait(SendPromise);
                                  Other ->
                                      {promise_error, TargetPromise, Other}
                              end
                      end,
                      ResultSchema),
    {reply, {ok, ResultPromise}, State}.

%% ===================================================================
wait({remote, Id}, From, State) ->
    case find(Id, State#state.questions) of
        {promise, Id} ->
            {noreply, wait_for_promise(Id, From, State)};
        Result ->
            ok = add_result_ref(From, Result),
            {reply, Result, State}
    end;
wait({answer, Id}, From, State) ->
    case find(Id, State#state.answers) of
        {pending, Id} ->
            {noreply, wait_for_answer(Id, From, State)};
        false ->
            {noreply, wait_for_answer(Id, From, State)};
        Result ->
            ok = add_result_ref(From, Result),
            {reply, Result, State}
    end.

add_result_ref({From, _Ref}, {ok, Obj}) ->
    ecapnp_obj:add_ref(From, Obj);
add_result_ref(_, _) -> ok.

%% ===================================================================
import_req(Pid, ObjectId, Schema, State) ->
    {Id, Promise, State1} = new_question(Pid, Schema, State),
    Restore = new_message(restore),
    ok = ecapnp:set(questionId, Id, Restore),
    ok = ecapnp:set(objectId, ObjectId, Restore),
    {reply, {ok, Promise}, send_message(Restore, State1)}.

%% ===================================================================
handle_message(<<>>, State) -> {noreply, State};
handle_message(Data, #state{ cont_data = Cont }=State) ->
    case ecapnp_message:read(Data, Cont) of
        {cont, Cont1} -> {noreply, State#state{ cont_data = Cont1 }};
        {ok, Message, Rest} ->
            Vat = self(),
            spawn_link(
              fun () ->
                      {ok, Root} = ecapnp_get:root(rpc_capnp:'Message'(), Message),
                      ok = handle_message_process(Root, Vat)
              end),
            handle_message(Rest, State#state{ cont_data = <<>> })
    end.

%% ===================================================================
purge_ref(Ref, #state{ questions = #questions{ promises = Ps }=Qs }=State) ->
    case lists:keyfind(Ref, 2, Ps) of
        false ->
            {noreply, State};
        {Id, Ref, Res} ->
            Ps1 =
                case Res of
                    {Ws, _} when is_list(Ws) ->
                        lists:keystore(Id, 1, Ps, {Id, 'DOWN', Res});
                    _ ->
                        lists:keydelete(Id, 1, Ps)
                end,
            State1 = State#state{
                       questions = Qs#questions{
                                     promises = Ps1
                                    }},
            %% releaseResultCaps is true by default, which is fine
            %% until we've implemented sending release messages
            Finish = new_message(finish),
            ok = ecapnp:set(questionId, Id, Finish),
            {noreply, send_message(Finish, State1)}
    end.

%% ===================================================================
purge_answer(Id, false, State) ->
    set_answer_result(Id, finish, State);
purge_answer(Id, true, State) ->
    case find(Id, State#state.answers) of
        false -> State;
        {ok, Res} ->
            {ok, Caps} = ecapnp_obj:get_cap_table(Res),
            State1 = release_caps(Caps, State),
            purge_answer(Id, false, State1);
        {pending, Id} ->
            purge_answer(Id, false, State)
    end.


%% ===================================================================
%% server utils
%% ===================================================================

%% ===================================================================
setup_state() ->
    #state{ owner = self() }.

setup_state(Transport) ->
    (setup_state())#state{ transport = Transport }.

setup_state(Transport, Restorer) ->
    (setup_state(Transport))#state{ restorer = Restorer }.

%% ===================================================================
send_message(Msg, #state{ transport = {Mod, Handle} }=State) ->
    case Mod:send(Handle, ecapnp_message:write(Msg)) of
        ok -> State;
        Err ->
            gen_server:cast(self(), {stop, Err}),
            State
    end;

%% called from message handler processes
send_message(Msg, Vat) when is_pid(Vat) ->
    gen_server:call(Vat, {send_message, Msg}, infinity).

%% ===================================================================
new_question(Pid, Schema,
             #state{ questions = #questions{
                                    next_id = Id,
                                    promises = Ps
                                   }=Qs }=State) ->
    {Id, new_promise(Id, Schema),
      State#state{
        questions = Qs#questions{
                      next_id = Id + 1,
                      promises = [{Id, monitor(process, Pid), {[], Schema}}
                                  |Ps]
                     }}
    }.

%% ===================================================================
process_message(Message, State) ->
    case ecapnp:get(Message) of
        {call, Call} ->
            update_cap_table(ecapnp:get(params, Call), State);
        {return, Return} ->
            Id = ecapnp:get(answerId, Return),
            {Result, State1} =
                case ecapnp:get(Return) of
                    {results, Payload} ->
                        {ecapnp:get(content, Payload),
                         update_cap_table(Payload, State)}
                end,
            set_answer_result(Id, Result, State1);
        _ ->
            State
    end.

%% ===================================================================
update_cap_table(Payload, State) ->
    {ok, Caps} = ecapnp_obj:get_cap_table(Payload),
    CapTable = ecapnp:set(capTable, length(Caps), Payload),
    lists:foldl(
      fun set_cap_descriptor/2,
      State, lists:zip(Caps, CapTable)).

%% ===================================================================
set_cap_descriptor({Cap, CapDesc}, State) ->
    case Cap of
        #capability{ id = {local, _} } ->
            {Id, State1} = export(Cap, State),
            ecapnp:set({senderHosted, Id}, CapDesc),
            State1;
        #capability{ id = {remote, {Id, Pid}} }
          when Pid =:= self() ->
            ecapnp:set({receiverHosted, Id}, CapDesc),
            State;
        #promise{ id = {remote, {Id, Pid}}, transform = Ts }
          when Pid =:= self() ->
            PromisedAnswer = ecapnp:init(receiverAnswer, CapDesc),
            set_promised_answer(Id, Ts, PromisedAnswer),
            State
    end.

%% ===================================================================
export(Cap, State) ->
    case lists:keyfind(Cap, 3, State#state.exports#exports.caps) of
        {Id, RefCount, Cap} ->
            {Id, update_export(Id, Cap, RefCount + 1, State)};
        false ->
            {Id, State1} = get_next_export_id(State),
            {Id, update_export(Id, Cap, 1, State1)}
    end.

%% ===================================================================
release_export(Id, Count, State) ->
    case lists:keyfind(Id, 1, State#state.exports#exports.caps) of
        {Id, RefCount, Cap} ->
            if Count =:= all ->
                    update_export(Id, Cap, 0, State);
               true ->
                    update_export(Id, Cap, RefCount - Count, State)
            end;
        false ->
            State
    end.

%% ===================================================================
update_export(Id, Cap, RefCount, #state{ exports = #exports{ caps = Cs }=Es }=State) ->
    Caps =
        if RefCount > 0 ->
                lists:keystore(Id, 1, Cs, {Id, RefCount, Cap});
           true ->
                %% TODO: notify Cap about being released
                lists:keydelete(Id, 1, Cs)
        end,
    State#state{ exports = Es#exports{ caps = Caps } }.

%% ===================================================================
get_next_export_id(#state{ exports = #exports{
                                        next_id = Id
                                       }=Es }=State) ->
    {Id, State#state{ exports = Es#exports{
                                  next_id = Id + 1
                                 }}}.

%% ===================================================================
release_caps(Caps, State0) ->
    Vat = self(),
    lists:foldl(
      fun (Cap, State) ->
              case Cap of
                  #capability{ id = {local, {Id, Vat}} } ->
                      release_export(Id, all, State);
                  _ ->
                      %% TODO: how do we release the other capabilities..
                      State
              end
      end, State0, Caps).

%% ===================================================================
set_promise_result(Id, Result, #state{ questions = #questions{ promises = Ps }=Qs }=State) ->
    State#state{ questions = Qs#questions{ promises = set_result(Id, Result, Ps) }}.

set_answer_result(Id, Result, #state{ answers = #answers{ results = Rs }=As }=State) ->
    State#state{ answers = As#answers{ results = set_result(Id, Result, Rs) }}.

wait_for_promise(Id, W, #state{ questions = #questions{ promises = Ps }=Qs }=State) ->
    State#state{ questions = Qs#questions{ promises = wait_for_result(Id, W, Ps) }}.

wait_for_answer(Id, W, #state{ answers = #answers{ results = Rs }=As }=State) ->
    State#state{ answers = As#answers{ results = wait_for_result(Id, W, Rs) }}.

%% ===================================================================

%% ===================================================================
%% process messages, these are run in their own processes
%% ===================================================================

%% ===================================================================
-spec handle_message_process(Message::ecapnp:object(), Vat::pid()) -> ok.
handle_message_process(Message, Vat) ->
    case ecapnp:get(Message) of
        {call, Call} -> handle_call(Call, Vat);
        {return, Return} -> handle_return(Return, Vat);
        {restore, Restore} -> handle_restore(Restore, Vat);
        {finish, Finish} -> handle_finish(Finish, Vat);
        {release, Release} -> handle_release(Release, Vat);
        _ ->
            {ok, Reply} = ecapnp:set_root('Message', rpc_capnp),
            ecapnp:set({unimplemented, Message}, Reply),
            send_message(Reply, Vat)
    end.

%% ===================================================================
handle_call(Call, Vat) ->
    Target = get_message_target(ecapnp:get(target, Call), Vat),
    Payload = ecapnp:get(params, Call),

    Message = new_message(),
    Return = ecapnp:init(return, Message),
    RetPayload = ecapnp:init(results, Return),

    {ok, Promise} = ecapnp:send(
                      #rpc_call{
                         owner = self(),
                         target = Target,
                         interface = ecapnp:get(interfaceId, Call),
                         method = ecapnp:get(methodId, Call),
                         params = get_payload_content(Payload, Vat),
                         results = RetPayload
                        }),

    %% TODO: _Content may be in another object if Target doesn't point
    %% at a local capability..
    {ok, _Content} = ecapnp:wait(Promise),

    Id = ecapnp:get(questionId, Call),
    ok = ecapnp:set(answerId, Id, Return),

    send_message(Message, Vat).

%% ===================================================================
handle_return(Return, Vat) ->
    case ecapnp:get(Return) of
        {results, Results} ->
            Id = ecapnp:get(answerId, Return),
            Content = get_payload_content(Results, Vat),
            gen_server:call(Vat, {answer, Id, Content})
    end.


%% ===================================================================
handle_restore(Restore, Vat) ->
    {ok, Cap} = gen_server:call(
                  Vat, {restore, ecapnp:get(objectId, Restore)},
                  infinity),

    Message = new_message(),
    Return = ecapnp:init(return, Message),
    ok = ecapnp:set(answerId, ecapnp:get(questionId, Restore), Return),
    Payload = ecapnp:init(results, Return),
    _Content = ecapnp:set(content, Cap, Payload),
    send_message(Message, Vat).

%% ===================================================================
handle_finish(Finish, Vat) ->
    Id = ecapnp:get(questionId, Finish),
    Release = ecapnp:get(releaseResultCaps, Finish),
    gen_server:call(Vat, {finish, Id, Release}).

%% ===================================================================
handle_release(Release, Vat) ->
    Id = ecapnp:get(id, Release),
    Count = ecapnp:get(referenceCount, Release),
    gen_server:call(Vat, {release, Id, Count}).

%% ===================================================================

%% ===================================================================
%% common utils
%% ===================================================================

%% ===================================================================
new_promise(Id, Schema) ->
    Cap = #promise{ id = {remote, {Id, self()}} },
    Kind = #interface_ref{ cap = Cap },
    #object{ ref = #ref{ kind = Kind }, schema = Schema }.

%% ===================================================================
new_message() ->
    {ok, Msg} = ecapnp:set_root('Message', rpc_capnp), Msg.

new_message(Type) ->
    ecapnp:init(Type, new_message()).

%% ===================================================================
set_target(#capability{ id = {remote, {Id, _}} }, MsgTarget) ->
    ecapnp:set({importedCap, Id}, MsgTarget);
set_target(#promise{ id = {remote, {Id, _}}, transform = Ts }, MsgTarget) ->
    PromisedAnswer = ecapnp:init(promisedAnswer, MsgTarget),
    set_promised_answer(Id, Ts, PromisedAnswer).

%% ===================================================================
set_promised_answer(Id, Ts, PromisedAnswer) ->
    ok = ecapnp:set(questionId, Id, PromisedAnswer),
    TObjs = ecapnp:set(transform, length(Ts), PromisedAnswer),
    [ecapnp:set(T, Obj)
     || {Obj, T} <- lists:zip(TObjs, lists:reverse(Ts))],
    ok.

%% ===================================================================
set_result(Id, Result, List) ->
    case lists:keyfind(Id, 1, List) of
        false ->
            if Result =:= finish -> List;
               true ->
                    ok = ecapnp_obj:add_ref(self(), Result),
                    Entry = {Id, undefined, Result},
                    lists:keystore(Id, 1, List, Entry)
            end;
        {Id, Mon, {Ws, Schema}} when is_list(Ws) ->
            Res = if Result =:= finish -> cancel;
                     true -> ecapnp_obj:to_struct(Schema, Result)
                  end,
            [case W of
                 {From, _Ref} ->
                     ok = ecapnp_obj:add_ref(From, Res),
                     gen_server:reply(W, {ok, Res})
             end || W <- Ws],
            if Mon =:= 'DOWN', Result =:= finish ->
                    lists:keydelete(Id, 1, List);
               true ->
                    ok = ecapnp_obj:add_ref(self(), Res),
                    Entry = {Id, Mon, Res},
                    lists:keystore(Id, 1, List, Entry)
            end;
        {Id, undefined, Res} when Result =:= finish ->
            ok = ecapnp_obj:discard_ref(self(), Res),
            lists:keydelete(Id, 1, List)
    end.

wait_for_result(Id, W, List) ->
    Entry =
        case lists:keyfind(Id, 1, List) of
            false ->
                {Id, undefined, {[W], undefined}};
            {Id, Mon, {Ws0, Schema}} when is_list(Ws0) ->
                {Id, Mon, {[W|Ws0], Schema}}
        end,
    lists:keystore(Id, 1, List, Entry).

%% ===================================================================
get_message_target(MessageTarget, Vat) ->
    Cap =
        case ecapnp:get(MessageTarget) of
            {importedCap, Id} ->
                #capability{ id = {exported, {Id, Vat}} };
            {promisedAnswer, PromisedAnswer} ->
                translate_promised_answer(PromisedAnswer, Vat)
        end,
    Kind = #interface_ref{ cap = Cap },
    #object{ ref = #ref{ kind = Kind } }.

%% ===================================================================
translate_cap_descriptor(CapDescriptor, Vat) ->
    case ecapnp:get(CapDescriptor) of
        none -> undefined;
        {senderHosted, Id} ->
            #capability{ id = {remote, {Id, Vat}} };
        {senderPromise, Id} ->
            #promise{ id = {resolve, {Id, Vat}} };
        {receiverHosted, Id} ->
            #capability{ id = {exported, {Id, Vat}} };
        {receiverAnswer, PromisedAnswer} ->
            translate_promised_answer(PromisedAnswer, Vat)
            %%{thirdPartyHosted, _} -> level 3 stuff, NYI
    end.

%% ===================================================================
translate_promised_answer(PromisedAnswer, Vat) ->
            Id = ecapnp:get(questionId, PromisedAnswer),
            Ts = ecapnp:get(transform, PromisedAnswer),
            #promise{ id = {answer, {Id, Vat}},
                      transform = [ecapnp:get(T) || T <- Ts] }.

%% ===================================================================
find(Id, #imports{ caps = Cs }) ->
    case lists:keyfind(Id, 1, Cs) of
        false -> false;
        {Id, _RefCount, Cap} -> {remote, Cap}
    end;
find(Id, #exports{ caps = Cs }) ->
    case lists:keyfind(Id, 1, Cs) of
        false -> false;
        {Id, _RefCount, Cap} -> {local, Cap}
    end;
find(Id, #questions{ promises = Ps }) ->
    case lists:keyfind(Id, 1, Ps) of
        false ->
            false;
        {Id, _MonRef, {Ws, _}} when is_list(Ws) ->
            {promise, Id};
        {Id, _MonRef, Res} ->
            {ok, Res}
    end;
find(Id, #answers{ results = Rs }) ->
    case lists:keyfind(Id, 1, Rs) of
        false -> false;
        {Id, _MonRef, {Ws, _}} when is_list(Ws) ->
            {pending, Id};
        {Id, _MonRef, Res} ->
            {ok, Res}
    end.

%% ===================================================================
get_payload_content(Payload, Vat) ->
    ecapnp:get(
      content, ecapnp_obj:set_cap_table(
                 [translate_cap_descriptor(C, Vat)
                  || C <- ecapnp:get(capTable, Payload)],
                 Payload)
     ).

%% ===================================================================
