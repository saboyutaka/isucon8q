require 'sinatra/base'
require 'erubis'

class App < Sinatra::Base
  session_secret = ENV['ISUCON_SESSION_SECRET'] || 'tonymoris'
  use Rack::Session::Cookie, key: 'rack.session', secret: session_secret
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../public', __FILE__)
  set :protection, true

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader

    require 'rack-mini-profiler'
    use Rack::MiniProfiler

    require 'rack-lineprof'
    use Rack::Lineprof, profile: 'app.rb'
  end

  get '/' do
    'HELLO'
  end
end
