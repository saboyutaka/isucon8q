class Connection
  attr_reader :worker_id, :redis
  def initialize(name: nil, &block)
    @worker_id = name || random_id
    @workers = {}
    @redis = Redis.new host: ENV['REDIS_HOST'] || 'localhost'
    @publish_queue = Queue.new
    @inbox = {}
    Thread.new { run_ping }.report_on_exception = true
    Thread.new { run_ping_receive }.report_on_exception = true
    Thread.new { run_receive(&block) }.report_on_exception = true
    Thread.new { run_async_publish }.report_on_exception = true
  end

  def random_id
    rand(0xffffffff).to_s(16)
  end

  def async_publish channel, data
    @publish_queue << [channel, data]
    nil
  end

  def run_async_publish
    loop do
      channel, data = @publish_queue.deq
      @redis.publish channel, data rescue nil
    end
  end

  def run_ping_receive
    subscribe 'ping' do |_, worker_id|
      time = Time.now
      @workers[worker_id] = time
      @workers = @workers.select { |_, t| t > time - 3 }
    end
  rescue StandardError => e
    puts e
    sleep 1
    retry
  end

  def live_workers
    time = Time.now - 3
    @workers.map { |id, t| id if time < t }.compact
  end

  def run_ping
    loop do
      @redis.publish 'ping', @worker_id rescue nil
      sleep 1
    end
  end

  def run_receive
    subscribe 'data', @worker_id do |type, data|
      if type == 'data'
        message, from, msg_id, include_self = Oj.load data
        next if !include_self && from == @worker_id
        response = yield message, from, !!msg_id
        next if msg_id.nil?
        @redis.publish from, Oj.dump([response, @worker_id, msg_id, true]) if msg_id
      else
        message, from, msg_id, is_reply = Oj.load data
        if is_reply
          box = @inbox[msg_id]
          box << [from, message] if box
        else
          response = yield message, from, !!msg_id
          @redis.publish from, Oj.dump([response, @worker_id, msg_id, true]) if msg_id
        end
      end
    end
  rescue StandardError => e
    puts e
    sleep 1
    retry
  end

  def subscribe *keys
    Redis.new(host: ENV['REDIS_HOST'] || 'localhost').subscribe(*keys) do |on|
      on.message do |key, message|
        yield key, message
      end
    end
  end

  def send message, to:
    async_publish to, Oj.dump([message, @worker_id, nil, false])
  end

  def send_with_ack message, to:, timeout: 5
    msg_id = random_id
    queue = Queue.new
    @inbox[msg_id] = queue
    @redis.publish to, Oj.dump([message, @worker_id, msg_id, false])
    Timeout.timeout timeout do
      queue.deq.last
    end rescue nil
  ensure
    @inbox.delete msg_id
  end

  def broadcast message, include_self: true
    async_publish 'data', Oj.dump([message, @worker_id, nil, include_self])
  end

  def broadcast_with_ack message, timeout: 5, include_self: true
    msg_id = random_id
    queue = Queue.new
    @inbox[msg_id] = queue
    @redis.publish 'data', Oj.dump([message, @worker_id, msg_id, include_self])
    output = []
    Timeout.timeout timeout do
      count = include_self ? live_workers.size : live_workers.size - 1
      count.times { output << queue.deq }
    end rescue nil
    output.to_h
  ensure
    @inbox.delete msg_id
  end
end
