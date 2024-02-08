# typed: false

class Mastodon
  def self.enabled?
    defined?(Mastodon::TOKEN.present?)
  end

  # these need to be overridden in config/initializers/production.rb
  cattr_accessor :INSTANCE_NAME, :BOT_NAME, :CLIENT_ID, :CLIENT_SECRET, :TOKEN, :LIST_ID

  @@INSTANCE_NAME = nil
  @@BOT_NAME = nil
  @@CLIENT_ID = nil
  @@CLIENT_SECRET = nil
  @@TOKEN = nil
  @@LIST_ID = nil

  MAX_STATUS_LENGTH = 500 # https://docs.joinmastodon.org/user/posting/#text
  LINK_LENGTH = 23 # https://docs.joinmastodon.org/user/posting/#links

  def self.accept_follow_request(id)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/follow_requests/#{id}/authorize",
      :post,
      {limit: 80},
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to accept follow request #{id}" if response.nil?
  end

  def self.add_list_accounts(accts)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/lists/#{self.LIST_ID}/accounts",
      :post,
      nil,
      accts.map { |i| "account_ids[]=#{i}" }.join("&"),
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to add to list" if response.nil? || puts(response.body) || JSON.parse(response.body) != {}
  end

  def self.follow_account(id)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/accounts/#{id}/follow",
      :post,
      {reblogs: false},
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to follow #{id}" if response.nil?
  end

  def self.get_account_id(acct)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/accounts/search",
      :get,
      nil,
      {q: acct, limit: 80, resolve: true},
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to lookup #{acct}" if response.nil?
    accounts = JSON.parse(response.body)

    account = accounts.find { |a| a["acct"] == acct }
    # treehouse.systems is hosted at social.treehouse.systems
    # no idea why that's inconsistent or a better way to reconcile
    account = accounts.find { |a| acct.split("@").first } if account.nil?
    raise "did not find acct #{acct} in #{accounts}" if account.nil?
    account["id"]
  end

  # returns list of ids for accept_follow_request calls
  def self.get_follow_requests
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/follow_requests",
      :get,
      nil,
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    accounts = JSON.parse(response.body)
    accounts.pluck("id")
  end

  # returns { "user@example.com" => 123 } for remove_list_accounts call
  def self.get_list_accounts
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/lists/#{self.LIST_ID}/accounts",
      :get,
      {limit: 0},
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    accounts = JSON.parse(response.body)
    accounts.map { |a| [a["acct"], a["id"]] }.to_h
  end

  def self.post(status)
    s = Sponge.new
    s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/statuses",
      :post,
      {
        status: status,
        visibility: "public"
      },
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
  end

  def self.remove_list_accounts(ids)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/lists/#{self.LIST_ID}/accounts",
      :delete,
      {account_ids: ids},
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to remove from list" if response.nil? || JSON.parse(response.body) != {}
  end

  def self.unfollow_account(id)
    s = Sponge.new
    response = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/accounts/#{id}/unfollow",
      :post,
      {account_ids: ids},
      nil,
      {"Authorization" => "Bearer #{self.TOKEN}"}
    )
    raise "failed to remove from list" if response.nil? || JSON.parse(response.body) != {}
  end

  def self.get_bot_credentials!
    raise "instructions in production.rb.sample" unless self.INSTANCE_NAME && self.BOT_NAME

    if !self.CLIENT_ID || !self.CLIENT_SECRET
      s = Sponge.new
      url = "https://#{self.INSTANCE_NAME}/api/v1/apps"
      res = s.fetch(
        url,
        :post,
        client_name: Rails.application.domain,
        redirect_uris: [
          "https://#{Rails.application.domain}/settings"
        ].join("\n"),
        scopes: "read write",
        website: "https://#{Rails.application.domain}"
      )
      if res.nil? || res.body.blank?
        errors.add :base, "App registration failed, is #{self.INSTANCE_NAME} a Mastodon instance?"
        return
      end
      reg = JSON.parse(res.body)
      raise "no json" if !reg
      raise "no client_id" if reg["client_id"].blank?
      raise "no client_secret" if reg["client_secret"].blank?

      puts "Mastodon.CLIENT_ID = \"#{reg["client_id"]}\""
      puts "Mastodon.CLIENT_SECRET = \"#{reg["client_secret"]}\""
    end

    client_id = self.CLIENT_ID || reg["client_id"]
    client_secret = self.CLIENT_SECRET || reg["client_secret"]

    puts
    puts "open this URL and authorize read/write access for the bot account"
    puts "you'll get redirected to /settings?code=..."
    puts "https://#{self.INSTANCE_NAME}/oauth/authorize?response_type=code&client_id=#{client_id}&scope=read+write&redirect_uri=" +
      CGI.escape(
        "https://#{Rails.application.domain}/settings"
      )
    puts

    puts "what is the value after code= (not the whole URL, just what's after the =)"
    code = gets.chomp

    s = Sponge.new
    res = s.fetch(
      "https://#{self.INSTANCE_NAME}/oauth/token",
      :post,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: CGI.escape("https://#{Rails.application.domain}/settings"),
      grant_type: "authorization_code",
      code: code,
      scope: "read write"
    )
    raise "mastodon getting user token failed, response from #{self.INSTANCE_NAME} was nil" if res.nil?
    ps = JSON.parse(res.body)
    tok = ps["access_token"]
    raise "no token" if tok.blank?

    headers = {"Authorization" => "Bearer #{tok}"}
    res = s.fetch(
      "https://#{self.INSTANCE_NAME}/api/v1/accounts/verify_credentials",
      :get,
      nil,
      nil,
      headers
    ).body
    js = JSON.parse(res)
    puts "uhh Mastodon.BOT_NAME='#{Mastodon.BOT_NAME}' but the instance thinks it's '#{js["username"]}' and the instance wins that disagreement" if Mastodon.BOT_NAME != js["username"]

    puts
    puts "Mastodon.TOKEN = \"#{tok}\""
    puts
    puts "copy the three values above to your config/initializers/production.rb"
    true
  end
end
