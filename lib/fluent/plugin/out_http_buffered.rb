# encoding: utf-8

module Fluent
  # Main Output plugin class

  class HTTPretryException < StandardError
  end

  class HttpBufferedOutput < Fluent::TimeSlicedOutput
    Fluent::Plugin.register_output('http_buffered', self)

    def initialize
      super
      require 'net/http'
      require 'uri'
    end

    # Endpoint URL ex. localhost.local/api/
    config_param :endpoint_url, :string

    # http verb
    config_param :http_method, :string, :default => :post

    # max # of events per HTTP request 
    config_param :http_event_limit, :integer

    # max retries if HTTP request fail
    config_param :http_fail_retry, :integer, default: 10

    # statuses under which to retry
    config_param :http_retry_statuses, :string, default: ''

    # read timeout for the http call
    config_param :http_read_timeout, :float, default: 300.0

    # open timeout for the http call
    config_param :http_open_timeout, :float, default: 60.0

    # Addtional HTTP Header
    config_param :additional_headers, :string, :default=> nil

    def configure(conf)
      super

      # Check if endpoint URL is valid
      unless @endpoint_url =~ /^#{URI.regexp}$/
        fail Fluent::ConfigError, 'endpoint_url invalid'
      end

      begin
        @uri = URI.parse(@endpoint_url)
      rescue URI::InvalidURIError
        raise Fluent::ConfigError, 'endpoint_url invalid'
      end

      # Parse http statuses
      @statuses = @http_retry_statuses.split(',').map { |status| status.to_i }

      @statuses = [] if @statuses.nil?

      # Convert string to Hash (Header name => string)
      if @additional_headers
        @additional_headers = Hash[@additional_headers.split(",").map{ |f| f.split("=",2)}]
      end

      if not [:get,:post,:put,:delete].include? @http_method.intern
        raise Fluent::ConfigError, 'http method invalid'
      end

    end

    def start
      super
    end

    def shutdown
      super
      begin
        #@http.finish
      rescue
      end
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def http_write(data)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = (@uri.scheme == "https")
      http.read_timeout = @http_read_timeout
      http.open_timeout = @http_open_timeout
      request = create_request(data)

      retry_count = 0
      begin
        retry_count = retry_count+1
        if retry_count > @http_fail_retry
          fail "Retry too much times, abort"
        end
        response = http.start do |http|
          http.request request
        end

        if @statuses.include? response.code.to_i
          # Raise an exception so that fluent retries
          #fail "Server returned bad status: #{response.code}"
          raise HTTPretryException, "Server returned bad status: #{response.code}"
        end
      rescue HTTPretryException => e
        $log.warn "Got HTTP client error #{e.message}, retry #{retry_count}"
        retry
      rescue IOError, EOFError, SystemCallError => e
        # server didn't respond
        $log.warn "Net::HTTP.#{request.method.capitalize} raises exception: #{e.class}, '#{e.message}'"
      ensure
        begin
          http.finish
        rescue
        end
      end
    end

    def write(chunk)
      buf = []
      threads = []
      data = []
      chunk.msgpack_each do |(tag, time, record)|
        buf << record
        if buf.length >= @http_event_limit
          data << buf
          small_chunk_index = data.length-1 
          threads << Thread.new { http_write(data[small_chunk_index]) }
          buf = []
        end
      end

      if buf.length > 0
        threads << Thread.new { http_write(buf) }
      end
      threads.each { |thr| thr.join }

      $log.debug "Wrote chunk size #{chunk.size} with #{threads.length} threads"

    end

    protected
    def create_request(data)
      request = Net::HTTP.const_get(@http_method.to_s.capitalize).new(@uri.request_uri)

      # Headers
      request['Content-Type'] = 'application/json'
      if @additional_headers
        @additional_headers.each{|k,v|
          request[k] = v
        }
      end

      # Body
      request.body = JSON.dump(data)

      request
    end
  end # class
end # module
