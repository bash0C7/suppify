require "benchmark"

N = 30

def interp_fib(n) = n < 2 ? n : interp_fib(n - 1) + interp_fib(n - 2)

interp_result = interp_fib(N)
aot_result = fib(N)
raise "mismatch: interpreter=#{interp_result} aot=#{aot_result}" unless interp_result == aot_result

interp_time = Benchmark.realtime { interp_fib(N) }
aot_time = Benchmark.realtime { fib(N) }

puts "variant=naive n=#{N} result=#{aot_result}"
puts "interpreter: #{interp_time.round(4)}s"
puts "AOT:         #{aot_time.round(4)}s"
puts "speedup:     #{(interp_time / aot_time).round(1)}x"
