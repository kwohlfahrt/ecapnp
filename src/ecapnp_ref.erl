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

-module(ecapnp_ref).
-author("Andreas Stenius <kaos@astekk.se>").

-export([get/3, get/4, set/2, copy/1, ptr/2,
         alloc/3, alloc/4, alloc_list/3,
         follow_far/1,
         read_struct_data/3, read_struct_ptr/2,
         read_struct_data/4, read_struct_ptr/3,
         read_list/1, read_text/1, read_data/1,
         read_list/2, read_text/2, read_data/2,
         write_struct_data/4, write_struct_ptr/2,
         write_list/4, write_text/3, write_data/3]).

-include("ecapnp.hrl").


%% ===================================================================
%% API functions
%% ===================================================================

alloc(SegmentId, Size, Data) ->
    {Id, Pos} = ecapnp_data:alloc(SegmentId, Size, Data),
    #ref{ segment=Id, pos=Pos, data=Data }.

alloc(Kind, SegmentId, Size, Data) ->
    set(Kind, alloc(SegmentId, Size, Data)).

set(Kind, Ref0) ->
    Ref = Ref0#ref{ kind=Kind },
    ok = write(Ref), Ref.

get(SegmentId, Pos, Data) when is_pid(Data) ->
    get(SegmentId, Pos, Data, true).

get(SegmentId, Pos, Data, FollowFar) when is_pid(Data) ->
    read_segment(SegmentId, Pos,
                 ecapnp_data:get_segment(SegmentId, Pos, 1, Data),
                 Data, FollowFar).

ptr(Idx, #ref{ segment=SegmentId, pos=Pos, data=Data,
               kind=#struct_ref{ dsize=DSize, psize=PSize } })
  when Idx >= 0, Idx < PSize ->
    #ref{ segment=SegmentId, pos=Pos + 1 + DSize + Idx, data=Data }.

read_struct_data(Align, Len, Ref) ->
    read_struct_data(Align, Len, Ref, <<0:Len/integer>>).
read_struct_data(_, _, #ref{ kind=null }, Default) -> Default;
read_struct_data(Align, Len,
                 #ref{ kind=#struct_ref{ dsize=DSize }}=Ref,
                 Default) ->
    if Align + Len =< DSize * 64 ->
            <<_:Align/bits, Value:Len/bits, _/bits>>
                = get_segment(1 + ((Align + Len - 1) div 64), Ref),
            Value;
       true -> Default
    end.

read_struct_ptr(Idx, Ref) -> read_struct_ptr(Idx, Ref, null_ref(Ref)).
read_struct_ptr(_, #ref{ kind=null }, Default) -> Default;
read_struct_ptr(Idx, #ref{ segment=SegmentId, pos=Pos,
                           offset=Offset, data=Data,
                           kind=#struct_ref{
                                   dsize=DSize, psize=PSize } },
                Default) ->
    if Idx >= 0 andalso Idx < PSize ->
            get(SegmentId, Pos + 1 + Offset + DSize + Idx, Data);
       true -> Default
    end.

read_list(Ref) -> read_list(Ref, []).
read_list(#ref{ kind=#list_ref{ count=0 } }, _) -> [];
read_list(#ref{ segment=SegmentId, pos=Pos, offset=Offset, data=Data,
                kind=#list_ref{ size=Size, count=Count } }, _) ->
    TagOffset = Pos + 1 + Offset,
    if Size == inlineComposite ->
            #ref{ offset=Len }=Tag = get(SegmentId, TagOffset, Data),
            [Tag#ref{ pos=-1, offset=O }
             || O <- lists:seq(TagOffset + 1,
                               TagOffset + Count,
                               Count div Len)];
       Size == pointer ->
            List = ecapnp_data:get_segment(
                     SegmentId, TagOffset, Count, Data),
            [read_segment(SegmentId, TagOffset + I,
                          binary_part(List, I, 8),
                          Data, true)
             || I <- lists:seq(0, (Count - 1) * 8, 8)];
       Size == empty ->
            lists:duplicate(Count, <<>>);
       true ->
            ElementSize = list_element_size(Size),
            List = ecapnp_data:get_segment(
                     SegmentId, TagOffset,
                     1 + ((ElementSize * Count - 1) div 64),
                     Data),
            read_list_elements(ElementSize, List, Count, [])
    end;
read_list(#ref{ kind=null }, Default) -> Default.

read_text(Ref) -> read_text(Ref, <<>>).
read_text(#ref{ kind=#list_ref{ size=byte, count=0 } }, _) -> <<>>;
read_text(#ref{ kind=#list_ref{ size=byte, count=Count } }=Ref, _) ->
    binary_part(get_segment(1 + ((Count - 2) div 8), Ref), 0, Count - 1);
read_text(#ref{ kind=null }, Default) -> Default.

read_data(Ref) -> read_data(Ref, <<>>).
read_data(#ref{ kind=#list_ref{ size=byte, count=0 } }, _) -> <<>>;
read_data(#ref{ kind=#list_ref{ size=byte, count=Count } }=Ref, _) ->
    binary_part(get_segment(1 + ((Count - 1) div 8), Ref), 0, Count);
read_data(#ref{ kind=null }, Default) -> Default.

write_struct_data(Align, Len, Value,
                  #ref{ kind=#struct_ref{ dsize=DSize } }=Ref)
  when Align + Len =< DSize * 64 ->
    <<Pre:Align/bits, _:Len/bits, Post/bits>>
        = get_segment(1 + ((Align + Len - 1) div 64), Ref),
    set_segment(<<Pre/bits, Value:Len/bits, Post/bits>>, Ref).

write_struct_ptr(Ptr, Ref) ->
    check_ptr(Ptr, Ref),
    write(Ptr).

write_text(Text, Ptr, Ref) ->
    write_data(<<Text/binary, 0>>, Ptr, Ref).

write_data(Data, Ptr, #ref{ segment=SegmentId, data=Pid }=Ref) ->
    check_ptr(Ptr, Ref),
    Count = size(Data),
    {Seg, Pos}=Segment = ecapnp_data:alloc(
                           SegmentId,
                           1 + ((Count - 1) div 8),
                           Pid),
    Seg = SegmentId, %% TODO: support far ptrs
    ok = ecapnp_data:update_segment(Segment, <<Data/binary, 0>>, Pid),
    write(
      update_offset(Pos,
                    Ptr#ref{ kind=#list_ref{
                                     size=byte,
                                     count=Count
                                    } })).

alloc_list(Idx, #list_ref{ size=Size, count=Count }=Kind,
           #ref{ segment=SegmentId, data=Data }=Ref) ->
    Ptr = ptr(Idx, Ref),
    Len = case list_element_size(Size) of
              %% TODO: support inlineComposite: undefined -> Count + 1;
              Bits -> Count * Bits
          end,
    {Seg, Pos} = ecapnp_data:alloc(SegmentId,
                                   1 + ((Len - 1) div 64),
                                   Data),
    Seg = SegmentId, %% TODO: support far ptrs
    write( update_offset(Pos, Ptr#ref{ kind=Kind }) ).

write_list(Idx, ElementIdx, Value, Ref) ->
    #ref{ kind=#list_ref{ size=Size, count=_Count }}=Ptr
        = read_struct_ptr(Idx, Ref, undefined),
    Len = list_element_size(Size),
    Align = round((if Size == bit ->
                           8 * ((ElementIdx div 8)
                                + ((7 - (ElementIdx rem 8)) / 8));
                      true -> ElementIdx end) * Len),
    <<Pre:Align/bits, _:Len/bits, Post/bits>>
        = get_segment(1 + ((Align + Len - 1) div 64), Ptr),
    set_segment(<<Pre/bits, Value:Len/bits, Post/bits>>, Ptr).
                           

follow_far(#ref{ offset=Offset, data=Data,
                 kind=#far_ref{ segment=SegmentId, double_far=Double } }) ->
    Pad = get(SegmentId, Offset, Data, false),
    if Double ->
            Tag = get(SegmentId, Offset + 1, Data, false),
            Tag#ref{ segment=(Pad#ref.kind)#far_ref.segment,
                     pos=-1, offset=Pad#ref.offset };
       true -> Pad
    end.

copy(Ref) ->
    iolist_to_binary(
      lists:reverse(
        copy(Ref, [])
       )).


%% ===================================================================
%% internal functions
%% ===================================================================

null_ref(#ref{ data=Data }) -> #ref{ data=Data }.

ptr_type(0, 0) -> null;
ptr_type(Offset, _) -> 
    ptr_type(Offset band 3).

ptr_type(0) -> struct;
ptr_type(1) -> list;
ptr_type(2) -> far_ptr;
ptr_type(3) -> reserved_ptr_type.

list_element_size(0) -> empty;
list_element_size(1) -> bit;
list_element_size(2) -> byte;
list_element_size(3) -> twoBytes;
list_element_size(4) -> fourBytes;
list_element_size(5) -> eightBytes;
list_element_size(6) -> pointer;
list_element_size(7) -> inlineComposite;
list_element_size(empty) -> 0;
list_element_size(bit) -> 1;
list_element_size(byte) -> 8;
list_element_size(twoBytes) -> 16;
list_element_size(fourBytes) -> 32;
list_element_size(eightBytes) -> 64;
list_element_size(inlineComposite) -> undefined.

get_segment(Len, #ref{ segment=SegmentId, pos=Pos,
                       offset=Offset, data=Data }) ->
    ecapnp_data:get_segment(SegmentId, Pos + 1 + Offset, Len, Data).

set_segment(Value, #ref{ segment=SegmentId, pos=Pos,
                         offset=Offset, data=Data }) ->
    ecapnp_data:update_segment({SegmentId, Pos + 1 + Offset}, Value, Data).

write(#ref{ segment=SegmentId, pos=Pos,
            offset=Offset, data=Data }=Ref) ->
    ecapnp_data:update_segment(
      {SegmentId, Pos},
      create_ptr(Offset, Ref),
      Data).

check_ptr(#ref{ segment=SegmentId, pos=Ptr, data=Data },
          #ref{ segment=SegmentId, pos=Pos, data=Data,
                offset=Offset,
                kind=#struct_ref{ dsize=DSize,
                                  psize=PSize } })
  when Ptr >= (Pos + 1 + Offset + DSize),
       Ptr <  (Pos + 1 + Offset + DSize + PSize) ->
    ok.


%% move_ptr(Idx, Ptr, #ref{ segment=SegmentId, pos=Pos,
%%                          offset=Offset, data=Data }) ->
%%     Ptr#ref{ segment=SegmentId, pos=Pos + 1 + Offset + Idx,
%%              offset=undefined, data=Data }.

update_offset(Target, #ref{ pos=Pos }=Ref) ->
    Ref#ref{ offset=Target - Pos - 1 }.



%% data_ref(Data) when is_list(Data) -> #ref{ kind=#list_ref{} };
%% data_ref(Data) when is_binary(Data) -> #ref{ kind=#list_ref{ size=byte, count=size(Data) } }.
%% ?? data_ref(Data) when is_record(Data, ref) -> #ref{ kind=#struct_ref{} }.

read_segment(SegmentId, Pos, Segment, Data, FollowFar)
  when size(Segment) == 8 ->
    Ref = read_ref(Segment),
    case {FollowFar, Ref#ref.kind} of
        {true, #far_ref{}} -> follow_far(Ref#ref{ data=Data });
        _ -> Ref#ref{ segment=SegmentId, pos=Pos, data=Data }
    end;
read_segment(SegmentId, _, _, Data, _) ->
    #ref{ segment=SegmentId, pos=-1, data=Data }.

read_ref(Segment) ->
    <<OffsetAndKind:32/integer-signed-little,
      Size:32/integer-little>> = Segment,
    case ptr_type(OffsetAndKind, Size) of
        null -> #ref{};
        struct ->
            #ref{ offset=OffsetAndKind bsr 2,
                  kind=#struct_ref{
                          dsize=Size band 16#ffff,
                          psize=Size bsr 16 }};
        list ->
            #ref{ offset=OffsetAndKind bsr 2,
                  kind=#list_ref{
                          size=list_element_size(Size band 7),
                          count=Size bsr 3 }};
        far_ptr ->
            #ref{ offset=OffsetAndKind bsr 3,
                  kind=#far_ref{
                          segment=Size,
                          double_far=OffsetAndKind band 4 > 0
                         }}
    end.

read_list_elements(_, _, 0, Acc) -> lists:reverse(Acc);
read_list_elements(1, <<Byte:1/bytes, Rest/binary>>, Count, Acc) ->
    read_list_element_bits(Byte, 7, Count, Rest, Acc);
read_list_elements(Size, List, Count, Acc) ->
    <<Elem:Size/bits, Rest/bits>> = List,
    read_list_elements(Size, Rest, Count - 1, [Elem|Acc]).

%% contrived routine to read bits off from a bit stream that is hard
%% coded big endian.. gnnggn!
read_list_element_bits(_, _, 0, _, Acc) -> lists:reverse(Acc);
read_list_element_bits(_, -1, Count, Rest, Acc) ->
    read_list_elements(1, Rest, Count, Acc);
read_list_element_bits(Bits, Left, Count, Rest, Acc) ->
    <<Next:Left/bits, Bit:1/bits>> = Bits,
    read_list_element_bits(Next, Left - 1, Count - 1, Rest, [Bit|Acc]).

copy(#ref{ kind=null }, Acc) -> [<<0:64/integer>>|Acc];
copy(#ref{ kind=#struct_ref{ dsize=DSize, psize=PSize } }=Ref, Acc) ->
    StructData = read_struct_data(0, DSize * 64, Ref),
    StructPtrs = [copy(read_struct_ptr(Idx, Ref), [])
                  || Idx <- lists:seq(0, PSize - 1)],
    [[create_ptr(Ref), StructData,
      update_offsets(StructPtrs, length(StructPtrs) - 1, [], [])]
     |Acc];
copy(#ref{ kind=#list_ref{ size=Size } }=Ref, Acc) ->
    Ptr = create_ptr(Ref),
    case Size of
        inlineComposite ->
            #ref{ offset=Len }=Tag
                = get(Ref#ref.segment,
                      Ref#ref.pos + Ref#ref.offset + 1,
                      Ref#ref.data),
            [[Ptr, create_ptr(Len, Tag),
              [copy(Elem) || Elem <- read_list(Ref)]]
             |Acc];
        pointer ->
            [[Ptr, [copy(Elem) || Elem <- read_list(Ref)]]|Acc];
        _ ->
            Count = (Ref#ref.kind)#list_ref.count,
            ElementSize = list_element_size(Size),
            List = get_segment(1 + ((ElementSize * Count - 1) div 64), Ref),
            [[Ptr, List]|Acc]
    end.

update_offsets([], _, AccPtrs, AccData) ->
    [lists:reverse(AccPtrs), lists:reverse(AccData)];
update_offsets([[[Ptr|Data]]|Ptrs], Offset, AccPtrs, AccData) ->
    update_offsets(
      Ptrs,
      Offset + iolist_size(Data) - 1,
      [ptr_offset(Ptr, Offset)|AccPtrs],
      [Data|AccData]);
update_offsets([Other|Ptrs], Offset, AccPtrs, AccData) ->
    update_offsets(Ptrs, Offset - 1, [Other|AccPtrs], AccData).


ptr_offset(<<_:6/bits, Kind:2/integer, _:24/bits, Data/binary>>, Offset) ->
    OffsetAndKind = (Offset bsl 2) bor Kind,
    <<OffsetAndKind:32/integer-signed-little, Data/binary>>.

create_ptr(Ptr) -> create_ptr(0, Ptr).
create_ptr(_Offset, #ref{ pos=-1 }) -> <<>>;
create_ptr(_Offset, null) -> <<0:64/integer>>;
create_ptr(Offset, #ref{ kind=Kind }) -> create_ptr(Offset, Kind);
create_ptr(Offset, #struct_ref{ dsize=DSize, psize=PSize }) ->
    Off = (Offset bsl 2),
    <<Off:32/integer-signed-little,
      DSize:16/integer-little,
      PSize:16/integer-little>>;
create_ptr(Offset, #list_ref{ size=Size, count=Count }) ->
    Off = (Offset bsl 2) + 1,
    Sz = (Count bsl 3) + element_size(Size),
    <<Off:32/integer-little,
      Sz:32/integer-little>>.

%% element size encoded value
element_size(empty) -> 0;
element_size(bit) -> 1;
element_size(byte) -> 2;
element_size(twoBytes) -> 3;
element_size(fourBytes) -> 4;
element_size(eightBytes) -> 5;
element_size(pointer) -> 6;
element_size(inlineComposite) -> 7.