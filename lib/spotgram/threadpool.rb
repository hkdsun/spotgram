class Threadpool
  def initialize(num_workers)
    @semaphore ||= Concurrent::Semaphore.new(num_workers)
  end

  def execute
    @semaphore.acquire
    Thread.new do
      begin
        yield
      ensure
        @semaphore.release
      end
    end
  end
end
