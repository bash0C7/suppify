# host.rb -- build_config for this example, pointing at its own generated mrbgem
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"
  conf.picoruby
  conf.gembox "minimum"
  conf.gem core: "picoruby-bin-picoruby"
  conf.gem core: "picoruby-time"
  conf.gem gemdir: File.expand_path("build/picoruby-fib", __dir__)
end
