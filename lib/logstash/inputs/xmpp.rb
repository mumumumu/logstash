# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"

# Monkey patch to fix the REXML's failure of parsing XML that xmpp servers send.
# See https://github.com/lnussbaum/xmpp4r/issues/3
require 'socket'
class TCPSocket
  def external_encoding
    Encoding::BINARY
  end
end

require 'rexml/source'
class REXML::IOSource
  alias_method :encoding_assign, :encoding=
  def encoding=(value)
    encoding_assign(value) if value
  end
end

begin
  # OpenSSL is optional and can be missing
  require 'openssl'
  class OpenSSL::SSL::SSLSocket
    def external_encoding
      Encoding::BINARY
    end
  end
rescue
end
# End monkey patch

# This input allows you to receive events over XMPP/Jabber.
#
# This plugin can be used for accepting events from humans or applications
# XMPP, or you can use it for PubSub or general message passing for logstash to
# logstash.
class LogStash::Inputs::Xmpp < LogStash::Inputs::Base
  
  config_name "xmpp"
  milestone 2

  default :codec, "plain"

  # The user or resource ID, like foo@example.com.
  config :user, :validate => :string, :required => :true

  # The xmpp password for the user/identity.
  config :password, :validate => :password, :required => :true

  # if muc/multi-user-chat required, give the name of the room that
  # you want to join: room@conference.domain/nick
  config :rooms, :validate => :array

  # The xmpp server to connect to. This is optional. If you omit this setting,
  # the host on the user/identity is used. (foo.com for user@foo.com)
  config :host, :validate => :string
  config :port, :validate => :number, :default => 5222
  config :use_ssl, :validate => :boolean, :default => false

  # Set to true to enable greater debugging in XMPP. Useful for debugging
  # network/authentication erros.
  config :debug, :validate => :boolean, :default => false, :deprecated => "Use the logstash --debug flag for this instead."


  public
  def register
    require 'xmpp4r' # xmpp4r gem
    Jabber::debug = true if @debug || @logger.debug?

    @client = Jabber::Client.new(Jabber::JID.new(@user))
    @client.use_ssl = @use_ssl
    @client.connect(@host, @port) # it is ok if host is nil
    @client.auth(@password.value)
    @client.send(Jabber::Presence.new.set_type(:available))

    # load the MUC Client if we are joining rooms.
    require 'xmpp4r/muc/helper/simplemucclient' if @rooms && !@rooms.empty?
  end # def register

  public
  def run(queue)
    if @rooms
      @rooms.each do |room| # handle muc messages in different rooms
        @muc = Jabber::MUC::SimpleMUCClient.new(@client)
        @muc.on_message do |time,from,body|
          @codec.decode(body) do |event|
            decorate(event)
            event["room"] = room
            event["from"] = from
            queue << event
          end
        end # @muc.on_message
        @muc.join(room)
      end # @rooms.each
    end # if @rooms

    @client.add_message_callback do |msg| # handle direct/private messages
      # accept normal msgs (skip presence updates, etc)
      if msg.body != nil
        @codec.decode(msg.body) do |event|
          decorate(event)
          # Maybe "from" should just be a hash: 
          # { "node" => ..., "domain" => ..., "resource" => ... }
          event["from"] = "#{msg.from.node}@#{msg.from.domain}/#{msg.from.resource}"
          queue << event
        end
      end
    end # @client.add_message_callback
    sleep
  end # def run

end # class LogStash::Inputs::Xmpp
