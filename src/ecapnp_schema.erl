%%  
%%  Copyright 2013, Andreas Stenius <kaos@astekk.se>
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

%% @copyright 2013, Andreas Stenius
%% @author Andreas Stenius <kaos@astekk.se>
%% @doc Schema functions.
%%
%% This module exports functions for interacting with a compiled
%% schema.

-module(ecapnp_schema).
-author("Andreas Stenius <kaos@astekk.se>").

-export([type_of/1, get/2, lookup/2, lookup/3, size_of/1, size_of/2,
         data_size/1, ptrs_size/1, get_ref_kind/1, get_ref_kind/2,
         set_ref_to/2, find_method_by_name/2, find_field/2, dump/1]).

-include("ecapnp.hrl").

-type lookup_type() :: type_id() | type_name() | object | schema_node().
%% The various types that can be looked up.
-type lookup_search() :: object() | ref() | pid() 
                       | schema_nodes() | schema_node().
%% Where to search for the type being looked up.

%% ===================================================================
%% API functions
%% ===================================================================

get(Type, Schema) ->
    case lookup(Type, Schema) of
        undefined -> throw({schema_not_found, Type, Schema});
        Node -> Node
    end.

lookup(Type, Schema, Default) ->
    case lookup(Type, Schema) of
        undefined -> Default;
        Node -> Node
    end.

-spec lookup(lookup_type(), lookup_search()) -> schema_node() | undefined.
%% @doc Find schema node for type.
lookup(N, _) when is_record(N, schema_node) -> N;
lookup(Type, Schema) when is_atom(Schema) ->
    if Type =:= object -> Schema;
       true -> Schema:schema(Type)
    end;
lookup(Id, #schema_node{ id=Id }=N) -> N;
lookup(Name, #schema_node{ name=Name }=N) -> N;
lookup(Type, #schema_node{ module=Module }) -> lookup(Type, Module);
lookup(Type, #object{ schema = Schema }) -> lookup(Type, Schema);
lookup(Type, [N|Ns]) ->
    case {lookup(Type, N), Ns} of
        {undefined, []} -> undefined;
        {undefined, _} -> lookup(Type, Ns);
        Node -> Node
    end;
lookup(_Type, _Schema) ->
    %%io:format("type not found: ~p (in schema ~p)~n", [Type, Schema]),
    undefined.

-spec type_of(object()) -> schema_node().
%% @doc Get type of object.
%% @todo Doesn't this belong in ecapnp_obj?
type_of(#object{ schema=Type }) -> Type.

-spec size_of(lookup_type(), lookup_search()) -> non_neg_integer().
%% @doc Lookup struct type and query it's size.
size_of(Type, Store) ->    
    size_of(lookup(Type, Store)).

-spec size_of(Node::schema_node()) -> non_neg_integer().
%% @doc Query size of a struct type.
%%
%% Will crash with `function_clause' if `Node' is not a struct or
%% interface node.
size_of(#schema_node{ kind=Kind }) -> size_of(Kind);
size_of(#struct{ dsize=DSize, psize=PSize }) -> DSize + PSize;
%% Size in message data, which simply is a Capability pointer, the
%% CapDescriptor is stored out-of-band.
size_of(#interface{}) -> 1.

-spec data_size(schema_node()) -> non_neg_integer().
%% @doc Get data size of a struct type.
data_size(#struct{ dsize=DSize }) -> DSize.

-spec ptrs_size(schema_node()) -> non_neg_integer().
%% @doc Get pointer count for a struct type.
ptrs_size(#struct{ psize=PSize }) -> PSize.

get_ref_kind(#struct{ dsize=DSize, psize=PSize }) ->
    #struct_ref{ dsize=DSize, psize=PSize };
get_ref_kind(#schema_node{ kind=Kind }) ->
    get_ref_kind(Kind);
get_ref_kind(#interface{}) ->
    #interface_ref{}.

get_ref_kind(Type, Ref) when is_atom(Type); is_number(Type) ->
    get_ref_kind(lookup(Type, Ref));
get_ref_kind(Type, _) ->
    get_ref_kind(Type).

    
-spec set_ref_to(lookup_type(), ref()) -> ref().
%% @doc Set reference kind.
%%
%% Lookup struct `Type' and return an updated {@link ref(). ref}.
%%
%% Note: it is only the record that is updated, the change is not
%% committed to the message.
set_ref_to(Type, Ref) ->
    Ref#ref{ kind=get_ref_kind(Type, Ref) }.

%% @doc Find Interface and Method.
find_method_by_name(MethodName, #schema_node{
                                   kind = #interface{ methods = Ms }
                                  }=S) ->
    case lists:keyfind(MethodName, #method.name, Ms) of
        false -> undefined;
        Method -> {ok, S, Method}
    end;
find_method_by_name(MethodName, [S|Ss]) ->
    case find_method_by_name(MethodName, S) of
        undefined ->
            find_method_by_name(MethodName, Ss);
        Result ->
            Result
    end;
find_method_by_name(_MethodName, []) -> undefined.

%% @doc Find struct field from schema definition by name or index.
find_field(Field, #schema_node{ kind = #struct{ fields = Fields } }) ->
    Idx = if is_atom(Field) -> #field.name;
             is_number(Field) -> #field.id
          end,
    lists:keyfind(Field, Idx, Fields).

dump(#schema_node{ src = Source, id = Id }) ->
    io_lib:format("~s(~p)", [Source, Id]).


%% ===================================================================
%% internal functions
%% ===================================================================
