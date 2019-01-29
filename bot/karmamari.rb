# frozen_string_literal: true

require 'slack-ruby-bot'
require 'redis'

# A class to keep all of the ENVironment variable calls in one place
# Stores a redis client, too.
class KarmamariConfig
  attr_accessor :redis_host, :redis_pass, :redis_client

  def initialize
    @redis_host = ENV.fetch('REDIS_HOST',
                            'karma-redis.default.svc.cluster.local')
    @redis_pass = ENV.fetch 'REDIS_PASS', ''
    @redis_client = Redis.new(host: @redis_host, password: @redis_pass)
  end
end

# The bot!
class Karmamari < SlackRubyBot::Bot
  attr_accessor :users
  attr_reader :config

  help do
    title 'Karma Bot'

    desc <<~WORDS
      This bot lets you add and remove karma from things.
      Achievements included! Add ++ or -- to any word/emoji.
    WORDS

    command 'achievement <karma> <message>' do
      desc 'Adds an achievement to a specified karma score'
      long_desc 'Allows you to set an achievement message when a user hits a certain karma.'
    end
  end

  def self.achievements(scores)
    scores.map! do |karma|
      q = @config.redis_client.get("KM:#{karma}")
      q.nil? ? nil : "ACHIEVEMENT UNLOCKED: #{karma}: #{q}"
    end
    (scores - [nil]).sort.uniq
  end

  def self.id_to_nick(id)
    id = id.upcase.gsub '<>@+-', ''
    user = @users.find { |u| u['id'].upcase == id } || {}
    user.fetch('name', id).gsub(/^@/, '')
  end

  # @param [karma_deltas] Hash{String: Int}
  # 
  def self.commit_scores(karma_deltas)
    final_scores = {}

    # this can probably become a .map
    karma_deltas.each do |word, offset|
      final_scores[word] = @config.redis_client.incrby(word, offset).to_i
    rescue Redis::CannotConnectError
      @config.redis_client = Redis.new host: @config.redis_host, password: @config.redis_pass
      final_scores[word] = @config.redis_client.incrby(word, offset).to_i
    end
    final_scores
  end

  command 'achievement' do |client, data, _|
    @config ||= KarmamariConfig.new

    # <@UFHN23EH2> achievement 15 yoloswag
    rxp = /(<@\w+> achievement )(\d+)(.*)/

    _x, karma, quip = data['text'].scan(rxp).flatten.map(&:strip)
    @config.redis_client.set("KM:#{karma}", quip)
    client.say text: "Set #{karma} to #{quip}", channel: data.channel
  end

  match(/(\S+)[ ]?(\+\+|--)/) do |client, data, match|
    @config ||= KarmamariConfig.new
    @users = client.web_client.users_list['members']

    # data.text
    utterance = data.text
    @users ||= client.web_client.users_list['members']

    liked = utterance.downcase.scan(/(\S+)[ ]?\+\+/).flatten
    disliked = utterance.downcase.scan(/(\S+)[ ]?--/).flatten

    # TODO: validate if user is allowed to mutate karma scores
    # so you can't give yourself points

    karma_delta_by_object = liked.each_with_object(Hash.new(0)) do |word, counts|
      counts[word] += 1
    end

    disliked.each_with_object(Hash.new(0)) do |word, _|
      karma_delta_by_object[word] -= 1
    end

    kdelta_nested_list = karma_delta_by_object.map do |name, karma|
      if name.match?(/<@\w+>/)
        [id_to_nick(name), karma]
      else
        [name, karma]
      end
    end

    final_scores = commit_scores Hash[kdelta_nested_list]

    score_lookups = final_scores.map do |word, score|
      # (5..2).to_a returns an empty Array,
      # which is why we play Ranger ordering games here
      if karma_delta_by_object[word].positive?
        ((score - karma_delta_by_object[word])..score).to_a
      else
        (score..(score - karma_delta_by_object[word])).to_a
      end
    end.flatten.sort.uniq

    achievements_text = achievements(score_lookups)
    output = final_scores.map { |w, s| "#{w} now has #{s} karma." }.join "\n"

    client.say(text: [output, achievements_text].join("\n"),
               channel: data.channel)
  end
end

Karmamari.run
