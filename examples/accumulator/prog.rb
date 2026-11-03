Acc.add(0, 1.5)
Acc.add(0, 1.5)
print Acc.label(0), "|", Acc.at(0), "|"
begin
  Acc.at(9)
rescue TypeError => e
  print "TypeError: ", e.message, "|"
end
Acc.reset
puts Acc.at(0)
