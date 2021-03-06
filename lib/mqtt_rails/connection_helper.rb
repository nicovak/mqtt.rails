# Copyright (c) 2016-2017 Pierre Goudet <p-goudet@ruby-dev.jp>
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# and Eclipse Distribution License v1.0 which accompany this distribution.
#
# The Eclipse Public License is available at
#    https://eclipse.org/org/documents/epl-v10.php.
# and the Eclipse Distribution License is available at
#   https://eclipse.org/org/documents/edl-v10.php.
#
# Contributors:
#    Pierre Goudet - initial committer

require 'socket'

module MqttRails
  class ConnectionHelper

    attr_accessor :sender

    def initialize(host, port, ssl, ssl_context, ack_timeout)
      @cs          = MQTT_CS_DISCONNECT
      @socket      = nil
      @host        = host
      @port        = port
      @ssl         = ssl
      @ssl_context = ssl_context
      @ack_timeout = ack_timeout
      @sender      = Sender.new(ack_timeout)
    end

    def handler=(handler)
      @handler = handler
    end

    def do_connect(reconnection=false)
      @cs = MQTT_CS_NEW
      @handler.socket = @socket
      # Waiting a Connack packet for "ack_timeout" second from the remote
      connect_timeout = Time.now + @ack_timeout
      while (Time.now <= connect_timeout) && !is_connected? do
        @cs = @handler.receive_packet
      end
      unless is_connected?
        Rails.logger.error("[MQTT RAILS][ERROR] Connection failed. Couldn't recieve a Connack packet from: #{@host}.")
        raise Exception.new("Connection failed. Check log for more details.") unless reconnection
      end
      @cs
    end

    def is_connected?
      @cs == MQTT_CS_CONNECTED
    end

    def do_disconnect(publisher, explicit, mqtt_thread)
      Rails.logger.info("[MQTT RAILS][INFO] Disconnecting from #{@host}.")
      if explicit
        explicit_disconnect(publisher, mqtt_thread)
      end
      @socket.close unless @socket.nil? || @socket.closed?
      @socket = nil
    end

    def explicit_disconnect(publisher, mqtt_thread)
      @sender.flush_waiting_packet(false)
      send_disconnect
      mqtt_thread.kill if mqtt_thread && mqtt_thread.alive?
      publisher.flush_publisher unless publisher.nil?
    end

    def setup_connection
      clean_start(@host, @port)
      config_socket
      unless @socket.nil?
        @sender.socket = @socket
      end
    end

    def config_socket
      Rails.logger.info("[MQTT RAILS][INFO] Attempt to connect to host: #{@host}...")
      begin
        tcp_socket = TCPSocket.new(@host, @port)
        if @ssl
          encrypted_socket(tcp_socket, @ssl_context)
        else
          @socket = tcp_socket
        end
      rescue StandardError
        Rails.logger.warn("[MQTT RAILS][WARNING] Could not open a socket with #{@host} on port #{@port}.")
      end
    end

    def encrypted_socket(tcp_socket, ssl_context)
      unless ssl_context.nil?
        @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
        @socket.sync_close = true
        @socket.connect
      else
        Rails.logger.error("[MQTT RAILS][ERROR] The SSL context was found as nil while the socket's opening.")
        raise Exception
      end
    end

    def clean_start(host, port)
      self.host = host
      self.port = port
      unless @socket.nil?
        @socket.close unless @socket.closed?
        @socket = nil
      end
    end

    def host=(host)
      if host.nil? || host == ""
        Rails.logger.error("[MQTT RAILS][ERROR] The host was found as nil while the connection setup.")
        raise ArgumentError
      else
        @host = host
      end
    end

    def port=(port)
      if port.to_i <= 0
        Rails.logger.error("[MQTT RAILS][ERROR] The port value is invalid (<= 0). Could not setup the connection.")
        raise ArgumentError
      else
        @port = port
      end
    end

    def send_connect(session_params)
      setup_connection
      packet = MqttRails::Packet::Connect.new(session_params)
      @handler.clean_session = session_params[:clean_session]
      @sender.send_packet(packet)
      MQTT_ERR_SUCCESS
    end

    def send_disconnect
      packet = MqttRails::Packet::Disconnect.new
      @sender.send_packet(packet)
      MQTT_ERR_SUCCESS
    end

    # Would return 'true' if ping requset should be sent and  'nil' if not
    def should_send_ping?(now, keep_alive, last_packet_received_at)
      last_pingreq_sent_at = @sender.last_pingreq_sent_at
      last_pingresp_received_at = @handler.last_pingresp_received_at
      if !last_pingreq_sent_at || (last_pingresp_received_at && (last_pingreq_sent_at <= last_pingresp_received_at))
        next_pingreq_at = [@sender.last_packet_sent_at, last_packet_received_at].min + (keep_alive * 0.7).ceil
        return next_pingreq_at <= now
      end
    end

    def check_keep_alive(persistent, keep_alive)
      now = Time.now
      last_packet_received_at = @handler.last_packet_received_at
      # send a PINGREQ only if we don't already wait for a PINGRESP
      if persistent && should_send_ping?(now, keep_alive, last_packet_received_at)
        Rails.logger.info("[MQTT RAILS][INFO] Checking if server is still alive...")
        @sender.send_pingreq
      end
      disconnect_timeout_at = last_packet_received_at + (keep_alive * 1.1).ceil
      if disconnect_timeout_at <= now
        Rails.logger.info("[MQTT RAILS][INFO] No activity is over timeout, disconnecting from #{@host}.")
        @cs = MQTT_CS_DISCONNECT
      end
      @cs
    end
  end
end
