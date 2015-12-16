# encoding: utf-8

class Hash
  """
  each traverse in hash
  """
  def each_deep(&proc)
    self.each_deep_detail([], &proc)
  end

  def each_deep_detail(directory, &proc)
    self.each do |k, v|
      current = directory + [k]
      if v.kind_of?(Hash)
        v.each_deep_detail(current, &proc)
      else
        yield(current, v)
      end
    end
  end

end


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
      #unless @endpoint_url =~ /^#{URI.regexp}$/
      #  fail Fluent::ConfigError, 'endpoint_url invalid'
      #end

      #begin
      #  @uri = URI.parse(@endpoint_url)
      #rescue URI::InvalidURIError
      #  raise Fluent::ConfigError, 'endpoint_url invalid'
      #end

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

    def http_write(url,data)
      $log.debug "URL: #{url}"
      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError
        $log.warn "[http_write] Wrong formatted URI #{uri}"
        return
      end
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = @http_read_timeout
      http.open_timeout = @http_open_timeout
      request = create_request(uri,data)

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
        $log.info "Got HTTP client error #{e.message}, retry #{retry_count}"
        retry
      rescue IOError, EOFError, SystemCallError => e
        # server didn't respond
        $log.warn "Net::HTTP.#{request.method.capitalize} raises exception: #{e.class}, '#{e.message}'"
      ensure
        begin
          http.finish
          # Thread.current.exit
        rescue
        end
      end
    end
    
    def format_url(record)
      '''
      replace format string to value
      example
        /test/<data> =(use {data: 1})> /test/1
        /test/<hash.data> =(use {hash:{data:2}})> /test/2
      '''
      result_url = @endpoint_url
      record.each_deep do |key_dir, value|
        result_url = result_url.gsub(/<#{key_dir.join(".")}>/, value.to_s)
      end
      return result_url

    end
    
    def write(chunk)
      urlObjs = {}
      threads = []
      chunk.msgpack_each do |(tag, time, record)|
        # get buffer
        url = format_url(record)
        if urlObjs.include? url
          urlObj = urlObjs[url]
        else
          urlObj = {}
          urlObj['buf']=[]
          urlObj['data']=[]
          urlObjs[url]=urlObj
        end

        urlObj['buf'] << record
        if urlObj['buf'].length >= @http_event_limit  # reached max events per HTTP request
          urlObj['data'] << urlObj['buf']
          small_chunk_index = urlObj['data'].length-1 
          threads << Thread.new { http_write(url,urlObj['data'][small_chunk_index]) }
          urlObj['buf'] = []
        end
      end

      urlObjs.each { |url,urlObj|
        if urlObj['buf'].length > 0
          threads << Thread.new { http_write(url,urlObj['buf']) }
        end
      }
            
      threads.each { |thr| thr.join }

      $log.debug "Wrote chunk size #{chunk.size} with #{threads.length} threads"

    end

    protected
    def create_request(uri,data)
      request = Net::HTTP.const_get(@http_method.to_s.capitalize).new(uri.request_uri)

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
