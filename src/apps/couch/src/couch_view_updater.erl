% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_view_updater).

-export([update/2, do_maps/4, do_writes/5, load_docs/3]).

-include("couch_db.hrl").

-spec update(_, #group{}) -> no_return().

update(Owner, Group) ->
    #group{
        dbname = DbName,
        name = GroupName,
        current_seq = Seq,
        purge_seq = PurgeSeq
    } = Group,
    couch_task_status:add_task(<<"View Group Indexer">>, <<DbName/binary," ",GroupName/binary>>, <<"Starting index update">>),

    {ok, Db} = couch_db:open(DbName, []),
    DbPurgeSeq = couch_db:get_purge_seq(Db),
    Group2 =
    if DbPurgeSeq == PurgeSeq ->
        Group;
    DbPurgeSeq == PurgeSeq + 1 ->
        couch_task_status:update(<<"Removing purged entries from view index.">>),
        purge_index(Db, Group);
    true ->
        couch_task_status:update(<<"Resetting view index due to lost purge entries.">>),
        exit(reset)
    end,
    {ok, MapQueue} = couch_work_queue:new(100000, 500),
    {ok, WriteQueue} = couch_work_queue:new(100000, 500),
    Self = self(),
    ViewEmptyKVs = [{View, []} || View <- Group2#group.views],
    spawn_link(?MODULE, do_maps, [Group, MapQueue, WriteQueue, ViewEmptyKVs]),
    spawn_link(?MODULE, do_writes, [Self, Owner, Group2, WriteQueue, Seq == 0]),
    % compute on all docs modified since we last computed.
    TotalChanges = couch_db:count_changes_since(Db, Seq),
    % update status every half second
    couch_task_status:set_update_frequency(500),
    #group{ design_options = DesignOptions } = Group,
    IncludeDesign = couch_util:get_value(<<"include_design">>,
        DesignOptions, false),
    LocalSeq = couch_util:get_value(<<"local_seq">>, DesignOptions, false),
    DocOpts =
    case LocalSeq of
    true -> [conflicts, deleted_conflicts, local_seq];
    _ -> [conflicts, deleted_conflicts]
    end,
    EnumFun = fun ?MODULE:load_docs/3,
    Acc0 = {0, Db, MapQueue, DocOpts, IncludeDesign, TotalChanges},
    {ok, _, _} = couch_db:enum_docs_since(Db, Seq, EnumFun, Acc0, []),
    couch_task_status:set_update_frequency(0),
    couch_task_status:update("Finishing."),
    couch_work_queue:close(MapQueue),
    receive {new_group, NewGroup} ->
        exit({new_group,
                NewGroup#group{current_seq=couch_db:get_update_seq(Db)}})
    end.

load_docs(DocInfo, _, {I, Db, MapQueue, DocOpts, IncludeDesign, Total} = Acc) ->
    couch_task_status:update("Processed ~p of ~p changes (~p%)", [I, Total,
        (I*100) div Total]),
    load_doc(Db, DocInfo, MapQueue, DocOpts, IncludeDesign),
    {ok, setelement(1, Acc, I+1)}.

purge_index(Db, #group{views=Views, id_btree=IdBtree}=Group) ->
    {ok, PurgedIdsRevs} = couch_db:get_last_purged(Db),
    Ids = [Id || {Id, _Revs} <- PurgedIdsRevs],
    {ok, Lookups, IdBtree2} = couch_btree:query_modify(IdBtree, Ids, [], Ids),

    % now populate the dictionary with all the keys to delete
    ViewKeysToRemoveDict = lists:foldl(
        fun({ok,{DocId,ViewNumRowKeys}}, ViewDictAcc) ->
            lists:foldl(
                fun({ViewNum, RowKey}, ViewDictAcc2) ->
                    dict:append(ViewNum, {RowKey, DocId}, ViewDictAcc2)
                end, ViewDictAcc, ViewNumRowKeys);
        ({not_found, _}, ViewDictAcc) ->
            ViewDictAcc
        end, dict:new(), Lookups),

    % Now remove the values from the btrees
    Views2 = lists:map(
        fun(#view{id_num=Num,btree=Btree}=View) ->
            case dict:find(Num, ViewKeysToRemoveDict) of
            {ok, RemoveKeys} ->
                {ok, Btree2} = couch_btree:add_remove(Btree, [], RemoveKeys),
                View#view{btree=Btree2};
            error -> % no keys to remove in this view
                View
            end
        end, Views),
    Group#group{id_btree=IdBtree2,
            views=Views2,
            purge_seq=couch_db:get_purge_seq(Db)}.

-spec load_doc(#db{}, #doc_info{}, pid(), [atom()], boolean()) -> ok.
load_doc(Db, DI, MapQueue, DocOpts, IncludeDesign) ->
    DocInfo = case DI of
    #full_doc_info{id=DocId, update_seq=Seq, deleted=Deleted} ->
        couch_doc:to_doc_info(DI);
    #doc_info{id=DocId, high_seq=Seq, revs=[#rev_info{deleted=Deleted}|_]} ->
        DI
    end,
    case {IncludeDesign, DocId} of
    {false, <<?DESIGN_DOC_PREFIX, _/binary>>} -> % we skip design docs
        ok;
    _ ->
        if Deleted ->
            couch_work_queue:queue(MapQueue, {Seq, #doc{id=DocId, deleted=true}});
        true ->
            {ok, Doc} = couch_db:open_doc_int(Db, DocInfo, DocOpts),
            couch_work_queue:queue(MapQueue, {Seq, Doc})
        end
    end.

-spec do_maps(#group{}, pid(), pid(), any()) -> any().
do_maps(Group, MapQueue, WriteQueue, ViewEmptyKVs) ->
    case couch_work_queue:dequeue(MapQueue) of
    closed ->
        couch_work_queue:close(WriteQueue),
        couch_query_servers:stop_doc_map(Group#group.query_server);
    {ok, Queue} ->
        Docs = [Doc || {_,#doc{deleted=false}=Doc} <- Queue],
        DelKVs = [{Id, []} || {_, #doc{deleted=true,id=Id}} <- Queue],
        LastSeq = lists:max([Seq || {Seq, _Doc} <- Queue]),
        {Group1, Results} = view_compute(Group, Docs),
        {ViewKVs, DocIdViewIdKeys} = view_insert_query_results(Docs,
                    Results, ViewEmptyKVs, DelKVs),
        couch_work_queue:queue(WriteQueue, {LastSeq, ViewKVs, DocIdViewIdKeys}),
        ?MODULE:do_maps(Group1, MapQueue, WriteQueue, ViewEmptyKVs)
    end.

-spec do_writes(pid(), pid() | nil, #group{}, pid(), boolean()) -> any().
do_writes(Parent, Owner, Group, WriteQueue, InitialBuild) ->
    case accumulate_writes(WriteQueue, couch_work_queue:dequeue(WriteQueue), nil) of
    stop ->
        Parent ! {new_group, Group};
    {Go, {NewSeq, ViewKeyValues, DocIdViewIdKeys}} ->
        Group2 = write_changes(Group, ViewKeyValues, DocIdViewIdKeys, NewSeq,
                InitialBuild),
        if Go =:= stop ->
            Parent ! {new_group, Group2};
        true ->
            case Owner of
            nil -> ok;
            _ -> ok = gen_server:cast(Owner, {partial_update, Parent, Group2})
            end,
            ?MODULE:do_writes(Parent, Owner, Group2, WriteQueue, InitialBuild)
        end
    end.

accumulate_writes(_, closed, nil) ->
    stop;
accumulate_writes(_, closed, Acc) ->
    {stop, Acc};
accumulate_writes(W, {ok, Queue}, Acc0) ->
    {_, _, DocIdViewIdKeys} = NewAcc = lists:foldl(
        fun(First, nil) -> First; ({Seq, ViewKVs, DocIdViewIdKeys}, Acc) ->
            {Seq2, AccViewKVs, AccDocIdViewIdKeys} = Acc,
            AccViewKVs2 = lists:zipwith(
                fun({View, KVsIn}, {_View, KVsAcc}) ->
                    {View, KVsIn ++ KVsAcc}
                end, ViewKVs, AccViewKVs),
            {erlang:max(Seq, Seq2), AccViewKVs2,
                DocIdViewIdKeys ++ AccDocIdViewIdKeys}
        end, Acc0, Queue),
    % check if we have enough items now
    MinItems = couch_config:get("view_updater", "min_writer_items", "100"),
    MinSize = couch_config:get("view_updater", "min_writer_size", "16777216"),
    case length(DocIdViewIdKeys) >= list_to_integer(MinItems) orelse
         process_info(self(), memory) >= list_to_integer(MinSize) of
    true ->
        {ok, NewAcc};
    false ->
        accumulate_writes(W, couch_work_queue:dequeue(W), NewAcc)
    end.

-spec view_insert_query_results([#doc{}], list(), any(), any()) -> any().
view_insert_query_results([], [], ViewKVs, DocIdViewIdKeysAcc) ->
    {ViewKVs, DocIdViewIdKeysAcc};
view_insert_query_results([Doc|RestDocs], [QueryResults | RestResults], ViewKVs, DocIdViewIdKeysAcc) ->
    {NewViewKVs, NewViewIdKeys} = view_insert_doc_query_results(Doc, QueryResults, ViewKVs, [], []),
    NewDocIdViewIdKeys = [{Doc#doc.id, NewViewIdKeys} | DocIdViewIdKeysAcc],
    view_insert_query_results(RestDocs, RestResults, NewViewKVs, NewDocIdViewIdKeys).

-spec view_insert_doc_query_results(#doc{}, list(), list(), any(), any()) ->
    any().
view_insert_doc_query_results(_Doc, [], [], ViewKVsAcc, ViewIdKeysAcc) ->
    {lists:reverse(ViewKVsAcc), lists:reverse(ViewIdKeysAcc)};
view_insert_doc_query_results(#doc{id=DocId}=Doc, [ResultKVs|RestResults], [{View, KVs}|RestViewKVs], ViewKVsAcc, ViewIdKeysAcc) ->
    % Take any identical keys and combine the values
    ResultKVs2 = lists:foldl(
        fun({Key,Value}, [{PrevKey,PrevVal}|AccRest]) ->
            case Key == PrevKey of
            true ->
                case PrevVal of
                {dups, Dups} ->
                    [{PrevKey, {dups, [Value|Dups]}} | AccRest];
                _ ->
                    [{PrevKey, {dups, [Value,PrevVal]}} | AccRest]
                end;
            false ->
                [{Key,Value},{PrevKey,PrevVal}|AccRest]
            end;
        (KV, []) ->
           [KV]
        end, [], lists:sort(ResultKVs)),
    NewKVs = [{{Key, DocId}, Value} || {Key, Value} <- ResultKVs2],
    NewViewKVsAcc = [{View, NewKVs ++ KVs} | ViewKVsAcc],
    NewViewIdKeys = [{View#view.id_num, Key} || {Key, _Value} <- ResultKVs2],
    NewViewIdKeysAcc = NewViewIdKeys ++ ViewIdKeysAcc,
    view_insert_doc_query_results(Doc, RestResults, RestViewKVs, NewViewKVsAcc, NewViewIdKeysAcc).

-spec view_compute(#group{}, [#doc{}]) -> {#group{}, any()}.
view_compute(Group, []) ->
    {Group, []};
view_compute(#group{def_lang=DefLang, query_server=QueryServerIn}=Group, Docs) ->
    {ok, QueryServer} =
    case QueryServerIn of
    nil -> % doc map not started
        Definitions = [View#view.def || View <- Group#group.views],
        couch_query_servers:start_doc_map(DefLang, Definitions);
    _ ->
        {ok, QueryServerIn}
    end,
    {ok, Results} = couch_query_servers:map_docs(QueryServer, Docs),
    {Group#group{query_server=QueryServer}, Results}.


write_changes(Group, ViewKeyValuesToAdd, DocIdViewIdKeys, NewSeq, InitialBuild) ->
    #group{id_btree=IdBtree} = Group,

    AddDocIdViewIdKeys = [{DocId, ViewIdKeys} || {DocId, ViewIdKeys} <- DocIdViewIdKeys, ViewIdKeys /= []],
    if InitialBuild ->
        RemoveDocIds = [],
        LookupDocIds = [];
    true ->
        RemoveDocIds = [DocId || {DocId, ViewIdKeys} <- DocIdViewIdKeys, ViewIdKeys == []],
        LookupDocIds = [DocId || {DocId, _ViewIdKeys} <- DocIdViewIdKeys]
    end,
    {ok, LookupResults, IdBtree2}
        = couch_btree:query_modify(IdBtree, LookupDocIds, AddDocIdViewIdKeys, RemoveDocIds),
    KeysToRemoveByView = lists:foldl(
        fun(LookupResult, KeysToRemoveByViewAcc) ->
            case LookupResult of
            {ok, {DocId, ViewIdKeys}} ->
                lists:foldl(
                    fun({ViewId, Key}, KeysToRemoveByViewAcc2) ->
                        dict:append(ViewId, {Key, DocId}, KeysToRemoveByViewAcc2)
                    end,
                    KeysToRemoveByViewAcc, ViewIdKeys);
            {not_found, _} ->
                KeysToRemoveByViewAcc
            end
        end,
        dict:new(), LookupResults),
    Views2 = lists:zipwith(fun(View, {_View, AddKeyValues}) ->
            KeysToRemove = couch_util:dict_find(View#view.id_num, KeysToRemoveByView, []),
            {ok, ViewBtree2} = couch_btree:add_remove(View#view.btree, AddKeyValues, KeysToRemove),
            View#view{btree = ViewBtree2}
        end,    Group#group.views, ViewKeyValuesToAdd),
    Group#group{views=Views2, current_seq=NewSeq, id_btree=IdBtree2}.


