require "bundler/setup"
require "sinatra"
require "sinatra/multi_route"
require "data_mapper"
require "twilio-ruby"
require 'twilio-ruby/rest/messages'
require "sanitize"
require "erb"
require "rotp"
require "haml"
include ERB::Util

set :static, true
set :root, File.dirname(__FILE__)

DataMapper::Logger.new(STDOUT, :debug)
DataMapper::setup(:default, ENV['DATABASE_URL'] || 'postgres://localhost/baby_notify')

class VerifiedUser
  include DataMapper::Resource

  property :id, Serial
  property :code, String, :length => 10
  property :name, String
  property :phone_number, String, :length => 30
  property :verified, Boolean, :default => false
  property :send_mms, Enum[ 'yes', 'no' ], :default => 'no'

  has n, :messages

end

class Baby
  include DataMapper::Resource

  property :id, Serial
  property :name, String
  property :time, String
  property :sex, String
  property :date, String
  property :weight, String
  property :length, String
  property :media_url, String

end

class Message
  include DataMapper::Resource

  property :id, Serial
  property :body, Text
  property :time, DateTime
  property :name, String

  belongs_to :verified_user

end
DataMapper.finalize
DataMapper.auto_upgrade!

before do
  @twilio_number = ENV['TWILIO_NUMBER']
  @client = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN']
  @mmsclient = @client.accounts.get(ENV['TWILIO_SID'])
  
  if params[:error].nil?
    @error = false
  else
    @error = true
  end

end

def sendMessage(from, to, body, media = nil)
  if media.nil?
    message = @client.account.messages.create(
      :from => from,
      :to => to,
      :body => body
    )
  else
    message = @mmsclient.messages.create(
      :from => from,
      :to => to,
      :body => body,
      :media_url => media,
    )
  end
  puts message.to
end

def createUser(name, phone_number, send_mms, verified)
  user = VerifiedUser.create(
    :name => name,
    :phone_number => phone_number,
    :send_mms => send_mms,
  )
  if verified == true
    user.verified = true
    user.save
  end
  Twilio::TwiML::Response.new do |r|
    r.Message "Awesome, #{name} at #{phone_number} you have been added to the Reyes family babynotify.me account."
  end.text
end

get "/" do
  haml :index
end

get "/signup" do
  haml :signup
end

get '/gotime' do
  haml :gotime
end

get '/notify' do
  Twilio::TwiML::Response.new do |r|
    r.Say 'The baby is Here!'
  end.text
end

get '/twilions' do
  haml :twilions
end

get '/success' do
  haml :success
end

get '/kindthings' do
  @messages = Message.all
  haml :messages
end

get '/users/' do
  @users = VerifiedUser.all
  haml :users
end

# Receive messages twilio app endpoint - inbound
route :get, :post, '/receiver' do
  @phone_number = Sanitize.clean(params[:From])
  @body = params[:Body]
  @time = DateTime.now

  # Find the user associated with this number if there is one
  @messageUser = VerifiedUser.first(:phone_number => @phone_number)

  # If there is no messageUser lets go ahead and create one
  if @messageUser.nil?
    # If the user did not send a name assume they are a Twilion
    @body = 'Twilion' if @body.empty?
    createUser(@body, @phone_number, 'yes', true)
  else
    # Since the user exists add the message to their profile
    @messageUser.messages.create(
      :name => @messageUser.name,
      :time => @time,
      :body => @body
    )
  end
end

# Register a subscriber through the web and send verification code
route :get, :post, '/register' do
  @phone_number = Sanitize.clean(params[:phone_number])
  if @phone_number.empty?
    redirect to("/?error=1")
  end

  begin
    if @error == false
      user = VerifiedUser.create(
        :name => params[:name],
        :phone_number => @phone_number,
        :send_mms => params[:send_mms]
      )

      if user.verified == true
        @phone_number = url_encode(@phone_number)
        redirect to("/verify?phone_number=#{@phone_number}&verified=1")
      end
      totp = ROTP::TOTP.new("drawtheowl")
      code = totp.now
      user.code = code
      user.save

      sendMessage(@twilio_number, @phone_number, "Your verification code is #{code}")
    end
    erb :register
  rescue
    redirect to("/?error=2")
  end
end

# Send the notification to all of your subscribers
route :get, :post, '/notify_all' do
  @users = VerifiedUser.all
  @name = params[:name]
  @time = params[:time]
  @sex = params[:sex]
  @date = params[:date]
  @weight = params[:weight]
  @media_url = params[:filepicker_url]

  baby = Baby.create(
    :name => @name,
    :time => params[:time]
    :sex => params[:sex]
    :date => params[:date]
    :weight => params[:weight]
    :media_url => params[:filepicker_url]
  )

  msg = "Jarod and Sarah have very exciting news! At #{@time} on #{@date} a beautiful little #{@sex} named #{@baby_name} was born. Let the celebrations begin!"
  @users.each do |user|
    if user.verified == true
      @phone_number = user.phone_number
      @name = user.name
      if user.send_mms == 'yes'
        sendMessage('TWILIO', @phone_number, "Hi #{@name}! #{msg}", baby.media_url)
      else
        sendMessage(@twilio_number, @phone_number, "Hi #{@name}! #{msg}")
      end
    end
  end
  erb :hurray
end

# Endpoint for verifying code was correct
route :get, :post, '/verify' do

  @phone_number = Sanitize.clean(params[:phone_number])

  @code = Sanitize.clean(params[:code])
  user = VerifiedUser.first(:phone_number => @phone_number)
  if user.verified == true
    @verified = true
  elsif user.nil? or user.code != @code
    @phone_number = url_encode(@phone_number)
    redirect to("/register?phone_number=#{@phone_number}&error=1")
  else
    user.verified = true
    user.save
  end
  erb :verified
end