module Suppify
  # Renders binding.c: a Library's entries as module methods of the VM the PicoRuby build selects,
  # mruby/c under PICORB_VM_MRUBYC and mruby otherwise. It reaches the kernel through the plain C
  # contract alone (Glue.header), so no spinel header meets the VM's.
  module Binding
    module_function

    #: (Library) -> String
    def render(lib)
      <<~C
        #include <stdbool.h>
        #include <string.h>
        #include "#{lib.name}.h"
        #if defined(PICORB_VM_MRUBYC)
        #{Mrubyc.render(lib)}
        #else
        #{Mruby.render(lib)}
        #endif
      C
    end

    # The arguments of the plain C entry, from locals named after Glue.params.
    #: (Entry) -> String
    def call_args(e)
      args, ret = Glue.types(e)
      list = args.each_with_index.map { |t, i| t.kind == :str ? "s#{i}, n#{i}" : "a#{i}" }
      list << (ret.kind == :str ? "&r, &rn" : "&r") unless ret.kind == :void
      list.join(", ")
    end

    # The full mruby VM (PICORB_VM_MRUBY).
    module Mruby
      module_function

      GET = { int: ["i", "mrb_int"], float: ["f", "mrb_float"], bool: ["b", "mrb_bool"] }.freeze

      #: (Library) -> String
      def render(lib)
        n = lib.name
        <<~C
          #include <mruby.h>
          #include <mruby/string.h>

          static mrb_value sx_raise(mrb_state *mrb) {
            const char *cls = #{n}_error_class();
            struct RClass *k = cls[0] && mrb_class_defined(mrb, cls) ? mrb_class_get(mrb, cls) : E_RUNTIME_ERROR;
            mrb_raise(mrb, k, #{n}_error_message());
            return mrb_nil_value();
          }
          #{lib.entries.map { cfunc(n, _1) }.join("\n")}
          void mrb_picoruby_#{n}_gem_init(mrb_state *mrb) {
            #{n}_init();
          #{defines(lib)}}

          void mrb_picoruby_#{n}_gem_final(mrb_state *mrb) { (void)mrb; }
        C
      end

      #: (String, Entry) -> String
      def cfunc(n, e)
        args, ret = Glue.types(e)
        fmt = +""
        decls = []
        ptrs = []
        args.each_with_index do |t, i|
          if t.kind == :str
            fmt << "s"
            decls << "const char *s#{i}; mrb_int len#{i}; size_t n#{i};"
            ptrs << "&s#{i}, &len#{i}"
          else
            code, type = GET.fetch(t.kind)
            fmt << code
            decls << "#{type} v#{i}; #{t.c} a#{i};"
            ptrs << "&v#{i}"
          end
        end
        convert = args.each_with_index.map { |t, i| t.kind == :str ? "n#{i} = (size_t)len#{i};" : "a#{i} = (#{t.c})v#{i};" }
        decls << (ret.kind == :str ? "const char *r; size_t rn;" : "#{ret.c} r;") unless ret.kind == :void
        give = case ret.kind
               when :void then "mrb_nil_value()"
               when :int then "mrb_int_value(mrb, (mrb_int)r)"
               when :float then "mrb_float_value(mrb, (mrb_float)r)"
               when :bool then "mrb_bool_value(r)"
               when :str then "r ? mrb_str_new(mrb, r, (mrb_int)rn) : mrb_nil_value()"
               end
        get = args.empty? ? "" : "  mrb_get_args(mrb, \"#{fmt}\", #{ptrs.join(', ')});\n  #{convert.join(' ')}\n"
        <<~C
          static mrb_value sx_#{e.func}(mrb_state *mrb, mrb_value self) {
            #{decls.join(' ')}
            (void)self;
          #{get}  if (#{n}_#{e.func}(#{Binding.call_args(e)})) return sx_raise(mrb);
            return #{give};
          }
        C
      end

      #: (Library) -> String
      def defines(lib)
        lib.entries.group_by(&:mod).each_with_index.map do |(mod, entries), i|
          "  struct RClass *m#{i} = mrb_define_module(mrb, \"#{mod}\");\n" +
            entries.map { |e| "  mrb_define_class_method(mrb, m#{i}, \"#{e.name}\", sx_#{e.func}, MRB_ARGS_REQ(#{e.params.length}));\n" }.join
        end.join
      end
    end

    # The mruby/c VM (PICORB_VM_MRUBYC).
    module Mrubyc
      module_function

      CHECK = { int: "v[%1$d].tt == MRBC_TT_INTEGER", float: "(v[%1$d].tt == MRBC_TT_FLOAT || v[%1$d].tt == MRBC_TT_INTEGER)",
                str: "v[%1$d].tt == MRBC_TT_STRING" }.freeze

      #: (Library) -> String
      def render(lib)
        n = lib.name
        <<~C
          #include <mrubyc.h>

          static void sx_raise(mrbc_vm *vm) {
            const char *cls = #{n}_error_class();
            mrbc_class *k = cls[0] ? mrbc_get_class_by_name(cls) : 0;
            mrbc_raise(vm, k ? k : MRBC_CLASS(RuntimeError), #{n}_error_message());
          }
          #{lib.entries.map { cfunc(n, _1) }.join("\n")}
          void mrbc_#{n}_init(mrbc_vm *vm) {
            #{n}_init();
          #{defines(lib)}}
        C
      end

      #: (String, Entry) -> String
      def cfunc(n, e)
        args, ret = Glue.types(e)
        checks = args.each_with_index.filter_map { |t, i| CHECK[t.kind] && format(CHECK[t.kind], i + 1) }
        locals = args.each_with_index.map do |t, i|
          case t.kind
          when :str then "const char *s#{i} = (const char *)v[#{i + 1}].string->data; size_t n#{i} = v[#{i + 1}].string->size;"
          when :int then "intptr_t a#{i} = (intptr_t)v[#{i + 1}].i;"
          when :float then "double a#{i} = v[#{i + 1}].tt == MRBC_TT_FLOAT ? v[#{i + 1}].d : (double)v[#{i + 1}].i;"
          when :bool then "bool a#{i} = v[#{i + 1}].tt != MRBC_TT_NIL && v[#{i + 1}].tt != MRBC_TT_FALSE;"
          end
        end
        locals << (ret.kind == :str ? "const char *r; size_t rn;" : "#{ret.c} r;") unless ret.kind == :void
        give = case ret.kind
               when :void then "SET_NIL_RETURN();"
               when :int then "SET_INT_RETURN(r);"
               when :float then "SET_FLOAT_RETURN(r);"
               when :bool then "SET_BOOL_RETURN(r);"
               when :str then "if (r) { SET_RETURN(mrbc_string_new(vm, r, (int)rn)); } else { SET_NIL_RETURN(); }"
               end
        guard = checks.empty? ? "" : "  if (!(#{checks.join(' && ')})) { mrbc_raise(vm, MRBC_CLASS(TypeError), \"wrong argument type\"); return; }\n"
        <<~C
          static void sx_#{e.func}(mrbc_vm *vm, mrbc_value v[], int argc) {
            if (argc != #{args.length}) { mrbc_raise(vm, MRBC_CLASS(ArgumentError), "wrong number of arguments"); return; }
          #{guard}  #{locals.join(' ')}
            if (#{n}_#{e.func}(#{Binding.call_args(e)})) { sx_raise(vm); return; }
            #{give}
          }
        C
      end

      #: (Library) -> String
      def defines(lib)
        lib.entries.group_by(&:mod).each_with_index.map do |(mod, entries), i|
          "  mrbc_class *m#{i} = mrbc_define_module(vm, \"#{mod}\");\n" +
            entries.map { |e| "  mrbc_define_method(vm, m#{i}, \"#{e.name}\", sx_#{e.func});\n" }.join
        end.join
      end
    end
  end
end
