# coding: utf-8, frozen_string_literal: true

require "json"
require "puma"
require "puma/plugin"

# Puma systemd plugin
#
# Uses systemd notify to let systemd know a little about what puma is doing, so
# you know when your system has *actually* started and is ready to take
# requests.
#
class Puma::Plugin::Systemd
  Puma::Plugins.register("systemd", self)

  # Puma creates the plugin when encountering `plugin` in the config.
  # Puma 5 removed the parameter as it was unused within the plugin
  def initialize(loader = nil)
    # This is a Puma::PluginLoader
    @loader = loader if loader
  end

  # We can start doing something when we have a launcher:
  def start(launcher)
    @launcher = launcher

    # Log relevant ENV in debug
    @launcher.events.debug "systemd: NOTIFY_SOCKET=#{ENV["NOTIFY_SOCKET"].inspect}"
    @launcher.events.debug "systemd: WATCHDOG_PID=#{ENV["WATCHDOG_PID"].inspect}"
    @launcher.events.debug "systemd: WATCHDOG_USEC=#{ENV["WATCHDOG_USEC"].inspect}"

    # Only install hooks if the system is booted by systemd, and systemd has
    # asked us to notify it of events.
    @systemd = Systemd.new
    if @systemd.booted? && @systemd.notify?
      @launcher.events.debug "systemd: detected running inside systemd, registering hooks"

      register_hooks

      # In clustered mode, we can start the status loop early and watch the
      # workers boot
      start_status_loop_thread if clustered?

      start_watchdog_loop_thread if @systemd.watchdog?
    else
      @launcher.events.debug "systemd: not running within systemd, doing nothing"
    end
  end

  private

  # Are we a single process worker, or do we have worker processes?
  #
  # Copied from puma, it's private:
  # https://github.com/puma/puma/blob/v3.6.0/lib/puma/launcher.rb#L267-L269
  #
  def clustered?
    (@launcher.options[:workers] || 0) > 0
  end

  def register_hooks
    @launcher.events.on_booted(&method(:booted))
    (@launcher.config.options[:on_restart] ||= []) << method(:restart)
  end

  def booted
    @launcher.events.log "* systemd: notify ready"
    begin
      @systemd.notify_ready
    rescue
      @launcher.events.error "! systemd: notify ready failed:\n  #{$!.to_s}\n  #{$!.backtrace.join("\n    ")}"
    end

    # In single mode, we can only start the status loop once the server is
    # started after booted
    start_status_loop_thread
  end

  def restart(launcher)
    @launcher.events.log "* systemd: notify reloading"
    begin
      @systemd.notify_reloading
    rescue
      @launcher.events.error "! systemd: notify reloading failed:\n  #{$!.to_s}\n  #{$!.backtrace.join("\n    ")}"
    end
  end

  def fetch_stats
    # In Puma < 5, the stats are JSON string
    # In Puma 5, the stats are already a hash
    if @launcher.stats.is_a?(String)
      JSON.parse(@launcher.stats)
    else
      @launcher.stats
    end
  end

  def status
    Status.new(fetch_stats)
  end

  # Update systemd status event second or so
  def status_loop
    loop do
      @launcher.events.debug "systemd: notify status"
      begin
        @systemd.notify_status(status.to_s)
      rescue
        @launcher.events.error "! systemd: notify status failed:\n  #{$!.to_s}\n  #{$!.backtrace.join("\n    ")}"
      ensure
        sleep 1
      end
    end
  end

  def start_status_loop_thread
    # This is basically what Puma::Plugins.add_background / fire_background
    # does, but at a time of our choosing.
    @status_loop_thread ||= Thread.new(&method(:status_loop))
  end

  # If watchdog is configured we'll send a ping at about half the timeout
  # configured in systemd as recommended in the docs.
  def watchdog_loop
    @launcher.events.log "* systemd: watchdog detected (#{@systemd.watchdog_usec}usec)"

    # Ruby wants seconds, and the docs suggest notifying halfway through the
    # timeout.
    sleep_seconds = @systemd.watchdog_usec / 1000.0 / 1000.0 / 2.0

    loop do
      begin
        @launcher.events.debug "systemd: notify watchdog"
        @systemd.notify_watchdog
      rescue
        @launcher.events.error "! systemd: notify watchdog failed:\n  #{$!.to_s}\n  #{$!.backtrace.join("\n    ")}"
      ensure
        @launcher.events.debug "systemd: sleeping #{sleep_seconds}s"
        sleep sleep_seconds
      end
    end
  end

  def start_watchdog_loop_thread
    @watchdog_loop_thread ||= Thread.new(&method(:watchdog_loop))
  end

  # Give us a way to talk to systemd.
  #
  # It'd be great to use systemd-notify for the whole shebang, but there's a
  # critical error introducing a race condition:
  #
  #   https://github.com/systemd/systemd/issues/2739
  #
  # systemd-notify docs:
  #
  #   https://www.freedesktop.org/software/systemd/man/systemd-notify.html
  #
  # We could use sd-daemon (sd_notify and friends) but they require a C
  # extension, and are really just fancy wrappers for blatting datagrams at a
  # socket advertised via ENV. See the docs:
  #
  #   https://www.freedesktop.org/software/systemd/man/sd-daemon.html
  #
  class Systemd
    # Is the system currently booted with systemd?
    #
    # See also sd_booted:
    #
    #   https://www.freedesktop.org/software/systemd/man/sd_booted.html
    #
    def booted?
      File.directory?("/run/systemd/system/")
    end

    # Are we running within a systemd unit that expects us to notify?
    def notify?
      ENV.include?("NOTIFY_SOCKET")
    end

    # Open a persistent notify socket.
    #
    # Ruby doesn't have a nicer way to open a unix socket as a datagram.
    #
    private def notify_socket
      @notify_socket ||= Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM, 0).tap do |socket|
        socket.connect(Socket.pack_sockaddr_un(ENV["NOTIFY_SOCKET"]))
        socket.close_on_exec = true
      end
    end

    # Send a raw notify message.
    #
    #   https://www.freedesktop.org/software/systemd/man/sd_notify.html
    #
    private def notify(message)
      notify_socket.sendmsg(message, Socket::MSG_NOSIGNAL)
    end

    # Tell systemd we are now the main pid
    def notify_pid
      notify("MAINPID=#{$$}")
    end

    # Tell systemd we're fully started and ready to handle requests
    def notify_ready
      notify("READY=1")
    end

    # Tell systemd our status
    def notify_status(status)
      notify("STATUS=#{status}")
    end

    # Tell systemd we're restarting
    def notify_reloading
      notify("RELOADING=1")
    end

    # Tell systemd we're still alive
    def notify_watchdog
      notify("WATCHDOG=1")
    end

    # Has systemd asked us to watchdog?
    #
    # https://www.freedesktop.org/software/systemd/man/sd_watchdog_enabled.html
    #
    def watchdog?
      ENV.include?("WATCHDOG_USEC") &&
        (!ENV.include?("WATCHDOG_PID") || ENV["WATCHDOG_PID"].to_i == $$)
    end

    # How long between pings until the watchdog will think we're unhealthy?
    def watchdog_usec
      ENV["WATCHDOG_USEC"].to_i
    end
  end

  # Take puma's stats and construct a sensible status line for Systemd
  class Status
    def initialize(stats)
      @stats = stats
    end

    def clustered?
      @stats.has_key? "workers"
    end

    def workers
      @stats.fetch("workers", 1)
    end

    def booted_workers
      @stats.fetch("booted_workers", 1)
    end

    def running
      if clustered?
        @stats["worker_status"].map { |s| s["last_status"].fetch("running", 0) }.inject(0, &:+)
      else
        @stats.fetch("running", 0)
      end
    end

    def backlog
      if clustered?
        @stats["worker_status"].map { |s| s["last_status"].fetch("backlog", 0) }.inject(0, &:+)
      else
        @stats.fetch("backlog", 0)
      end
    end

    def pool_capacity
      if clustered?
        @stats["worker_status"].map { |s| s["last_status"].fetch("pool_capacity", 0) }.inject(0, &:+)
      else
        @stats.fetch("pool_capacity", 0)
      end
    end

    def max_threads
      if clustered?
        @stats["worker_status"].map { |s| s["last_status"].fetch("max_threads", 0) }.inject(0, &:+)
      else
        @stats.fetch("max_threads", 0)
      end
    end

    def to_s
      if clustered?
        "puma #{Puma::Const::VERSION} cluster: #{booted_workers}/#{workers} workers: #{running}/#{max_threads} threads, #{pool_capacity} available, #{backlog} backlog"
      else
        "puma #{Puma::Const::VERSION}: #{running}/#{max_threads} threads, #{pool_capacity} available, #{backlog} backlog"
      end
    end
  end
end
