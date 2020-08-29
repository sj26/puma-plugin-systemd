bind ENV.fetch("PUMA_BIND", "tcp://127.0.0.1:9292")

unless ENV["PUMA_CONTROL"] == "false"
  activate_control_app ENV.fetch("PUMA_CONTROL", "tcp://127.0.0.1:9393")
end

if ENV.has_key?("PUMA_WORKERS") && ENV["PUMA_WORKERS"] != "false"
  workers ENV["PUMA_WORKERS"].to_i
end

max_threads = ENV.fetch("PUMA_MAX_THREADS", 2).to_i
min_threads = ENV.fetch("PUMA_MIN_THREADS") { max_threads }

threads min_threads, max_threads

plugin :systemd
