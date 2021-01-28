require 'down'
require 'fileutils'
require_relative '../jackett_api'

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
      require 'byebug'; byebug
      # /dl homecoming 0
      d = ctx.message.data.split(" ")
    end

    def handle_query(ctx)
      ctx.search_query = ctx.message.text

      res = JackettAPI.get(ctx.search_query)
      results = res['Results']

      kb = []
      results[0..10].each_with_index do |tor, idx|
        title = tor['Title']
        # blackhole_link = tor.fetch('BlackholeLink')
        kb << Telegram::Bot::Types::InlineKeyboardButton.new(text: title, callback_data: "/dl #{ctx.search_query} #{idx}")
      end

      markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)


      ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: "please choose", reply_markup: markup)
    end
  end
end
