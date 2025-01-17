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

$conn = Connection.new do |message|
  type, data = message
  case type
  when :event
    (($event_cache[data['id']] ||= { reservations: {} })[:data] ||= {}).update data
  when :user
    $user_cache[data['id']] = data
  when :reserve
    eid, sid, payload = data
    if payload
      $event_cache[eid][:reservations][sid] = payload
    else
      $event_cache[eid][:reservations].delete sid
    end
  when :init
    init_cache
  end
  :ok
end

def conn
  $conn
end

def init_cache
  p :start_cache_initialize
  $user_cache = {}
  $event_cache = {}
  db.query('SELECT * FROM users').each do |user|
    $user_cache[user['id']] = user
  end
  db.query('SELECT * FROM events').each do |event|
    event['public'] = event.delete 'public_fg'
    event['closed'] = event.delete 'closed_fg'
    reservations_cache = {}
    $event_cache[event['id']] = { data: event, reservations: reservations_cache }
    db.xquery('SELECT sheet_id, user_id, reserved_at FROM reservations WHERE canceled_at IS NULL and event_id = ?', event['id']).each do |res|
      reservations_cache[res['sheet_id']] = [res['user_id'], res['reserved_at'].to_i]
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

init_redis_reservation
init_cache

module Torb
  class Web < Sinatra::Base
    configure :development do
      require 'sinatra/reloader'
      register Sinatra::Reloader
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

      def db
        Thread.current[:db] ||= Mysql2::Client.new(
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

      def get_events(where = nil)
        where ||= ->(e) { e['public'] }

        db.query('BEGIN')
        begin
          event_ids = $event_cache.values.map { |a| a[:data] }.select(&where).map { |e| e['id'] }
          events = event_ids.map do |event_id|
            get_event_data_with_remain_sheets(event_id)
          end
          db.query('COMMIT')
        rescue => e
          p e
          db.query('ROLLBACK')
        end

        events
      end

      def get_only_event_data(event_id)
        $event_cache[event_id.to_i]&.[] :data
        # event = db.xquery('SELECT id, title, public_fg as public, closed_fg as closed, price FROM events WHERE id = ?', event_id).first
        # return unless event
        #
        # event
      end

      def get_event_data_with_remain_sheets(event_id)
        event = db.xquery('SELECT id, title, public_fg as public, closed_fg as closed, price FROM events WHERE id = ?', event_id).first
        return unless event

        event['total']   = 1000
        event['remains'] = 0
        event['sheets'] = {
          'S' => { 'total' => 50, 'remains' => 0, 'price' => event['price'] + 5000},
          'A' => { 'total' => 150, 'remains' => 0, 'price' => event['price'] + 3000},
          'B' => { 'total' => 300, 'remains' => 0, 'price' => event['price'] + 1000},
          'C' => { 'total' => 500, 'remains' => 0, 'price' => event['price']}
        }

        remain_sheets_counts = %w(S A B C).map do |rank|
          key = event_remain_sheet_list(event_id, rank)
          [rank, redis.scard(key)]
        end.to_h

        remain_sheets_counts.each do |rank, remain_count|
          event['remains'] += remain_count
          event['sheets'][rank]['remains'] = remain_count
        end

        event
      end

      def get_event(event_id, login_user_id = nil)
        event = $event_cache[event_id.to_i]&.[] :data
        # event = db.xquery('SELECT * FROM events WHERE id = ?', event_id).first
        return unless event
        event = event.dup

        event['total']   = 1000
        event['remains'] = 0
        event['sheets'] = {
          'S' => { 'total' => 50, 'remains' => 0, 'detail' => [], 'price' => event['price'] + 5000},
          'A' => { 'total' => 150, 'remains' => 0, 'detail' => [], 'price' => event['price'] + 3000},
          'B' => { 'total' => 300, 'remains' => 0, 'detail' => [], 'price' => event['price'] + 1000},
          'C' => { 'total' => 500, 'remains' => 0, 'detail' => [], 'price' => event['price']}
        }
        # reservation_by_sheet_id = db.xquery('SELECT * FROM reservations WHERE event_id = ? AND canceled_at is null', event['id']).map { |e| [e['sheet_id'], e] }.to_h

        SHEETS.map(&:dup).each do |sheet|
          # reservation = reservation_by_sheet_id[sheet['id']]
          reservation = $event_cache[event_id.to_i][:reservations][sheet['id']]
          if reservation
            user_id, at = reservation
            sheet['mine']        = true if login_user_id == user_id
            sheet['reserved']    = true
            sheet['reserved_at'] = at
          else
            event['remains'] += 1
            event['sheets'][sheet['rank']]['remains'] += 1
          end
          event['sheets'][sheet['rank']]['detail'].push(sheet)
          sheet.delete('id')
          sheet.delete('price')
          sheet.delete('rank')
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
        db.xquery('SELECT id, nickname FROM users WHERE id = ?', user_id).first
      end

      def get_login_administrator
        administrator_id = session['administrator_id']
        return unless administrator_id
        db.xquery('SELECT id, nickname FROM administrators WHERE id = ?', administrator_id).first
      end

      def validate_rank(rank)
        db.xquery('SELECT COUNT(*) AS total_sheets FROM sheets WHERE `rank` = ?', rank).first['total_sheets'] > 0
      end

      def body_params
        @body_params ||= JSON.parse(request.body.tap(&:rewind).read)
      end

      def halt_with_error(status = 500, error = 'unknown')
        halt status, { error: error }.to_json
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

    get '/initialize' do
      system "../db/init.sh"
      conn.broadcast_with_ack :init
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
      { id: user_id, nickname: nickname }.to_json
    end

    get '/api/users/:id', login_required: true do |user_id|
      user = db.xquery('SELECT id, nickname FROM users WHERE id = ?', user_id).first
      if user['id'] != get_login_user['id']
        halt_with_error 403, 'forbidden'
      end

      rows = db.xquery('SELECT r.*, s.rank AS sheet_rank, s.num AS sheet_num FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id WHERE r.user_id = ? ORDER BY IFNULL(r.canceled_at, r.reserved_at) DESC LIMIT 5', user['id'])
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
      user['total_price'] = db.xquery('SELECT IFNULL(SUM(e.price + s.price), 0) AS total_price FROM reservations r INNER JOIN sheets s ON s.id = r.sheet_id INNER JOIN events e ON e.id = r.event_id WHERE r.user_id = ? AND r.canceled_at IS NULL', user['id']).first['total_price']

      rows = db.xquery('SELECT event_id FROM reservations WHERE user_id = ? GROUP BY event_id ORDER BY MAX(IFNULL(canceled_at, reserved_at)) DESC LIMIT 5', user['id'])
      recent_events = rows.map do |row|
        event = get_event_data_with_remain_sheets(row['event_id'])
        event
      end
      user['recent_events'] = recent_events

      user.to_json
    end


    post '/api/actions/login' do
      login_name = body_params['login_name']
      password   = body_params['password']

      user      = db.xquery('SELECT * FROM users WHERE login_name = ?', login_name).first
      pass_hash = db.xquery('SELECT SHA2(?, 256) AS pass_hash', password).first['pass_hash']
      halt_with_error 401, 'authentication_failed' if user.nil? || pass_hash != user['pass_hash']

      session['user_id'] = user['id']

      user = get_login_user
      user.to_json
    end

    post '/api/actions/logout', login_required: true do
      session.delete('user_id')
      status 204
    end

    get '/api/events' do
      events = get_events.map(&method(:sanitize_event))
      events.to_json
    end

    get '/api/events/:id' do |event_id|
      user = get_login_user || {}
      event = get_event(event_id, user['id'])
      halt_with_error 404, 'not_found' if event.nil? || !event['public']

      event = sanitize_event(event)
      event.to_json
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
      time = Time.now.utc.strftime('%F %T.%6N')
      db.xquery('INSERT INTO reservations (event_id, sheet_id, user_id, reserved_at) VALUES (?, ?, ?, ?)', event['id'], sheet_id, user['id'], time)
      reservation_id = db.last_id
      conn.broadcast_with_ack [:reserve, [event['id'], sheet_id, [user['id'], time.to_i]]]
      status 202
      { id: reservation_id, sheet_rank: rank, sheet_num: sheet_num } .to_json
    end

    delete '/api/events/:id/sheets/:rank/:num/reservation', login_required: true do |event_id, rank, num|
      user  = get_login_user
      event = get_event(event_id, user['id'])
      halt_with_error 404, 'invalid_event' unless event && event['public']
      halt_with_error 404, 'invalid_rank'  unless validate_rank(rank)

      sheet = db.xquery('SELECT * FROM sheets WHERE `rank` = ? AND num = ?', rank, num).first
      halt_with_error 404, 'invalid_sheet' unless sheet

      db.query('BEGIN')
      begin
        reservation = db.xquery('SELECT * FROM reservations WHERE event_id = ? AND sheet_id = ? AND canceled_at IS NULL GROUP BY event_id HAVING reserved_at = MIN(reserved_at) FOR UPDATE', event['id'], sheet['id']).first
        unless reservation
          db.query('ROLLBACK')
          halt_with_error 400, 'not_reserved'
        end
        if reservation['user_id'] != user['id']
          db.query('ROLLBACK')
          halt_with_error 403, 'not_permitted'
        end

        db.xquery('UPDATE reservations SET canceled_at = ? WHERE id = ?', Time.now.utc.strftime('%F %T.%6N'), reservation['id'])
        db.query('COMMIT')
        redis.sadd "sheets_#{event['id']}_#{rank}", sheet['id']
        conn.broadcast_with_ack [:reserve, [event['id'], sheet['id'], nil]]
      rescue => e
        warn "rollback by: #{e}"
        db.query('ROLLBACK')
        halt_with_error
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
      administrator.to_json
    end

    post '/admin/api/actions/logout', admin_login_required: true do
      session.delete('administrator_id')
      status 204
    end

    get '/admin/api/events', admin_login_required: true do
      events = get_events(->(_) { true })
      events.to_json
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
      event&.to_json
    end

    get '/admin/api/events/:id', admin_login_required: true do |event_id|
      event = get_event(event_id)
      halt_with_error 404, 'not_found' unless event

      event.to_json
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
      event.to_json
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
