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
%% @doc Message framing.
%%
%% Takes care of reading a framed message, getting the segments data
%% out, and writing the message header with the segment table.

-module(ecapnp_message).
-author("Andreas Stenius <kaos@astekk.se>").

-export([read/1, read/2, write/1, read_file/1]).

-include("ecapnp.hrl").

-type continuation() :: term().
-type read_result() :: {ok, message(), Rest::binary()} | {cont, continuation()}.

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Parse segment table in the (unpacked, but otherwise framed)
%% message.
-spec read(binary()) -> read_result().
read(Data) when is_binary(Data) ->
    read_message(Data).

-spec read(binary(), continuation() | undefined) -> read_result().
read(Data, <<>>) when is_binary(Data) -> read_message(Data);
read(Data, {SegSizes, Rest, Segments}) when is_binary(Data) ->
    read_message(SegSizes, <<Rest/binary, Data/binary>>, Segments);
read(Data, {SegCount, Rest}) when is_binary(Data) ->
    read_message(SegCount, <<Rest/binary, Data/binary>>);
read(Data, Rest) when is_binary(Data), is_binary(Rest) ->
    read_message(<<Rest/binary, Data/binary>>).


%% @doc Write segment table for message and return it along with the
%% segments data.
%%
%% Any non-default object may be passed to this function.
-spec write(object()) -> binary().
write(#object{ ref=#ref{ data=#builder{ pid=Data } } }) ->
    write_message(ecapnp_data:get_segments(Data));
write(#object{ ref=#ref{ data=#reader{ data = Data } } }) ->
    Segments = if is_binary(Data) -> [Data];
                  true -> Data
               end,
    write_message(Segments).

%% @doc Read binary message from file.
%% @see read/1
-spec read_file(string()) -> read_result().
read_file(Filename) ->
    {ok, Data} = file:read_file(Filename),
    read_message(Data).


%% ===================================================================
%% internal functions
%% ===================================================================

read_message(<<SegCount:32/integer-little, Data/binary>>) ->
    read_message({SegCount + 1, SegCount rem 2}, Data);
read_message(Data) -> {cont, Data}.

read_message({SegCount, Pad}, Data)
  when is_integer(SegCount), SegCount > 0,
       size(Data) >= (4 * (SegCount + Pad)) ->
    <<SegSizes:SegCount/binary-unit:32,
      _Padding:Pad/binary-unit:32,
      Rest/binary>> = Data,
    read_message(SegSizes, Rest, []);
read_message(SegCount, Data) ->
    {cont, {SegCount, Data}}.

read_message(<<SegSize:32/integer-little, SegSizes/binary>>, Data, Segments)
  when size(Data) >= (SegSize * 8) ->
    <<Segment:SegSize/binary-unit:64, Rest/binary>> = Data,
    read_message(SegSizes, Rest, [Segment|Segments]);
read_message(<<>>, Rest, Segments) ->
    {ok, lists:reverse(Segments), Rest};
read_message(SegSizes, Rest, Segments) ->
    {cont, {SegSizes, Rest, Segments}}.

write_message(Segments) ->
    SegCount = length(Segments) - 1,
    Pad = SegCount rem 2,
    Padding = <<0:Pad/integer-unit:32>>,
    SegSizes = << <<(size(S) div 8):32/integer-little>> || S <- Segments >>,
    iolist_to_binary([<<SegCount:32/integer-little>>, SegSizes, Padding | Segments]).
