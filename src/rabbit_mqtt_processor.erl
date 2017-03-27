%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_mqtt_processor).

-export([info/2, initial_state/2, initial_state/4,
         process_frame/2, amqp_pub/2, amqp_callback/2, send_will/1,
         close_connection/1]).

%% for testing purposes
-export([get_vhost_username/1]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_mqtt_frame.hrl").
-include("rabbit_mqtt.hrl").

-define(APP, rabbitmq_mqtt).
-define(FRAME_TYPE(Frame, Type),
        Frame = #mqtt_frame{ fixed = #mqtt_frame_fixed{ type = Type }}).

initial_state(Socket, SSLLoginName) ->
    initial_state(Socket, SSLLoginName,
        adapter_info(Socket, 'MQTT'),
        fun send_client/2).

initial_state(Socket, SSLLoginName,
              AdapterInfo0 = #amqp_adapter_info{additional_info = Extra},
              SendFun) ->
    %% MQTT connections use exactly one channel. The frame max is not
    %% applicable and there is no way to know what client is used.
    AdapterInfo = AdapterInfo0#amqp_adapter_info{additional_info = [
        {channels, 1},
        {channel_max, 1},
        {frame_max, 0},
        {client_properties,
         [{<<"product">>, longstr, <<"MQTT client">>}]} | Extra]},
    #proc_state{ unacked_pubs   = gb_trees:empty(),
                 awaiting_ack   = gb_trees:empty(),
                 message_id     = 1,
                 subscriptions  = dict:new(),
                 consumer_tags  = {undefined, undefined},
                 channels       = {undefined, undefined},
                 exchange       = rabbit_mqtt_util:env(exchange),
                 socket         = Socket,
                 adapter_info   = AdapterInfo,
                 ssl_login_name = SSLLoginName,
                 send_fun       = SendFun }.

info(client_id, #proc_state{ client_id = ClientId }) -> ClientId.

process_frame(#mqtt_frame{ fixed = #mqtt_frame_fixed{ type = Type }},
              PState = #proc_state{ connection = undefined } )
  when Type =/= ?CONNECT ->
    {error, connect_expected, PState};
process_frame(Frame = #mqtt_frame{ fixed = #mqtt_frame_fixed{ type = Type }},
              PState) ->
    case process_request(Type, Frame, PState) of
        {ok, PState1} -> {ok, PState1, PState1#proc_state.connection};
        Ret -> Ret
    end.

process_request(?CONNECT,
                #mqtt_frame{ variable = #mqtt_frame_connect{
                                           username   = Username,
                                           password   = Password,
                                           proto_ver  = ProtoVersion,
                                           clean_sess = CleanSess,
                                           client_id  = ClientId0,
                                           keep_alive = Keepalive} = Var},
                PState = #proc_state{ ssl_login_name = SSLLoginName,
                                      send_fun = SendFun }) ->
    ClientId = case ClientId0 of
                   []    -> rabbit_mqtt_util:gen_client_id();
                   [_|_] -> ClientId0
               end,
    {Return, PState1} =
        case {lists:member(ProtoVersion, proplists:get_keys(?PROTOCOL_NAMES)),
              ClientId0 =:= [] andalso CleanSess =:= false} of
            {false, _} ->
                {?CONNACK_PROTO_VER, PState};
            {_, true} ->
                {?CONNACK_INVALID_ID, PState};
            _ ->
                case creds(Username, Password, SSLLoginName) of
                    nocreds ->
                        rabbit_log:error("MQTT login failed: no credentials provided~n"),
                        {?CONNACK_CREDENTIALS, PState};
                    {invalid_creds, {undefined, Pass}} when is_list(Pass) ->
                        rabbit_log:error("MQTT login failed: no user username is provided"),
                        {?CONNACK_CREDENTIALS, PState};
                    {invalid_creds, {User, undefined}} when is_list(User) ->
                        rabbit_log:error("MQTT login failed for ~p: no password provided", [User]),
                        {?CONNACK_CREDENTIALS, PState};
                    {UserBin, PassBin} ->
                        case process_login(UserBin, PassBin, ProtoVersion, PState) of
                            {?CONNACK_ACCEPT, Conn, VHost, AState} ->
                                 RetainerPid =
                                   rabbit_mqtt_retainer_sup:child_for_vhost(VHost),
                                link(Conn),
                                {ok, Ch} = amqp_connection:open_channel(Conn),
                                link(Ch),
                                amqp_channel:enable_delivery_flow_control(Ch),
                                ok = rabbit_mqtt_collector:register(
                                  ClientId, self()),
                                Prefetch = rabbit_mqtt_util:env(prefetch),
                                #'basic.qos_ok'{} = amqp_channel:call(
                                  Ch, #'basic.qos'{prefetch_count = Prefetch}),
                                rabbit_mqtt_reader:start_keepalive(self(), Keepalive),
                                {SP, ProcState} =
                                    maybe_clean_sess(
                                        PState #proc_state{
                                            will_msg   = make_will_msg(Var),
                                            clean_sess = CleanSess,
                                            channels   = {Ch, undefined},
                                            connection = Conn,
                                            client_id  = ClientId,
                                            retainer_pid = RetainerPid,
                                            auth_state = AState}),
                                {{?CONNACK_ACCEPT, SP}, ProcState};
                            ConnAck ->
                                {ConnAck, PState}
                        end
                end
        end,
    {ReturnCode, SessionPresent} = case Return of
        {?CONNACK_ACCEPT, _} = Return -> Return;
        Return                        -> {Return, false}
    end,
    SendFun(#mqtt_frame{ fixed    = #mqtt_frame_fixed{ type = ?CONNACK},
                         variable = #mqtt_frame_connack{
                                     session_present = SessionPresent,
                                     return_code = ReturnCode}},
            PState1),
    {ok, PState1};

process_request(?PUBACK,
                #mqtt_frame{
                  variable = #mqtt_frame_publish{ message_id = MessageId }},
                #proc_state{ channels     = {Channel, _},
                             awaiting_ack = Awaiting } = PState) ->
    %% tag can be missing because of bogus clients and QoS downgrades
    case gb_trees:is_defined(MessageId, Awaiting) of
      false ->
        {ok, PState};
      true ->
        Tag = gb_trees:get(MessageId, Awaiting),
        amqp_channel:cast(Channel, #'basic.ack'{ delivery_tag = Tag }),
        {ok, PState #proc_state{ awaiting_ack = gb_trees:delete( MessageId, Awaiting)}}
    end;

process_request(?PUBLISH,
                #mqtt_frame{
                  fixed = #mqtt_frame_fixed{ qos = ?QOS_2 }}, PState) ->
    {error, qos2_not_supported, PState};
process_request(?PUBLISH,
                #mqtt_frame{
                  fixed = #mqtt_frame_fixed{ qos    = Qos,
                                             retain = Retain,
                                             dup    = Dup },
                  variable = #mqtt_frame_publish{ topic_name = Topic,
                                                  message_id = MessageId },
                  payload = Payload },
                  PState = #proc_state{retainer_pid = RPid}) ->
    check_publish_or_die(Topic, fun() ->
        Msg = #mqtt_msg{retain     = Retain,
                        qos        = Qos,
                        topic      = Topic,
                        dup        = Dup,
                        message_id = MessageId,
                        payload    = Payload},
        Result = amqp_pub(Msg, PState),
        case Retain of
          false -> ok;
          true  -> hand_off_to_retainer(RPid, Topic, Msg)
        end,
        {ok, Result}
    end, PState);

process_request(?SUBSCRIBE,
                #mqtt_frame{
                  variable = #mqtt_frame_subscribe{
                              message_id  = MessageId,
                              topic_table = Topics},
                  payload = undefined},
                #proc_state{channels = {Channel, _},
                            exchange = Exchange,
                            retainer_pid = RPid,
                            send_fun = SendFun } = PState0) ->
    check_subscribe_or_die(Topics, fun() ->
        {QosResponse, PState1} =
            lists:foldl(fun (#mqtt_topic{name = TopicName,
                                         qos  = Qos}, {QosList, PState}) ->
                           SupportedQos = supported_subs_qos(Qos),
                           {Queue, #proc_state{subscriptions = Subs} = PState1} =
                               ensure_queue(SupportedQos, PState),
                           Binding = #'queue.bind'{
                                       queue       = Queue,
                                       exchange    = Exchange,
                                       routing_key = rabbit_mqtt_util:mqtt2amqp(
                                                       TopicName)},
                           #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
                           {[SupportedQos | QosList],
                            PState1 #proc_state{subscriptions =
                                                dict:append(TopicName, SupportedQos, Subs)}}
                       end, {[], PState0}, Topics),
        SendFun(#mqtt_frame{fixed    = #mqtt_frame_fixed{type = ?SUBACK},
                            variable = #mqtt_frame_suback{
                                        message_id = MessageId,
                                        qos_table  = QosResponse}}, PState1),
        %% we may need to send up to length(Topics) messages.
        %% if QoS is > 0 then we need to generate a message id,
        %% and increment the counter.
        N = lists:foldl(fun (Topic, Acc) ->
                          case maybe_send_retained_message(RPid, Topic, Acc, PState1) of
                            {true, X} -> Acc + X;
                            false     -> Acc
                          end
                        end, MessageId, Topics),
        {ok, PState1#proc_state{message_id = N}}
    end, PState0);

process_request(?UNSUBSCRIBE,
                #mqtt_frame{
                  variable = #mqtt_frame_subscribe{ message_id  = MessageId,
                                                    topic_table = Topics },
                  payload = undefined }, #proc_state{ channels      = {Channel, _},
                                                      exchange      = Exchange,
                                                      client_id     = ClientId,
                                                      subscriptions = Subs0,
                                                      send_fun      = SendFun } = PState) ->
    Queues = rabbit_mqtt_util:subcription_queue_name(ClientId),
    Subs1 =
    lists:foldl(
      fun (#mqtt_topic{ name = TopicName }, Subs) ->
        QosSubs = case dict:find(TopicName, Subs) of
                      {ok, Val} when is_list(Val) -> lists:usort(Val);
                      error                       -> []
                  end,
        lists:foreach(
          fun (QosSub) ->
                  Queue = element(QosSub + 1, Queues),
                  Binding = #'queue.unbind'{
                              queue       = Queue,
                              exchange    = Exchange,
                              routing_key =
                                  rabbit_mqtt_util:mqtt2amqp(TopicName)},
                  #'queue.unbind_ok'{} = amqp_channel:call(Channel, Binding)
          end, QosSubs),
        dict:erase(TopicName, Subs)
      end, Subs0, Topics),
    SendFun(#mqtt_frame{ fixed    = #mqtt_frame_fixed { type       = ?UNSUBACK },
                         variable = #mqtt_frame_suback{ message_id = MessageId }},
                PState),
    {ok, PState #proc_state{ subscriptions = Subs1 }};

process_request(?PINGREQ, #mqtt_frame{}, #proc_state{ send_fun = SendFun } = PState) ->
    %% we are sending PINGREQ message via amqp_pub to topic named after our client_id
    %% to notify other clients, that our client is alive
    %% this feature does not follow MQTT spec :(
    Msg = #mqtt_msg{retain    = false,
                    qos       = ?QOS_0,
                    topic     = "/1/" ++ PState#proc_state.client_id,
                    dup       = false,
                    message_id= 0,
                    payload = list_to_binary("PINGREQ")},
    amqp_pub(Msg, PState),    
	SendFun(#mqtt_frame{ fixed = #mqtt_frame_fixed{ type = ?PINGRESP }},
                PState),
    {ok, PState};

process_request(?DISCONNECT, #mqtt_frame{}, PState) ->
    {stop, PState}.

%%----------------------------------------------------------------------------

hand_off_to_retainer(RetainerPid, Topic, #mqtt_msg{payload = <<"">>}) ->
  rabbit_mqtt_retainer:clear(RetainerPid, Topic),
  ok;
hand_off_to_retainer(RetainerPid, Topic, Msg) ->
  rabbit_mqtt_retainer:retain(RetainerPid, Topic, Msg),
  ok.

maybe_send_retained_message(RPid, #mqtt_topic{name = S, qos = SubscribeQos}, MsgId,
                            #proc_state{ send_fun = SendFun } = PState) ->
  case rabbit_mqtt_retainer:fetch(RPid, S) of
    undefined -> false;
    Msg       ->
                %% calculate effective QoS as the lower value of SUBSCRIBE frame QoS
                %% and retained message QoS. The spec isn't super clear on this, we
                %% do what Mosquitto does, per user feedback.
                Qos = erlang:min(SubscribeQos, Msg#mqtt_msg.qos),
                Id = case Qos of
                  ?QOS_0 -> undefined;
                  ?QOS_1 -> MsgId
                end,
                SendFun(#mqtt_frame{fixed = #mqtt_frame_fixed{
                    type = ?PUBLISH,
                    qos  = Qos,
                    dup  = false,
                    retain = Msg#mqtt_msg.retain
                 }, variable = #mqtt_frame_publish{
                    message_id = Id,
                    topic_name = S
                 },
                 payload = Msg#mqtt_msg.payload}, PState),
                 case Qos of
                   ?QOS_0 -> false;
                   ?QOS_1 -> {true, 1}
                 end
  end.

amqp_callback({#'basic.deliver'{ consumer_tag = ConsumerTag,
                                 delivery_tag = DeliveryTag,
                                 routing_key  = RoutingKey },
               #amqp_msg{ props = #'P_basic'{ headers = Headers },
                          payload = Payload },
               DeliveryCtx} = Delivery,
              #proc_state{ channels      = {Channel, _},
                           awaiting_ack  = Awaiting,
                           message_id    = MsgId,
                           send_fun      = SendFun } = PState) ->
    amqp_channel:notify_received(DeliveryCtx),
    case {delivery_dup(Delivery), delivery_qos(ConsumerTag, Headers, PState)} of
        {true, {?QOS_0, ?QOS_1}} ->
            amqp_channel:cast(
              Channel, #'basic.ack'{ delivery_tag = DeliveryTag }),
            {ok, PState};
        {true, {?QOS_0, ?QOS_0}} ->
            {ok, PState};
        {Dup, {DeliveryQos, _SubQos} = Qos}     ->
            SendFun(
              #mqtt_frame{ fixed = #mqtt_frame_fixed{
                                     type = ?PUBLISH,
                                     qos  = DeliveryQos,
                                     dup  = Dup },
                           variable = #mqtt_frame_publish{
                                        message_id =
                                          case DeliveryQos of
                                              ?QOS_0 -> undefined;
                                              ?QOS_1 -> MsgId
                                          end,
                                        topic_name =
                                          rabbit_mqtt_util:amqp2mqtt(
                                            RoutingKey) },
                           payload = Payload}, PState),
              case Qos of
                  {?QOS_0, ?QOS_0} ->
                      {ok, PState};
                  {?QOS_1, ?QOS_1} ->
                      {ok,
                       next_msg_id(
                         PState #proc_state{
                           awaiting_ack =
                             gb_trees:insert(MsgId, DeliveryTag, Awaiting)})};
                  {?QOS_0, ?QOS_1} ->
                      amqp_channel:cast(
                        Channel, #'basic.ack'{ delivery_tag = DeliveryTag }),
                      {ok, PState}
              end
    end;

amqp_callback(#'basic.ack'{ multiple = true, delivery_tag = Tag } = Ack,
              PState = #proc_state{ unacked_pubs = UnackedPubs,
                                    send_fun     = SendFun }) ->
    case gb_trees:size(UnackedPubs) > 0 andalso
         gb_trees:take_smallest(UnackedPubs) of
        {TagSmall, MsgId, UnackedPubs1} when TagSmall =< Tag ->
            SendFun(
              #mqtt_frame{ fixed    = #mqtt_frame_fixed{ type = ?PUBACK },
                           variable = #mqtt_frame_publish{ message_id = MsgId }},
              PState),
            amqp_callback(Ack, PState #proc_state{ unacked_pubs = UnackedPubs1 });
        _ ->
            {ok, PState}
    end;

amqp_callback(#'basic.ack'{ multiple = false, delivery_tag = Tag },
              PState = #proc_state{ unacked_pubs = UnackedPubs,
                                    send_fun     = SendFun }) ->
    SendFun(
      #mqtt_frame{ fixed    = #mqtt_frame_fixed{ type = ?PUBACK },
                   variable = #mqtt_frame_publish{
                                message_id = gb_trees:get(
                                               Tag, UnackedPubs) }}, PState),
    {ok, PState #proc_state{ unacked_pubs = gb_trees:delete(Tag, UnackedPubs) }}.

delivery_dup({#'basic.deliver'{ redelivered = Redelivered },
              #amqp_msg{ props = #'P_basic'{ headers = Headers }},
              _DeliveryCtx}) ->
    case rabbit_mqtt_util:table_lookup(Headers, <<"x-mqtt-dup">>) of
        undefined   -> Redelivered;
        {bool, Dup} -> Redelivered orelse Dup
    end.

next_msg_id(PState = #proc_state{ message_id = 16#ffff }) ->
    PState #proc_state{ message_id = 1 };
next_msg_id(PState = #proc_state{ message_id = MsgId }) ->
    PState #proc_state{ message_id = MsgId + 1 }.

%% decide at which qos level to deliver based on subscription
%% and the message publish qos level. non-MQTT publishes are
%% assumed to be qos 1, regardless of delivery_mode.
delivery_qos(Tag, _Headers,  #proc_state{ consumer_tags = {Tag, _} }) ->
    {?QOS_0, ?QOS_0};
delivery_qos(Tag, Headers,   #proc_state{ consumer_tags = {_, Tag} }) ->
    case rabbit_mqtt_util:table_lookup(Headers, <<"x-mqtt-publish-qos">>) of
        {byte, Qos} -> {lists:min([Qos, ?QOS_1]), ?QOS_1};
        undefined   -> {?QOS_1, ?QOS_1}
    end.

maybe_clean_sess(PState = #proc_state { clean_sess = false,
                                        channels   = {Channel, _},
                                        client_id  = ClientId }) ->
    {_Queue, PState1} = ensure_queue(?QOS_1, PState),
    SessionPresent = session_present(Channel, ClientId),
    {SessionPresent, PState1};
maybe_clean_sess(PState = #proc_state { clean_sess = true,
                                        connection = Conn,
                                        client_id  = ClientId }) ->
    {_, Queue} = rabbit_mqtt_util:subcription_queue_name(ClientId),
    {ok, Channel} = amqp_connection:open_channel(Conn),
    try amqp_channel:call(Channel, #'queue.delete'{ queue = Queue }) of
        #'queue.delete_ok'{} -> ok = amqp_channel:close(Channel)
    catch
        exit:_Error -> ok
    end,
    {false, PState}.

session_present(Channel, ClientId)  ->
    {_, QueueQ1} = rabbit_mqtt_util:subcription_queue_name(ClientId),
    Declare = #'queue.declare'{queue   = QueueQ1,
                               passive = true},
    case amqp_channel:call(Channel, Declare) of
        #'queue.declare_ok'{} -> true;
        _                     -> false
    end.

%%----------------------------------------------------------------------------

make_will_msg(#mqtt_frame_connect{ will_flag   = false }) ->
    undefined;
make_will_msg(#mqtt_frame_connect{ will_retain = Retain,
                                   will_qos    = Qos,
                                   will_topic  = Topic,
                                   will_msg    = Msg }) ->
    #mqtt_msg{ retain  = Retain,
               qos     = Qos,
               topic   = Topic,
               dup     = false,
               payload = Msg }.

process_login(UserBin, PassBin, ProtoVersion,
              #proc_state{ channels     = {undefined, undefined},
                           socket       = Sock,
                           adapter_info = AdapterInfo }) ->
    {VHost, UsernameBin} = get_vhost_username(UserBin),
    case amqp_connection:start(#amqp_params_direct{
                                  username     = UsernameBin,
                                  password     = PassBin,
                                  virtual_host = VHost,
                                  adapter_info = set_proto_version(AdapterInfo, ProtoVersion)}) of
        {ok, Connection} ->
            case rabbit_access_control:check_user_loopback(UsernameBin, Sock) of
                ok          ->
                    [{internal_user, InternalUser}] = amqp_connection:info(
                        Connection, [internal_user]),
                    {?CONNACK_ACCEPT, Connection, VHost,
                                      #auth_state{user = InternalUser,
                                                  username = UsernameBin,
                                                  vhost = VHost}};
                not_allowed ->
                    amqp_connection:close(Connection),
                    rabbit_log:warning(
                      "MQTT login failed for ~p access_refused "
                      "(access must be from localhost)~n",
                      [binary_to_list(UsernameBin)]),
                    ?CONNACK_AUTH
            end;
        {error, {auth_failure, Explanation}} ->
            rabbit_log:error("MQTT login failed for ~p auth_failure: ~s~n",
                             [binary_to_list(UserBin), Explanation]),
            ?CONNACK_CREDENTIALS;
        {error, access_refused} ->
            rabbit_log:warning("MQTT login failed for ~p access_refused "
                               "(vhost access not allowed)~n",
                               [binary_to_list(UserBin)]),
            ?CONNACK_AUTH
    end.

get_vhost_username(UserBin) ->
    Default = {rabbit_mqtt_util:env(vhost), UserBin},
    case application:get_env(?APP, ignore_colons_in_username) of
        {ok, true} -> Default;
        _ ->
            %% split at the last colon, disallowing colons in username
            case re:split(UserBin, ":(?!.*?:)") of
                [Vhost, UserName] -> {Vhost,  UserName};
                [UserBin]         -> Default
            end
    end.

creds(User, Pass, SSLLoginName) ->
    DefaultUser   = rabbit_mqtt_util:env(default_user),
    DefaultPass   = rabbit_mqtt_util:env(default_pass),
    {ok, Anon}    = application:get_env(?APP, allow_anonymous),
    {ok, TLSAuth} = application:get_env(?APP, ssl_cert_login),
    HaveDefaultCreds = Anon =:= true andalso
                       is_binary(DefaultUser) andalso
                       is_binary(DefaultPass),

    CredentialsProvided = User =/= undefined orelse
                          Pass =/= undefined,

    CorrectCredentials = is_list(User) andalso
                         is_list(Pass),

    SSLLoginProvided = TLSAuth =:= true andalso
                       SSLLoginName =/= none,

    case {CredentialsProvided, CorrectCredentials, SSLLoginProvided, HaveDefaultCreds} of
        %% Username and password take priority
        {true, true, _, _}          -> {list_to_binary(User),
                                        list_to_binary(Pass)};
        %% Either username or password is provided
        {true, false, _, _}         -> {invalid_creds, {User, Pass}};
        %% rabbitmq_mqtt.ssl_cert_login is true. SSL user name provided.
        %% Authenticating using username only.
        {false, false, true, _}     -> {SSLLoginName, none};
        %% Anonymous connection uses default credentials
        {false, false, false, true} -> {DefaultUser, DefaultPass};
        _                           -> nocreds
    end.

supported_subs_qos(?QOS_0) -> ?QOS_0;
supported_subs_qos(?QOS_1) -> ?QOS_1;
supported_subs_qos(?QOS_2) -> ?QOS_1.

delivery_mode(?QOS_0) -> 1;
delivery_mode(?QOS_1) -> 2.

%% different qos subscriptions are received in different queues
%% with appropriate durability and timeout arguments
%% this will lead to duplicate messages for overlapping subscriptions
%% with different qos values - todo: prevent duplicates
ensure_queue(Qos, #proc_state{ channels      = {Channel, _},
                               client_id     = ClientId,
                               clean_sess    = CleanSess,
                          consumer_tags = {TagQ0, TagQ1} = Tags} = PState) ->
    {QueueQ0, QueueQ1} = rabbit_mqtt_util:subcription_queue_name(ClientId),
    Qos1Args = case {rabbit_mqtt_util:env(subscription_ttl), CleanSess} of
                   {undefined, _} ->
                       [];
                   {Ms, false} when is_integer(Ms) ->
                       [{<<"x-expires">>, long, Ms}];
                   _ ->
                       []
               end,
    QueueSetup =
        case {TagQ0, TagQ1, Qos} of
            {undefined, _, ?QOS_0} ->
                {QueueQ0,
                 #'queue.declare'{ queue       = QueueQ0,
                                   durable     = false,
                                   auto_delete = true },
                 #'basic.consume'{ queue  = QueueQ0,
                                   no_ack = true }};
            {_, undefined, ?QOS_1} ->
                {QueueQ1,
                 #'queue.declare'{ queue       = QueueQ1,
                                   durable     = true,
                                   %% Clean session means a transient connection,
                                   %% translating into auto-delete.
                                   %%
                                   %% see rabbitmq/rabbitmq-mqtt#37
                                   auto_delete = CleanSess,
                                   arguments   = Qos1Args },
                 #'basic.consume'{ queue  = QueueQ1,
                                   no_ack = false }};
            {_, _, ?QOS_0} ->
                {exists, QueueQ0};
            {_, _, ?QOS_1} ->
                {exists, QueueQ1}
          end,
    case QueueSetup of
        {Queue, Declare, Consume} ->
            #'queue.declare_ok'{} = amqp_channel:call(Channel, Declare),
            #'basic.consume_ok'{ consumer_tag = Tag } =
                amqp_channel:call(Channel, Consume),
            {Queue, PState #proc_state{ consumer_tags = setelement(Qos+1, Tags, Tag) }};
        {exists, Q} ->
            {Q, PState}
    end.

send_will(PState = #proc_state{ will_msg = WillMsg }) ->
    amqp_pub(WillMsg, PState).

amqp_pub(undefined, PState) ->
    PState;

%% set up a qos1 publishing channel if necessary
%% this channel will only be used for publishing, not consuming
amqp_pub(Msg   = #mqtt_msg{ qos = ?QOS_1 },
         PState = #proc_state{ channels       = {ChQos0, undefined},
                               awaiting_seqno = undefined,
                               connection     = Conn }) ->
    {ok, Channel} = amqp_connection:open_channel(Conn),
    #'confirm.select_ok'{} = amqp_channel:call(Channel, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(Channel, self()),
    amqp_pub(Msg, PState #proc_state{ channels       = {ChQos0, Channel},
                                      awaiting_seqno = 1 });

amqp_pub(#mqtt_msg{ qos        = Qos,
                    topic      = Topic,
                    dup        = Dup,
                    message_id = MessageId,
                    payload    = Payload },
         PState = #proc_state{ channels       = {ChQos0, ChQos1},
                               exchange       = Exchange,
                               unacked_pubs   = UnackedPubs,
                               awaiting_seqno = SeqNo }) ->
    Method = #'basic.publish'{ exchange    = Exchange,
                               routing_key =
                                   rabbit_mqtt_util:mqtt2amqp(Topic)},
    Headers = [{<<"x-mqtt-publish-qos">>, byte, Qos},
               {<<"x-mqtt-dup">>, bool, Dup}],
    Msg = #amqp_msg{ props   = #'P_basic'{ headers       = Headers,
                                           delivery_mode = delivery_mode(Qos)},
                     payload = Payload },
    {UnackedPubs1, Ch, SeqNo1} =
        case Qos =:= ?QOS_1 andalso MessageId =/= undefined of
            true  -> {gb_trees:enter(SeqNo, MessageId, UnackedPubs), ChQos1,
                      SeqNo + 1};
            false -> {UnackedPubs, ChQos0, SeqNo}
        end,
    amqp_channel:cast_flow(Ch, Method, Msg),
    PState #proc_state{ unacked_pubs   = UnackedPubs1,
                        awaiting_seqno = SeqNo1 }.

adapter_info(Sock, ProtoName) ->
    amqp_connection:socket_adapter_info(Sock, {ProtoName, "N/A"}).

set_proto_version(AdapterInfo = #amqp_adapter_info{protocol = {Proto, _}}, Vsn) ->
    AdapterInfo#amqp_adapter_info{protocol = {Proto,
        human_readable_mqtt_version(Vsn)}}.

human_readable_mqtt_version(3) ->
    "3.1.0";
human_readable_mqtt_version(4) ->
    "3.1.1";
human_readable_mqtt_version(_) ->
    "N/A".

send_client(Frame, #proc_state{ socket = Sock }) ->
    %rabbit_log:info("MQTT sending frame ~p ~n", [Frame]),
    rabbit_net:port_command(Sock, rabbit_mqtt_frame:serialise(Frame)).

close_connection(PState = #proc_state{ connection = undefined }) ->
    PState;
close_connection(PState = #proc_state{ connection = Connection,
                                       client_id  = ClientId }) ->
    % todo: maybe clean session
    case ClientId of
        undefined -> ok;
        _         -> ok = rabbit_mqtt_collector:unregister(ClientId, self())
    end,
    %% ignore noproc or other exceptions to avoid debris
    catch amqp_connection:close(Connection),
    PState #proc_state{ channels   = {undefined, undefined},
                        connection = undefined }.

% NB: check_*_or_die: MQTT spec says we should ack normally, ie pretend there
% was no auth error, but here we are closing the connection with an error. This
% is what happens anyway if there is an authorization failure at the AMQP level.

check_publish_or_die(TopicName, Fn, PState) ->
  case check_topic_access(TopicName, write, PState) of
    ok -> Fn();
    _ -> {err, unauthorized, PState}
  end.

check_subscribe_or_die([], Fn, _) ->
  Fn();

check_subscribe_or_die([#mqtt_topic{name = TopicName} | Topics], Fn, PState) ->
  case check_topic_access(TopicName, read, PState) of
    ok -> check_subscribe_or_die(Topics, Fn, PState);
    _ -> {err, unauthorized, PState}
  end.

check_topic_access(TopicName, Access,
                   #proc_state{
                      auth_state = #auth_state{user = User,
                                               vhost = VHost}}) ->
  Resource = #resource{virtual_host = VHost,
                       kind = topic,
                       name = TopicName},
  rabbit_access_control:check_resource_access(User, Resource, Access).
