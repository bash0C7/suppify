require "benchmark"

N = 30

def interp_fib(n)
  a, b = 0, 1
  n.times { a, b = b, a + b }
  a
end

interp_result = interp_fib(N)
aot_result = fib(N)
raise "mismatch: interpreter=#{interp_result} aot=#{aot_result}" unless interp_result == aot_result

interp_time = Benchmark.realtime { interp_fib(N) }
aot_time = Benchmark.realtime { fib(N) }

puts "variant=iter n=#{N} result=#{aot_result}"
puts "interpreter: #{interp_time.round(4)}s"
puts "AOT:         #{aot_time.round(4)}s"
puts "speedup:     #{(interp_time / aot_time).round(1)}x"
