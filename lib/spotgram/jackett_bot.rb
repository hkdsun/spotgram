require 'down'
require 'fileutils'
require_relative '../jackett_api'
require_relative '../lru_hash'
require 'securerandom'


module Spotgram
  class JackettBot
    def initialize(api_key)
      @api_key = api_key
    end

    def run
      STDOUT.sync = true

      threadpool = Threadpool.new(8)
      Telegram::Bot::Client.run(@api_key) do |bot|
        bot.listen do |message|
          threadpool.execute do
            ctx = Context.new(bot, message)

            begin
              if message.is_a?(Telegram::Bot::Types::CallbackQuery)
                handle_dl_callback(ctx)
              else
                case message.text
                when '/start'
                  msg = <<~MESSAGE
                    within the land of wonder, only the pure of heart can live, a
                    place where love and wisdom reigns and where people are
                    immune to suffering, want, or old age
                  MESSAGE

                  ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: msg)
                else
                  begin
                    handle_query(ctx)
                  rescue => e
                    puts "Rescued exception while handling message=#{message}: #{e}"
                  end
                end
              end
            end
          end
        end
      end
    end

    private

    Context = Struct.new(
      :bot,
      :message,
      :search_query,
    )

    def handle_dl_callback(ctx)
      cache_id = ctx.message.data.split(" ")[1]
      res_idx = Integer(ctx.message.data.split(" ")[2])

      ctx.bot.api.delete_message(chat_id: ctx.message.message.chat.id,
                                  message_id: ctx.message.message.message_id)

      return if res_idx == -1

      tor = results_cache.read(cache_id)[1][res_idx]

      blackhole_uri = URI.parse(tor['BlackholeLink'])
      req = Net::HTTP::Get.new(blackhole_uri.to_s)
      res = Net::HTTP.start(blackhole_uri.host, blackhole_uri.port) do |http|
        http.request(req)
      end
      res = JSON.parse(res.body)['result']


      if res == 'success'
        info_text = "Okay. Successfully downloading #{tor['Title']}"
      else
        info_text = "Jackett returned an error"
      end
      ctx.bot.api.send_message(chat_id: ctx.message.message.chat.id, text: info_text)
    end

    def handle_query(ctx)
      ctx.search_query = ctx.message.text

      res = JackettAPI.get(ctx.search_query)
      results = res['Results']
      results = results.sort_by { |t| -t['Seeders'] }

      cache_id = SecureRandom.uuid # => "96b0a57c-d9ae-453f-b56f-3b154eb10cda"
      results_cache.store(cache_id, results)

      kb = []
      results[0..10].each_with_index do |tor, idx|
        title = tor.fetch('Title')
        seeders = tor.fetch('Seeders')
        size_bytes = tor.fetch('Size')
        size_gb = (size_bytes.to_f / 2**10 / 2**10 / 2**10).round(2)

        display_title = "S:#{seeders} | #{size_gb}GB | #{title}"
        if size_gb > 10
          display_title = "**WARN: Big file** " + display_title
        end

        kb << Telegram::Bot::Types::InlineKeyboardButton.new(text: display_title, callback_data: "/dl #{cache_id} #{idx}")
      end
      kb << Telegram::Bot::Types::InlineKeyboardButton.new(text: "Cancel", callback_data: "/dl #{cache_id} -1")

      markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)


      ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: "please choose", reply_markup: markup)
    end

    def results_cache
      @cache ||= LRUHash.new(10)
    end
  end
end
