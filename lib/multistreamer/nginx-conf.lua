return [[
worker_processes <%= worker_processes %>;
error_log stderr <%= log_level %>;
daemon off;
pid logs/nginx.pid;

env CONFIG_FILE;

events {
  worker_connections 1024;
}

http {
  lua_socket_log_errors off;

  resolver <%= dns_resolver %>;
  lua_ssl_trusted_certificate <%= ssl_trusted_certificate %>;
  lua_ssl_verify_depth <%= ssl_verify_depth %>;
  lua_shared_dict streams <%= lua_shared_dict_streams_size %>;
  lua_shared_dict writers <%= lua_shared_dict_writers_size %>;
  lua_shared_dict status 1m;

  types {
    text/html                             html htm shtml;
    text/css                              css;
    text/plain                            txt;

    application/x-javascript              js;

    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    image/png                             png;
    image/x-icon                          ico;
    image/svg+xml                         svg svgz;

    video/mp4                             mp4;
    application/vnd.apple.mpegurl         m3u8;
    video/mp2t                            ts;
  }

  init_by_lua_block {
    require'multistreamer.config'.loadconfig(os.getenv('CONFIG_FILE'))
    package.loaded['models'] = require'multistreamer.models'
  }

  init_worker_by_lua_block {
    networks = require('multistreamer.networks')
    uuid = require'resty.jit-uuid'
    chatmgr = require('multistreamer.chat_manager').new()
    processmgr = require('multistreamer.process_manager').new()
    uuid.seed(ngx.time() + ngx.worker.pid())
    ngx.timer.at(0,function()
      chatmgr:run()
    end)
    ngx.timer.at(0,function()
      processmgr:run()
    end)
  }

  server {
    <% for _,v in ipairs(http_listen) do %>
    listen <%= v %>;
    <% end %>
    lua_code_cache on;

    location / {
      default_type text/html;
      content_by_lua_block {
        require('lapis').serve('multistreamer.webapp')
      }
    }

    location <%= http_prefix %>/api/v1 {
      default_type application/json;
      content_by_lua_block {
        require('lapis').serve('multistreamer.api.v1')
      }
    }

    location ~ <%= http_prefix %>/static/(.*) {
      root <%= static_dir %>;
      try_files /local/$1 /static/$1 =404;
      log_not_found on;
    }

    location /favicon.ico {
      alias <%= static_dir %>/static/favicon.ico;
      log_not_found off;
      access_log off;
    }

    location /robots.txt {
      allow all;
      log_not_found off;
      access_log off;
    }

    location <%= http_prefix %>/video_raw {
      internal;
      log_not_found off;
      alias <%= work_dir %>/hls;
    }

    location <%= http_prefix %>/stats_raw {
        internal;
        rtmp_stat all;
    }
	# custom rtmp-stats starting    
    location <%= http_prefix %>/rtmpstats {
        rtmp_stat all;
        rtmp_stat_stylesheet stat.xsl;
#        auth_basic "Restricted";
#        auth_basic_user_file /opt/multistreamer/share/multistreamer/html/static/rtmp-stats/.htpasswd;
    }
    location /stat.xsl {
        root /opt/multistreamer/share/multistreamer/html/static/rtmp-stats;
    }
    location /control {
      rtmp_control all;
      add_header Access-Control-Allow-Origin * always;
    }
	# custom rtmp-stats ends
  }
}

rtmp_auto_push on;

rtmp {
  server {
    <% for _,v in ipairs(rtmp_listen) do %>
    listen <%= v %>;
    <% end %>
    chunk_size 4096;
    ping <%= ping %>;
    ping_timeout <%= ping_timeout %>;

    application <%= rtmp_prefix %> {
      live on;
      record off;
      meta on;
      idle_streams off;
      wait_video on;
      wait_key on;
      sync 10ms;
      notify_update_timeout 5s;

      on_publish <%= private_http_url .. http_prefix .. '/on-publish' %>;
      on_publish_done <%= private_http_url .. http_prefix .. '/on-done' %>;
      on_update <%= private_http_url .. http_prefix .. '/on-update' %>;

      hls on;
      hls_path <%= work_dir %>/hls;
      hls_nested on;
      hls_cleanup on;
      hls_continuous off;
      hls_fragment 10s;
      hls_playlist_length 60s;

    }
  }
}

stream {
  lua_socket_log_errors off;
  lua_code_cache on;
  lua_ssl_trusted_certificate <%= ssl_trusted_certificate %>;
  lua_ssl_verify_depth <%= ssl_verify_depth %>;
  resolver <%= dns_resolver %>;

  init_by_lua_block {
    require'multistreamer.config'.loadconfig(os.getenv('CONFIG_FILE'))
    package.loaded['models'] = require'multistreamer.models'
  }

  init_worker_by_lua_block {
    start_time = ngx.now()
    uuid = require'resty.jit-uuid'
    uuid.seed(ngx.time() + ngx.worker.pid() + <%= worker_processes %>)
    networks = require('multistreamer.networks')
    IRC = require('multistreamer.irc.state').new()
    ngx.timer.at(0,function()
      while true do
        local irc_thread = ngx.thread.spawn(function()
          IRC:run()
        end)
        ngx.thread.wait(irc_thread)
        ngx.sleep(5)
      end
    end)
  }
  server {
    <% for _,v in ipairs(irc_listen) do %>
    listen <%= v %>;
    <% end %>
    content_by_lua_block {
      local IRC = IRC
      local IRCServer = require'multistreamer.irc.server'
      local sock, err = ngx.req.socket(true)
      if err then ngx.exit(ngx.OK) end
      if not IRC:isReady() then ngx.exit(ngx.OK) end

      local ok, user = IRCServer.startClient(sock)
      if ok then
        local server = IRCServer.new(sock,user,IRC)
        server:run()
      end
    }
  }
}
]]
