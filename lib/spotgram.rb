require "spotgram/version"
require "telegram/bot"
require 'open3'
require 'concurrent-ruby'

module Spotgram
  class Threadpool
    def initialize(num_workers)
      @semaphore ||= Concurrent::Semaphore.new(num_workers)
    end

    def execute
      @semaphore.acquire
      Thread.new do
        begin
          yield
        ensure
          @semaphore.release
        end
      end
    end
  end

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

      threadpool = Threadpool.new(8)
      Telegram::Bot::Client.run(@api_key) do |bot|
        bot.listen do |message|
          ctx = Context.new(bot, message)

          begin
            case message.text
            when '/start'
              puts "[Access Log] joined: username=#{message.from.username} first_name=#{message.from.first_name}"
              txt = "Hello, #{message.from.first_name}. Send me any Spotify/Youtube link and I'll convert it to mp3. You can even share it directly from the apps"
              bot.api.send_message(chat_id: message.chat.id, text: txt)
            else
              threadpool.execute do
                puts "[Access Log] received: username=#{message.from.username} text=#{message.text}"
                handle_message(ctx)
              end
            end
          rescue => e
            puts "Rescued exception while handling message=#{message}: #{e}"
          end
        end
      end
    end

    private

    Context = Struct.new(
      :bot,
      :message,
      :last_msg,
      :filename,
      :youtube_link,
      :spotify_link,
      :artist,
      :track,
      :youtube_title,
      :song_info_page,
    )

    def handle_message(ctx)
      new_text_msg(ctx, "🔎 Let me find your song on youtube.\n\nTip: I also accept direct youtube links")

      # "Handle query"
      query_link = extract_spotify_link(ctx.message.text)
      return set_progress_txt(ctx, "😔 Couldn't find link") if query_link.nil?

      if query_link.match(/youtube.com/)
        ctx.youtube_link = query_link
      elsif query_link.match(/spotify/)
        ctx.spotify_link = query_link
        return set_progress_txt(ctx, "😔 Not supported yet. Share tracks instead of albums") if query_link.match(/album/)
      else
        return set_progress_txt(ctx, "😔 Link not supported")
      end

      fetch_youtube_link(ctx)
      if ctx.youtube_link
        download_youtube_metadata(ctx)

        ctx.song_info_page = "\n\nVideo Link: #{ctx.youtube_link}"
        ctx.song_info_page += "\nVideo Title: #{ctx.youtube_title}" if ctx.youtube_title
        ctx.song_info_page += "\nSong Arist: #{ctx.artist}" if ctx.artist
        ctx.song_info_page += "\nSong Title: #{ctx.track}" if ctx.track

        set_progress_txt(ctx, "🏃‍♀️ Converting from youtube" + ctx.song_info_page)
      else
        new_text_msg(ctx, "😔 Couldnt find the youtube link. Try pasting a youtube link?")
        return
      end

      download_youtube_audio(ctx)

      if ctx.filename
        set_progress_txt(ctx, "💈 Uploading file" + ctx.song_info_page)

        send_audio(ctx, ctx.filename, title: ctx.track, performer: ctx.artist)
        set_progress_txt(ctx, "📻 See you later" + ctx.song_info_page)
      else
        new_text_msg(ctx, "😔 Couldnt download that youtube link, sorry")
      end
    end

    def download_youtube_metadata(ctx)
      cmd = [
        "youtube-dl",
        "-j",
        ctx.youtube_link,
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      if status.success?
        yt_metadata = JSON.parse(stdout)

        ctx.artist = yt_metadata['artist'] if yt_metadata['artist']
        ctx.track = yt_metadata['track'] if yt_metadata['track']
        ctx.youtube_title = yt_metadata['title'] if yt_metadata['title']
      else
        puts "error downloading metadata"
        puts stdout, stderr
      end

    end

    def new_text_msg(ctx, text)
      msg = ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: text)
      ctx.last_msg = msg if msg['ok']
    end

    def set_progress_txt(ctx, text)
      ctx.bot.api.edit_message_text(
        chat_id: ctx.message.chat.id,
        message_id: ctx.last_msg['result']['message_id'],
        text: text,
        disable_web_page_preview: true
      )
    end

    def send_audio(ctx, filename, **args)
      ctx.bot.api.send_audio(**args, chat_id: ctx.message.chat.id, audio: Faraday::UploadIO.new(filename, 'audio/mp3'), )
    end

    def extract_spotify_link(msg)
      matches = msg.match(LINKS_RE)
      return matches && matches[0].split(" ")[0]
    end

    def fetch_youtube_link(ctx)
      return if ctx.youtube_link

      spotify_link = ctx.spotify_link
      cmd = [
        "spotdl",
        "-d",
        "-s",
        spotify_link
      ]

      _, stderr, status = Open3.capture3(*cmd)
      if status.success?
        matches = stderr.match(/(http.*)\)/)
        ctx.youtube_link = matches && matches[1]
      end
    end

    def get_youtube_dl_filename(youtube_link)
      stdout, stderr, status = Open3.capture3(
        "youtube-dl",
        "--get-filename",
        "--audio-format",
        "mp3",
        "-o",
        "./tmp/downloads/%(title)s.mp3",
        youtube_link
      )

      if status.success?
        return stdout.chomp
      else
        puts "failed to get filename"
        puts stdout, stderr
      end
    end

    def progress_indicator(ctx, text)
      random_emoji = ["😀","😁","😂","😃","😄","😅","😆","😇","😈","👿","😉",
                    "😊","☺️","😋","😌","😍","😎","😏","😐","😑","😒","😓",
                    "😔","😕","😖"].sample
      set_progress_txt(ctx, "#{random_emoji} #{text}" + ctx.song_info_page)
    rescue => e
      puts "WARN: #{e}"
    end

    def download_youtube_audio(ctx)
      youtube_link = ctx.youtube_link
      output_filename = get_youtube_dl_filename(youtube_link)
      return unless output_filename

      stdin, stdouts, wait_thr = Open3.popen2e(
        "youtube-dl",
        "--extract-audio",
        "--continue",
        "--no-post-overwrites",
        "--no-overwrites",
        "--no-playlist",
        "--ignore-errors",
        "--add-metadata",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "--no-mtime",
        "-o",
        "./tmp/downloads/%(title)s.%(ext)s",
        youtube_link,
      )
      stdin.close

      start_time = Time.now.to_i
      while wait_thr.alive?
        progress_indicator(ctx, "Downloading youtube audio..")
        sleep 2

        elapsed = Time.now.to_i - start_time
        if elapsed > 5 * 60
          Process.kill("KILL",wait_thr.pid)
          new_text_msg(ctx, "😔 That took a long time. Gave up")
        end
      end

      if wait_thr.value.success?
        puts "downloaded successfully"
        ctx.filename = output_filename
      else
        puts "failed to download"
        puts stdouts.read
      end
    ensure
      stdouts.close
    end

    def upgrade_youtube_dl
      puts "Attempting to upgrade youtube-dl"
      puts `youtube-dl -U`
    end
  end
end
