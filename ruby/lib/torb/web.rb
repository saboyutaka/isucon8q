require 'json'
require 'oj'
require 'sinatra/base'
require 'erubi'
require 'mysql2'
require 'mysql2-cs-bind'
require 'redis'
require_relative 'sheets'
require_relative 'redis_keys'
require_relative 'broadcast'

def redis
  @redis ||= Redis.new(host: ENV['REDIS_HOST'] || 'localhost')
end

def db
  Thread.current[:db] ||= new_db_connection
end
def new_db_connection
  Mysql2::Client.new(
    host: ENV['DB_HOST'],
    port: ENV['DB_PORT'],
    username: ENV['DB_USER'],
    password: ENV['DB_PASS'],
    database: ENV['DB_DATABASE'],
    database_timezone: :utc,
    cast_booleans: true,
    reconnect: true,
    init_command: 'SET SESSION sql_mode="STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"',
  )
end

def wait_for_db
  new_db_connection.close
rescue => e
  puts "waiting for db launch: #{e}"
  sleep 1
  retry
end

def wait_for_redis(host_option = {})
  redis = Redis.new host_option
  begin
    redis.get 'test'
  rescue => e
    puts "waiting for redis launch: #{e}"
    sleep 1
    retry
  end
  redis.close
end

wait_for_db
wait_for_redis host: ENV['REDIS_HOST'] || 'localhost'

def logs_add logs, id, time
  if a = logs.find{|i,_|i==id}
    a[1] = [a[1], time].max
  else
    logs << [id, time]
  end
  logs.sort_by!(&:last)
  logs.shift if logs.size > 5
end

CACHE_JSON_PATH = './initialize_data.json'
def load_cache
  return false unless File.exist? CACHE_JSON_PATH
  data = Oj.load File.read(CACHE_JSON_PATH)
  $user_cache = data[:user_cache]
  $event_cache = data[:event_cache]
  true
rescue => e
  p e
  p e.backtrace
end

def save_cache
  data = { user_cache: $user_cache, event_cache: $event_cache }
  File.write CACHE_JSON_PATH, Oj.dump(data)
rescue => e
  p e
  p e.backtrace
end

$conn = Connection.new do |message|
  type, data = message
  case type
  when :event
    if (cache = $event_cache[data['id']])
      cache[:data].update data
    else
      add_new_event_cache data
    end
  when :user
    $user_cache[data['id']] = data.merge total: 0, reserve_logs: [], event_logs: []
  when :reserve
    eid, sid, user_id, reservation_id, time, reserved = data
    rank = rank_by_sheet_id sid
    cache = $event_cache[eid]
    num = sid - {'S'=>0,'A'=>50,'B'=>200,'C'=>500}[rank]
    uc = $user_cache[user_id]
    logs_add uc[:reserve_logs], reservation_id, time
    logs_add uc[:event_logs], eid, time
    price = cache[:data]['price'] + SHEET_PRICES[rank]
    if reserved
      uc[:total] += price
      cache[:reserved_users][rank][sid] = user_id
      cache[:user_reserve_counts][rank][user_id] += 1
      sheet = cache[:detail][rank][num - 1]
      sheet['reserved_at'] = time
      sheet['reserved'] = true
    else
      uc[:total] -= price
      cache[:reserved_users][rank].delete sid
      cache[:user_reserve_counts][rank][user_id] -= 1
      sheet = cache[:detail][rank][num - 1] = { 'num' => num }
    end
  when :init
    if data || !load_cache
      init_cache
      save_cache
    end
  end
  :ok
end

def conn
  $conn
end

def rank_by_sheet_id sheet_id
  sheet_id <= 50 ? 'S' : sheet_id <= 200 ? 'A' : sheet_id <= 500 ? 'B' : 'C'
end

def add_new_event_cache event
  detail_cache = { 'S' => [], 'A' => [], 'B' => [], 'C' => [] }
  {'S'=>50,'A'=>150,'B'=>300,'C'=>500}.each do |r, n|
    detail_cache[r] = (1..n).map { |n| { 'num' => n } }
  end
  $event_cache[event['id']] = {
    data: event,
    reserved_users: { 'S' => {}, 'A' => {}, 'B' => {}, 'C' => {} },
    user_reserve_counts: { 'S' => Hash.new(0), 'A' => Hash.new(0), 'B' => Hash.new(0), 'C' => Hash.new(0) },
    detail: detail_cache
  }
end

def init_cache
  p :start_cache_initialize
  $user_cache = {}
  $event_cache = {}
  db.query('SELECT users.* FROM users').each do |user|
    $user_cache[user['id']] = user.merge total: 0, reserve_logs: [], event_logs: []
  end
  db.query('SELECT * FROM events').each do |event|
    event_id = event['id']
    event['public'] = event.delete 'public_fg'
    event['closed'] = event.delete 'closed_fg'
    event_cache = add_new_event_cache event
    reservation_cache = event_cache[:reserved_users]
    user_reserve_counts = event_cache[:user_reserve_counts]
    detail_cache = event_cache[:detail]
    db.xquery('SELECT sheet_id, user_id, reserved_at FROM reservations WHERE canceled_at IS NULL and event_id = ?', event_id).each do |res|
      sheet_id = res['sheet_id']
      user_id = res['user_id']
      reserved_at = res['reserved_at'].to_i
      rank = rank_by_sheet_id sheet_id
      reservation_cache[rank][sheet_id] = user_id
      user_reserve_counts[rank][user_id] += 1
      num = sheet_id - {'S'=>0,'A'=>50,'B'=>200,'C'=>500}[rank]
      detail_cache[rank][num - 1] = { 'num' => num, 'reserved' => true, 'reserved_at' => reserved_at }
      $user_cache[user_id][:total] += event['price'] + SHEET_PRICES[rank] if res['canceled_at'].nil?
    end
    db.xquery("SELECT id, user_id, reserved_at, canceled_at FROM reservations WHERE event_id = #{event_id.to_s}", as: :array).each do |id, user_id, reserved_at, canceled_at|
      uc = $user_cache[user_id]
      time = [reserved_at, canceled_at].compact.map(&:to_i).max
      logs_add uc[:reserve_logs], id, time
      logs_add uc[:event_logs], event_id, time
    end
  end
  p :end_cache_initialize
end
def init_redis_reservation
  p :start_redis_sheets_initialize
  redis.flushall
  db.query('SELECT id FROM events').each do |event|
    sheet_ids = db.xquery("SELECT sheet_id FROM reservations WHERE canceled_at IS NULL and event_id = #{event['id'].to_i}", as: :array).to_a.flatten
    s_ids = (1..50).to_a - sheet_ids
    a_ids = (51..200).to_a - sheet_ids
    b_ids = (201..500).to_a - sheet_ids
    c_ids = (501..1000).to_a - sheet_ids
    redis.sadd "sheets_#{event['id']}_S", s_ids unless s_ids.empty?
    redis.sadd "sheets_#{event['id']}_A", a_ids unless a_ids.empty?
    redis.sadd "sheets_#{event['id']}_B", b_ids unless b_ids.empty?
    redis.sadd "sheets_#{event['id']}_C", c_ids unless c_ids.empty?
  end
  p :end_redis_sheets_initialize
end

Thread.new { init_redis_reservation; init_cache }.join

ENV['RACK_ENV']='production'
module Torb
  class Web < Sinatra::Base
    configure :development do
      # require 'sinatra/reloader'
      # register Sinatra::Reloader
      # require 'rack-lineprof'
      # use Rack::Lineprof, profile: 'web.rb'
      enable :logging
    end

    set :root, File.expand_path('../..', __dir__)
    set :sessions, key: 'torb_session', expire_after: 3600
    set :session_secret, 'tagomoris'
    set :protection, frame_options: :deny

    set :erb, escape_html: true

    set :login_required, ->(value) do
      condition do
        if value && !get_login_user
          halt_with_error 401, 'login_required'
        end
      end
    end

    set :admin_login_required, ->(value) do
      condition do
        if value && !get_login_administrator
          halt_with_error 401, 'admin_login_required'
        end
      end
    end

    before '/api/*|/admin/api/*' do
      content_type :json
    end

    helpers do

      def get_events(where = nil)
        where ||= ->(e) { e['public'] }
        event_ids = $event_cache.values.map { |a| a[:data] }.select(&where).map { |e| e['id'] }
        event_ids.map do |event_id|
          get_event_data_with_remain_sheets(event_id)
        end
      end

      def get_only_event_data(event_id)
        $event_cache[event_id.to_i]&.[] :data
        # event = db.xquery('SELECT id, title, public_fg as public, closed_fg as closed, price FROM events WHERE id = ?', event_id).first
        # return unless event
        #
        # event
      end

      def get_event_data_with_remain_sheets(event_id)
        cached = $event_cache[event_id]
        return unless cached
        event = cached[:data].dup
        reservations = cached[:reserved_users]

        event['total']   = 1000
        event['remains'] = 1000 - reservations.values.map(&:size).sum
        event['sheets'] = {
          'S' => { 'total' => 50, 'remains' => 50 - reservations['S'].size, 'price' => event['price'] + 5000},
          'A' => { 'total' => 150, 'remains' => 150 - reservations['A'].size, 'price' => event['price'] + 3000},
          'B' => { 'total' => 300, 'remains' => 300 - reservations['B'].size, 'price' => event['price'] + 1000},
          'C' => { 'total' => 500, 'remains' => 500 - reservations['C'].size, 'price' => event['price']}
        }
        event
      end

      def get_event(event_id, login_user_id = nil)
        event_id = event_id.to_i
        cache = $event_cache[event_id]
        # event = db.xquery('SELECT * FROM events WHERE id = ?', event_id).first
        return unless cache
        event = cache[:data].dup
        reservations = cache[:reserved_users]
        event['total']   = 1000
        event['remains'] = 1000 - reservations.values.map(&:size).sum
        event_sheets = event['sheets'] = {
          'S' => { 'total' => 50, 'remains' => 50 - reservations['S'].size, 'detail' => [], 'price' => event['price'] + 5000},
          'A' => { 'total' => 150, 'remains' => 150 - reservations['A'].size, 'detail' => [], 'price' => event['price'] + 3000},
          'B' => { 'total' => 300, 'remains' => 300 - reservations['B'].size, 'detail' => [], 'price' => event['price'] + 1000},
          'C' => { 'total' => 500, 'remains' => 500 - reservations['C'].size, 'detail' => [], 'price' => event['price']}
        }

        event_sheets.each do |rank, sheet|
          if cache[:user_reserve_counts][rank][login_user_id] == 0
            event_sheets[rank]['detail'] = cache[:detail][rank]
            next
          end
          id_offset = {'S'=>0,'A'=>50,'B'=>200,'C'=>500}[rank]
          reserved_user_set = reservations[rank]
          event_sheets[rank]['detail'] = cache[:detail][rank].map do |sheet|
            next sheet unless sheet['reserved'] && reserved_user_set[sheet['num']+id_offset] == login_user_id
            sheet.merge 'mine' => true
          end
        end
        event
      end

      def sanitize_event(event)
        sanitized = event.dup  # shallow clone
        sanitized.delete('price')
        sanitized.delete('public')
        sanitized.delete('closed')
        sanitized
      end

      def get_login_user
        user_id = session[:user_id]
        return unless user_id
        $user_cache[user_id.to_i]&.slice 'id', 'nickname'
      end

      def get_login_administrator
        administrator_id = session['administrator_id']
        return unless administrator_id
        db.xquery('SELECT id, nickname FROM administrators WHERE id = ?', administrator_id).first
      end

      def validate_rank(rank)
        %w[S A B C].include? rank
      end

      def body_params
        @body_params ||= JSON.parse(request.body.tap(&:rewind).read)
      end

      def halt_with_error(status = 500, error = 'unknown')
        halt status, Oj.to_json({ error: error })
      end

      def render_report_csv(reports)
        reports = reports.sort_by { |report| report[:sold_at] }

        keys = %i[reservation_id event_id rank num price user_id sold_at canceled_at]
        body = keys.join(',')
        body << "\n"
        reports.each do |report|
          body << report.values_at(*keys).join(',')
          body << "\n"
        end

        headers({
          'Content-Type'        => 'text/csv; charset=UTF-8',
          'Content-Disposition' => 'attachment; filename="report.csv"',
        })
        body
      end
    end

    get '/' do
      @user   = get_login_user
      @events = get_events.map(&method(:sanitize_event))
      erb :index
    end

    get '/initialize' do # /initialize?generate=true to re-generate initialize_data.json
      system "../db/init.sh"
      conn.broadcast_with_ack [:init, !!params[:generate]], timeout: 9
      init_redis_reservation
      status 204
    end

    post '/api/users' do
      nickname   = body_params['nickname']
      login_name = body_params['login_name']
      password   = body_params['password']

      db.query('BEGIN')
      begin
        duplicated = db.xquery('SELECT * FROM users WHERE login_name = ?', login_name).first
        if duplicated
          db.query('ROLLBACK')
          halt_with_error 409, 'duplicated'
        end

        db.xquery('INSERT INTO users (login_name, pass_hash, nickname) VALUES (?, SHA2(?, 256), ?)', login_name, password, nickname)
        user_id = db.last_id
        db.query('COMMIT')
        conn.broadcast_with_ack [:user, { 'id' => user_id, 'login_name' => login_name, 'password' => password, 'nickname' => nickname }]
      rescue => e
        warn "rollback by: #{e}"
        db.query('ROLLBACK')
        halt_with_error
      end

      status 201
      Oj.to_json({ id: user_id, nickname: nickname })
    end

    get '/api/users/:id', login_required: true do |user_id|
      user = get_login_user
      if user_id.to_i != user['id']
        halt_with_error 403, 'forbidden'
      end
      uc = $user_cache[user['id']]
      row_ids = uc[:reserve_logs].map(&:first)
      rows = row_ids.empty? ? [] : db.xquery('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id WHERE r.id in (?) ORDER BY IFNULL(r.canceled_at, r.reserved_at) DESC LIMIT 5', row_ids)
      recent_reservations = rows.map do |row|
        event = get_only_event_data(row['event_id'])
        price = event['price'] + SHEET_PRICES[row['sheet_rank']]

        {
          id:          row['id'],
          event:       event,
          sheet_rank:  row['sheet_rank'],
          sheet_num:   row['sheet_num'],
          price:       price,
          reserved_at: row['reserved_at'].to_i,
          canceled_at: row['canceled_at']&.to_i,
        }
      end

      user['recent_reservations'] = recent_reservations
      user['total_price'] = uc[:total]

      row_ids = uc[:event_logs].map(&:first).reverse
      p uc
      recent_events = row_ids.map do |id|
        get_event_data_with_remain_sheets id
      end
      user['recent_events'] = recent_events

      Oj.to_json user
    end


    post '/api/actions/login' do
      login_name = body_params['login_name']
      password   = body_params['password']

      user      = db.xquery('SELECT * FROM users WHERE login_name = ?', login_name).first
      pass_hash = db.xquery('SELECT SHA2(?, 256) AS pass_hash', password).first['pass_hash']
      halt_with_error 401, 'authentication_failed' if user.nil? || pass_hash != user['pass_hash']

      session['user_id'] = user['id']

      user = get_login_user
      Oj.to_json user
    end

    post '/api/actions/logout', login_required: true do
      session.delete('user_id')
      status 204
    end

    get '/api/events' do
      events = get_events.map(&method(:sanitize_event))
      Oj.to_json events
    end

    get '/api/events/:id' do |event_id|
      user = get_login_user || {}
      event = get_event(event_id, user['id'])
      halt_with_error 404, 'not_found' if event.nil? || !event['public']

      event = sanitize_event(event)
      Oj.to_json event
    end

    post '/api/events/:id/actions/reserve', login_required: true do |event_id|
      rank = body_params['sheet_rank']

      user  = get_login_user
      event = get_event(event_id, user['id'])
      halt_with_error 404, 'invalid_event' unless event && event['public']
      halt_with_error 400, 'invalid_rank' unless validate_rank(rank)

      sheet_id = redis.spop("sheets_#{event_id}_#{rank}")&.to_i
      halt_with_error 409, 'sold_out' unless sheet_id
      sheet_num = sheet_id - {'S'=>0,'A'=>50,'B'=>200,'C'=>500}[rank]
      time = Time.now
      db.xquery('INSERT INTO reservations (event_id, sheet_id, user_id, reserved_at) VALUES (?, ?, ?, ?)', event['id'], sheet_id, user['id'], time.utc.strftime('%F %T.%6N'))
      reservation_id = db.last_id
      conn.broadcast_with_ack [:reserve, [event['id'], sheet_id, user['id'], reservation_id, time.to_i, true]]
      status 202
      Oj.to_json({ id: reservation_id, sheet_rank: rank, sheet_num: sheet_num })
    end

    delete '/api/events/:id/sheets/:rank/:num/reservation', login_required: true do |event_id, rank, num|
      event_id = event_id.to_i
      user  = get_login_user
      event = get_event(event_id, user['id'])
      halt_with_error 404, 'invalid_event' unless event && event['public']
      halt_with_error 404, 'invalid_rank'  unless validate_rank(rank)
      sheet_offset = {'S' => 0, 'A' => 50, 'B' => 200, 'C' => 500 }[rank]
      sheet_id = sheet_offset + num.to_i
      halt_with_error 404, 'invalid_sheet' if sheet_id <= 0 || sheet_id > 1000 || rank_by_sheet_id(sheet_id) != rank
      reservation = db.xquery('select id, user_id from reservations WHERE event_id = ? AND sheet_id = ? AND canceled_at IS NULL', event_id, sheet_id).first
      unless reservation
        halt_with_error 400, 'not_reserved'
      end
      if reservation['user_id'] != user['id']
        halt_with_error 403, 'not_permitted'
      end

      time = Time.now
      db.xquery('UPDATE reservations SET canceled_at = ? WHERE id = ? AND canceled_at IS NULL', time.utc.strftime('%F %T.%6N'), reservation['id'])
      if db.affected_rows == 1
        redis.sadd "sheets_#{event['id']}_#{rank}", sheet_id
        conn.broadcast_with_ack [:reserve, [event['id'], sheet_id, reservation['user_id'], reservation['id'], time.to_i, false]]
      end

      status 204
    end

    get '/admin/' do
      @administrator = get_login_administrator
      @events = get_events(->(_) { true }) if @administrator

      erb :admin
    end

    post '/admin/api/actions/login' do
      login_name = body_params['login_name']
      password   = body_params['password']

      administrator = db.xquery('SELECT * FROM administrators WHERE login_name = ?', login_name).first
      pass_hash     = db.xquery('SELECT SHA2(?, 256) AS pass_hash', password).first['pass_hash']
      halt_with_error 401, 'authentication_failed' if administrator.nil? || pass_hash != administrator['pass_hash']

      session['administrator_id'] = administrator['id']

      administrator = get_login_administrator
      Oj.to_json administrator
    end

    post '/admin/api/actions/logout', admin_login_required: true do
      session.delete('administrator_id')
      status 204
    end

    get '/admin/api/events', admin_login_required: true do
      events = get_events(->(_) { true })
      Oj.to_json events
    end

    post '/admin/api/events', admin_login_required: true do
      title  = body_params['title']
      public = body_params['public'] || false
      price  = body_params['price']

      db.query('BEGIN')
      begin
        db.xquery('INSERT INTO events (title, public_fg, closed_fg, price) VALUES (?, ?, 0, ?)', title, public, price)
        event_id = db.last_id
        db.query('COMMIT')
        redis.multi do
          redis.sadd "sheets_#{event_id}_S", (1..50).to_a
          redis.sadd "sheets_#{event_id}_A", (51..200).to_a
          redis.sadd "sheets_#{event_id}_B", (201..500).to_a
          redis.sadd "sheets_#{event_id}_C", (501..1000).to_a
        end
        conn.broadcast_with_ack [:event, { 'id' => event_id, 'title' => title, 'public' => public, 'closed' => false, 'price' => price }]
      rescue => e
        db.query('ROLLBACK')
      end
      event = get_event(event_id)
      Oj.to_json event
    end

    get '/admin/api/events/:id', admin_login_required: true do |event_id|
      event = get_event(event_id)
      halt_with_error 404, 'not_found' unless event

      Oj.to_json event
    end

    post '/admin/api/events/:id/actions/edit', admin_login_required: true do |event_id|
      event_id = event_id.to_i
      public = body_params['public'] || false
      closed = body_params['closed'] || false
      public = false if closed

      event = get_event(event_id)
      halt_with_error 404, 'not_found' unless event

      if event['closed']
        halt_with_error 400, 'cannot_edit_closed_event'
      elsif event['public'] && closed
        halt_with_error 400, 'cannot_close_public_event'
      end

      db.query('BEGIN')
      begin
        db.xquery('UPDATE events SET public_fg = ?, closed_fg = ? WHERE id = ?', public, closed, event['id'])
        db.query('COMMIT')
        conn.broadcast_with_ack [:event, { 'id' => event_id, 'public' => public, 'closed' => closed }]
      rescue
        db.query('ROLLBACK')
      end

      event = get_event(event_id)
      Oj.to_json event
    end

    get '/admin/api/reports/events/:id/sales', admin_login_required: true do |event_id|
      event = get_event(event_id)

      reservations = db.xquery('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num, s.price AS sheet_price, e.price AS event_price FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id WHERE r.event_id = ? ORDER BY reserved_at ASC FOR UPDATE', event['id'])
      reports = reservations.map do |reservation|
        {
          reservation_id: reservation['id'],
          event_id:       event['id'],
          rank:           reservation['sheet_rank'],
          num:            reservation['sheet_num'],
          user_id:        reservation['user_id'],
          sold_at:        reservation['reserved_at'].iso8601,
          canceled_at:    reservation['canceled_at']&.iso8601 || '',
          price:          reservation['event_price'] + reservation['sheet_price'],
        }
      end

      render_report_csv(reports)
    end

    get '/admin/api/reports/sales', admin_login_required: true do
      reservations = db.query('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num, s.price AS sheet_price, e.id AS event_id, e.price AS event_price FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id ORDER BY reserved_at ASC FOR UPDATE')
      reports = reservations.map do |reservation|
        {
          reservation_id: reservation['id'],
          event_id:       reservation['event_id'],
          rank:           reservation['sheet_rank'],
          num:            reservation['sheet_num'],
          user_id:        reservation['user_id'],
          sold_at:        reservation['reserved_at'].iso8601,
          canceled_at:    reservation['canceled_at']&.iso8601 || '',
          price:          reservation['event_price'] + reservation['sheet_price'],
        }
      end

      render_report_csv(reports)
    end

    get '/redis/:key' do |key|
      redis.get(key)
    end
  end
end
