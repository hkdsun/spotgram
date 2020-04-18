require "spotgram/version"
require "telegram/bot"
require 'open3'

module Spotgram
  class Bot
    LINKS_RE = /(^(http|https):\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?$)/ix
    STORAGE = "#{ENV['HOME']}/.spotgram"

    def initialize(api_key)
      @api_key = api_key

      unless File.directory?(STORAGE)
        Dir.mkdir(STORAGE)
      end
    end

    def run
      STDOUT.sync = true

      Thread.new do
        one_hour = 60 * 60
        last_update = 0
        loop do
          time_since_update = Time.now.to_i - last_update
          if time_since_update > one_hour
            upgrade_youtube_dl
            last_update = Time.now.to_i
          end
          sleep 5
        end
      end

      Telegram::Bot::Client.run(@api_key) do |bot|
        bot.listen do |message|
          begin
            case message.text
            when '/start'
              puts "[Access Log] joined: username=#{message.from.username} first_name=#{message.from.first_name}"
              txt = "Hello, #{message.from.first_name}. Send me any Spotify link and I'll convert it to mp3. You can even share it to this chat from the Spotify app directly"
              bot.api.send_message(chat_id: message.chat.id, text: txt)
            else
              puts "[Access Log] received: username=#{message.from.username} text=#{message.text}"
              handle_message(bot, message)
            end
          rescue => e
            puts "Rescued exception while handling message=#{message}: #{e}"
          end
        end
      end
    end

    private

    def upgrade_youtube_dl
      puts "Attempting to upgrade youtube-dl"
      puts `youtube-dl -U`
    end

    def handle_message(bot, message)
      first_msg = bot.api.send_message(chat_id: message.chat.id, text: "Let me find your song on youtube")
      return unless first_msg['ok']

      sp_link = extract_spotify_link(message.text)
      unless sp_link
        bot.api.edit_message_text(
          chat_id: message.chat.id,
          message_id: first_msg['result']['message_id'],
          text: "Couldn't find a Spotify link there. You sure?",
          disable_web_page_preview: true
        )
        return
      end

      yt_link = spotify_to_yt_link(sp_link)
      if yt_link
        bot.api.edit_message_text(
          chat_id: message.chat.id,
          message_id: first_msg['result']['message_id'],
          text: "Found this on youtube.. let me convert it..\n#{yt_link}",
          disable_web_page_preview: true
        )
      else
        bot.api.send_message(chat_id: message.chat.id, text: "Couldnt convert Spotify to Youtube, sorry")
        return
      end

      filename = get_yt_mp3(yt_link)
      if filename
        bot.api.edit_message_text(
          chat_id: message.chat.id,
          message_id: first_msg['result']['message_id'],
          text: "I have the file ready. Uploading it on my slowass internet now"
        )

        bot.api.send_audio(chat_id: message.chat.id, audio: Faraday::UploadIO.new(filename, 'audio/mp3'))
      else
        bot.api.send_message(chat_id: message.chat.id, text: "Couldnt download that youtube link, sorry")
      end
    end

    def extract_spotify_link(msg)
      matches = msg.match(LINKS_RE)
      return matches && matches[0].split(" ")[0]
    end

    def spotify_to_yt_link(spotify_link)
      cmd = [
        "spotdl",
        "-d",
        "-s",
        spotify_link
      ]

      _, stderr, status = Open3.capture3(*cmd)
      if status.success?
        matches = stderr.match(/(http.*)\)/)
        return matches && matches[1]
      end
    end

    def get_youtube_dl_filename(yt_link)
      stdout, stderr, status = Open3.capture3(
        "youtube-dl",
        "--get-filename",
        "--audio-format",
        "mp3",
        "-o",
        "./tmp/downloads/%(title)s.mp3",
        yt_link
      )

      if status.success?
        return stdout.chomp
      else
        puts "failed to get filename"
        puts stdout, stderr
      end
    end

    def get_yt_mp3(yt_link)
      output_filename = get_youtube_dl_filename(yt_link)
      return unless output_filename

      stdout, stderr, status = Open3.capture3(
        "youtube-dl",
        "--extract-audio",
        "--continue",
        "--no-post-overwrites",
        "--no-overwrites",
        "--ignore-errors",
        "--add-metadata",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "--no-mtime",
        "-o",
        "./tmp/downloads/%(title)s.%(ext)s",
        yt_link,
      )

      if status.success?
        puts "downloaded successfully"
        return output_filename
      else
        puts "failed to download"
        puts stdout, stderr
      end
    end
  end
end
