module Suppify
  # How a spinel C type crosses the library's contract.
  #   kind: :int, :float, :bool, :str or :void
  #   c:    the plain C type the contract states it in
  #   ruby: the Ruby class the signature string names
  Type = Data.define(:kind, :c, :ruby, :spinel)

  TYPES = {
    "sp_int" => Type.new(:int, "intptr_t", "Integer", "sp_int"),
    "sp_float" => Type.new(:float, "double", "Float", "sp_float"),
    "sp_bool" => Type.new(:bool, "bool", "bool", "sp_bool"),
    "sp_String *" => Type.new(:str, "const char *", "String", "sp_String *"),
    "const char *" => Type.new(:str, "const char *", "String", "const char *"),
    "void" => Type.new(:void, "void", "nil", "void"),
  }.freeze

  OPTIONAL_RETURNS = {
    "sp_oint" => [Type.new(:int, "intptr_t", "Integer", "sp_oint"), "sp_oint_arg_of"],
    "sp_ofloat" => [Type.new(:float, "double", "Float", "sp_ofloat"), "sp_ofloat_arg"],
  }.freeze

  # One copy of the kernel and spinel's runtime, used by one caller: the prefix of its C entries and
  # the name of its kernel table.
  Instance = Data.define(:api, :table) do
    #: () -> bool
    def own_table? = table == "#{api}_kernels"
  end

  # The C a Library's entries are reached through: the public header every caller includes, and the
  # translation unit that turns its plain C types into spinel's.
  module Glue
    module_function

    STATUS = { "MALFORMED" => -1, "NOSPACE" => -2, "RAISED" => -3, "RANGE" => -4 }.freeze

    #: (String, String) -> Type
    def type(entry, c)
      TYPES.fetch(c) { raise Error, "#{entry} has #{c}, which crosses no contract suppify writes" }
    end

    #: (Entry) -> [Array[Type], Type]
    def types(e)
      ret = OPTIONAL_RETURNS.dig(e.ret, 0) || type("#{e.mod}.#{e.name}", e.ret)
      [e.params.map { type("#{e.mod}.#{e.name}", _1) }, ret]
    end

    # `intptr_t a0, const char *s1, size_t n1, intptr_t *ret` for the typed entry.
    #: (Entry) -> String
    def params(e)
      args, ret = types(e)
      list = args.each_with_index.map { |t, i| t.kind == :str ? "const char *s#{i}, size_t n#{i}" : "#{t.c} a#{i}" }
      list << (ret.kind == :str ? "const char **ret, size_t *ret_len" : "#{ret.c} *ret") unless ret.kind == :void
      list.empty? ? "void" : list.join(", ")
    end

    #: (Entry) -> String
    def signature(e)
      args, ret = types(e)
      "(#{args.map(&:ruby).join(', ')}) -> #{ret.ruby}"
    end

    # The public header: the entries of every instance. A table named by `--table` is left to the
    # header of the code that looks it up (multicore.h declares `multicore_kernels`).
    #: (Library, Array[Instance]) -> String
    def header(lib, instances)
      guard = "SUPPIFY_#{lib.name.upcase}_H"
      decls = instances.map do |inst|
        n = inst.api
        "void #{n}_init(void);\n" \
          "const char *#{n}_error_class(void);\n" \
          "const char *#{n}_error_message(void);\n" +
          lib.entries.map do |e|
            "int #{n}_#{e.func}(#{params(e)});\n" \
              "int32_t #{n}_#{e.func}_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap);\n" \
              "const char *#{n}_#{e.func}_signature(void);\n"
          end.join +
          (inst.own_table? ? "extern const suppify_kernel_t #{inst.table}[];\n" : "")
      end
      <<~C
        #ifndef #{guard}
        #define #{guard}
        #include <stdbool.h>
        #include <stddef.h>
        #include <stdint.h>

        #ifndef SUPPIFY_KERNEL_T
        #define SUPPIFY_KERNEL_T
        #{STATUS.map { |k, v| "#define SUPPIFY_#{k} (#{v})" }.join("\n")}
        typedef struct {
          const char *name;
          int32_t (*call)(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap);
          const char *(*signature)(void);
          void (*init)(void);
          const char *(*error_message)(void);
        } suppify_kernel_t;
        #endif

        #{decls.join("\n")}
        #endif
      C
    end

    # The glue translation unit of one instance.
    #: (Library, Instance) -> String
    def source(lib, inst)
      names = lib.entries.map(&:name)
      dup = names.select { names.count(_1) > 1 }.uniq
      raise Error, "entries share a method name across modules: #{dup.join(', ')}" unless dup.empty?
      [prelude(lib, inst.api), *lib.entries.map { entry(inst.api, _1) }, table(lib, inst)].join("\n")
    end

    #: (Library, String) -> String
    def prelude(lib, n)
      <<~C
        #include <string.h>
        #include "#{lib.name}_spinel.h"
        #include "suppify/#{lib.name}.h"

        static char sx_cls[64];
        static char sx_msg[256];

        void #{n}_init(void) {
          static bool ready;
          if (!ready) { ready = true; #{lib.name}_spinel(); }
        }
        const char *#{n}_error_class(void) { return sx_cls; }
        const char *#{n}_error_message(void) { return sx_msg; }

        static inline int sx_try(void (*body)(void *), void *ctx) {
          const char *cls, *msg;
          sx_cls[0] = sx_msg[0] = 0;
          if (!#{lib.name}_spinel_try(body, ctx, &cls, &msg)) return 0;
          strncpy(sx_cls, cls ? cls : "", sizeof sx_cls - 1);
          strncpy(sx_msg, msg ? msg : "", sizeof sx_msg - 1);
          return 1;
        }

        typedef struct { const uint8_t *p, *end; } sx_in;
        typedef struct { uint8_t *p, *end; bool full; } sx_out;

        static inline bool sx_take(sx_in *r, size_t n, const uint8_t **at) {
          if ((size_t)(r->end - r->p) < n) return false;
          *at = r->p; r->p += n; return true;
        }
        static inline bool sx_be(sx_in *r, size_t n, uint64_t *v) {
          const uint8_t *b;
          if (!sx_take(r, n, &b)) return false;
          *v = 0;
          for (size_t i = 0; i < n; i++) *v = (*v << 8) | b[i];
          return true;
        }
        static inline int64_t sx_array(sx_in *r) {
          uint64_t v; const uint8_t *t;
          if (!sx_take(r, 1, &t)) return -1;
          if ((*t & 0xf0) == 0x90) return *t & 0x0f;
          if (*t == 0xdc) return sx_be(r, 2, &v) ? (int64_t)v : -1;
          if (*t == 0xdd) return sx_be(r, 4, &v) ? (int64_t)v : -1;
          return -1;
        }
        static inline int sx_int64(sx_in *r, int64_t *out) {
          uint64_t v; const uint8_t *t;
          if (!sx_take(r, 1, &t)) return SUPPIFY_MALFORMED;
          if (*t <= 0x7f) { *out = *t; return 0; }
          if (*t >= 0xe0) { *out = (int8_t)*t; return 0; }
          switch (*t) {
            case 0xcc: if (!sx_be(r, 1, &v)) break; *out = (int64_t)v; return 0;
            case 0xcd: if (!sx_be(r, 2, &v)) break; *out = (int64_t)v; return 0;
            case 0xce: if (!sx_be(r, 4, &v)) break; *out = (int64_t)v; return 0;
            case 0xcf: if (!sx_be(r, 8, &v)) break; if (v > INT64_MAX) return SUPPIFY_RANGE; *out = (int64_t)v; return 0;
            case 0xd0: if (!sx_be(r, 1, &v)) break; *out = (int8_t)v; return 0;
            case 0xd1: if (!sx_be(r, 2, &v)) break; *out = (int16_t)v; return 0;
            case 0xd2: if (!sx_be(r, 4, &v)) break; *out = (int32_t)v; return 0;
            case 0xd3: if (!sx_be(r, 8, &v)) break; *out = (int64_t)v; return 0;
          }
          return SUPPIFY_MALFORMED;
        }
        static inline int sx_get_int(sx_in *r, intptr_t *out) {
          int64_t v;
          int s = sx_int64(r, &v);
          if (s) return s;
          if (v < INTPTR_MIN || v > INTPTR_MAX) return SUPPIFY_RANGE;
          *out = (intptr_t)v;
          return 0;
        }
        static inline int sx_get_float(sx_in *r, double *out) {
          uint64_t v;
          if (r->p < r->end && *r->p == 0xcb) { r->p++; if (!sx_be(r, 8, &v)) return SUPPIFY_MALFORMED; memcpy(out, &v, 8); return 0; }
          if (r->p < r->end && *r->p == 0xca) {
            uint32_t w; float f;
            r->p++;
            if (!sx_be(r, 4, &v)) return SUPPIFY_MALFORMED;
            w = (uint32_t)v; memcpy(&f, &w, 4); *out = f; return 0;
          }
          int64_t i;
          int s = sx_int64(r, &i);
          if (s) return s;
          *out = (double)i;
          return 0;
        }
        static inline int sx_get_bool(sx_in *r, bool *out) {
          const uint8_t *t;
          if (!sx_take(r, 1, &t)) return SUPPIFY_MALFORMED;
          if (*t == 0xc3) { *out = true; return 0; }
          if (*t == 0xc2 || *t == 0xc0) { *out = false; return 0; }
          return SUPPIFY_MALFORMED;
        }
        static inline int sx_get_str(sx_in *r, const char **s, size_t *n) {
          uint64_t v; const uint8_t *t, *b;
          if (!sx_take(r, 1, &t)) return SUPPIFY_MALFORMED;
          if ((*t & 0xe0) == 0xa0) v = *t & 0x1f;
          else if ((*t == 0xd9 || *t == 0xc4) && sx_be(r, 1, &v)) ;
          else if ((*t == 0xda || *t == 0xc5) && sx_be(r, 2, &v)) ;
          else if ((*t == 0xdb || *t == 0xc6) && sx_be(r, 4, &v)) ;
          else return SUPPIFY_MALFORMED;
          if (!sx_take(r, (size_t)v, &b)) return SUPPIFY_MALFORMED;
          *s = (const char *)b; *n = (size_t)v;
          return 0;
        }

        static inline void sx_put(sx_out *w, const void *b, size_t n) {
          if ((size_t)(w->end - w->p) < n) { w->full = true; return; }
          memcpy(w->p, b, n); w->p += n;
        }
        static inline void sx_put_be(sx_out *w, uint8_t tag, uint64_t v, size_t n) {
          uint8_t b[9];
          b[0] = tag;
          for (size_t i = 0; i < n; i++) b[1 + i] = (uint8_t)(v >> (8 * (n - 1 - i)));
          sx_put(w, b, 1 + n);
        }
        static inline void sx_put_int(sx_out *w, intptr_t v) {
          if (v >= 0 && v <= 0x7f) { uint8_t b = (uint8_t)v; sx_put(w, &b, 1); }
          else if (v < 0 && v >= -32) { uint8_t b = (uint8_t)(int8_t)v; sx_put(w, &b, 1); }
          else sx_put_be(w, 0xd3, (uint64_t)(int64_t)v, 8);
        }
        static inline void sx_put_float(sx_out *w, double d) {
          uint64_t v;
          memcpy(&v, &d, 8);
          sx_put_be(w, 0xcb, v, 8);
        }
        static inline void sx_put_bool(sx_out *w, bool b) { uint8_t t = b ? 0xc3 : 0xc2; sx_put(w, &t, 1); }
        static inline void sx_put_nil(sx_out *w) { uint8_t t = 0xc0; sx_put(w, &t, 1); }
        static inline void sx_put_str(sx_out *w, const char *s, size_t n) {
          if (!s) { sx_put_nil(w); return; }
          if (n < 32) { uint8_t t = (uint8_t)(0xa0 | n); sx_put(w, &t, 1); }
          else if (n <= 0xff) sx_put_be(w, 0xd9, n, 1);
          else if (n <= 0xffff) sx_put_be(w, 0xda, n, 2);
          else sx_put_be(w, 0xdb, n, 4);
          sx_put(w, s, n);
        }
      C
    end

    #: (String, Entry) -> String
    def entry(n, e)
      args, ret = types(e)
      f = "#{n}_#{e.func}"
      fields = args.each_with_index.map { |t, i| t.kind == :str ? "const char *s#{i}; size_t n#{i};" : "#{t.c} a#{i};" }
      fields << (ret.kind == :str ? "const char *ret; size_t ret_len;" : "#{ret.c} ret;") unless ret.kind == :void
      fields << "int unused;" if fields.empty?
      locals = args.each_with_index.select { |t, _| t.kind == :str }.map do |t, i|
        conv = t.spinel == "sp_String *" ? "SP_STR_HDL(sp_str_from_bytes(c->s#{i}, c->n#{i}))" : "sp_str_from_bytes(c->s#{i}, c->n#{i})"
        "  #{t.spinel} a#{i} = #{conv}; SP_GC_ROOT(a#{i});\n"
      end
      call_args = args.each_with_index.map { |t, i| t.kind == :str ? "a#{i}" : "c->a#{i}" }.join(", ")
      call = "#{e.cname}(#{call_args})"
      call = "#{OPTIONAL_RETURNS[ret.spinel][1]}(#{call})" if OPTIONAL_RETURNS.key?(ret.spinel)
      store = case ret.kind
              when :void then "  #{call};\n"
              when :str then "  c->ret = #{call};\n  c->ret_len = c->ret ? sp_str_byte_len(c->ret) : 0;\n"
              else "  c->ret = #{call};\n"
              end
      init = args.each_with_index.map { |t, i| t.kind == :str ? ".s#{i} = s#{i}, .n#{i} = n#{i}" : ".a#{i} = a#{i}" }
      give = case ret.kind
             when :void then ""
             when :str then "  *ret = c.ret; *ret_len = c.ret_len;\n"
             else "  *ret = c.ret;\n"
             end
      reads = args.each_with_index.map do |t, i|
        t.kind == :str ? "sx_get_str(&r, &c.s#{i}, &c.n#{i})" : "sx_get_#{t.kind}(&r, &c.a#{i})"
      end
      put = case ret.kind
            when :void then "sx_put_nil(&w)"
            when :str then "sx_put_str(&w, c.ret, c.ret_len)"
            else "sx_put_#{ret.kind}(&w, c.ret)"
            end
      <<~C
        typedef struct { #{fields.join(' ')} } #{f}_ctx;
        static void #{f}_body(void *p) {
          #{f}_ctx *c = p;
          SP_GC_SAVE();
        #{locals.join}#{store}}
        int #{f}(#{params(e)}) {
          #{f}_ctx c = { #{init.empty? ? '0' : init.join(', ')} };
          if (sx_try(#{f}_body, &c)) return 1;
        #{give}  return 0;
        }
        int32_t #{f}_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap) {
          sx_cls[0] = sx_msg[0] = 0;
          if (in_len < 0 || out_cap < 0) return SUPPIFY_MALFORMED;
          sx_in r = { in, in + in_len };
          sx_out w = { out, out + out_cap, false };
          #{f}_ctx c;
          int s = 0; (void)s;
          memset(&c, 0, sizeof c);
          #{n}_init();
          if (sx_array(&r) != #{args.length}) return SUPPIFY_MALFORMED;
        #{reads.map { "  if ((s = #{_1})) return s;\n" }.join}  if (r.p != r.end) return SUPPIFY_MALFORMED;
          if (sx_try(#{f}_body, &c)) return SUPPIFY_RAISED;
          #{put};
          return w.full ? SUPPIFY_NOSPACE : (int32_t)(w.p - out);
        }
        const char *#{f}_signature(void) { return "#{signature(e)}"; }
      C
    end

    #: (Library, Instance) -> String
    def table(lib, inst)
      n = inst.api
      rows = lib.entries.map { |e| "  { \"#{e.name}\", #{n}_#{e.func}_call, #{n}_#{e.func}_signature, #{n}_init, #{n}_error_message },\n" }
      "const suppify_kernel_t #{inst.table}[] = {\n#{rows.join}  { 0, 0, 0, 0, 0 },\n};\n"
    end

    # The C symbols one instance exports; everything else in a sealed instance is local.
    #: (Library, Instance) -> Array[String]
    def exports(lib, inst)
      n = inst.api
      %W[#{n}_init #{n}_error_class #{n}_error_message #{inst.table}] +
        lib.entries.flat_map { |e| %W[#{n}_#{e.func} #{n}_#{e.func}_call #{n}_#{e.func}_signature] }
    end
  end
end
