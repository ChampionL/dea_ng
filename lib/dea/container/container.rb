require "em/warden/client"
require "dea/container/connection"

module Dea
  class Container
    class ConnectionError < StandardError; end
    class BaseError < StandardError; end
    class WardenError < BaseError; end

    BIND_MOUNT_MODE_MAP = {
      "ro" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    attr_reader :socket_path, :path, :host_ip
    attr_accessor :handle

    def initialize(socket_path)
      @socket_path = socket_path
      @connections = {}
      @path = nil
    end

    def info
      request = ::Warden::Protocol::InfoRequest.new
      request.handle = @handle
      client.call(request)
    end

    def promise_update_path_and_ip
      Promise.new do |p|
        raise ArgumentError, "container handle must not be nil" unless @handle

        request = ::Warden::Protocol::InfoRequest.new(:handle => @handle)
        response = call(:info, request)

        raise RuntimeError, "container path is not available" unless response.container_path
        @path = response.container_path
        @host_ip = response.host_ip

        p.deliver(response)
      end
    end

    def find_connection(name)
      @connections[name]
    end

    def cache_connection(name, connection)
      @connections[name] = connection
    end

    def close_all_connections
      @connections.keys.each do |name|
        close_connection(name)
      end
    end

    def close_connection(name)
      if connection = @connections.delete(name)
        connection.close
      end
    end

    def get_connection(name)
      connection = find_connection(name)

      # Deliver cached connection if possible
      if connection && connection.connected?
        return connection
      else
        connection = Connection.new(name, socket_path)
        connection.promise_create.resolve
        cache_connection(name, connection) if connection
        return connection
      end
    end

    def call(name, request)
      connection = get_connection(name)
      connection.promise_call(request).resolve
    end

    def get_new_warden_net_in
      request = ::Warden::Protocol::NetInRequest.new
      request.handle = handle
      call(:app, request)
    end

    def call_with_retry(name, request)
      count = 0
      response = nil

      begin
        response = call(name, request)
      rescue ::EM::Warden::Client::ConnectionError => error
        count += 1
        logger.warn("Request failed: #{request.inspect}, retrying ##{count}.")
        logger.log_exception(error)
        retry
      end

      if count > 0
        logger.debug("Request succeeded after #{count} retries: #{request.inspect}")
      end
      response
    end

    def promise_run_script(name, script, privileged=false)
      Promise.new do |promise|
        request = ::Warden::Protocol::RunRequest.new
        request.handle = handle
        request.script = script
        request.privileged = privileged

        response = call(name, request)
        if response.exit_status > 0
          data = {
            :script      => script,
            :exit_status => response.exit_status,
            :stdout      => response.stdout,
            :stderr      => response.stderr,
          }
          logger.warn("%s exited with status %d" % [script.inspect, response.exit_status], data)
          promise.fail(WardenError.new("Script exited with status #{response.exit_status}"))
        else
          promise.deliver(response)
        end
      end
    end

    def promise_spawn(script, nproc_limit, file_descriptor_limit)
      Promise.new do |promise|
        request = ::Warden::Protocol::SpawnRequest.new
        request.rlimits = ::Warden::Protocol::ResourceLimits.new
        request.handle = handle
        request.rlimits.nproc = nproc_limit
        request.rlimits.nofile = file_descriptor_limit
        request.script = script
        response = call(:app, request)
        promise.deliver(response)
      end
    end

    def promise_create_container(bind_mounts)
      Promise.new do |p|
        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = bind_mounts.map do |bm|

          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new

          bind_mount.src_path = bm["src_path"]
          bind_mount.dst_path = bm["dst_path"] || bm["src_path"]

          mode = bm["mode"] || "ro"
          bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]
          bind_mount
        end

        response = call(:app, create_request)
        self.handle = response.handle
        p.deliver
      end
    end

    private

    def client
      @client ||=
        EventMachine::Warden::FiberAwareClient.new(@socket_path).tap(&:connect)
    end
  end
end