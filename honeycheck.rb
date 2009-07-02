#!/usr/bin/env ruby

# Honeycheck Email Parser
#
# This script extracts URLs in emails delivered to specified POP3 accounts
# and sends them as jobs to Honeyclient deployments, where each job contains
# the URLs extracted from a single email message.

require 'net/pop'
require 'rubygems'
require 'tmail'
require 'uri'
require 'time'
require 'guid'
require 'hpricot'
require 'json'
require 'eventmachine'
require 'mq'
require 'base64'
require 'net/smtp'
require 'socket'
require 'logger'
require 'yaml'
require 'pp'

# Specify the following log format.
class Logger
  def format_message(severity, timestamp, progname, msg)
    /^(.+?):(\d+)(?::in `(.*)')?/ =~ caller(3).first
    file   = Regexp.last_match[1]
    lineno = Regexp.last_match[2].to_i
    method = Regexp.last_match[3]
    "#{timestamp.strftime("%Y-%m-%d %H:%M:%S")} #{sprintf("%5s", severity)} [#{method}] (#{file}:#{lineno}) - #{msg}\n"
  end
end

class Honeycheck
  # Define the configuration file.
  CONFIG_FILE = 'honeycheck.yml'

  # Initialize our instance variables.
  def initialize(pop3_profile = nil)
    # Load the configuration file.
    @CONFIG = YAML.load(IO.read(File.join(CONFIG_FILE)))

    # Create a new logger.
    if @CONFIG['daemonize']
      @LOG = Logger.new(@CONFIG['log']['file'])
    else
      @LOG = Logger.new(STDOUT)
    end

    # Set the logging level.
    @LOG.level = eval("Logger::" + @CONFIG['log']['level'])

    # Sanity check arguments.
    @POP3_PROFILE = pop3_profile
    if (@POP3_PROFILE.nil? ||
        @CONFIG['pop3'][@POP3_PROFILE].nil?)
      @LOG.error "Invalid email profile specified."
      puts "\nHoneycheck Email Parser"
      puts "Usage: #$0 <email_profile>\n\n"
      profiles = @CONFIG['pop3'].keys
      if profiles.size > 0
        puts "- Valid profiles are: " + profiles.join(', ')
      else
        puts "- Warning: No valid profiles found!"
      end
      puts "- See the '" + CONFIG_FILE + "' configuration file for details.\n\n"
      exit
    end

    # Get the PID file.
    @PID_FILE = File.join(@CONFIG['pid_file'])
  end

  def check_pid
    if pid = read_pid
      if process_running? pid
        raise "#{@PID_FILE} already exists (PID: #{pid})"
      else
        @LOG.info "Removing stale PID file: #{@PID_FILE}"
        remove_pid
      end
    end
  end

  def write_pid
    open(@PID_FILE, 'w') {|f| f.write(Process.pid) }
    File.chmod(0644, @PID_FILE)
  end
  private :write_pid

  def remove_pid
    File.delete(@PID_FILE) if pid_exists?
  end
  private :remove_pid

  def read_pid
    open(@PID_FILE, 'r') {|f| f.read.to_i } if pid_exists?
  end
  private :read_pid

  def pid_exists?
    File.exists? @PID_FILE
  end
  private :pid_exists?

  def process_running?(pid)
    Process.getpgid(pid) != -1
  rescue Errno::ESRCH
    false
  end
  private :process_running?

  def daemonize
    check_pid
    exit if fork
    Process.setsid
    exit if fork
    File.umask 0000
    #STDIN.reopen "/dev/null"
    #STDOUT.reopen "/dev/null", "a"
    #STDERR.reopen STDOUT
    @LOG.info "Starting Daemon (PID: #{Process.pid})."
    write_pid
    at_exit { remove_pid }
  end

  def stop_daemon
    unless pid = read_pid
      @LOG.warn "File: '#{@PID_FILE}' not found."
      exit
    end
    @LOG.info "Stopping Daemon (PID: #{pid})."
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      @LOG.error "Process does not exist (PID: #x{pid})."
      exit
    end
  end

  # Helper method, designed to parse all parts of a
  # message body and return an array of all URLs found.
  def parse_body(message = nil)
    return [] if message.nil?
  
    urls = []
    @LOG.debug "Body:"
    if message.multipart?
      message.parts.each do |part|
        @LOG.debug "--- Message Part ---"
        @LOG.debug "Main Type: " + part.main_type
        @LOG.debug "Content Type: " + part.content_type
        if part.multipart?
          urls << parse_body(part)
        else
          if part.content_type == 'text/plain'
            @LOG.debug "Content:"
            @LOG.debug part.body
            urls << extract_urls(part.body)
          elsif part.content_type == 'text/html'
            @LOG.debug "Content:"
            @LOG.debug part.body
            # Parse all <a href> links in the HTML.
            doc = Hpricot(part.body, :fixup_tags => true)
            doc.search("a") do |link|
              link.attributes.each_key do |attrib|
                if attrib.downcase == 'href'
                  urls << extract_urls(link[attrib])
                end
              end
            end
          end
        end
      end
    else
      @LOG.debug message.body
      urls << extract_urls(message.body)
    end
    return urls
  end
  private :parse_body

  # Helper method, designed to extract all URLs found.
  def extract_urls(string = nil)
    return [] if string.nil?
    return URI::extract(string, @CONFIG['protocols_supported'])
  end
  private :extract_urls

  # Process mail.
  def process_mail(pop)
    # Iterate through each AMQP profile found.
    @CONFIG['amqp'].each_pair do |amqp_profile, amqp_config|
      EM.run do
        # Connect to the AMQP server.
        connection = AMQP.connect(:host    => amqp_config['server'],
                                  :port    => amqp_config['port'],
                                  :user    => amqp_config['username'],
                                  :pass    => amqp_config['password'],
                                  :vhost   => amqp_config['vhost'],
                                  :logging => false)
  
        # Open a channel on the AMQP connection.
        channel = MQ.new(connection)
  
        # Declare/create the events exchange.
        events_exchange = MQ::Exchange.new(channel, :topic, amqp_config['events_exchange_name'],
                                           {:passive     => false,
                                            :durable     => true,
                                            :auto_delete => false,
                                            :internal    => false,
                                            :nowait      => false})
  
        pop.each_mail do |message|
          @LOG.info "=== Message ===" 
          mail = TMail::Mail.parse(message.pop)
          @LOG.debug "Sender: " + mail.sender_addr.to_s
          @LOG.info "From: " + mail.from.to_s
          @LOG.debug "Reply To: " + mail.reply_to.to_s
          @LOG.debug "To: " + mail.to.to_s
          @LOG.info "Subject: " + mail.subject.to_s
          @LOG.debug "Date: " + mail.date.utc.to_s
  
          # Figure out who should be notified.
          notifiers = mail.from
          if !mail.reply_to.nil?
            notifiers = mail.reply_to
          end
  
          # Parse the message body and extract all URLs.
          urls = parse_body(mail)
          urls.flatten!.uniq!

          @LOG.info "URLs Found: " + urls.size.to_s

          # Sanity Check: If no URLs were found, then output an error to the
          # sender.
          if urls.size <= 0
            Net::SMTP.start(@CONFIG['smtp']['gateway'],
                            @CONFIG['smtp']['port'], 
                            Socket.gethostname) do |smtp|
  
              # Construct the error message.
              reply = mail.create_reply
              reply.from = @CONFIG['smtp']['from'] + '@' + Socket.gethostname
              reply.to = notifiers
              reply.bcc = @CONFIG['smtp']['admin_address']
              reply.date = Time.now.utc
              reply.subject =  "[" + Socket.gethostname + "] " + @CONFIG['smtp']['error_subject_prefix'] + mail.subject
              reply.body = @CONFIG['smtp']['error_message_body']
              notifiers << @CONFIG['smtp']['admin_address']
              smtp.send_message reply.to_s, reply.from, notifiers
  
              if @CONFIG['smtp']['forward_errors']
                # If specified, forward the original message to the admin.
                forward = mail.create_forward
                forward.from = reply.from
                forward.to = reply.bcc
                forward.date = reply.date
                forward.subject = reply.subject
                smtp.send_message forward.to_s, forward.from, forward.to
              end
            end
            next
          end
  
  
          # Figure out which priority to use.
          priority = amqp_config['default_priority']
          routing_key = amqp_config['default_routing_key']
          if amqp_config['priority_maps'].key?(mail.from.first)
            priority = amqp_config['priority_maps'][mail.from.first]['priority']
            routing_key = amqp_config['priority_maps'][mail.from.first]['routing_key']
          end
 
          # Construct the job. 
          event = {
            'job' => {
              'created_at' => mail.date.utc.iso8601,
              'uuid'       => Guid.new.to_s,
              'job_source' => {
                'name'     => mail.friendly_from,
                'protocol' => 'smtp',
              },
              'job_alerts' => notifiers.map {|from| { 'protocol' => 'smtp',
                                                      'address'  => from }},
              'urls'       => urls.map {|url| { 'url'        => url,
                                                'priority'   => priority,
                                                'url_status' => {'status' => 'queued'} }},
            } 
          }
  
          # Figure out if we know the job source group.
          domain = mail.from.first.split('@').last
          if @CONFIG['groups'].key?(domain)
            event['job']['job_source']['group'] = { 'name' => @CONFIG['groups'][domain] }
          end
 
          if amqp_config['publish_messages'] 
            @LOG.info "[#{amqp_profile}] Publishing Job Using Key: " + routing_key
            @LOG.debug JSON.pretty_generate(event)
            events_exchange.publish(event.to_json, {:routing_key => routing_key, :persistent => true})
            @LOG.info "[#{amqp_profile}] Published Job"
          end
        end
  
        connection.close { EM.stop }
      end
    end

  end
  private :process_mail

  # Check mailbox.
  def check_mailbox
 
    @LOG.info "Checking Mailbox: '" + @CONFIG['pop3'][@POP3_PROFILE]['username'] + '@' + @CONFIG['pop3'][@POP3_PROFILE]['server'] + "'" 
    pop = Net::POP3.new(@CONFIG['pop3'][@POP3_PROFILE]['server'])
    pop.start(@CONFIG['pop3'][@POP3_PROFILE]['username'],
              Base64.decode64(@CONFIG['pop3'][@POP3_PROFILE]['password']))
  
    @LOG.info "(#{pop.n_mails}) messages found."
   
    # Sanity check.
    if !pop.mails.empty?
      # Process all messages.
      process_mail(pop)  

      # Purge messages, if need be.
      if @CONFIG['pop3'][@POP3_PROFILE]['purge_messages']
        @LOG.info "Purging messages."
        pop.delete_all
      else
        @LOG.warn "Retaining all messages."
      end 
    end 
 
    # Close the POP3 connection.
    pop.finish

    @LOG.info "Sleeping for (" + @CONFIG['pop3'][@POP3_PROFILE]['repeat_check_delay'].to_s + ") seconds."
    sleep(@CONFIG['pop3'][@POP3_PROFILE]['repeat_check_delay'])
  end

  def start
    if @CONFIG['daemonize'] 
      daemonize
    end

    Signal.trap(:INT) do
      if @CONFIG['daemonize'] 
        @LOG.info "Stopping Daemon (PID: #{Process.pid})."
      end
      @LOG.info "Shutting down."
      exit
    end

    Signal.trap(:QUIT) do
      if @CONFIG['daemonize'] 
        @LOG.info "Stopping Daemon (PID: #{Process.pid})."
      end
      @LOG.info "Shutting down."
      exit
    end

    while true
      check_mailbox
    end
  end
end

begin
  Honeycheck.new(ARGV[0]).start
rescue
  Logger.new(STDOUT).warn $!.to_s
end
