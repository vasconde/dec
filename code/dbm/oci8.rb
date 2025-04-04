#   --*- ruby -*--
# This is based on yoshidam's oracle.rb.
#
# sample one liner:
#  ruby -r oci8 -e 'OCI8.new("scott", "tiger", nil).exec("select * from emp") do |r| puts r.join(","); end'
#  # select all data from emp and print them as CVS format.

if RUBY_PLATFORM =~ /cygwin/
  # Cygwin manages environment variables by itself.
  # They don't synchroize with Win32's ones.
  # This set some Oracle's environment variables to win32's enviroment.
  require 'Win32API'
  win32setenv = Win32API.new('Kernel32.dll', 'SetEnvironmentVariableA', 'PP', 'I')
  ['NLS_LANG', 'ORA_NLS10', 'ORA_NLS32', 'ORA_NLS33', 'ORACLE_BASE', 'ORACLE_HOME', 'ORACLE_SID', 'TNS_ADMIN', 'LOCAL'].each do |name|
    val = ENV[name]
    win32setenv.call(name, val && val.dup)
  end
end

require 'oci8lib'
require 'date'
require 'thread'

class OCIBreak < OCIException
  def initialize(errstr = "Canceled by user request.")
    super(errstr)
  end
end

class OCIDefine # :nodoc:
  # define handle of OCILobLocator needs @env and @svc.
  def set_handle(env, svc) 
    @env = env
    @svc = svc
  end
end

class OCIBind # :nodoc:
  # define handle of OCILobLocator needs @env and @svc.
  def set_handle(env, svc, ctx)
    @env = env
    @svc = svc
    @ctx = ctx
  end
end

class OCI8
  if OCIEnv.respond_to?("create")
    @@env = OCIEnv.create(OCI_OBJECT)
  else
    OCIEnv.initialise(OCI_OBJECT)
    @@env = OCIEnv.init()
  end

  VERSION = '0.1.16'
  CLIENT_VERSION = '920'
  # :stopdoc:
  RAW = OCI_TYPECODE_RAW
  STMT_SELECT = OCI_STMT_SELECT
  STMT_UPDATE = OCI_STMT_UPDATE
  STMT_DELETE = OCI_STMT_DELETE
  STMT_INSERT = OCI_STMT_INSERT
  STMT_CREATE = OCI_STMT_CREATE
  STMT_DROP = OCI_STMT_DROP
  STMT_ALTER = OCI_STMT_ALTER
  STMT_BEGIN = OCI_STMT_BEGIN
  STMT_DECLARE = OCI_STMT_DECLARE
  # :startdoc:

  # sql type (varchar, varchar2)
  SQLT_CHR = 1
  # sql type (number, double precision, float, real, numeric, int, integer, smallint)
  SQLT_NUM = 2
  # sql type (long)
  SQLT_LNG = 8
  # sql type (date)
  SQLT_DAT = 12
  # sql type (raw)
  SQLT_BIN = 23
  # sql type (long raw)
  SQLT_LBI = 24
  # sql type (char)
  SQLT_AFC = 96
  # sql type (rowid)
  SQLT_RDD = 104
  # sql type (clob)
  SQLT_CLOB = 112
  # sql type (blob)
  SQLT_BLOB = 113
  # sql type (result set)
  SQLT_RSET = 116
  # sql type (timestamp), not supported yet.
  #
  # If you want to fetch a timestamp before native timestamp data type
  # will be supported, fetch data as an OraDate by adding the following
  # code to your code.
  #   OCI8::BindType::Mapping[OCI8::SQLT_TIMESTAMP] = OCI8::BindType::OraDate
  SQLT_TIMESTAMP = 187
  # sql type (timestamp with time zone), not supported yet
  SQLT_TIMESTAMP_TZ = 188
  # sql type (interval year to month), not supported yet
  SQLT_INTERVAL_YM = 189
  # sql type (interval day to second), not supported yet
  SQLT_INTERVAL_DS = 190
  # sql type (timestamp with local time zone), not supported yet
  SQLT_TIMESTAMP_LTZ = 232

  # mapping of sql type number to sql type name.
  SQLT_NAMES = {}
  constants.each do |name|
    next if name.index("SQLT_") != 0
    val = const_get name.intern
    if val.is_a? Fixnum
      SQLT_NAMES[val] = name
    end
  end

  module Util # :nodoc:
    CTX_EXECFLAG = 0
    CTX_MUTEX = 1
    CTX_THREAD = 2
    CTX_LONG_READ_LEN = 3

    def do_ocicall(ctx)
      sleep_time = 0.01
      ctx[CTX_MUTEX].lock
      ctx[CTX_THREAD] = Thread.current
      begin
	yield
      rescue OCIStillExecuting # non-blocking mode
	ctx[CTX_MUTEX].unlock
	sleep(sleep_time)
	ctx[CTX_MUTEX].lock
	if ctx[CTX_THREAD].nil?
	  raise OCIBreak
	end
	# expand sleep time to prevent busy loop.
	sleep_time *= 2 if sleep_time < 0.5
	retry
      ensure
	ctx[CTX_THREAD] = nil
	ctx[CTX_MUTEX].unlock
      end
    end # do_ocicall
  end
  include Util

  def initialize(uid, pswd, conn = nil, privilege = nil)
    case privilege
    when nil
      @privilege = nil
    when :SYSDBA
      @privilege = OCI_SYSDBA
    when :SYSOPER
      @privilege = OCI_SYSOPER
    else
      raise ArgumentError, "invalid privilege name #{privilege} (expect :SYSDBA, :SYSOPER or nil)"
    end

    @prefetch_rows = nil
    @ctx = [0, Mutex.new, nil, 65535]
    if @privilege
      @svc = @@env.alloc(OCISvcCtx)
      @srv = @@env.alloc(OCIServer)
      @auth = @@env.alloc(OCISession)

      @auth.attrSet(OCI_ATTR_USERNAME, uid)
      @auth.attrSet(OCI_ATTR_PASSWORD, pswd)
      do_ocicall(@ctx) { @srv.attach(conn) }
      begin
        @svc.attrSet(OCI_ATTR_SERVER, @srv)
        do_ocicall(@ctx) { @auth.begin(@svc, OCI_CRED_RDBMS, @privilege) }
        @svc.attrSet(OCI_ATTR_SESSION, @auth)
      rescue
        @srv.detach()
        raise
      end
    else
      @svc = @@env.logon(uid, pswd, conn)
    end
  end # initialize

  def logoff
    rollback()
    if @privilege
      do_ocicall(@ctx) { @auth.end(@svc) }
      do_ocicall(@ctx) { @srv.detach() }
    else
      @svc.logoff
    end
    @svc.free()
    true
  end # logoff

  def exec(sql, *bindvars)
    cursor = OCI8::Cursor.new(@@env, @svc, @ctx)
    cursor.prefetch_rows = @prefetch_rows if @prefetch_rows
    cursor.parse(sql)
    if cursor.type == OCI_STMT_SELECT && ! block_given?
      cursor.exec(*bindvars)
      cursor
    else
      begin
	ret = cursor.exec(*bindvars)
	case cursor.type
	when OCI_STMT_SELECT
	  cursor.fetch { |row| yield(row) }   # for each row
	  cursor.row_count()
	when OCI_STMT_BEGIN, OCI_STMT_DECLARE # PL/SQL block
	  ary = []
	  cursor.keys.sort.each do |key|
	    ary << cursor[key]
	  end
	  ary
	else
	  ret
	end
      ensure
	cursor.close
      end
    end
  end # exec

  def parse(sql)
    cursor = OCI8::Cursor.new(@@env, @svc, @ctx)
    cursor.prefetch_rows = @prefetch_rows if @prefetch_rows
    cursor.parse(sql)
    cursor
  end # parse

  def commit
    do_ocicall(@ctx) { @svc.commit }
  end # commit

  def rollback
    do_ocicall(@ctx) { @svc.rollback }
  end # rollback

  def autocommit?
    (@ctx[CTX_EXECFLAG] & OCI_COMMIT_ON_SUCCESS) == OCI_COMMIT_ON_SUCCESS
  end # autocommit?

  # add alias compatible with 'Oracle7 Module for Ruby'.
  alias autocommit autocommit?

  def autocommit=(ac)
    if ac
      commit()
      @ctx[CTX_EXECFLAG] |= OCI_COMMIT_ON_SUCCESS
    else
      @ctx[CTX_EXECFLAG] &= ~OCI_COMMIT_ON_SUCCESS
    end
    ac
  end # autocommit=

  def prefetch_rows=(rows)
    @prefetch_rows = rows
  end

  def non_blocking?
    @svc.attrGet(OCI_ATTR_NONBLOCKING_MODE)
  end # non_blocking?

  def non_blocking=(nb)
    if nb && ! non_blocking?
      # If the argument and the current status are different,
      # toggle blocking / non-blocking.
      @srv = @svc.attrGet(OCI_ATTR_SERVER) unless @srv
      @srv.attrSet(OCI_ATTR_NONBLOCKING_MODE, nil)
    end
  end # non_blocking=

  def break
    @ctx[CTX_MUTEX].synchronize do
      @svc.break()
      unless @ctx[CTX_THREAD].nil?
	@ctx[CTX_THREAD].wakeup()
	@ctx[CTX_THREAD] = nil
	if @svc.respond_to?("reset")
	  begin
	    @svc.reset()
	  rescue OCIError
	    raise if $!.code != 1013 # ORA-01013
	  end
	end
      end
    end
  end # break

  def long_read_len
    @ctx[OCI8::Util::CTX_LONG_READ_LEN]
  end

  def long_read_len=(len)
    @ctx[OCI8::Util::CTX_LONG_READ_LEN] = len
  end

  module BindType
    # get/set String
    String = Object.new
    class << String
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_CHR, val, length || (val.nil? ? nil : val.length)]
      end
    end

    # get/set RAW
    RAW = Object.new
    class << RAW
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_BIN, val, length || (val.nil? ? nil : val.length)]
      end
    end

    # get/set OraDate
    OraDate = Object.new
    class << OraDate
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_DAT, val, nil]
      end
    end

    # get/set Time
    Time = Object.new
    class << Time
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_DAT, val, nil]
      end
      def decorate(b)
        def b.set(val)
          super(val && ::OraDate.new(val.year, val.mon, val.mday, val.hour, val.min, val.sec))
        end
        def b.get()
          (val = super()) && val.to_time
        end
      end
    end

    # get/set Date
    Date = Object.new
    class << Date
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_DAT, val, nil]
      end
      def decorate(b)
        def b.set(val)
          super(val && ::OraDate.new(val.year, val.mon, val.mday))
        end
        def b.get()
          (val = super()) && val.to_date
        end
      end
    end

    if defined? ::DateTime # ruby 1.8.0 or upper
      # get/set DateTime 
      DateTime = Object.new
      class << DateTime
        def fix_type(env, val, length, precision, scale)
          [OCI8::SQLT_DAT, val, nil]
        end
        def decorate(b)
          def b.set(val)
            super(val && ::OraDate.new(val.year, val.mon, val.mday, val.hour, val.min, val.sec))
          end
          def b.get()
            (val = super()) && val.to_datetime
          end
        end
      end
    end

    # get/set Float
    Float = Object.new
    class << Float
      def fix_type(env, val, length, precision, scale)
        [::Float, val, nil]
      end
    end

    # get/set Fixnum
    Fixnum = Object.new
    class << Fixnum
      def fix_type(env, val, length, precision, scale)
        [::Fixnum, val, nil]
      end
    end

    # get/set Integer
    Integer = Object.new
    class << Integer
      def fix_type(env, val, length, precision, scale)
        [::Integer, val, nil]
      end
    end

    # get/set OraNumber
    OraNumber = Object.new
    class << OraNumber
      def fix_type(env, val, length, precision, scale)
        [::OraNumber, val, nil]
      end
    end

    # get/set Number (for OCI8::SQLT_NUM)
    Number = Object.new
    class << Number
      def fix_type(env, val, length, precision, scale)
        if scale == -127
          if precision == 0
            # NUMBER declared without its scale and precision. (Oracle 9.2.0.3 or above)
            ::OCI8::BindType::Mapping[:number_no_prec_setting].fix_type(env, val, length, precision, scale)
          else
            # FLOAT or FLOAT(p)
            [::Float, val, nil]
          end
        elsif scale == 0
          if precision == 0
            # NUMBER whose scale and precision is unknown
            # or
            # NUMBER declared without its scale and precision. (Oracle 9.2.0.2 or below)
            ::OCI8::BindType::Mapping[:number_unknown_prec].fix_type(env, val, length, precision, scale)
          elsif precision <= 9
            # NUMBER(p, 0); p is less than or equals to the precision of Fixnum
            [::Fixnum, val, nil]
          else
            # NUMBER(p, 0); p is greater than the precision of Fixnum
            [::Integer, val, nil]
          end
        else
          # NUMBER(p, s)
          if precision < 15 # the precision of double.
            [::Float, val, nil]
          else
            # use BigDecimal instead?
            [::OraNumber, val, nil]
          end
        end
      end
    end

    # get/set OCIRowid
    OCIRowid = Object.new
    class << OCIRowid
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_RDD, nil, val]
      end
    end

    # get/set BLOB
    BLOB = Object.new
    class << BLOB
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_BLOB, nil, val.nil? ? env.alloc(OCILobLocator) : val]
      end
      def decorate(b)
        def b.get()
          (val = super()) && OCI8::BLOB.new(@env, @svc, val.clone(@svc))
        end
      end
    end

    # get/set CLOB
    CLOB = Object.new
    class << CLOB
      def fix_type(env, val, length, precision, scale)
        [OCI8::SQLT_CLOB, nil, val.nil? ? env.alloc(OCILobLocator) : val]
      end
      def decorate(b)
        def b.get()
          (val = super()) && OCI8::CLOB.new(@env, @svc, val.clone(@svc))
        end
      end
    end

    # get Cursor
    Cursor = Object.new
    class << Cursor
      def fix_type(env, val, length, precision, scale)
        raise NotImplementedError unless val.nil?
        [OCI8::SQLT_RSET, nil, env.alloc(OCIStmt)]
      end
      def decorate(b)
        def b.set(val)
          raise NotImplementedError
        end
        def b.get()
          (val = super()) && OCI8::Cursor.new(@env, @svc, @ctx, val)
        end
      end
    end

    Mapping = {}
  end # BindType

  class Cursor

    include OCI8::Util

    # for backward compatibility
    def self.select_number_as=(val) # :nodoc:
      if val == ::Fixnum
        bind_type = ::OCI8::BindType::Fixnum
      elsif val == ::Integer
        bind_type = ::OCI8::BindType::Integer
      elsif val == ::Float
        bind_type = ::OCI8::BindType::Float
      else
        raise ArgumentError, "must be Fixnum, Integer or Float"
      end
      ::OCI8::BindType::Mapping[:number_unknown_prec] = bind_type
    end

    # for backward compatibility
    def self.select_number_as # :nodoc:
      ::OCI8::BindType::Mapping[:number_unknown_prec].fix_type(nil, nil, nil, nil, nil)[0]
    end

    def initialize(env, svc, ctx, stmt = nil)
      @env = env
      @svc = svc
      @ctx = ctx
      @binds = nil
      @parms = nil
      @defns = nil
      if stmt.nil?
        @stmt = @env.alloc(OCIStmt)
        @stmttype = nil
      else
        @stmt = stmt
        @stmttype = @stmt.attrGet(OCI_ATTR_STMT_TYPE)
        define_columns()
      end
    end # initialize

    def parse(sql)
      free_binds()
      @parms = nil
      @stmt.prepare(sql)
      @stmttype = do_ocicall(@ctx) { @stmt.attrGet(OCI_ATTR_STMT_TYPE) }
    end # parse

    def define(pos, type, length = nil)
      @defns = [] if @defns.nil?
      if type == String and length.nil?
	length = 4000
      end
      b = bind_or_define(:define, pos, nil, type, length, nil, nil, false)
      @defns[pos].free() unless @defns[pos].nil?
      @defns[pos] = b
      self
    end # define

    def bind_param(key, val, type = nil, length = nil)
      @binds = {} if @binds.nil?
      b = bind_or_define(:bind, key, val, type, length, nil, nil, false)
      @binds[key].free() unless @binds[key].nil?
      @binds[key] = b
      self
    end # bind_param

    # get bind value
    def [](key)
      if @binds.nil? or @binds[key].nil?
	return nil 
      end
      @binds[key].get()
    end

    # set bind value
    def []=(key, val)
      if @binds.nil? or @binds[key].nil?
	return nil 
      end
      @binds[key].set(val)
    end

    # get bind keys
    def keys
      if @binds.nil?
	[]
      else
	@binds.keys
      end
    end

    def exec(*bindvars)
      bind_params(*bindvars)
      case @stmttype
      when OCI_STMT_SELECT
	do_ocicall(@ctx) { @stmt.execute(@svc, 0, OCI_DEFAULT) }
        define_columns()
      when OCI_STMT_UPDATE, OCI_STMT_DELETE, OCI_STMT_INSERT
	do_ocicall(@ctx) { @stmt.execute(@svc, 1, @ctx[CTX_EXECFLAG]) }
	@stmt.attrGet(OCI_ATTR_ROW_COUNT)
      else
	do_ocicall(@ctx) { @stmt.execute(@svc, 1, @ctx[CTX_EXECFLAG]) }
	true
      end
    end # exec

    def type
      @stmttype
    end

    def row_count
      @stmt.attrGet(OCI_ATTR_ROW_COUNT)
    end

    def get_col_names
      return [] if @parms.nil?
      @parms.collect do |p|
	do_ocicall(@ctx) { p.attrGet(OCI_ATTR_NAME) }
      end
    end # get_col_names

    # add alias compatible with 'Oracle7 Module for Ruby'.
    alias getColNames get_col_names

    def fetch
      if iterator?
	while ret = fetch_a_row()
	  yield(ret)
	end
      else
	fetch_a_row()
      end
    end # fetch

    def fetch_hash
      if rs = fetch_a_row()
        ret = {}
        @parms.each do |p|
          ret[p.attrGet(OCI_ATTR_NAME)] = rs.shift
        end
        ret
      else 
        nil
      end
    end # fetch_hash

    def close
      @env = nil
      @svc = nil
      free_defns()
      free_binds()
      @stmt.free()
      @parms = nil
      @stmttype = nil
    end # close

    def rowid
      @stmt.attrGet(OCI_ATTR_ROWID)
    end

    def prefetch_rows=(rows)
      @stmt.attrSet(OCI_ATTR_PREFETCH_ROWS, rows)
    end

    private

    def bind_or_define(bind_type, key, val, type, length, precision, scale, strict_check)
      if type.nil?
	if val.nil?
	  raise "bind type is not given." if type.nil?
	else
          if val.class == Class
            type = val
            val = nil
          else
            type = val.class
          end
	end
      end

      binder = OCI8::BindType::Mapping[type]
      if binder
        type, val, option = binder.fix_type(@env, val, length, precision, scale)
      else
        if strict_check
          raise "unsupported datatype: #{SQLT_NAMES[type] ? SQLT_NAMES[type] : type}"
        else
          option = length
        end
      end

      case bind_type
      when :bind
	if key.is_a? Fixnum
	  b = @stmt.bindByPos(key, type, option)
	else
	  b = @stmt.bindByName(key, type, option)
	end
        b.set_handle(@env, @svc, @ctx)
      when :define
	b = @stmt.defineByPos(key, type, option)
        b.set_handle(@env, @svc)
      end

      if binder && binder.respond_to?(:decorate)
        # decorate the bind handle.
        binder.decorate(b)
      end

      b.set(val) unless val.nil?
      b
    end # bind_or_define

    def define_columns
      num_cols = @stmt.attrGet(OCI_ATTR_PARAM_COUNT)
      @parms = Array.new(num_cols)
      1.upto(num_cols) do |i|
        @parms[i - 1] = @stmt.paramGet(i)
      end
      @defns = Array.new(@parms.size) if @defns.nil?
      1.upto(num_cols) do |i|
	@defns[i] = define_a_column(i) if @defns[i].nil?
      end
      num_cols
    end # define_columns

    def define_a_column(i)
      p = @parms[i - 1]
      datatype = do_ocicall(@ctx) { p.attrGet(OCI_ATTR_DATA_TYPE) }
      datasize = do_ocicall(@ctx) { p.attrGet(OCI_ATTR_DATA_SIZE) }
      precision = do_ocicall(@ctx) { p.attrGet(OCI_ATTR_PRECISION) }
      scale = do_ocicall(@ctx) { p.attrGet(OCI_ATTR_SCALE) }

      case datatype
      when SQLT_CHR, SQLT_AFC
        # character size may become large on character set conversion.
        # The length of a half-width kana is one in Shift_JIS, two in EUC-JP,
        # three in UTF-8.
        datasize *= 3
      when SQLT_LNG, SQLT_LBI
        datasize = @ctx[OCI8::Util::CTX_LONG_READ_LEN]
      end

      bind_or_define(:define, i, nil, datatype, datasize, precision, scale, true)
    end # define_a_column

    def bind_params(*bindvars)
      bindvars.each_with_index do |val, i|
	if val.is_a? Array
	  bind_param(i + 1, val[0], val[1], val[2])
	else
	  bind_param(i + 1, val)
	end
      end
    end # bind_params

    def fetch_a_row
      res = do_ocicall(@ctx) { @stmt.fetch() }
      return nil if res.nil?
      res.collect do |r| r.get() end
    end # fetch_a_row

    def free_defns
      unless @defns.nil?
	@defns.each do |b|
	  b.free() unless b.nil?
	end
      end
      @defns = nil
    end # free_defns

    def free_binds
      unless @binds.nil?
	@binds.each_value do |b|
	  b.free()
	end
      end
      @binds = nil
    end # free_binds
  end # OCI8::Cursor

  class LOB
    attr :pos
    def initialize(env, svc, locator)
      raise "invalid argument" unless env.is_a? OCIEnv
      raise "invalid argument" unless svc.is_a? OCISvcCtx
      raise "invalid argument" unless locator.is_a? OCILobLocator
      @env = env
      @svc = svc
      @locator = locator
      @pos = 0
    end

    def available?
      @locator.is_initialized?(@env)
    end

    def truncate(len)
      raise "uninitialized LOB" unless available?
      @locator.trim(@svc, len)
      self
    end

    def read(size = nil)
      raise "uninitialized LOB" unless available?
      rest = @locator.getLength(@svc) - @pos
      return nil if rest == 0 # eof.
      if size.nil? or size > rest
        size = rest # read until EOF.
      end
      rv = @locator.read(@svc, @pos + 1, size)
      @pos += size
      rv
    end

    def write(data)
      raise "uninitialized LOB" unless available?
      size = @locator.write(@svc, @pos + 1, data)
      @pos += size
      size
    end

    def size
      raise "uninitialized LOB" unless available?
      @locator.getLength(@svc)
    end

    def size=(len)
      raise "uninitialized LOB" unless available?
      @locator.trim(@svc, len)
      len
    end

    def chunk_size # in bytes.
      raise "uninitialized LOB" unless available?
      @locator.getChunkSize(@svc)
    end

    def eof?
      raise "uninitialized LOB" unless available?
      @pos == @locator.getLength(@svc)
    end

    def tell
      @pos
    end

    def seek(pos, whence = IO::SEEK_SET)
      raise "uninitialized LOB" unless available?
      length = @locator.getLength(@svc)
      case whence
      when IO::SEEK_SET
        @pos = pos
      when IO::SEEK_CUR
        @pos += pos
      when IO::SEEK_END
        @pos = length + pos
      end
      @pos = length if @pos >= length
      @pos = 0 if @pos < 0
      self
    end

    def rewind
      @pos = 0
      self
    end

    def close
      @locator.free()
    end

  end

  class BLOB < LOB
  end

  class CLOB < LOB
  end

  # bind or explicitly define
  BindType::Mapping[::String]       = BindType::String
  BindType::Mapping[::OCI8::RAW]    = BindType::RAW
  BindType::Mapping[::OraDate]      = BindType::OraDate
  BindType::Mapping[::Time]         = BindType::Time
  BindType::Mapping[::Date]         = BindType::Date
  BindType::Mapping[::DateTime]     = BindType::DateTime if defined? DateTime
  BindType::Mapping[::OCIRowid]     = BindType::OCIRowid
  BindType::Mapping[::OCI8::BLOB]   = BindType::BLOB
  BindType::Mapping[::OCI8::CLOB]   = BindType::CLOB
  BindType::Mapping[::OCI8::Cursor] = BindType::Cursor

  # implicitly define

  # datatype        type     size prec scale
  # -------------------------------------------------
  # CHAR(1)       SQLT_AFC      1    0    0
  # CHAR(10)      SQLT_AFC     10    0    0
  BindType::Mapping[OCI8::SQLT_AFC] = BindType::String

  # datatype        type     size prec scale
  # -------------------------------------------------
  # VARCHAR(1)    SQLT_CHR      1    0    0
  # VARCHAR(10)   SQLT_CHR     10    0    0
  # VARCHAR2(1)   SQLT_CHR      1    0    0
  # VARCHAR2(10)  SQLT_CHR     10    0    0
  BindType::Mapping[OCI8::SQLT_CHR] = BindType::String

  # datatype        type     size prec scale
  # -------------------------------------------------
  # RAW(1)        SQLT_BIN      1    0    0
  # RAW(10)       SQLT_BIN     10    0    0
  BindType::Mapping[OCI8::SQLT_BIN] = BindType::RAW

  # datatype        type     size prec scale
  # -------------------------------------------------
  # LONG          SQLT_LNG      0    0    0
  BindType::Mapping[OCI8::SQLT_LNG] = BindType::String

  # datatype        type     size prec scale
  # -------------------------------------------------
  # LONG RAW      SQLT_LBI      0    0    0
  BindType::Mapping[OCI8::SQLT_LBI] = BindType::RAW

  # datatype        type     size prec scale
  # -------------------------------------------------
  # CLOB          SQLT_CLOB  4000    0    0
  BindType::Mapping[OCI8::SQLT_CLOB] = BindType::CLOB

  # datatype        type     size prec scale
  # -------------------------------------------------
  # BLOB          SQLT_BLOB  4000    0    0
  BindType::Mapping[OCI8::SQLT_BLOB] = BindType::BLOB

  # datatype        type     size prec scale
  # -------------------------------------------------
  # DATE          SQLT_DAT      7    0    0
  BindType::Mapping[OCI8::SQLT_DAT] = BindType::OraDate

  # datatype        type     size prec scale
  # -------------------------------------------------
  # ROWID         SQLT_RDD      4    0    0
  BindType::Mapping[OCI8::SQLT_RDD] = BindType::OCIRowid

  # datatype           type     size prec scale
  # -----------------------------------------------------
  # FLOAT            SQLT_NUM     22  126 -127
  # FLOAT(1)         SQLT_NUM     22    1 -127
  # FLOAT(126)       SQLT_NUM     22  126 -127
  # DOUBLE PRECISION SQLT_NUM     22  126 -127
  # REAL             SQLT_NUM     22   63 -127
  # calculated value SQLT_NUM     22    0    0
  # NUMBER           SQLT_NUM     22    0    0 (Oracle 9.2.0.2 or below)
  # NUMBER           SQLT_NUM     22    0 -127 (Oracle 9.2.0.3 or above)
  # NUMBER(1)        SQLT_NUM     22    1    0
  # NUMBER(38)       SQLT_NUM     22   38    0
  # NUMBER(1, 0)     SQLT_NUM     22    1    0
  # NUMBER(38, 0)    SQLT_NUM     22   38    0
  # NUMERIC          SQLT_NUM     22   38    0
  # INT              SQLT_NUM     22   38    0
  # INTEGER          SQLT_NUM     22   38    0
  # SMALLINT         SQLT_NUM     22   38    0
  BindType::Mapping[OCI8::SQLT_NUM] = BindType::Number

  # This parameter specify the ruby datatype for
  # calculated number values whose precision is unknown in advance.
  #   select col1 * 1.1 from tab1;
  # For Oracle 9.2.0.2 or below, this is also used for NUMBER
  # datatypes that have no explicit setting of their precision
  # and scale.
  BindType::Mapping[:number_unknown_prec] = BindType::Float

  # This parameter specify the ruby datatype for NUMBER datatypes
  # that have no explicit setting of their precision and scale.
  #   create table tab1 (col1 number);
  #   select col1 from tab1;
  # note: This is available only on Oracle 9.2.0.3 or above.
  # see:  Oracle 9.2.0.x Patch Set Notes.
  BindType::Mapping[:number_no_prec_setting] = BindType::Float
end # OCI8

class OraDate
  def to_time
    begin
      Time.local(year, month, day, hour, minute, second)
    rescue ArgumentError
      msg = format("out of range of Time (expect between 1970-01-01 00:00:00 UTC and 2037-12-31 23:59:59, but %04d-%02d-%02d %02d:%02d:%02d %s)", year, month, day, hour, minute, second, Time.at(0).zone)
      #raise RangeError.new(msg)
    end
  end

  def to_date
    Date.new(year, month, day)
  end

  if defined? DateTime # ruby 1.8.0 or upper
    def to_datetime
      DateTime.new(year, month, day, hour, minute, second)
    end
  end

  def yaml_initialize(type, val) # :nodoc:
    initialize(*val.split(/[ -\/:]+/).collect do |i| i.to_i end)
  end

  def to_yaml(opts = {}) # :nodoc:
    YAML.quick_emit(object_id, opts) do |out|
      out.scalar(taguri, self.to_s, :plain)
    end
  end
end

class OraNumber
  def yaml_initialize(type, val) # :nodoc:
    initialize(val)
  end

  def to_yaml(opts = {}) # :nodoc:
    YAML.quick_emit(object_id, opts) do |out|
      out.scalar(taguri, self.to_s, :plain)
    end
  end
end
