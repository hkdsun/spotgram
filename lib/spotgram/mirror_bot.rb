require 'down'
require 'fileutils'

module Spotgram
  class MirrorBot
    def initialize(api_key, admin_user_id, storage_root, log_chat: nil)
      @api_key = api_key
      @admin_user_id = admin_user_id
      @log_chat = log_chat
      @storage_root = storage_root

      raise "storage root=#{@storage_root} doesn't exist" unless File.directory?(@storage_root)
    end

    def run
      STDOUT.sync = true

      threadpool = Threadpool.new(8)
      Telegram::Bot::Client.run(@api_key) do |bot|
        bot.listen do |message|
          threadpool.execute do
            ctx = Context.new(bot, message)

            begin
              case message.text
              when '/start'
                msg = <<~MESSAGE
                  within the land of wonder, only the pure of heart can live, a
                  place where love and wisdom reigns and where people are
                  immune to suffering, want or old age
                MESSAGE

                ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: msg)
              else
                begin
                  handle_message(ctx)
                rescue => e
                  puts "Rescued exception while handling message=#{message}: #{e}"
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
      :chatroom,
    )

    def handle_message(ctx)
      ctx.chatroom = ctx.message.chat.title || "unknown"

      if (audio = ctx.message.audio)
        title = audio.title || "Unknown Title"
        performer = audio.performer || "Unknown Artist"
        unique_id = audio.file_unique_id
        file_id = audio.file_id

        res = ctx.bot.api.get_file(file_id: file_id)
        unless res['ok']
          raise NotImplementedError
        end

        file_path = res['result']['file_path']
        unless file_path.end_with?(".mp3")
          raise NotImplementedError
        end

        original_ext = "mp3"

        url = "https://api.telegram.org/file/bot#{@api_key}/#{file_path}"

        ctx.bot.api.send_message(chat_id: @log_chat, text: "[Eagle] hunting new audio from #{ctx.chatroom}")

        tempfile = Down.download(url)

        dest_dir = "#{@storage_root}/spoteagle.#{ctx.chatroom}"
        unless File.directory?(dest_dir)
          Dir.mkdir(dest_dir)
        end

        dest_path = "#{dest_dir}/#{performer} - #{title} - #{unique_id}.#{original_ext}"
        FileUtils.mv(tempfile.path, dest_path)
      end
    end
  end
end
