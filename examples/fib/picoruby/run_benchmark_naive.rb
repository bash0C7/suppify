N = 30

def interp_fib(n) = n < 2 ? n : interp_fib(n - 1) + interp_fib(n - 2)

interp_result = interp_fib(N)
aot_result = fib(N)
raise "mismatch: interpreter=#{interp_result} aot=#{aot_result}" unless interp_result == aot_result

t0 = Time.now
interp_fib(N)
interp_time = Time.now - t0

t1 = Time.now
fib(N)
aot_time = Time.now - t1

print "variant=naive n=#{N} result=#{aot_result}\n"
print "interpreter: #{interp_time}s\n"
print "AOT:         #{aot_time}s\n"
