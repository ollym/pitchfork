require 'test_helper'

module Pitchfork
  class IntegrationTest < Minitest::Test
    ROOT = File.expand_path('../', __dir__)
    BIN = File.join(ROOT, 'exe/pitchfork')
    def setup
      super

      @_old_pwd = Dir.pwd
      @_pids = []
      @pwd = Dir.mktmpdir('pitchfork')
      Dir.chdir(@pwd)
    end

    def teardown
      pids = @_pids.select do |pid|
        Process.kill('INT', pid)
        true
      rescue Errno::ESRCH
        false
      end

      pids.reject! do |pid|
        Process.wait(pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::ECHILD
        true
      end

      unless pids.empty?
        sleep 0.2
      end

      pids.reject! do |pid|
        Process.wait(pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::ECHILD
        true
      end

      pids.reject! do |pid|
        Process.kill('KILL', pid)
        false
      rescue Errno::ESRCH
        true
      end

      pids.each do |pid|
        Process.wait(pid)
      end

      Dir.chdir(@_old_pwd)
      if passed?
        FileUtils.rm_rf(@pwd)
      else
        $stderr.puts("Working directory left at: #{@pwd}")
      end

      super
    end

    def unused_port
      default_port = 8080
      addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
      retries = 100
      base = 5000
      port = sock = lock_path = nil

      begin
        begin
          port = base + rand(32768 - base)
          while port == default_port
            port = base + rand(32768 - base)
          end

          sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
          sock.bind(Socket.pack_sockaddr_in(port, addr))
          sock.listen(5)
        rescue Errno::EADDRINUSE, Errno::EACCES
          sock.close rescue nil
          retry if (retries -= 1) >= 0
        end

        # since we'll end up closing the random port we just got, there's a race
        # condition could allow the random port we just chose to reselect itself
        # when running tests in parallel with gmake.  Create a lock file while
        # we have the port here to ensure that does not happen.
        lock_path = "#{Dir::tmpdir}/unicorn_test.#{addr}:#{port}.lock"
        _ = File.open(lock_path, File::WRONLY|File::CREAT|File::EXCL, 0600)
      rescue Errno::EEXIST
        sock.close rescue nil
        retry
      end
      sock.close rescue nil
      [addr, port]
    end

    private

    def assert_stderr(pattern, timeout: 1)
      print_stderr_on_error do
        wait_stderr?(pattern, timeout)
        assert_match(pattern, read_stderr)
      end
    end

    def read_stderr
      # We have to strip because file truncation is not always atomic.
      File.read("stderr.log").strip
    end

    def wait_stderr?(pattern, timeout)
      pattern = Regexp.new(Regexp.escape(pattern)) if String === pattern
      (timeout * 10).times do
        return true if pattern.match?(read_stderr)
        sleep 0.1
      end
      false
    end

    def assert_clean_shutdown(pid, timeout: 4)
      print_stderr_on_error do
        Process.kill("QUIT", pid)
        status = nil
        (timeout * 2).times do
          Process.kill(0, pid)
          break if status = Process.wait2(pid, Process::WNOHANG)
          sleep 0.5
        end
        assert status, "process pid=#{pid} didn't exit in #{timeout} seconds"
        assert_predicate status[1], :success?
      end
    end

    def assert_exited(pid, exitstatus, timeout: 4)
      print_stderr_on_error do
        status = nil
        (timeout * 2).times do
          break if status = Process.wait2(pid, Process::WNOHANG)
          sleep 0.5
        end
        assert status, "process pid=#{pid} didn't exit in #{timeout} seconds"
        assert_equal exitstatus, status[1].exitstatus
      end
    end

    def assert_healthy(host, timeout = 2)
      assert wait_healthy?(host, timeout), "Expected server to be healthy but it wasn't"
    end

    def wait_healthy?(host, timeout)
      (timeout * 10).times do
        return true if healthy?(host)
        sleep 0.1
      end
      false
    end

    def healthy?(url)
      http_get(url)
      true
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, EOFError
      false
    end

    def http_get(url)
      uri = URI(url)
      http = Net::HTTP.start(uri.host, uri.port)
      http.max_retries = 0

      path_info = uri.path.empty? ? "/" : uri.path
      if uri.query
        path_info = "#{path_info}?#{uri.query}"
      end
      http.get(path_info)
    end

    def spawn_server(*args, app:, config:, lint: true)
      File.write("pitchfork.conf.rb", config)
      env = lint ? { "RACK_ENV" => "development" } : {}
      spawn(env, BIN, app, "-c", "pitchfork.conf.rb", *args)
    end

    def spawn(*args)
      pid = Process.spawn(*args, out: "stdout.log", err: "stderr.log")
      @_pids << pid
      pid
    end

    def print_stderr_on_error
      yield
    rescue Minitest::Assertion
      puts '=' * 40
      puts read_stderr
      puts '=' * 40
      raise
    end
  end
end
