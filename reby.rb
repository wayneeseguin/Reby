#!/usr/bin/env ruby

# == REBY
#
# Ruby-Eggdrop Bridge Yes-this-letter-has-no-meaning-in-the-acronym
# :title: Reby
# Version:: 0.7.5 (January 3, 2008)
#
# Author:: Pistos (irc.freenode.net)
# http://purepistos.net/eggdrop/reby
#
# == Examples
#
#
#     def test( nick, userhost, handle, channel, text )
#         if text.class == Array
#             text2 = text.toTclList
#             text2.sub!( /^\{/, "" )
#             text2.sub!( /\}$/, "" )
#             text2 = text2.gsub( /\{/, "\\{" ).gsub( /\}/, "\\}" )
#         else
#             text2 = text
#         end
#         $reby.putserv "PRIVMSG #{channel} :Test called: #{nick}, #{userhost}, #{handle}, #{channel}, #{text2}."
#     end
#     $reby.bind( "pub", "-", "!reby", "test" )
#
#     def countus( nick, userhost, handle, channel, text )
#         num = $reby.countusers
#         $reby.putserv "PRIVMSG #{channel} :#{num} (#{num.class})"
#     end
#     $reby.bind( "pub", "-", "!countusers", "countus" )
#
#     class SampleRebyClass
#         def initialize
#         end
#         def anotherTest( nick, userhost, handle, channel, text )
#             $reby.putserv "PRIVMSG #{channel} :#{text}"
#         end
#         def chanlist( nick, userhost, handle, channel, text )
#             listing = ""
#             $reby.chanlist( channel ).each do |member|
#                 listing += member + " "
#             end
#             $reby.putserv "PRIVMSG #{channel} :#{listing}"
#         end
#     end
#     $sample = SampleRebyClass.new
#     $reby.bind( "pub", "-", "!reby2", "anotherTest", "$sample" )
#     $reby.bind( "pub", "-", "!chanlist", "chanlist", "$sample" )
#
#     return_id = $reby.evalTcl( "countusers" )
#     puts "Got back: " + $reby.getReturnValue( return_id )
#


require "net/telnet"
require "thread"
require 'ostruct'
require 'eventmachine'

#Thread::abort_on_exception = true

# The Reby class contains wrapper methods for the eggdrop Tcl commands, as at
# http://www.eggheads.org/support/egghtml/1.6.15/tcl-commands.html
# Any commands not defined here can be called by using #evalTcl,
# or even #sendTcl.
class Reby
    def initialize( config_file, console_mode = false, console_command_file = nil )
        # These values are just defaults.  Specify them in reby.conf.
        @host = "localhost"
        @port = 6086
        @username = "nobody"
        @password = nil
        @log_timestamp_format = "%Y-%m-%d %H:%M:%S"
        @logfile = $stdout
        @config_file = config_file
        @debug_channel = '#mathetes'
        @console_mode = console_mode
        @console_command_file = console_command_file

        if @console_mode
            puts "Running in console mode."
            @console = {
                :pub_binds => Hash.new,
                :msg_binds => Hash.new,
                :nick => 'Pistos',
                :queued_commands => Array.new,
                :timers => Hash.new,
                :utimers => Hash.new
            }
        end

        # Most users won't need to change anything under here.
        # Change these if you think you know what you're doing.
        @RETURN_VALUE_CHECK_INTERVAL = 0.5
        @LOOP_CHECK_MILESTONE = 10
        @REBY_PREFIX = "^\\[\\d+:\\d+\\] REBY"

        @VERSION = "0.7.5"
        @LAST_MODIFIED = "January 24, 2008"
        @GOD_IS_GOOD = true

        @registered_methods = Array.new
        @next_return_id = 0
        @return_values = Array.new
        @return_id_mutex = Mutex.new
        @is_identified = Hash.new
        @script_threads = Array.new
        @con = nil

        @excuses = File.readlines( File.join( File.dirname( __FILE__ ), 'excuses.txt' ) )
    end

    def loadConfiguration
        log "Loading configuration from #{@config_file}"
        permissions = File.stat( @config_file ).mode
        if ( permissions & 040 ) == 1
            log "Warning: #{@config_file} is group readable! (#{'%o' % permissions})"
        end
        if ( permissions & 04 ) == 1
            log "Warning: #{@config_file} is world readable! (#{'%o' % permissions})"
        end
        threads = []
        IO.readlines( @config_file ).each do |line|
            case line
                when /^host (.+)$/
                    @host = $1
                when /^load (.+)$/
                    connect
                    filename = $1
                    log "Loading '#{filename}' ..."
                    #threads << Thread.new( filename ) do |fn|
                        begin
                            #load( fn )
                            load filename
                            log "... Loaded '#{filename}'"
                        rescue Exception => e
                            log_exception e
                        end
                    #end
                when /^log (.+)$/
                    @logfile = File.new( $1, "a" )
                when /^password (.+)$/
                    @password = $1
                when /^port (.+)$/
                    @port = $1.to_i
                when /^timestamp (.+)$/
                    @log_timestamp_format = $1
                when /^username (.+)$/
                    @username = $1
            end
        end
        if @logfile != $stdout
            $stderr.close
            $stderr = @logfile
        end
        if @console_command_file
            load_console_commands @console_command_file
        end
        connect
    end

    # Connects to the eggdrop via telnet and logs in if not already connected.
    def connect
        if @con == nil and not @console_mode
            log "Connecting to eggdrop"
            @con = Net::Telnet::new(
                {
                    "Host" => @host,
                    "Port" => @port,
                    "Telnetmode" => false
                }
            )

            log "Logging into eggdrop"
            login

            begin
                @con.puts( ".rehash" )
                defineRebyProcs

                # Clear extant Reby-originated binds.

                sendTcl "set old_binds [binds \"rebybind__*\"]"
                sendTcl "foreach b $old_binds { " +
                    "putlog \"Unbinding [lindex $b 0] [lindex $b 1] [lindex $b 2] [lindex $b 4]\"; " +
                    "unbind [lindex $b 0] [lindex $b 1] [lindex $b 2] [lindex $b 4]" +
                    "}"

                # Clear extant Reby-originated timers.

                sendTcl "set old_timers [timers]"
                sendTcl "foreach t $old_timers { " +
                    "if {[string match {*rebybind*} [lindex $t 1]]} { " +
                        "putlog \"Killing timer [lindex $t 1] [lindex $t 2]\"; " +
                        "killtimer [lindex $t 2] " +
                    "} " +
                "}"
            rescue Errno::EPIPE
                log "*** Login failure?"
                raise
            end
        end
    end
    protected :connect

    def defineRebyProcs
        sendTcl "proc rebyCall {instance method_name {arglist \"\"}} { " +
            "putlog \"REBY call $instance $method_name $arglist\"; " +
            "return 0 " +
            "}"

        sendTcl "proc rebyTcl {return_id tcl_code} {" +
            " putlog \"REBY return $return_id [eval $tcl_code]\" " +
            "}"

        sendTcl "proc putnow { a } { " +
            "append a \"\\n\";  putdccraw 0 [string length $a] $a; " +
        "}"
    end
    protected :defineRebyProcs

    def login
        @con.waitfor( /(?:Please enter your n|N)ickname\./ )
        @con.puts( @username )
        @con.waitfor( /Enter your password\./ )
        if @password == nil
            print "Password: "; $stdout.flush
            @password = gets.strip
        end
        @con.puts( @password )
    end
    protected :login

    def logout
        @con.puts( ".quit" )
        @con.close
    end
    protected :logout

    # Makes a list out of a Tcl-syntax list.
    # how_many is how many elements at most the top-level array should contain.
    # Set how_many to -1 for no limit.
    # You may want to use String.changeBraces before calling this,
    # and String.restoreBraces afterward.
    def makeArray( list_text, how_many = -1, max_depth = 999 )
        return nil if list_text.nil?
        remainder = list_text.strip
        if remainder !~ /(?:^| )\{|\}(?:$| )/
            # No braces: Just a single-level list.
            a = remainder.strip.replaceQuotes.split( /(.*?[^\\])\s+/, how_many )
            a.delete( "" )
            return a
        end
        retval = Array.new
        num_done = 0

        while @GOD_IS_GOOD
            match = /(?:^| )\{/.match remainder
            if match == nil
                # No braces: Just a single-level list.
                a = remainder.strip.replaceQuotes.split( /(.*?[^\\])\s+/, how_many - num_done )
                a.delete( "" )
                retval.concat a
                break
            end
            pre = match.pre_match.strip.replaceQuotes.split( /(.*?[^\\])\s+/, how_many - num_done )
            if pre != nil
                pre.delete( "" )
                retval.concat pre
                num_done += pre.length
                if num_done == how_many
                    break
                end
            end
            remainder = match.post_match
            if num_done == how_many - 1
                retval.push remainder.gsub( /(?:^| )\{|\}(?:$| )/, "" )
                break
            end

            # Find the matching close brace.

            match_text = ""
            catch( :problem ) do
                while @GOD_IS_GOOD
                    # Expand our match_text to the next close brace
                    match2 = /\}(?:$| )/.match remainder
                    if match2 == nil
                        log "Closing brace not found (#{remainder})."
                        match_text = "{" + remainder.replaceQuotes
                        remainder = ""
                        throw :problem
                    end
                    remainder = match2.post_match
                    match_text += match2.pre_match
                    if match_text.count( "{" ) == match_text.count( "}" )
                        break
                    end
                    match_text += "} "
                end

                # This match_text is itself a list, so we must construct a
                # subarray.
                next_depth = max_depth - 1
                if next_depth > 0
                    match_text = makeArray( match_text, how_many, next_depth )
                end
            end

            retval.push match_text

            num_done += 1
            if num_done == how_many - 1
                retval.push remainder.gsub( /(?:^| )\{|\}(?:$| )/, "" ).replaceQuotes
                break
            end
        end

        return retval
    end

    # Sends raw Tcl code to the eggdrop for evaluation.
    # Ignores any return value.
    def sendTcl( tcl_code )
        if not @console_mode
            log "sendTcl: #{tcl_code}"
            tcl_code_stripped = tcl_code.gsub( /\n/, "" )
            @con.puts ".tcl #{tcl_code_stripped}"
        end
    end

    # Evaluate raw Tcl code.
    # Returns a return id code which is passed to #getReturnValue.
    def evalTcl( tcl_code )
        return_id = -1
        @return_id_mutex.synchronize do
            return_id = @next_return_id
            @next_return_id += 1
        end
        @return_values[ return_id ] = nil
        sendTcl "rebyTcl #{return_id} {#{tcl_code}}"
        return return_id
    end

    # Obtains the return value of Tcl code executed with #evalTcl.
    # The return id code returned by #evalTcl must be passed in as an argument.
    # The return value is always of type String; use the Reby.get___ReturnValue
    # methods to get the return value in other forms.
    def getReturnValue( return_id )
        return nil if @console_mode

        num_loops = 0
        printed_stack = false
        while @return_values[ return_id ] == nil
            sleep @RETURN_VALUE_CHECK_INTERVAL
            num_loops += 1
            if num_loops == @LOOP_CHECK_MILESTONE
                log "Warning: Stuck in getReturnValue( #{return_id} )"
                if not printed_stack
                    begin
                        raise Exception.exception
                    rescue Exception => e
                        log e.backtrace.join( "\n" )
                        printed_stack = true
                    end
                end
                num_loops = 0
            end
        end
        return @return_values[ return_id ]
    end
    def getBooleanReturnValue( return_id )
        return ( getReturnValue( return_id ) != "0" )
    end
    def getIntegerReturnValue( return_id )
        return getReturnValue( return_id ).to_i
    end
    def getListReturnValue( return_id )
        return makeArray( getReturnValue( return_id ) )
    end

    def getFullMethodName( instance, method_name )
        retval = method_name
        if instance != "nil"
            retval = instance + "." + retval
        end
        return retval
    end
    protected :getFullMethodName

    def getTclProcName( instance, method_name )
        return "rebybind_#{ instance.gsub( /\$/, '_' ) }_#{ method_name }"
    end
    protected :getTclProcName

    def registerMethod( method_name, instance = "nil" )
        tcl_proc_name = getTclProcName( instance, method_name )
        full_method_name = getFullMethodName( instance, method_name )
        @registered_methods.push full_method_name
        return tcl_proc_name
    end
    protected :registerMethod

    # Scripts that run independent threads should use this method to register
    # their thread(s) with Reby, so that the threads are cleanly terminated
    # when Reby is reset.  If a thread is not registered, it will continue to
    # exist across a reset, resulting in multiple threads doing the same work.
    def registerThread( thread )
        @script_threads.push thread
    end

    # Writes a line of text to Reby's log file, which defaults to $stdout,
    # or can be specified in reby.conf.
    def log( text )
        message = "#{Time.new.strftime( @log_timestamp_format )} #{text}"
        if not @console_mode
            @logfile.puts message
            #@logfile.puts caller.join( "\n\t" )
            @logfile.flush
        else
            puts message
        end
    end

    def excuse
      @excuses[ rand( @excuses.size ) ]
    end

    def log_exception( e )
        putserv "PRIVMSG #{@debug_channel} :Eep!  A critical Reby error! #{e.class} \"#{excuse}\""
        log "Reby error: #{e.class} #{e.message}"
        log e.backtrace.join( "\n" )
    end

    # Don't put $ at the beginning of tcl_varname.
    def getTclGlobal( tcl_varname )
        sendTcl "proc rebyGetTclGlobal {} { " +
            "global #{tcl_varname}; " +
            "return $#{tcl_varname} " +
            "}"
        return getReturnValue(
            evalTcl(
                "rebyGetTclGlobal"
            )
        )
    end

    def isIdentified( nick )
        return @is_identified[ nick ]
    end

    def checkIfIdentified( nick )
        @is_identified[ nick ] = nil
        putserv "PRIVMSG NickServ :info #{nick}"
        count = 0
        while @is_identified[ nick ] == nil
            sleep 1
            count += 1
            if count > 20
                # Timeout
                log "ID timeout (#{nick})"
                break
            end
        end
        retval = false
        if @is_identified[ nick ]
            retval = true
        end
        return retval
    end

    def nicknameNotice( nick, userhost, handle, text, dest )
        notice = text.join( " " )
        if notice =~ /Nickname: (\S+)/
            who = $1
            if notice =~ /<< ONLINE >>/
                @is_identified[ who ] = true
            else
                @is_identified[ who ] = false
            end
            log "#{who} identified: #{@is_identified[ who ]}"
        elsif notice =~ /The nickname.+is private/
            @is_identified[ nick ] = false
        else
            log "Notice: #{notice}"
        end
    end

    # -----------------------------------------------------------------------

    # This is the main program loop.
    # It reads in lines and responds to Reby commands issued by the eggdrop bot.

    def start
        f = File.new( "reby.pid", "w" )
        f.puts Process.pid
        f.close

        log "Reby #{@VERSION} (#{@LAST_MODIFIED}) started."

        if not @console_mode
            normal_start
        else
            console_start
        end
    end

    def normal_start
        bind( "notc", "-", "*ickname*", "nicknameNotice", "$reby" )

        while $reby_signal == nil
            begin
                while $reby_signal == nil
                    line = @con.readline
                    #log line if line =~ /^Tcl|REBY/
                    case line
                        when /#{@REBY_PREFIX} call (\S+) (\S+) (.+)/
                            instance = $1
                            method_name = $2
                            rest = $3.changeBraces
                            rest = rest.unescapeBackslashed
                            arglist = makeArray( rest, -1, 1 )
                            arglist.collect! do |arg|
                                arg.toReby
                            end

                            full_method_name = getFullMethodName( instance, method_name )
                            call_method( full_method_name, arglist )
                        when /#{@REBY_PREFIX} return (\d+) (.+)/
                            return_id = $1.to_i
                            retval = $2
                            #log "Reby return (#{return_id}): #{retval}"
                            @return_values[ return_id ] = retval.strip
                        when /#{@REBY_PREFIX}/
                            log "*** UNKNOWN REBY MESSAGE ***"
                            log line
                        #when /^Tcl error: (.+)$/

                    end
                end
            rescue EOFError
                log "telnet EOF"
                sleep( 5 )
            end
        end

        logout
    end

    def call_method( full_method_name, arglist )
        if @registered_methods.include?( full_method_name )
            ruby_code = "#{full_method_name}(#{ arglist.join( ',' ) })"
            Thread.new( ruby_code ) do |code_to_evaluate|
                code_to_evaluate =
                    "begin\n" +
                        code_to_evaluate +
                    <<-EOS

                        rescue Exception => e
                            log "call_method: \#\{ruby_code\}"
                            log_exception e
                        end
                    EOS

                eval code_to_evaluate
            end
        else
            log "No such method: #{full_method_name}"
        end
    end

    def load_console_commands( file )
        return if not @console

        File.open( file ) do |f|
            f.each_line do |line|
                @console[ :queued_commands ] << line
            end
        end
    end

    def console_start
        loop do
            prompt = 'reby>'
            case @console[ :target ]
                when :pub
                    prompt = "pub #{@console[ :channel ]} <#{@console[ :nick ]}>"
                when :msg
                    prompt = "msg <#{@console[ :nick ]}>"
            end
            $stdout.print "#{prompt} "; $stdout.flush
            if @console[ :queued_commands ].empty?
                line = STDIN.gets
            else
                line = @console[ :queued_commands ].shift.strip
                puts line
            end
            break if line.nil?
            line.strip!
            case line
                when %r{^/(.+)}
                    process_console_command $1
                else
                    process_console_line line
            end
        end
    end

    def cleanup
        @script_threads.each do |thread|
            thread.exit
        end
    end

    def process_console_command( command )
        case command
            when /^(pub|msg)(.*)/
                @console[ :target ] = $1.to_sym
                rest = $2
                if rest
                    @console[ :channel ] = rest.strip
                end
            when /^nick +(\S+)$/
                @console[ :nick ] = $1
            when /^reby$/
                @console[ :target ] = nil
            else
                puts "Change target:"
                puts "\t/pub [channel]"
                puts "\t/msg [channel]"
                puts "\t/reby"
                puts "<any text> to send to target"
                puts "^D to quit"
        end
    end

    def bind_for( bindset, line )
        /^(\S+)(?:\s+(.*))?$/ =~ line
        line_command = $1
        line_args = $2
        trigger, bind_specs = @console[ bindset ].find { |k,v|
            k == line_command
        }
        [ bind_specs, line_args ]
    end

    def process_console_line( line )
        case @console[ :target ]
            when :pub
                Thread.new do
                    bind_specs, line_args = bind_for( :pub_binds, line )
                    if bind_specs
                        obj = eval( bind_specs[ :object_name ] )
                        if obj
                            bind_args = [
                                @console[ :nick ],
                                'bleh@blue.com',
                                nil,
                                @console[ :channel ],
                                line_args
                            ]
                            begin
                                obj.send( bind_specs[ :method ], *bind_args )
                            rescue Exception => e
                                $stderr.puts "Eep!  A critical Reby error! \"#{excuse}\""
                                log "Reby error: " + e.message
                                log e.backtrace.join( "\n" )
                            end
                        end
                    end
                end
            when :msg
                Thread.new do
                    bind_specs, line_args = bind_for( :msg_binds, line )
                    if bind_specs
                        obj = eval( bind_specs[ :object_name ] )
                        if obj
                            bind_args = [
                                @console[ :nick ],
                                'bleh@blue.com',
                                nil,
                                line_args
                            ]
                            obj.send( bind_specs[ :method ], *bind_args )
                        end
                    end
                end
            else
                # Evaluate as Reby (Ruby) code.
                Thread.new( line ) do |code_to_evaluate|
                    code_to_evaluate =
                        "begin\n" +
                            code_to_evaluate +
                        <<-EOS

                            rescue Exception => e
                                $stderr.puts "Eep!  A critical Reby error! \"#{excuse}\""
                                log "Reby error: " + e.message
                                log e.backtrace.join( "\n" )
                            end
                        EOS

                    eval code_to_evaluate
                end
        end
    end

    #-----------------------------------------------------------------------
    #++

    def backup
        sendTcl "backup"
    end

    def bind( type, flags, command_or_mask, method_name, instance = "nil" )
        tcl_proc_name = registerMethod( method_name, instance )

        sendTcl "bind #{type} #{flags} \"#{command_or_mask}\" #{tcl_proc_name}"

        case type.downcase
            when "join"
                sendTcl "proc #{tcl_proc_name} {nick userhost handle channel} { " +
                    "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle $channel] " +
                    "}"
            when "msg", "msgm"
                if not @console_mode
                    sendTcl "proc #{tcl_proc_name} {nick userhost handle text} { " +
                        "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle [subst -nobackslashes -nocommands -novariables $text]] " +
                        "}"
                else
                    bind_spec = {
                        :object_name => instance,
                        :method => method_name.to_sym,
                    }
                    @console[ :msg_binds ][ command_or_mask ] = bind_spec
                end
            when "part"
                sendTcl "proc #{tcl_proc_name} {nick userhost handle channel {msg ""}} { " +
                    "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle $channel [subst -nobackslashes -nocommands -novariables $msg]] " +
                    "}"
            when "pub","pubm"
                if not @console_mode
                    sendTcl "proc #{tcl_proc_name} {nick userhost handle channel text} { " +
                        "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle $channel [subst -nobackslashes -nocommands -novariables $text]] " +
                        "}"
                else
                    bind_spec = {
                        :object_name => instance,
                        :method => method_name.to_sym,
                    }
                    @console[ :pub_binds ][ command_or_mask ] = bind_spec
                end
            when "notc"
                sendTcl "proc #{tcl_proc_name} {nick userhost handle text {dest ""}} { " +
                    "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle [subst -nobackslashes -nocommands -novariables $text] $dest] " +
                    "}"
            when "raw"
                sendTcl "proc #{tcl_proc_name} {from keyword text} { " +
                    "rebyCall {#{instance}} #{method_name} [list $from $keyword [subst -nobackslashes -nocommands -novariables $text]]; " +
                    "return 0 " +
                    "}"
            when "sign"
                sendTcl "proc #{tcl_proc_name} {nick userhost handle channel reason} { " +
                    "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle $channel [subst -nobackslashes -nocommands -novariables $reason]] " +
                    "}"
            when "ctcp"
                sendTcl "proc #{tcl_proc_name} {nick userhost handle dest keyword text} { " +
                    "rebyCall {#{instance}} #{method_name} [list $nick $userhost $handle $dest $keyword [subst -nobackslashes -nocommands -novariables $text]] " +
                    "}"
        end
    end

    def binds( type_mask )
        return getListReturnValue( evalTcl( "binds #{type_mask}" ) )
    end

    def botishalfop( channel = "" )
        return getBooleanReturnValue( evalTcl( "botishalfop #{channel}" ) )
    end

    def botisop( channel = "" )
        return getBooleanReturnValue( evalTcl( "botisop #{channel}" ) )
    end

    def botisvoice( channel = "" )
        return getBooleanReturnValue( evalTcl( "botisvoice #{channel}" ) )
    end

    def botonchan( channel = "" )
        return getBooleanReturnValue( evalTcl( "botonchan #{channel}" ) )
    end

    def callevent( event )
        sendTcl "callevent #{event}"
    end

    def chanlist( channel, flags = "" )
        return getListReturnValue( evalTcl( "chanlist #{channel} #{flags}" ) )
    end

    def channel_add( name, option_list )
        sendTcl "channel add #{name} {#{option_list.join( ' ' )}}"
    end

    # Returns a String value
    def channel_get( name, setting )
        return getReturnValue( evalTcl( "channel get #{name} #{setting}" ) )
    end

    def channel_info( name )
        return getListReturnValue( evalTcl( "channel info #{name}" ) )
    end

    def channel_remove( name )
        sendTcl "channel remove #{name}"
    end

    def channel_set( name, options )
        sendTcl "channel set #{name} #{options}"
    end

    def channels
        return getListReturnValue( evalTcl( "channels" ) )
    end

    def chattr( handle, changes = "", channel = "" )
        return getReturnValue( evalTcl( "chattr #{handle} #{changes} #{channel}" ) )
    end

    def chhandle( old_handle, new_handle )
        return getBooleanReturnValue( evalTcl( "chhandle #{old_handle} #{new_handle}" ) )
    end

    def clearqueue( queue )
        sendTcl "clearqueue #{queue}"
    end

    def countusers
        return getIntegerReturnValue( evalTcl( "countusers" ) )
    end

    def decrypt( key, string )
        return getReturnValue( evalTcl( "decrypt #{key} #{string}" ) )
    end

    def die( reason = "" )
        sendTcl( "die #{reason}" )
    end

    def dumpfile( nick, filename )
        sendTcl "dumpfile #{nick.toTclString} #{filename}"
    end

    def duration( seconds )
        return getReturnValue( evalTcl( "duration #{seconds}" ) )
    end

    def encpass( password )
        return getReturnValue( evalTcl( "encpass #{password}" ) )
    end

    def encrypt( key, string )
        return getReturnValue( evalTcl( "encrypt #{key} #{string}" ) )
    end

    def finduser( nickuserhost )
        sendTcl "finduser #{nickuserhost}"
    end

    def flushmode( channel )
        sendTcl "flushmode #{channel}"
    end

    def getchanhost( nick, channel = "" )
        return getReturnValue( evalTcl( "getchanhost #{nick.toTclString} #{channel}" ) )
    end

    def getchanidle( nick, channel )
        return getIntegerReturnValue( evalTcl( "getchanidle #{nick.toTclString} #{channel}" ) )
    end

    # Returns a String value.  (Should this be a Fixnum?)
    def getchanjoin( nick, channel )
        return getReturnValue( evalTcl( "getchanjoin #{nick.toTclString} #{channel}" ) )
    end

    def getchanmode( channel )
        return getReturnValue( evalTcl( "getchanmode #{channel}" ) )
    end

    def getuser( handle, entry_type, extra_info = "" )
        return_type = "string"
        case entry_type
            when "BOTADDR", "HOSTS", "LASTON"
                return_type = "list"
        end
        retval = getReturnValue( evalTcl( "getuser #{handle} #{entry_type} #{extra_info}" ) )
        if return_type == "list"
            retval = makeArray( retval )
        end
        return retval
    end

    def hand2nick( handle, channel = "" )
        return getReturnValue( evalTcl( "hand2nick #{handle} #{channel}" ) )
    end

    def handonchan( handle, channel = "" )
        return getReturnValue( evalTcl( "handonchan #{handle} #{channel}" ) )
    end

    def isbotnick( nick )
        return getBooleanReturnValue( evalTcl( "isbotnick #{nick.toTclString}" ) )
    end

    def isdynamic( channel )
        return getBooleanReturnValue( evalTcl( "isdynamic #{channel}" ) )
    end

    def ishalfop( nick, channel = "" )
        return getBooleanReturnValue( evalTcl( "ishalfop #{nick.toTclString} #{channel}" ) )
    end

    def isop( nick, channel = "" )
        return getBooleanReturnValue( evalTcl( "isop #{nick.toTclString} #{channel}" ) )
    end

    def isvoice( nick, channel = "" )
        return getBooleanReturnValue( evalTcl( "isvoice #{nick.toTclString} #{channel}" ) )
    end

    def jump( server = "", port = "", password = "" )
        sendTcl "jump #{server} #{port} #{password}"
    end

    def killtimer( id )
        if @console_mode
            @console[ :timers ][ id ].kill
            @console[ :timers ].delete( id )
        else
            sendTcl "killtimer #{id}"
        end
    end

    def killutimer( id )
        if @console_mode
            @console[ :utimers ][ id ].kill
            @console[ :utimers ].delete( id )
        else
            sendTcl "killutimer #{id}"
        end
    end

    def loadchannels
        sendTcl "loadchannels"
    end

    def maskhost( nickuserhost )
        return getReturnValue( evalTcl( "maskhost #{nickuserhost}" ) )
    end

    def matchattr( handle, flags, channel = "" )
        return getBooleanReturnValue( evalTcl( "matchattr #{handle} #{flags} #{channel}" ) )
    end

    def md5( string )
        return getReturnValue( evalTcl( "md5 #{string}" ) )
    end

    def myip
        return getReturnValue( evalTcl( "myip" ) )
    end

    def newban( target, creator, comment = "Ban set at #{Time.now}", lifetime = nil, options = nil )
        command = "newban #{target.toTclString} #{creator.toTclString} {#{comment}} "
        if lifetime
            command << " #{lifetime}"
        end
        if options
            command << " #{options}"
        end
        sendTcl command
    end

    def nick2hand( nick, channel = "" )
        return getReturnValue( evalTcl( "nick2hand #{nick.toTclString} #{channel}" ) )
    end

    def onchan( nick, channel = "" )
        return getBooleanReturnValue( evalTcl( "onchan #{nick.toTclString} #{channel}" ) )
    end

    def onchansplit( nick, channel = "" )
        return getReturnValue( evalTcl( "onchansplit #{nick.toTclString} #{channel}" ) )
    end

    def passwdok( handle, password )
        return getBooleanReturnValue( evalTcl( "passwdok #{handle} #{password}" ) )
    end

    def pushmode( channel, mode, arg = "" )
        sendTcl "pushmode #{channel} #{mode} #{arg}"
    end

    def doPut( type, text, options = "" )
        message = "#{type} {#{ text }} #{options}"
        if not @console_mode
            sendTcl message
        else
            puts message
        end
    end
    protected :doPut

    def putcmdlog( text )
        sendTcl "putcmdlog #{ text }"
    end
    def putnow( text )
        doPut( "putnow", text )
    end
    def puthelp( text, options = "" )
        doPut( "puthelp", text, options )
    end
    def putkick( channel, nicklist, reason = "" )
        if nicklist.class == Array
            nicklist.collect! { |nick| nick.toTclString }
            nicks = nicklist.join( "," )
        else
            nicks = nicklist.toTclString
        end
        sendTcl "putkick #{channel} #{nicks} #{reason}"
    end
    def putlog( text )
        sendTcl "putlog #{ text }"
    end
    def putloglev( levels, channel, text )
        sendTcl "putloglev #{levels} #{channel} #{ text }"
    end
    def putquick( text, options = "" )
        doPut( "putquick", text, options )
    end
    def putserv( text, options = "" )
        doPut( "putserv", text, options )
    end
    def putxferlog( text )
        sendTcl "putxferlog #{ text }"
    end

    def queuesize( queue = "" )
        sendTcl "queuesize #{queue}"
    end

    def rehash
        sendTcl "rehash"
    end

    def reload
        sendTcl "reload"
    end

    def resetchan( channel )
        sendTcl "resetchan #{channel}"
    end

    def restart
        sendTcl "restart"
    end

    def save
        sendTcl "save"
    end

    def savechannels
        sendTcl "savechannels"
    end

    def setuser( handle, entry_type, extra_info = "" )
        sendTcl "setuser #{handle} #{entry_type} #{extra_info}"
    end

    def timer( minutes, method_name, instance = "nil" )
        if not @console_mode
            tcl_proc_name = registerMethod( method_name, instance )
            sendTcl "proc #{tcl_proc_name} {} { " +
                "rebyCall {#{instance}} #{method_name} " +
                "}"
            return_id = evalTcl( "timer #{minutes} #{tcl_proc_name}" )
            return getReturnValue( return_id )
        else
            duration = minutes * 60
            t = OpenStruct.new
            t.end_time = Time.now + duration
            t.ident = t.start_time.to_f
            t.full_method_name = getFullMethodName( instance, method_name )
            registerMethod( method_name, instance )
            t.thread = Thread.new( duration, t.full_method_name ) do |d,m|
                sleep( d )
                call_method( m, [] )
            end
            @console[ :timers ][ t.ident ] = t
            return t.ident
        end
    end

    def timers
        if @console_mode
            @console[ :timers ].values.find_all { |t|
                t.thread.alive?
            }.map { |t|
                [
                    ( t.end_time.to_i - Time.now.to_i ) / 60.0,
                    t.full_method_name,
                    t.ident
                ]
            }
        else
            getListReturnValue( evalTcl( "timers" ) )
        end
    end

    def topic( channel )
        return getReturnValue( evalTcl( "topic #{channel}" ) )
    end

    def unbind( type, flags, command_or_mask, method_name, instance = "nil" )
        tcl_proc_name = getTclProcName( instance, method_name )
        sendTcl "unbind #{type} #{flags} #{command_or_mask} #{tcl_proc_name}"
    end

    def unixtime
        return getIntegerReturnValue( evalTcl( "unixtime" ) )
    end

    def utimer( seconds, method_name, instance = "nil" )
        if not @console_mode
            tcl_proc_name = registerMethod( method_name, instance )
            sendTcl "proc #{tcl_proc_name} {} { " +
                "rebyCall {#{instance}} #{method_name} " +
                "}"
            return_id = evalTcl( "utimer #{seconds} #{tcl_proc_name}" )
            return getReturnValue( return_id )
        else
            duration = seconds
            t = OpenStruct.new
            t.end_time = Time.now + duration
            t.ident = t.start_time.to_f
            t.full_method_name = getFullMethodName( instance, method_name )
            registerMethod( method_name, instance )
            t.thread = Thread.new( duration, t.full_method_name ) do |d,m|
                sleep( d )
                call_method( m, [] )
            end
            @console[ :utimers ][ t.ident ] = t
            return t.ident
        end
    end

    def userlist( flags = "" )
        return getListReturnValue( evalTcl( "userlist #{flags}" ) )
    end

    def utimers
        if @console_mode
            @console[ :utimers ].values.find_all { |t|
                t.thread.alive?
            }.map { |t|
                [
                    ( t.end_time.to_i - Time.now.to_i ),
                    t.full_method_name,
                    t.ident
                ]
            }
        else
            getListReturnValue( evalTcl( "utimers" ) )
        end
    end

    def validchan( channel )
        return getBooleanReturnValue( evalTcl( "validchan #{channel}" ) )
    end

    def validuser( handle )
        return getBooleanReturnValue( evalTcl( "validuser #{handle}" ) )
    end

    def washalfop( nick, channel )
        return getBooleanReturnValue( evalTcl( "washalfop #{nick.toTclString} #{channel}" ) )
    end

    def wasop( nick, channel )
        return getBooleanReturnValue( evalTcl( "wasop #{nick.toTclString} #{channel}" ) )
    end

end

class String
    def replaceQuotes
        # We should only need two backslashes, right?  Possible Ruby bug.
        #return gsub( /'/, "\\'" )
        #return gsub( /'/, "\\\\'" )
        return gsub( /'/ ) { |s| "\\" + s }
    end
    def replaceCloseBraces
        return gsub( /\}/, "\\}" )
    end
    def changeBraces
        return gsub( /\\\{/, "\001" ).gsub( /\\\}/, "\002" )
    end
    def restoreBraces
        return gsub( /\001/, "\\{" ).gsub( /\002/, "\\}" )
    end
    def unescapeBackslashed
        return gsub( /\\([^ ])/, "\\1" )
    end
    def toReby
        return "'" + restoreBraces.replaceQuotes + "'"
    end
    def to_a
        return [ self ]
    end
    def join( joinstr = " " )
        return self
    end

    # Surrounds with curly braces if needed.
    def toTclString
        retval = to_s
        if retval =~ /[\[\]]/
            retval = "{#{retval}}"
        end
        return retval
    end
end

class Array
    def toReby
        retval = "[ "
        each do |element|
            if element.class == Array
                retval += element.toReby
            else
                retval += element.toReby
            end
            retval += ", "
        end
        return retval[ 0..(length > 0 ? -3 : -1) ] + " ]"
    end

    def toTclList
        retval = "{"
        each do |element|
            if element.class == Array
                retval += element.toTclList
            else
                retval += element
            end
            retval += " "
        end
        return retval[ 0..(length > 0 ? -2 : -1) ] + "}"
    end
end

# ---------------------------------------------------------------------------

if PLATFORM !~ /win/
    trap( "SIGHUP" ) do | |
        $reby_signal = "SIGHUP"
        $reby.log "Received SIGHUP"
    end
    trap( "SIGTERM" ) do | |
        $reby_signal = "SIGTERM"
        $reby.log "Received SIGTERM"
    end
end

$reby = nil
begin
    loop do
        $reby_signal = nil
        args = ARGV.dup
        console_mode = false
        conf_file = 'reby.conf'
        console_command_file = nil

        while args.length > 0
            arg = args.shift
            case arg
                when '--console'
                    console_mode = true
                when
                    '--console-commands'
                    console_command_file = args.shift
                when '--help', '-h'
                    $stderr.puts "#{$0} [options] <configuration file>"
                    $stderr.puts "Options:"
                    $stderr.puts "\t--console"
                    $stderr.puts "\t--console-commands <command file>"
                    $stderr.puts "\t--help"
                    exit 1
                else
                    conf_file = arg
            end
        end

        $reby = Reby.new( conf_file, console_mode, console_command_file )
        $reby.loadConfiguration
        $reby.start
        break if $reby_signal == "SIGTERM" or console_mode
        $reby.log "*** Restarting ***"
        $reby.cleanup
    end
    $reby.log "*** Terminating ***"
rescue Exception => e
    if $reby
        $reby.log( "Reby error: " + e.message )
        $reby.log( e.backtrace.join( "\n" ) )
    else
        $stderr.puts( "Reby error: " + e.message )
        $stderr.puts( e.backtrace.join( "\n" ) )
    end
    raise
end
